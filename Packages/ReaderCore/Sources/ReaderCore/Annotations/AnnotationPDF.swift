import Foundation
import PDFKit
import Compression

#if os(iOS)
import UIKit
private typealias ReaderPDFColor = UIColor
#elseif os(macOS)
import AppKit
private typealias ReaderPDFColor = NSColor
#endif

public enum ReaderAnnotationPDF {
  public static let managedPrefix = ReaderAnnotationLimits.managedPrefix

  /// Converts PDFKit's bottom-left page coordinates into the top-left viewport
  /// coordinates used by the shared annotation JSON model.
  public static func viewportRect(for pdfRect: CGRect, on page: PDFPage) -> ReaderAnnotationRect {
    viewportRect(pdfRect, geometry: PageGeometry(page: page))
  }

  /// Converts a quick-link box's top-left page coordinates into PDF page space.
  public static func pdfPoint(for box: ReaderQuickLinkBox, on page: PDFPage) -> CGPoint {
    pdfPoint(CGPoint(x: CGFloat(box.x), y: CGFloat(box.y)), geometry: PageGeometry(page: page))
  }

  public static func viewportRects(
    for selection: PDFSelection,
    on page: PDFPage
  ) -> [ReaderAnnotationRect] {
    let lineSelections = selection.selectionsByLine()
    let rects = lineSelections.compactMap { lineSelection -> ReaderAnnotationRect? in
      guard lineSelection.pages.contains(where: { $0 === page }) else { return nil }
      let rect = lineSelection.bounds(for: page)
      guard rect.width > 0, rect.height > 0 else { return nil }
      return viewportRect(for: rect, on: page)
    }
    if !rects.isEmpty { return rects }
    let rect = selection.bounds(for: page)
    return rect.width > 0 && rect.height > 0 ? [viewportRect(for: rect, on: page)] : []
  }

  public static func importAnnotations(from document: PDFDocument) -> ReaderAnnotationImportResult {
    importAnnotations(from: document, nativeReferencesByPage: nil)
  }

  public static func importAnnotations(from data: Data) throws -> ReaderAnnotationImportResult {
    guard data.count <= ReaderAnnotationLimits.maximumPDFBytes,
      let document = PDFDocument(data: data)
    else {
      if data.count > ReaderAnnotationLimits.maximumPDFBytes {
        throw ReaderAnnotationValidationError.pdfTooLarge
      }
      throw ReaderAnnotationPDFError.invalidPDF
    }
    return importAnnotations(
      from: document,
      nativeReferencesByPage: nativeReferencesByPage(in: data)
    )
  }

  private static func importAnnotations(
    from document: PDFDocument,
    nativeReferencesByPage: [[String]]?
  ) -> ReaderAnnotationImportResult {
    var annotations: [ReaderAnnotation] = []
    var nativeRefs: [String] = []
    let now = iso8601String(Date())

    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      let geometry = PageGeometry(page: page)
      for (annotationIndex, annotation) in page.annotations.enumerated() {
        if let managed = managedAnnotation(from: annotation) {
          annotations.append(managed)
          continue
        }
        if isManagedName(annotation.value(forAnnotationKey: rawKey("NM"))) {
          continue
        }

        let subtype = normalizedSubtype(annotation.type)
        guard subtype == "Highlight" || subtype == "Text" else { continue }
        let sourceRect = viewportRect(annotation.bounds, geometry: geometry)
        guard sourceRect.width > 0, sourceRect.height > 0 else { continue }
        let rects: [ReaderAnnotationRect]
        if subtype == "Highlight" {
          rects = quadRects(annotation, geometry: geometry)
            .filter { $0.width > 0 && $0.height > 0 }
            .ifEmpty([sourceRect])
        } else {
          rects = [sourceRect]
        }

        let createdAt = annotation.modificationDate.map(iso8601String) ?? now
        let nativeRef: String?
        if let references = nativeReferencesByPage,
          pageIndex < references.count,
          annotationIndex < references[pageIndex].count
        {
          nativeRef = references[pageIndex][annotationIndex]
        } else {
          nativeRef = nil
        }
        let nativeID = nativeRef.map { "native:\($0)" } ?? "native:p\(pageIndex + 1)-a\(annotationIndex)"
        let imported = ReaderAnnotation(
          id: nativeID,
          page: pageIndex + 1,
          kind: subtype == "Highlight" ? .highlight : .comment,
          origin: .source,
          text: subtype == "Highlight" ? annotation.contents ?? "" : "",
          comment: subtype == "Text" ? annotation.contents ?? "" : "",
          color: hexColor(annotation.color),
          rects: rects,
          createdAt: createdAt,
          nativeRef: nativeRef,
          dateUnknown: annotation.modificationDate == nil,
          author: annotation.userName ?? "",
          sourceRect: sourceRect
        )
        if let normalized = try? ReaderAnnotationValidator.validate(imported) {
          annotations.append(normalized)
          if let nativeRef { nativeRefs.append(nativeRef) }
        }
      }
    }

    return ReaderAnnotationImportResult(annotations: annotations, nativeRefs: nativeRefs)
  }

  /// Embeds managed annotations in a PDFKit document and restores `/NM` after PDFKit serializes.
  /// PDFKit accepts the desktop custom JSON key but silently omits `/NM` on write.
  public static func embedAnnotations(
    _ annotations: [ReaderAnnotation],
    in document: PDFDocument,
    nativeRefs: [String] = [],
    removeForeignMarkup: Bool = true
  ) throws -> Data {
    try embedAnnotations(
      annotations,
      in: document,
      nativeRefs: nativeRefs,
      removeForeignMarkup: removeForeignMarkup,
      foreignReferencesByPage: nil
    )
  }

  private static func embedAnnotations(
    _ annotations: [ReaderAnnotation],
    in document: PDFDocument,
    nativeRefs: [String],
    removeForeignMarkup: Bool,
    foreignReferencesByPage: [[String]]?
  ) throws -> Data {
    let normalized = try ReaderAnnotationValidator.validate(annotations)
    _ = try ReaderAnnotationValidator.validateNativeReferences(nativeRefs)
    var managedNames: [String] = []

    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      let existing = page.annotations
      for (annotationIndex, annotation) in existing.enumerated() {
        if managedAnnotation(from: annotation) != nil ||
          isManagedName(annotation.value(forAnnotationKey: rawKey("NM")))
        {
          page.removeAnnotation(annotation)
        } else if removeForeignMarkup && isForeignMarkup(annotation),
          let references = foreignReferencesByPage,
          pageIndex < references.count,
          annotationIndex < references[pageIndex].count,
          nativeRefs.contains(references[pageIndex][annotationIndex])
        {
          // Imported native highlights/comments are removed by their exact
          // indirect reference, matching the desktop prepare step.
          page.removeAnnotation(annotation)
        }
      }
    }

    for annotation in normalized {
      guard let page = document.page(at: annotation.page - 1) else {
        throw ReaderAnnotationPDFError.missingPage(annotation.page)
      }
      let pdfAnnotation = try makeAnnotation(annotation, on: page)
      page.addAnnotation(pdfAnnotation)
      let managedName = managedPrefix + annotation.id
      managedNames.append(managedName)
    }

    guard let data = document.dataRepresentation() else {
      throw ReaderAnnotationPDFError.couldNotSerialize
    }
    return restoreManagedNames(in: data, names: managedNames)
  }

  /// Updates one live page without serializing or replacing its document.
  /// Supply every imported/managed highlight and comment for this page; other
  /// annotation types (links, widgets, ink, and transfer markers) are preserved.
  public static func replacePageAnnotations(
    _ annotations: [ReaderAnnotation],
    on page: PDFPage
  ) throws {
    let normalized = try ReaderAnnotationValidator.validate(annotations)
    let replacements = try normalized.map { try makeAnnotation($0, on: page) }
    for existing in page.annotations {
      if managedAnnotation(from: existing) != nil ||
        isManagedName(existing.value(forAnnotationKey: rawKey("NM"))) || isForeignMarkup(existing)
      {
        page.removeAnnotation(existing)
      }
    }
    for replacement in replacements { page.addAnnotation(replacement) }
  }

  private static func makeAnnotation(_ annotation: ReaderAnnotation, on page: PDFPage) throws -> PDFAnnotation {
    let geometry = PageGeometry(page: page)
    let viewportRects = annotation.rects.compactMap { clamp($0, width: geometry.width, height: geometry.height) }
    guard !viewportRects.isEmpty else {
      throw ReaderAnnotationPDFError.annotationOutsidePage(annotation.id)
    }
    let pdfRects = viewportRects.map { pdfRect($0, geometry: geometry) }
    let markerViewport = annotation.sourceRect.flatMap {
      clamp($0, width: geometry.width, height: geometry.height)
    } ?? viewportRects[0]
    let markerRect = pdfRect(markerViewport, geometry: geometry)
    let isText = annotation.kind == .comment ||
      (annotation.origin == .translation && annotation.kind == .highlight)
    let bounds = isText ? markerRect : union(pdfRects)

    let subtype: PDFAnnotationSubtype = isText ? .text : .highlight
    let pdfAnnotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
    pdfAnnotation.color = platformColor(annotation.color)
    pdfAnnotation.contents = annotationContents(annotation)
    pdfAnnotation.userName = annotation.author?.isEmpty == false
      ? annotation.author
      : "PDFMathReader"
    if let date = date(from: annotation.modifiedAt ?? annotation.createdAt) {
      pdfAnnotation.modificationDate = date
    }
    _ = pdfAnnotation.setValue(4, forAnnotationKey: .flags)
    let managedName = managedPrefix + annotation.id
    _ = pdfAnnotation.setValue(managedName, forAnnotationKey: rawKey("NM"))
    let payload = try encodedJSON(annotation)
    _ = pdfAnnotation.setValue(payload, forAnnotationKey: rawKey("PDFMathReader"))

    if annotation.kind == .highlight && !isText {
      pdfAnnotation.quadrilateralPoints = viewportRects.flatMap { rect in
        let pdfRect = self.pdfRect(rect, geometry: geometry)
        return quadPoints(pdfRect, bounds: bounds)
      }
    } else {
      pdfAnnotation.iconType = .comment
      _ = pdfAnnotation.setValue("Comment", forAnnotationKey: .iconName)
      _ = pdfAnnotation.setBoolean(false, forAnnotationKey: .open)
    }
    return pdfAnnotation
  }

  public static func embedAnnotations(
    _ annotations: [ReaderAnnotation],
    in data: Data,
    nativeRefs: [String] = [],
    removeForeignMarkup: Bool = true
  ) throws -> Data {
    guard data.count <= ReaderAnnotationLimits.maximumPDFBytes,
      let document = PDFDocument(data: data)
    else {
      if data.count > ReaderAnnotationLimits.maximumPDFBytes {
        throw ReaderAnnotationValidationError.pdfTooLarge
      }
      throw ReaderAnnotationPDFError.invalidPDF
    }
    return try embedAnnotations(
      annotations,
      in: document,
      nativeRefs: nativeRefs,
      removeForeignMarkup: removeForeignMarkup,
      foreignReferencesByPage: nativeReferencesByPage(in: data)
    )
  }

  public static func stripManagedAnnotations(from data: Data) throws -> Data {
    try embedAnnotations([], in: data, removeForeignMarkup: false)
  }

  private static func managedAnnotation(from annotation: PDFAnnotation) -> ReaderAnnotation? {
    // PDFKit drops /NM on reserialization, but retains our JSON payload.
    // Recognize that payload so edits replace the previous mark rather than
    // stacking another highlight on top of it.
    guard let value = annotation.value(forAnnotationKey: rawKey("PDFMathReader")) as? String,
      let data = value.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(ReaderAnnotation.self, from: data),
      let validated = try? ReaderAnnotationValidator.validate(decoded)
    else { return nil }
    return validated
  }

  private static func encodedJSON(_ annotation: ReaderAnnotation) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(annotation), as: UTF8.self)
  }

  private static func annotationContents(_ annotation: ReaderAnnotation) -> String {
    let operation = annotation.kind == .highlight ? "高亮" : "批注"
    let origin = annotation.origin == .translation ? "译文" : "原文"
    let colorSuffix = annotation.kind == .highlight ? " \(annotation.color)" : ""
    return [
      "[\(origin)\(operation)\(colorSuffix)]",
      annotation.text,
      annotation.comment,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func isForeignMarkup(_ annotation: PDFAnnotation) -> Bool {
    let subtype = normalizedSubtype(annotation.type)
    return subtype == "Highlight" || subtype == "Text"
  }

  private static func isManagedName(_ value: Any?) -> Bool {
    guard let name = value as? String else { return false }
    return name.hasPrefix(managedPrefix)
  }

  private static func normalizedSubtype(_ value: String?) -> String {
    value?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
  }

  private static func rawKey(_ value: String) -> PDFAnnotationKey {
    PDFAnnotationKey(rawValue: value)
  }

  private static func hexColor(_ color: ReaderPDFColor?) -> String {
    guard let color else { return "#fff36a" }
    #if os(iOS)
    var red: CGFloat = 1
    var green: CGFloat = 0.95
    var blue: CGFloat = 0.42
    var alpha: CGFloat = 1
    if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
      return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    #else
    if let rgb = color.usingColorSpace(.deviceRGB) {
      return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    #endif
    return "#fff36a"
  }

  private static func platformColor(_ value: String) -> ReaderPDFColor {
    let digits = Array(value.dropFirst().prefix(6))
    guard digits.count == 6,
      let red = Int(String(digits[digits.startIndex..<digits.index(digits.startIndex, offsetBy: 2)]), radix: 16),
      let green = Int(String(digits[digits.index(digits.startIndex, offsetBy: 2)..<digits.index(digits.startIndex, offsetBy: 4)]), radix: 16),
      let blue = Int(String(digits[digits.index(digits.startIndex, offsetBy: 4)..<digits.endIndex]), radix: 16)
    else { return .yellow }
    #if os(iOS)
    return ReaderPDFColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    #else
    return ReaderPDFColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    #endif
  }

  private struct PageGeometry {
    let crop: CGRect
    let rotation: Int
    let width: Double
    let height: Double

    init(page: PDFPage) {
      crop = page.bounds(for: .cropBox)
      rotation = ((page.rotation % 360) + 360) % 360
      width = rotation % 180 == 0 ? Double(crop.width) : Double(crop.height)
      height = rotation % 180 == 0 ? Double(crop.height) : Double(crop.width)
    }
  }

  private static func viewportRect(_ rect: CGRect, geometry: PageGeometry) -> ReaderAnnotationRect {
    let points = [
      viewportPoint(CGPoint(x: rect.minX, y: rect.minY), geometry: geometry),
      viewportPoint(CGPoint(x: rect.maxX, y: rect.maxY), geometry: geometry),
    ]
    let x = points.map(\.x).min() ?? 0
    let y = points.map(\.y).min() ?? 0
    let right = points.map(\.x).max() ?? 0
    let bottom = points.map(\.y).max() ?? 0
    return ReaderAnnotationRect(x: x, y: y, width: right - x, height: bottom - y)
  }

  private static func quadRects(
    _ annotation: PDFAnnotation,
    geometry: PageGeometry
  ) -> [ReaderAnnotationRect] {
    guard let points = annotation.quadrilateralPoints, points.count >= 4 else { return [] }
    let origin = annotation.bounds.origin
    let absolute = points.compactMap { value -> CGPoint? in
      #if os(iOS)
      return value.cgPointValue
      #else
      return value.pointValue
      #endif
    }.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
    return stride(from: 0, through: absolute.count - 4, by: 4).map { index in
      let points = absolute[index..<(index + 4)]
      let rect = CGRect(
        x: points.map(\.x).min() ?? 0,
        y: points.map(\.y).min() ?? 0,
        width: (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
        height: (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
      )
      return viewportRect(rect, geometry: geometry)
    }
  }

  private static func viewportPoint(_ point: CGPoint, geometry: PageGeometry) -> CGPoint {
    let crop = geometry.crop
    switch geometry.rotation {
    case 90: return CGPoint(x: point.y - crop.minY, y: point.x - crop.minX)
    case 180: return CGPoint(x: crop.maxX - point.x, y: point.y - crop.minY)
    case 270: return CGPoint(x: crop.maxY - point.y, y: crop.maxX - point.x)
    default: return CGPoint(x: point.x - crop.minX, y: crop.maxY - point.y)
    }
  }

  private static func pdfRect(_ rect: ReaderAnnotationRect, geometry: PageGeometry) -> CGRect {
    let points = [
      pdfPoint(CGPoint(x: rect.x, y: rect.y), geometry: geometry),
      pdfPoint(CGPoint(x: rect.x + rect.width, y: rect.y), geometry: geometry),
      pdfPoint(CGPoint(x: rect.x, y: rect.y + rect.height), geometry: geometry),
      pdfPoint(CGPoint(x: rect.x + rect.width, y: rect.y + rect.height), geometry: geometry),
    ]
    let minX = points.map(\.x).min() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func pdfPoint(_ point: CGPoint, geometry: PageGeometry) -> CGPoint {
    let crop = geometry.crop
    switch geometry.rotation {
    case 90: return CGPoint(x: crop.minX + point.y, y: crop.minY + point.x)
    case 180: return CGPoint(x: crop.maxX - point.x, y: crop.minY + point.y)
    case 270: return CGPoint(x: crop.maxX - point.y, y: crop.maxY - point.x)
    default: return CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
    }
  }

  private static func quadPoints(_ rect: CGRect, bounds: CGRect) -> [NSValue] {
    let points = [
      CGPoint(x: rect.minX - bounds.minX, y: rect.maxY - bounds.minY),
      CGPoint(x: rect.maxX - bounds.minX, y: rect.maxY - bounds.minY),
      CGPoint(x: rect.minX - bounds.minX, y: rect.minY - bounds.minY),
      CGPoint(x: rect.maxX - bounds.minX, y: rect.minY - bounds.minY),
    ]
    #if os(iOS)
    return points.map { NSValue(cgPoint: $0) }
    #else
    return points.map { NSValue(point: $0) }
    #endif
  }

  private static func union(_ rects: [CGRect]) -> CGRect {
    rects.dropFirst().reduce(rects[0]) { $0.union($1) }
  }

  private static func clamp(
    _ rect: ReaderAnnotationRect,
    width: Double,
    height: Double
  ) -> ReaderAnnotationRect? {
    let left = max(0, min(width, rect.x))
    let top = max(0, min(height, rect.y))
    let right = max(0, min(width, rect.x + rect.width))
    let bottom = max(0, min(height, rect.y + rect.height))
    guard right > left, bottom > top else { return nil }
    return ReaderAnnotationRect(x: left, y: top, width: right - left, height: bottom - top)
  }

  private static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? {
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: value)
    }()
  }

  private static func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  // PDFKit exposes annotation dictionaries but not their indirect object
  // references. Recover the page annotation array references from ordinary PDF
  // object dictionaries so foreign annotations can be prepared like desktop.
  private struct PDFObjectReference: Hashable {
    let object: Int
    let generation: Int

    var value: String { "\(object) \(generation) R" }
  }

  private static func nativeReferencesByPage(in data: Data) -> [[String]]? {
    let objects = indirectObjects(in: Array(data))
    guard !objects.isEmpty,
      let root = lastReference(in: Array(data), for: "/Root"),
      let pages = objects[root],
      let pageTree = reference(after: "/Pages", in: pages)
    else { return nil }

    var pageReferences: [PDFObjectReference] = []
    var visited = Set<PDFObjectReference>()
    collectPageReferences(
      pageTree,
      objects: objects,
      into: &pageReferences,
      visited: &visited
    )
    guard !pageReferences.isEmpty else { return nil }
    return pageReferences.map { reference -> [String] in
      guard let page = objects[reference] else { return [] }
      return referencesAfter("/Annots", in: page, objects: objects).map(\.value)
    }
  }

  private static func indirectObjects(in bytes: [UInt8]) -> [PDFObjectReference: [UInt8]] {
    var result: [PDFObjectReference: [UInt8]] = [:]
    var index = 0
    while index < bytes.count {
      guard isDigit(bytes[index]) else {
        index += 1
        continue
      }
      let numberStart = index
      guard let object = parseInteger(bytes, from: &index) else {
        index = numberStart + 1
        continue
      }
      skipWhitespace(bytes, index: &index)
      guard let generation = parseInteger(bytes, from: &index) else {
        index = numberStart + 1
        continue
      }
      skipWhitespace(bytes, index: &index)
      guard matches(bytes, "obj", at: index) else {
        index = numberStart + 1
        continue
      }
      index += 3
      let bodyStart = index
      let bodyEnd = bytes.firstRange(of: Array("endobj".utf8), startingAt: bodyStart) ?? bytes.count
      result[PDFObjectReference(object: object, generation: generation)] = Array(bytes[bodyStart..<bodyEnd])
      index = min(bytes.count, bodyEnd + 6)
    }
    let objectStreams = result.values.compactMap { objectStreamObjects(in: $0) }
    for stream in objectStreams {
      for (reference, body) in stream {
        result[reference] = body
      }
    }
    return result
  }

  private static func objectStreamObjects(in body: [UInt8]) -> [(PDFObjectReference, [UInt8])] {
    guard let streamMarker = body.firstRange(of: Array("stream".utf8), startingAt: 0) else {
      return []
    }
    let dictionary = Array(body[..<streamMarker])
    guard name(after: "/Type", in: dictionary) == "/ObjStm",
      let count = integer(after: "/N", in: dictionary),
      let first = integer(after: "/First", in: dictionary),
      count >= 0,
      first >= 0
    else { return [] }

    var streamStart = streamMarker + 6
    if body[safe: streamStart] == 13 {
      streamStart += 1
      if body[safe: streamStart] == 10 { streamStart += 1 }
    } else if body[safe: streamStart] == 10 {
      streamStart += 1
    }
    let streamEnd = integer(after: "/Length", in: dictionary).map {
      min(body.count, streamStart + $0)
    } ?? body.firstRange(of: Array("endstream".utf8), startingAt: streamStart) ?? body.count
    guard streamStart <= streamEnd else { return [] }
    let encoded = Array(body[streamStart..<streamEnd])
    let decoded: [UInt8]
    if dictionary.firstRange(of: Array("/FlateDecode".utf8), startingAt: 0) != nil {
      guard let inflated = flateDecode(encoded) else { return [] }
      decoded = inflated
    } else {
      decoded = encoded
    }
    guard first <= decoded.count else { return [] }

    var headers: [(PDFObjectReference, Int)] = []
    var cursor = 0
    for _ in 0..<count {
      skipWhitespace(decoded, index: &cursor)
      guard let object = parseInteger(decoded, from: &cursor) else { return [] }
      skipWhitespace(decoded, index: &cursor)
      guard let offset = parseInteger(decoded, from: &cursor), offset >= 0 else { return [] }
      headers.append((PDFObjectReference(object: object, generation: 0), offset))
    }

    return headers.enumerated().compactMap { index, entry in
      let start = first + entry.1
      let end = first + (index + 1 < headers.count ? headers[index + 1].1 : decoded.count - first)
      guard start >= first, start <= end, end <= decoded.count else { return nil }
      return (entry.0, Array(decoded[start..<end]))
    }
  }

  private static func flateDecode(_ bytes: [UInt8]) -> [UInt8]? {
    guard !bytes.isEmpty else { return [] }
    // Compression's zlib decoder expects raw DEFLATE, while PDF FlateDecode
    // streams commonly include the two-byte zlib header and Adler-32 trailer.
    let isZlibWrapped = bytes.count >= 6 &&
      ((Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0) &&
      (bytes[0] & 0x0f) == 8
    let candidates: [[UInt8]] = isZlibWrapped
      ? [Array(bytes.dropFirst(2).dropLast(4)), bytes]
      : [bytes]
    var capacity = max(bytes.count * 4, 1_024)
    for candidate in candidates {
      for _ in 0..<8 {
        var output = [UInt8](repeating: 0, count: capacity)
        let outputCapacity = capacity
        let count = output.withUnsafeMutableBytes { destination in
          candidate.withUnsafeBytes { source in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
              let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return compression_decode_buffer(
              destinationBase,
              outputCapacity,
              sourceBase,
              candidate.count,
              nil,
              COMPRESSION_ZLIB
            )
          }
        }
        if count > 0 && count < capacity { return Array(output.prefix(count)) }
        capacity *= 4
      }
    }
    return nil
  }

  private static func collectPageReferences(
    _ reference: PDFObjectReference,
    objects: [PDFObjectReference: [UInt8]],
    into result: inout [PDFObjectReference],
    visited: inout Set<PDFObjectReference>
  ) {
    guard visited.insert(reference).inserted, let body = objects[reference] else { return }
    if name(after: "/Type", in: body) == "/Page" {
      result.append(reference)
      return
    }
    for child in referencesAfter("/Kids", in: body, objects: objects) {
      collectPageReferences(child, objects: objects, into: &result, visited: &visited)
    }
  }

  private static func referencesAfter(
    _ key: String,
    in body: [UInt8],
    objects: [PDFObjectReference: [UInt8]]
  ) -> [PDFObjectReference] {
    guard let keyIndex = body.firstRange(of: Array(key.utf8), startingAt: 0) else { return [] }
    var index = keyIndex + key.utf8.count
    skipWhitespace(body, index: &index)
    if body[safe: index] == 91 { // [
      let end = matchingBracket(in: body, from: index) ?? body.count
      return references(in: body, start: index + 1, end: end)
    }
    guard let direct = reference(in: body, from: &index), let target = objects[direct] else { return [] }
    guard let start = target.firstIndex(of: 91), let end = matchingBracket(in: target, from: start) else {
      return []
    }
    return references(in: target, start: start + 1, end: end)
  }

  private static func references(
    in bytes: [UInt8],
    start: Int,
    end: Int
  ) -> [PDFObjectReference] {
    var result: [PDFObjectReference] = []
    var index = start
    while index < end {
      guard isDigit(bytes[index]) else {
        index += 1
        continue
      }
      guard let object = parseInteger(bytes, from: &index) else { continue }
      skipWhitespace(bytes, index: &index)
      guard let generation = parseInteger(bytes, from: &index) else { continue }
      skipWhitespace(bytes, index: &index)
      guard bytes[safe: index] == 82 else { continue } // R
      result.append(PDFObjectReference(object: object, generation: generation))
      index += 1
    }
    return result
  }

  private static func lastReference(in bytes: [UInt8], for key: String) -> PDFObjectReference? {
    let target = Array(key.utf8)
    var search = 0
    var result: PDFObjectReference?
    while let location = bytes.firstRange(of: target, startingAt: search) {
      var index = location + target.count
      skipWhitespace(bytes, index: &index)
      if let reference = reference(in: bytes, from: &index) { result = reference }
      search = location + target.count
    }
    return result
  }

  private static func reference(after key: String, in body: [UInt8]) -> PDFObjectReference? {
    guard let index = body.firstRange(of: Array(key.utf8), startingAt: 0) else { return nil }
    var cursor = index + key.utf8.count
    skipWhitespace(body, index: &cursor)
    return reference(in: body, from: &cursor)
  }

  private static func reference(in bytes: [UInt8], from index: inout Int) -> PDFObjectReference? {
    guard let object = parseInteger(bytes, from: &index) else { return nil }
    skipWhitespace(bytes, index: &index)
    guard let generation = parseInteger(bytes, from: &index) else { return nil }
    skipWhitespace(bytes, index: &index)
    guard bytes[safe: index] == 82 else { return nil }
    index += 1
    return PDFObjectReference(object: object, generation: generation)
  }

  private static func name(after key: String, in body: [UInt8]) -> String? {
    guard let location = body.firstRange(of: Array(key.utf8), startingAt: 0) else { return nil }
    var index = location + key.utf8.count
    skipWhitespace(body, index: &index)
    let start = index
    while index < body.count, body[index] > 32, body[index] != 62, body[index] != 93 { index += 1 }
    return start < index ? String(decoding: body[start..<index], as: UTF8.self) : nil
  }

  private static func matchingBracket(in bytes: [UInt8], from start: Int) -> Int? {
    var depth = 0
    var index = start
    while index < bytes.count {
      if bytes[index] == 40 {
        index = skipLiteralString(bytes, from: index, limit: bytes.count)
        continue
      }
      if bytes[index] == 91 { depth += 1 }
      if bytes[index] == 93 {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func parseInteger(_ bytes: [UInt8], from index: inout Int) -> Int? {
    guard index < bytes.count, isDigit(bytes[index]) else { return nil }
    var value = 0
    while index < bytes.count, isDigit(bytes[index]) {
      value = value * 10 + Int(bytes[index] - 48)
      index += 1
    }
    return value
  }

  private static func integer(after key: String, in body: [UInt8]) -> Int? {
    guard let location = body.firstRange(of: Array(key.utf8), startingAt: 0) else { return nil }
    var index = location + key.utf8.count
    skipWhitespace(body, index: &index)
    return parseInteger(body, from: &index)
  }

  private static func skipWhitespace(_ bytes: [UInt8], index: inout Int) {
    while index < bytes.count, bytes[index] == 0 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 12 || bytes[index] == 13 || bytes[index] == 32 {
      index += 1
    }
  }

  private static func matches(_ bytes: [UInt8], _ value: String, at index: Int) -> Bool {
    let target = Array(value.utf8)
    guard index >= 0, index + target.count <= bytes.count else { return false }
    return Array(bytes[index..<(index + target.count)]) == target
  }

  private static func isDigit(_ value: UInt8) -> Bool {
    value >= 48 && value <= 57
  }

  private static func restoreManagedNames(in data: Data, names: [String]) -> Data {
    guard !names.isEmpty else { return data }
    var bytes = Array(data)
    var searchStart = 0
    for name in names {
      let marker = Array("/PDFMathReader".utf8)
      guard let markerStart = bytes.firstRange(of: marker, startingAt: searchStart),
        let dictionaryStart = dictionaryStart(in: bytes, before: markerStart),
        let dictionaryEnd = dictionaryEnd(in: bytes, after: markerStart),
        !containsKey("/NM", in: bytes, start: dictionaryStart, end: dictionaryEnd)
      else { continue }
      let value = "/NM <\(hexPDFString(name))> ".utf8
      bytes.insert(contentsOf: value, at: dictionaryStart + 2)
      searchStart = dictionaryEnd + value.count
    }
    return Data(bytes)
  }

  private static func hexPDFString(_ value: String) -> String {
    let scalars = value.utf16
    var result = "FEFF"
    for scalar in scalars {
      result += String(format: "%04X", scalar)
    }
    return result
  }

  private static func containsKey(_ key: String, in bytes: [UInt8], start: Int, end: Int) -> Bool {
    let target = Array(key.utf8)
    guard end > start + target.count else { return false }
    return Array(bytes[start..<end]).firstRange(of: target) != nil
  }

  private static func dictionaryStart(in bytes: [UInt8], before position: Int) -> Int? {
    var stack: [Int] = []
    var index = 0
    while index < position {
      if bytes[index] == 37 { // PDF comment
        while index < position, bytes[index] != 10, bytes[index] != 13 { index += 1 }
        continue
      }
      if bytes[index] == 40 {
        index = skipLiteralString(bytes, from: index, limit: position)
        continue
      }
      if bytes[index] == 60 {
        if index + 1 < position, bytes[index + 1] == 60 {
          stack.append(index)
          index += 2
        } else {
          index = skipHexString(bytes, from: index, limit: position)
        }
        continue
      }
      if bytes[index] == 62, index + 1 < position, bytes[index + 1] == 62 {
        if !stack.isEmpty { stack.removeLast() }
        index += 2
        continue
      }
      index += 1
    }
    return stack.last
  }

  private static func dictionaryEnd(in bytes: [UInt8], after position: Int) -> Int? {
    var depth = 0
    var index = dictionaryStart(in: bytes, before: position) ?? position
    while index + 1 < bytes.count {
      if bytes[index] == 37 {
        while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
        continue
      }
      if bytes[index] == 40 {
        index = skipLiteralString(bytes, from: index, limit: bytes.count)
        continue
      }
      if bytes[index] == 60 {
        if bytes[index + 1] == 60 { depth += 1; index += 2 }
        else { index = skipHexString(bytes, from: index, limit: bytes.count) }
        continue
      }
      if bytes[index] == 62, bytes[index + 1] == 62 {
        depth -= 1
        if depth == 0 { return index + 2 }
        index += 2
        continue
      }
      index += 1
    }
    return nil
  }

  private static func skipLiteralString(_ bytes: [UInt8], from start: Int, limit: Int) -> Int {
    var depth = 1
    var index = start + 1
    while index < limit, depth > 0 {
      if bytes[index] == 92 { index += 2; continue }
      if bytes[index] == 40 { depth += 1 }
      else if bytes[index] == 41 { depth -= 1 }
      index += 1
    }
    return index
  }

  private static func skipHexString(_ bytes: [UInt8], from start: Int, limit: Int) -> Int {
    var index = start + 1
    while index < limit, bytes[index] != 62 { index += 1 }
    return min(limit, index + 1)
  }
}

public enum ReaderAnnotationPDFError: Error, Equatable, LocalizedError, Sendable {
  case invalidPDF
  case missingPage(Int)
  case annotationOutsidePage(String)
  case couldNotSerialize

  public var errorDescription: String? {
    switch self {
    case .invalidPDF: ReaderLocalization.resolve("The PDF could not be opened.")
    case .missingPage(let page): ReaderLocalization.string("Annotation references missing PDF page {0}.", String(page))
    case .annotationOutsidePage(let id): ReaderLocalization.string("Annotation {0} is outside its PDF page.", id)
    case .couldNotSerialize: ReaderLocalization.resolve("The annotated PDF could not be serialized.")
    }
  }
}

private extension Array where Element: Equatable {
  func firstRange(of needle: [Element], startingAt start: Int = 0) -> Int? {
    guard !needle.isEmpty, start >= 0, start <= count - needle.count else { return nil }
    // PDF streams can contain millions of bytes. Compare in place rather than
    // allocating an ArraySlice copy for every candidate byte.
    for index in start...(count - needle.count) where self[index] == needle[0] {
      var offset = 1
      while offset < needle.count, self[index + offset] == needle[offset] {
        offset += 1
      }
      if offset == needle.count { return index }
    }
    return nil
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }

  func ifEmpty(_ replacement: @autoclosure () -> [Element]) -> [Element] {
    isEmpty ? replacement() : self
  }
}
