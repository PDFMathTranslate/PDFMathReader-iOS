import CryptoKit
import Foundation
import PDFKit
import PencilKit
import ReaderCore

/// Prepares a durable, width-aligned derivative while keeping the source PDF
/// and its document identity untouched.
enum ReaderAlignedDocument {
  private static let directoryName = "Aligned PDFs"
  private static let drawingDirectoryName = "drawings"
  private static let annotationDirectoryName = "annotations"
  private static let quickLinkDirectoryName = "quick-links"
  private static let digestVersion = "v1"

  enum Error: Swift.Error, LocalizedError {
    case invalidNormalizationResult
    case invalidDrawingSidecar
    case invalidDrawingPage(Int)
    case invalidDrawingData(Int)

    var errorDescription: String? {
      switch self {
      case .invalidNormalizationResult:
        return "PDF width normalization returned invalid page scales."
      case .invalidDrawingSidecar:
        return "The PencilKit drawing sidecar is invalid."
      case .invalidDrawingPage(let page):
        return "The PencilKit drawing references invalid PDF page \(page + 1)."
      case .invalidDrawingData(let page):
        return "The PencilKit drawing on PDF page \(page + 1) is invalid."
      }
    }
  }

  /// Returns an existing derivative when available, creates one for mixed
  /// displayed page widths, and returns `nil` for an already-uniform PDF.
  static func prepare(
    sourceData: Data,
    sourceURL: URL,
    sourceID: String,
    contentHash: String,
    directory: URL,
    readingState: ReadingState
  ) async throws -> URL? {
    // LibraryModel is main-actor isolated, but PDFKit serialization and the
    // sidecar reads are deliberately kept off that actor. The drawing bridge
    // below hops back only for PencilKit's main-actor API.
    try await Task.detached(priority: .userInitiated) {
      try await prepareOffMain(
        sourceData: sourceData,
        sourceURL: sourceURL,
        sourceID: sourceID,
        contentHash: contentHash,
        directory: directory,
        readingState: readingState
      )
    }.value
  }

  private static func prepareOffMain(
    sourceData: Data,
    sourceURL: URL,
    sourceID: String,
    contentHash: String,
    directory: URL,
    readingState: ReadingState
  ) async throws -> URL? {
    let digest = derivativeDigest(sourceID: sourceID, contentHash: contentHash)
    let destination = derivativeURL(
      sourceURL: sourceURL,
      directory: directory,
      digest: digest
    )
    if isReusableFile(at: destination) { return destination }

    // This inexpensive preflight avoids touching transfer metadata for a
    // uniform source. The normalizer remains authoritative for the actual
    // rewrite and its returned scales.
    if let uniform = isUniformPDF(sourceData), uniform { return nil }

    // Snapshot application state before the PDF rewrite. Supplying the
    // original native references here removes imported native markup by its
    // exact indirect reference, so the JavaScript rewrite cannot make those
    // references stale and cause duplicate annotations later.
    let annotationStore = ReaderAnnotationStore(
      directory: directory.appendingPathComponent(annotationDirectoryName, isDirectory: true)
    )
    let annotationState = try annotationStore.loadOrImport(
      sourceID,
      sourceData: sourceData,
      persistImported: false
    )
    let quickLinks = try loadQuickLinks(
      sourceData: sourceData,
      sourceID: sourceID,
      directory: directory
    )
    let drawingSidecar = try drawingSidecarData(
      sourceURL: sourceURL,
      directory: directory
    )
    let pageCount = try sourcePageCount(sourceData)
    let state = clampedReadingState(readingState, pageCount: pageCount)
    let snapshot = try ReaderTransferPDF.export(
      sourceData: sourceData,
      annotations: annotationState.annotations,
      quickLinks: quickLinks,
      readingState: state,
      nativeRefs: annotationState.nativeRefs
    )

    guard let normalized = try await ReaderPageWidthNormalizer.normalize(data: snapshot) else {
      // The preflight and engine intentionally agree on the width bucket. A
      // nil result here means the snapshot became uniform while it was being
      // prepared; no derivative is needed.
      return nil
    }
    guard normalized.scales.count == pageCount,
      normalized.scales.allSatisfy({ $0.isFinite && $0 > 0 })
    else {
      throw Error.invalidNormalizationResult
    }

    let transformedAnnotations = try scaleAnnotations(
      annotationState.annotations,
      scales: normalized.scales
    )
    let transformedQuickLinks = try scaleQuickLinks(
      quickLinks,
      scales: normalized.scales
    )
    let derivativeDocumentID = derivativeUUID(for: digest)
    let transformedState = clampedReadingState(
      state,
      pageCount: normalized.scales.count
    )

    // Re-embed transformed drawings before the final metadata export. The
    // transfer export then carries both drawing markers and its replacement
    // metadata through the final portable PDF copy.
    let withDrawings = try await MainActor.run {
      try reembedDrawings(
        normalizedData: normalized.data,
        sourceData: snapshot,
        sidecarData: drawingSidecar,
        scales: normalized.scales
      )
    }
    let output = try ReaderTransferPDF.export(
      sourceData: withDrawings,
      annotations: transformedAnnotations,
      quickLinks: transformedQuickLinks,
      readingState: transformedState,
      // The snapshot already removed original native annotations using their
      // source references. Transformed annotations have no source nativeRef,
      // so the final pass cannot treat new object references as source ones.
      nativeRefs: [],
      documentID: derivativeDocumentID
    )

    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try output.write(to: destination, options: [.atomic])
    return destination
  }
}

private extension ReaderAlignedDocument {
  static func derivativeDigest(sourceID: String, contentHash: String) -> String {
    let input = "\(digestVersion):\(sourceID):\(contentHash)"
    return SHA256.hash(data: Data(input.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func derivativeUUID(for digest: String) -> String {
    var characters = Array(digest.prefix(32))
    precondition(characters.count == 32)
    // Keep the transfer metadata's UUID identity contract while making the
    // value deterministic for this source and alignment version.
    characters[12] = "5"
    characters[16] = "8"
    return [
      String(characters[0..<8]),
      String(characters[8..<12]),
      String(characters[12..<16]),
      String(characters[16..<20]),
      String(characters[20..<32]),
    ].joined(separator: "-")
  }

  static func derivativeURL(sourceURL: URL, directory: URL, digest: String) -> URL {
    let filename = sourceURL.lastPathComponent.isEmpty
      ? "document.pdf"
      : sourceURL.lastPathComponent
    return directory
      .appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(digest, isDirectory: true)
      .appendingPathComponent(filename)
  }

  static func isReusableFile(at url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
      return false
    }
    return values.isRegularFile == true
  }

  static func isUniformPDF(_ data: Data) -> Bool? {
    guard let document = PDFDocument(data: data), document.pageCount > 0 else {
      return nil
    }
    let widths = (0..<document.pageCount).compactMap { index -> Int? in
      guard let page = document.page(at: index) else { return nil }
      let crop = page.bounds(for: .cropBox)
      guard crop.width > 0, crop.height > 0 else { return nil }
      let rotation = ((page.rotation % 360) + 360) % 360
      let width = rotation % 180 == 0 ? crop.width : crop.height
      guard width.isFinite, width > 0 else { return nil }
      return Int((Double(width) * 10).rounded(.awayFromZero))
    }
    guard widths.count == document.pageCount else { return nil }
    return Set(widths).count <= 1
  }

  static func sourcePageCount(_ data: Data) throws -> Int {
    guard let document = PDFDocument(data: data), document.pageCount > 0 else {
      throw ReaderTransferPDFError.invalidPDF
    }
    return document.pageCount
  }

  static func clampedReadingState(_ state: ReadingState, pageCount: Int) -> ReadingState {
    var result = state
    result.page = min(max(1, state.page), max(1, pageCount))
    return result
  }

  static func loadQuickLinks(
    sourceData: Data,
    sourceID: String,
    directory: URL
  ) throws -> [ReaderQuickLink] {
    let store = ReaderQuickLinkStore(
      directory: directory.appendingPathComponent(quickLinkDirectoryName, isDirectory: true)
    )
    let localURL = try store.url(for: sourceID)
    if FileManager.default.fileExists(atPath: localURL.path) {
      return try store.load(sourceID)
    }
    guard let document = PDFDocument(data: sourceData),
      let metadata = try ReaderTransferPDF.metadata(from: document)
    else {
      return []
    }
    return metadata.quickLinks
  }

  static func drawingSidecarData(sourceURL: URL, directory: URL) throws -> Data? {
    let key = sourceURL.standardizedFileURL.absoluteString
    let digest = SHA256.hash(data: Data(key.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let url = directory
      .appendingPathComponent(drawingDirectoryName, isDirectory: true)
      .appendingPathComponent(digest)
      .appendingPathExtension("json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }

  static func scaleAnnotations(
    _ annotations: [ReaderAnnotation],
    scales: [Double]
  ) throws -> [ReaderAnnotation] {
    try annotations.map { annotation in
      let factor = try pageScale(for: annotation.page, scales: scales)
      var transformed = annotation
      // Native references identify objects in the source PDF. The normalized
      // PDF has a new object graph, so retaining them would make the final
      // transfer pass treat unrelated objects as source annotations.
      transformed.nativeRef = nil
      transformed.rects = annotation.rects.map { scale($0, by: factor) }
      transformed.sourceRect = annotation.sourceRect.map { scale($0, by: factor) }
      transformed.translationRect = annotation.translationRect.map { scale($0, by: factor) }
      return transformed
    }
  }

  static func scaleQuickLinks(
    _ links: [ReaderQuickLink],
    scales: [Double]
  ) throws -> [ReaderQuickLink] {
    try links.map { link in
      var transformed = link
      transformed.origin.box = scale(
        transformed.origin.box,
        by: try pageScale(for: transformed.origin.page, scales: scales)
      )
      transformed.result.box = scale(
        transformed.result.box,
        by: try pageScale(for: transformed.result.page, scales: scales)
      )
      return transformed
    }
  }

  static func pageScale(for page: Int, scales: [Double]) throws -> Double {
    guard page >= 1, page <= scales.count else {
      throw ReaderTransferPDFError.missingPage(page)
    }
    let scale = scales[page - 1]
    guard scale.isFinite, scale > 0 else {
      throw Error.invalidNormalizationResult
    }
    return scale
  }

  static func scale(_ rect: ReaderAnnotationRect, by factor: Double) -> ReaderAnnotationRect {
    ReaderAnnotationRect(
      x: rect.x * factor,
      y: rect.y * factor,
      width: rect.width * factor,
      height: rect.height * factor
    )
  }

  static func scale(_ box: ReaderQuickLinkBox, by factor: Double) -> ReaderQuickLinkBox {
    ReaderQuickLinkBox(
      x: box.x * factor,
      y: box.y * factor,
      width: box.width * factor,
      height: box.height * factor
    )
  }

  @MainActor
  static func reembedDrawings(
    normalizedData: Data,
    sourceData: Data,
    sidecarData: Data?,
    scales: [Double]
  ) throws -> Data {
    var drawings: [Int: PKDrawing]
    if let sidecarData {
      let encoded: [Int: Data]
      do {
        encoded = try JSONDecoder().decode([Int: Data].self, from: sidecarData)
      } catch {
        throw Error.invalidDrawingSidecar
      }
      drawings = [:]
      for (page, data) in encoded {
        guard page >= 0, page < scales.count else {
          throw Error.invalidDrawingPage(page)
        }
        guard let drawing = try? PKDrawing(data: data) else {
          throw Error.invalidDrawingData(page)
        }
        drawings[page] = drawing.transformed(
          using: CGAffineTransform(scaleX: CGFloat(scales[page]), y: CGFloat(scales[page]))
        )
      }
    } else {
      let embedded = try ReaderDrawingPDF.drawings(in: sourceData)
      drawings = [:]
      for (page, drawing) in embedded {
        guard page >= 0, page < scales.count else {
          throw Error.invalidDrawingPage(page)
        }
        drawings[page] = drawing.transformed(
          using: CGAffineTransform(scaleX: CGFloat(scales[page]), y: CGFloat(scales[page]))
        )
      }
    }
    return try ReaderDrawingPDF.embed(drawings, in: normalizedData)
  }
}
