import Foundation
import PDFKit

/// The self-contained state carried by a PDF transfer.
public struct ReaderTransferMetadata: Codable, Hashable, Sendable {
  public var version: Int
  /// Stable identity for the transferred document across PDF rewrites.
  public var documentID: String?
  public var annotations: [ReaderAnnotation]
  public var quickLinks: [ReaderQuickLink]
  public var readingState: ReadingState

  public init(
    version: Int = 1,
    annotations: [ReaderAnnotation],
    quickLinks: [ReaderQuickLink],
    readingState: ReadingState,
    documentID: String? = nil
  ) {
    self.version = version
    self.documentID = documentID
    self.annotations = annotations
    self.quickLinks = quickLinks
    self.readingState = readingState
  }
}

public enum ReaderTransferPDFError: Error, Equatable, LocalizedError, Sendable {
  case invalidPDF
  case malformedMetadata
  case unsupportedMetadataVersion(Int)
  case metadataTooLarge
  case missingPage(Int)
  case impossibleBox(String)
  case couldNotSerialize
  case metadataNotPersisted

  public var errorDescription: String? {
    switch self {
    case .invalidPDF:
      return ReaderLocalization.resolve("The PDF could not be opened.")
    case .malformedMetadata:
      return ReaderLocalization.resolve("The PDF contains malformed transfer metadata.")
    case .unsupportedMetadataVersion(let version):
      return ReaderLocalization.string("The PDF uses unsupported transfer metadata version {0}.", String(version))
    case .metadataTooLarge:
      return ReaderLocalization.resolve("The PDF transfer metadata is too large.")
    case .missingPage(let page):
      return ReaderLocalization.string("Transfer data references missing PDF page {0}.", String(page))
    case .impossibleBox(let value):
      return ReaderLocalization.string("Transfer data contains an impossible box for {0}.", value)
    case .couldNotSerialize:
      return ReaderLocalization.resolve("The transferred PDF could not be serialized.")
    case .metadataNotPersisted:
      return ReaderLocalization.resolve("The transferred PDF did not preserve its metadata.")
    }
  }
}

/// Embeds annotations, quick links, and reader state directly into a PDF.
public enum ReaderTransferPDF {
  public static let metadataVersion = 1

  private static let metadataAttributeName = "PDFMathReaderTransfer"
  private static let metadataAnnotationKey = PDFAnnotationKey(rawValue: metadataAttributeName)
  private static let metadataMarkerKey = PDFAnnotationKey(rawValue: "PDFMathReaderTransferMetadata")
  private static let metadataMarker = "PDFMathReaderTransferMetadata:v1"
  private static let quickLinkKey = PDFAnnotationKey(rawValue: "PDFMathReaderQuickLink")
  private static let maximumMetadataBytes = 4 * 1024 * 1024

  /// Writes a portable copy of a PDF with all supplied reader state embedded.
  public static func export(
    sourceData: Data,
    annotations: [ReaderAnnotation],
    quickLinks: [ReaderQuickLink],
    readingState: ReadingState,
    nativeRefs: [String] = []
  ) throws -> Data {
    guard sourceData.count <= ReaderAnnotationLimits.maximumPDFBytes,
      let sourceDocument = PDFDocument(data: sourceData),
      sourceDocument.pageCount > 0
    else {
      if sourceData.count > ReaderAnnotationLimits.maximumPDFBytes {
        throw ReaderAnnotationValidationError.pdfTooLarge
      }
      throw ReaderTransferPDFError.invalidPDF
    }

    // A pre-existing transfer marker must be readable before it is replaced.
    // This prevents a corrupt marker from being silently discarded on export.
    let existingMetadata = try metadata(from: sourceDocument)

    let normalizedAnnotations = try ReaderAnnotationValidator.validate(annotations)
    let normalizedQuickLinks = try ReaderQuickLinkValidator.validate(quickLinks)
    try validatePageReferences(
      annotations: normalizedAnnotations,
      quickLinks: normalizedQuickLinks,
      readingState: readingState,
      in: sourceDocument
    )
    let documentID = existingMetadata?.documentID ?? UUID().uuidString
    try validateDocumentID(documentID)

    let metadataValue = ReaderTransferMetadata(
      version: metadataVersion,
      annotations: normalizedAnnotations,
      quickLinks: normalizedQuickLinks,
      readingState: readingState,
      documentID: documentID
    )
    let metadataJSON = try encodedMetadata(metadataValue)

    // The data overload prepares foreign native annotations using their exact
    // indirect references. It also removes managed annotations when the input
    // array is empty, which is required when a user deleted all annotations.
    let preparedData = try ReaderAnnotationPDF.embedAnnotations(
      normalizedAnnotations,
      in: sourceData,
      nativeRefs: Array(Set(nativeRefs + normalizedAnnotations.compactMap(\.nativeRef)))
    )
    guard let preparedDocument = PDFDocument(data: preparedData) else {
      throw ReaderTransferPDFError.invalidPDF
    }
    // PDFPage.copy() preserves annotation payloads but drops PDFKit's custom
    // `/NM` value. Remove the managed copies before cloning pages so the final
    // annotation pass cannot mistake them for foreign comments.
    removeManagedReaderAnnotations(from: preparedDocument)
    let document = try makePortableDocument(from: preparedDocument)

    try setDocumentMetadata(metadataJSON, in: document)
    removeManagedTransferAnnotations(from: document)
    try addMetadataFallback(metadataJSON, to: document)
    removeManagedQuickLinks(from: document)
    try addQuickLinks(normalizedQuickLinks, to: document)

    // Re-run the existing annotation writer so PDFKit's `/NM` loss is repaired
    // after the metadata/link pass. Link and fallback markers use separate
    // custom keys and therefore survive this managed annotation rewrite.
    guard let documentData = document.dataRepresentation() else {
      throw ReaderTransferPDFError.couldNotSerialize
    }
    let output = try ReaderAnnotationPDF.embedAnnotations(
      normalizedAnnotations,
      in: documentData,
      nativeRefs: normalizedAnnotations.compactMap(\.nativeRef)
    )
    guard output.count <= ReaderAnnotationLimits.maximumPDFBytes,
      let reloaded = PDFDocument(data: output)
    else {
      if output.count > ReaderAnnotationLimits.maximumPDFBytes {
        throw ReaderAnnotationValidationError.pdfTooLarge
      }
      throw ReaderTransferPDFError.couldNotSerialize
    }
    guard try metadata(from: reloaded) == metadataValue else {
      throw ReaderTransferPDFError.metadataNotPersisted
    }
    return output
  }

  /// Reads the embedded transfer state. Missing metadata returns `nil`.
  public static func metadata(from document: PDFDocument) throws -> ReaderTransferMetadata? {
    let key = PDFDocumentAttribute(rawValue: metadataAttributeName)
    if let value = document.documentAttributes?[key] {
      guard let string = value as? String else {
        throw ReaderTransferPDFError.malformedMetadata
      }
      return try decodeMetadata(string, in: document)
    }

    var fallbackValues: [String] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in page.annotations {
        guard annotation.value(forAnnotationKey: metadataMarkerKey) as? String == metadataMarker else {
          continue
        }
        guard let value = annotation.value(forAnnotationKey: metadataAnnotationKey) as? String else {
          throw ReaderTransferPDFError.malformedMetadata
        }
        fallbackValues.append(value)
      }
    }

    guard let first = fallbackValues.first else { return nil }
    guard fallbackValues.allSatisfy({ $0 == first }) else {
      throw ReaderTransferPDFError.malformedMetadata
    }
    return try decodeMetadata(first, in: document)
  }

  private static func encodedMetadata(_ metadata: ReaderTransferMetadata) throws -> String {
    guard metadata.version == metadataVersion else {
      throw ReaderTransferPDFError.unsupportedMetadataVersion(metadata.version)
    }
    try validateDocumentID(metadata.documentID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(metadata)
    guard data.count <= maximumMetadataBytes else {
      throw ReaderTransferPDFError.metadataTooLarge
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func decodeMetadata(
    _ string: String,
    in document: PDFDocument
  ) throws -> ReaderTransferMetadata {
    let data = Data(string.utf8)
    guard data.count <= maximumMetadataBytes else {
      throw ReaderTransferPDFError.metadataTooLarge
    }
    let metadata: ReaderTransferMetadata
    do {
      metadata = try JSONDecoder().decode(ReaderTransferMetadata.self, from: data)
    } catch {
      throw ReaderTransferPDFError.malformedMetadata
    }
    guard metadata.version == metadataVersion else {
      throw ReaderTransferPDFError.unsupportedMetadataVersion(metadata.version)
    }
    try validateDocumentID(metadata.documentID)
    do {
      _ = try ReaderAnnotationValidator.validate(metadata.annotations)
      _ = try ReaderQuickLinkValidator.validate(metadata.quickLinks)
    } catch {
      throw ReaderTransferPDFError.malformedMetadata
    }
    try validatePageReferences(
      annotations: metadata.annotations,
      quickLinks: metadata.quickLinks,
      readingState: metadata.readingState,
      in: document
    )
    return metadata
  }

  private static func validateDocumentID(_ documentID: String?) throws {
    guard let documentID else { return }
    guard !documentID.isEmpty, documentID.utf8.count <= 64,
      UUID(uuidString: documentID) != nil
    else {
      throw ReaderTransferPDFError.malformedMetadata
    }
  }

  private static func makePortableDocument(from source: PDFDocument) throws -> PDFDocument {
    let output = PDFDocument()
    output.documentAttributes = source.documentAttributes

    for index in 0..<source.pageCount {
      guard let sourcePage = source.page(at: index),
        let copiedPage = sourcePage.copy() as? PDFPage
      else {
        throw ReaderTransferPDFError.invalidPDF
      }
      output.insert(copiedPage, at: output.pageCount)
    }

    if let root = source.outlineRoot {
      output.outlineRoot = copyOutline(
        root,
        sourceDocument: source,
        outputDocument: output
      )
    }
    return output
  }

  private static func copyOutline(
    _ sourceOutline: PDFOutline,
    sourceDocument: PDFDocument,
    outputDocument: PDFDocument
  ) -> PDFOutline {
    let copy = PDFOutline()
    copy.label = sourceOutline.label
    copy.isOpen = sourceOutline.isOpen

    if let sourceDestination = sourceOutline.destination,
      let sourcePage = sourceDestination.page
    {
      let index = sourceDocument.index(for: sourcePage)
      if index >= 0, index < sourceDocument.pageCount,
        let outputPage = outputDocument.page(at: index)
      {
        let destination = PDFDestination(page: outputPage, at: sourceDestination.point)
        destination.zoom = sourceDestination.zoom
        copy.destination = destination
      }
    }

    for childIndex in 0..<sourceOutline.numberOfChildren {
      guard let child = sourceOutline.child(at: childIndex) else { continue }
      copy.insertChild(
        copyOutline(
          child,
          sourceDocument: sourceDocument,
          outputDocument: outputDocument
        ),
        at: copy.numberOfChildren
      )
    }
    return copy
  }

  private static func validatePageReferences(
    annotations: [ReaderAnnotation],
    quickLinks: [ReaderQuickLink],
    readingState: ReadingState,
    in document: PDFDocument
  ) throws {
    guard readingState.page >= 1, readingState.page <= document.pageCount else {
      throw ReaderTransferPDFError.missingPage(readingState.page)
    }
    guard readingState.zoom.isFinite, readingState.zoom >= 0.1 else {
      throw ReaderTransferPDFError.malformedMetadata
    }

    for annotation in annotations {
      guard annotation.page >= 1, annotation.page <= document.pageCount,
        let page = document.page(at: annotation.page - 1)
      else {
        throw ReaderTransferPDFError.missingPage(annotation.page)
      }
      for rect in annotation.rects {
        try validateAnnotationBox(rect, named: "annotation \(annotation.id)", on: page)
      }
      if let rect = annotation.sourceRect {
        try validateAnnotationBox(rect, named: "annotation \(annotation.id)", on: page)
      }
      if let rect = annotation.translationRect {
        try validateAnnotationBox(rect, named: "annotation \(annotation.id)", on: page)
      }
    }

    for link in quickLinks {
      try validateQuickLinkEndpoint(link.origin, named: "quick link \(link.id) origin", in: document)
      try validateQuickLinkEndpoint(link.result, named: "quick link \(link.id) result", in: document)
    }
  }

  private static func validateAnnotationBox(
    _ box: ReaderAnnotationRect,
    named name: String,
    on page: PDFPage
  ) throws {
    let (width, height) = viewportSize(of: page)
    guard box.x >= 0, box.y >= 0,
      box.width > 0, box.height > 0,
      box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite,
      (box.x + box.width).isFinite, (box.y + box.height).isFinite,
      box.x + box.width <= width, box.y + box.height <= height
    else {
      throw ReaderTransferPDFError.impossibleBox(name)
    }
  }

  private static func validateQuickLinkEndpoint(
    _ endpoint: ReaderQuickLinkEndpoint,
    named name: String,
    in document: PDFDocument
  ) throws {
    guard endpoint.page >= 1, endpoint.page <= document.pageCount,
      let page = document.page(at: endpoint.page - 1)
    else {
      throw ReaderTransferPDFError.missingPage(endpoint.page)
    }
    let box = endpoint.box
    let (width, height) = viewportSize(of: page)
    guard box.x >= 0, box.y >= 0,
      box.width > 0, box.height > 0,
      box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite,
      (box.x + box.width).isFinite, (box.y + box.height).isFinite,
      box.x + box.width <= width, box.y + box.height <= height
    else {
      throw ReaderTransferPDFError.impossibleBox(name)
    }
  }

  private static func viewportSize(of page: PDFPage) -> (Double, Double) {
    let crop = page.bounds(for: .cropBox)
    let rotation = ((page.rotation % 360) + 360) % 360
    if rotation % 180 == 0 {
      return (Double(crop.width), Double(crop.height))
    }
    return (Double(crop.height), Double(crop.width))
  }

  private static func setDocumentMetadata(_ json: String, in document: PDFDocument) throws {
    guard json.utf8.count <= maximumMetadataBytes else {
      throw ReaderTransferPDFError.metadataTooLarge
    }
    var attributes = document.documentAttributes ?? [:]
    attributes[PDFDocumentAttribute(rawValue: metadataAttributeName)] = json
    document.documentAttributes = attributes
  }

  private static func addMetadataFallback(_ json: String, to document: PDFDocument) throws {
    guard let page = document.page(at: 0) else {
      throw ReaderTransferPDFError.invalidPDF
    }
    let annotation = PDFAnnotation(
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      forType: .stamp,
      withProperties: nil
    )
    _ = annotation.setValue(metadataMarker, forAnnotationKey: metadataMarkerKey)
    _ = annotation.setValue(json, forAnnotationKey: metadataAnnotationKey)
    _ = annotation.setValue(2, forAnnotationKey: .flags) // Hidden.
    page.addAnnotation(annotation)
  }

  private static func removeManagedTransferAnnotations(from document: PDFDocument) {
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in page.annotations where
        annotation.value(forAnnotationKey: metadataMarkerKey) as? String == metadataMarker
      {
        page.removeAnnotation(annotation)
      }
    }
  }

  private static func removeManagedReaderAnnotations(from document: PDFDocument) {
    let nameKey = PDFAnnotationKey(rawValue: "NM")
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in page.annotations {
        guard let name = annotation.value(forAnnotationKey: nameKey) as? String,
          name.hasPrefix(ReaderAnnotationPDF.managedPrefix)
        else { continue }
        page.removeAnnotation(annotation)
      }
    }
  }

  private static func removeManagedQuickLinks(from document: PDFDocument) {
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in page.annotations where isManagedQuickLink(annotation) {
        page.removeAnnotation(annotation)
      }
    }
  }

  private static func isManagedQuickLink(_ annotation: PDFAnnotation) -> Bool {
    annotation.value(forAnnotationKey: quickLinkKey) as? String != nil
  }

  private static func addQuickLinks(
    _ links: [ReaderQuickLink],
    to document: PDFDocument
  ) throws {
    for link in links {
      guard let originPage = document.page(at: link.origin.page - 1),
        let resultPage = document.page(at: link.result.page - 1)
      else {
        throw ReaderTransferPDFError.missingPage(
          document.page(at: link.origin.page - 1) == nil ? link.origin.page : link.result.page
        )
      }
      addQuickLinkAnnotation(
        link,
        endpoint: link.origin,
        endpointName: "origin",
        destinationPage: resultPage,
        destinationBox: link.result.box,
        on: originPage
      )
      addQuickLinkAnnotation(
        link,
        endpoint: link.result,
        endpointName: "result",
        destinationPage: originPage,
        destinationBox: link.origin.box,
        on: resultPage
      )
    }
  }

  private static func addQuickLinkAnnotation(
    _ link: ReaderQuickLink,
    endpoint: ReaderQuickLinkEndpoint,
    endpointName: String,
    destinationPage: PDFPage,
    destinationBox: ReaderQuickLinkBox,
    on page: PDFPage
  ) {
    let bounds = pdfRect(for: endpoint.box, on: page)
    let destinationPoint = ReaderAnnotationPDF.pdfPoint(for: destinationBox, on: destinationPage)
    let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
    let destination = PDFDestination(page: destinationPage, at: destinationPoint)
    // Keep both representations. PDF viewers commonly use the `/A` action,
    // while PDFKit itself exposes the direct `/Dest` property after reload.
    annotation.destination = destination
    annotation.action = PDFActionGoTo(destination: destination)

    // A visible one-point border keeps these links discoverable in ordinary
    // PDF viewers while retaining the normal link click behavior.
    let border = PDFBorder()
    border.style = .solid
    border.lineWidth = 1
    annotation.border = border
    _ = annotation.setValue(
      "\(metadataVersion):\(link.id):\(endpointName)",
      forAnnotationKey: quickLinkKey
    )
    page.addAnnotation(annotation)
  }

  private static func pdfRect(for box: ReaderQuickLinkBox, on page: PDFPage) -> CGRect {
    let first = ReaderAnnotationPDF.pdfPoint(for: box, on: page)
    let opposite = ReaderAnnotationPDF.pdfPoint(
      for: ReaderQuickLinkBox(
        x: box.x + box.width,
        y: box.y + box.height,
        width: 0,
        height: 0
      ),
      on: page
    )
    return CGRect(
      x: min(first.x, opposite.x),
      y: min(first.y, opposite.y),
      width: abs(opposite.x - first.x),
      height: abs(opposite.y - first.y)
    )
  }
}
