import CoreText
import Foundation

@preconcurrency import PDFKit

/// A translated paragraph positioned in the page viewport's top-left coordinate system.
public struct ExportParagraphBlock: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var translation: String
  public var fontSize: Double
  public var bold: Bool
  public var textAlign: String?

  public init(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    translation: String,
    fontSize: Double = 12,
    bold: Bool = false,
    textAlign: String? = nil
  ) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.translation = translation
    self.fontSize = fontSize
    self.bold = bold
    self.textAlign = textAlign
  }

  /// Convenience initializer for callers that already have a CGRect paragraph box.
  public init(
    rect: CGRect,
    translation: String,
    fontSize: Double = 12,
    bold: Bool = false,
    textAlign: String? = nil
  ) {
    self.init(
      x: Double(rect.minX),
      y: Double(rect.minY),
      width: Double(rect.width),
      height: Double(rect.height),
      translation: translation,
      fontSize: fontSize,
      bold: bold,
      textAlign: textAlign
    )
  }

  /// Alias useful when the source model calls the translated value `text`.
  public var text: String {
    get { translation }
    set { translation = newValue }
  }

  public var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

public enum TranslatedPDFExporterError: Error, Equatable, LocalizedError, Sendable {
  case invalidDocument
  case invalidReplacementPage(index: Int)
  case invalidParagraph(page: Int, index: Int)
  case unableToRenderPage(index: Int)
  case unableToSerialize

  public var errorDescription: String? {
    switch self {
    case .invalidDocument:
      return ReaderLocalization.resolve("The source PDF could not be opened.")
    case .invalidReplacementPage(let index):
      return ReaderLocalization.string("The replacement PDF for page {0} is not a single-page PDF.", String(index + 1))
    case .invalidParagraph(let page, let index):
      return ReaderLocalization.string("The translated paragraph at page {0}, index {1} has invalid geometry.", String(page + 1), String(index))
    case .unableToRenderPage(let index):
      return ReaderLocalization.string("The translated PDF page {0} could not be rendered.", String(index + 1))
    case .unableToSerialize:
      return ReaderLocalization.resolve("The translated PDF could not be serialized.")
    }
  }
}

/// Creates a translated PDF while retaining the source PDF's vector page content.
///
/// Ultra-fast paragraphs are painted over their original text in a new content stream.
/// Remote-kernel page data takes precedence over paragraph blocks for that page.
public final class TranslatedPDFExporter {
  public init() {}

  /// Exports a document with zero-based per-page paragraph and kernel results.
  ///
  /// The arrays may be shorter than the source document; missing entries are treated as
  /// untouched pages. A non-nil replacement entry must contain exactly one PDF page.
  public func export(
    originalPDFData: Data,
    paragraphsByPage: [[ExportParagraphBlock]] = [],
    replacementPDFDataByPage: [Data?] = [],
    fontName: String = "",
    serif: Bool = false
  ) throws -> Data {
    let hasTranslatedBlocks = paragraphsByPage.contains {
      $0.contains { !$0.translation.isEmpty }
    }
    let hasReplacementPages = replacementPDFDataByPage.contains { $0 != nil }
    guard hasTranslatedBlocks || hasReplacementPages else {
      // Keep the original bytes when no export work is requested. Besides being cheaper,
      // this preserves metadata and incremental PDF features exactly for ShareLink.
      return originalPDFData
    }

    guard let source = PDFDocument(data: originalPDFData), source.pageCount > 0 else {
      throw TranslatedPDFExporterError.invalidDocument
    }

    let output = PDFDocument()
    output.documentAttributes = source.documentAttributes

    for index in 0..<source.pageCount {
      guard let sourcePage = source.page(at: index) else {
        throw TranslatedPDFExporterError.invalidDocument
      }

      if let replacementData = replacementPDFDataByPage[safe: index], let replacementData {
        guard let replacementDocument = PDFDocument(data: replacementData),
          replacementDocument.pageCount == 1,
          let replacementPage = replacementDocument.page(at: 0),
          let copiedPage = replacementPage.copy() as? PDFPage
        else {
          throw TranslatedPDFExporterError.invalidReplacementPage(index: index)
        }
        output.insert(copiedPage, at: output.pageCount)
        continue
      }

      let blocks = paragraphsByPage[safe: index] ?? []
      let translatedBlocks = blocks.filter { !$0.translation.isEmpty }
      if translatedBlocks.isEmpty {
        guard let copiedPage = sourcePage.copy() as? PDFPage else {
          throw TranslatedPDFExporterError.invalidDocument
        }
        output.insert(copiedPage, at: output.pageCount)
      } else {
        let page = try renderTranslatedPage(
          sourcePage,
          blocks: translatedBlocks,
          index: index,
          fontName: fontName,
          serif: serif
        )
        output.insert(page, at: output.pageCount)
      }
    }

    if let root = source.outlineRoot {
      output.outlineRoot = copyOutline(
        root,
        sourceDocument: source,
        outputDocument: output
      )
    }

    guard let data = output.dataRepresentation() else {
      throw TranslatedPDFExporterError.unableToSerialize
    }
    return data
  }

  /// Label-compatible alias for app code that calls the source bytes `originalData`.
  public func export(
    originalData: Data,
    translatedBlocksByPage: [[ExportParagraphBlock]] = [],
    replacementPagesByPage: [Data?] = [],
    fontName: String = "",
    serif: Bool = false
  ) throws -> Data {
    try export(
      originalPDFData: originalData,
      paragraphsByPage: translatedBlocksByPage,
      replacementPDFDataByPage: replacementPagesByPage,
      fontName: fontName,
      serif: serif
    )
  }

  private func renderTranslatedPage(
    _ sourcePage: PDFPage,
    blocks: [ExportParagraphBlock],
    index: Int,
    fontName: String,
    serif: Bool
  ) throws -> PDFPage {
    guard let pageRef = sourcePage.pageRef else {
      throw TranslatedPDFExporterError.unableToRenderPage(index: index)
    }

    let mediaBox = sourcePage.bounds(for: .mediaBox)
    guard mediaBox.width > 0, mediaBox.height > 0 else {
      throw TranslatedPDFExporterError.unableToRenderPage(index: index)
    }

    let outputBytes = NSMutableData()
    guard let consumer = CGDataConsumer(data: outputBytes) else {
      throw TranslatedPDFExporterError.unableToRenderPage(index: index)
    }
    var outputMediaBox = mediaBox
    guard let context = CGContext(consumer: consumer, mediaBox: &outputMediaBox, nil) else {
      throw TranslatedPDFExporterError.unableToRenderPage(index: index)
    }

    context.beginPDFPage(nil)
    context.saveGState()
    context.drawPDFPage(pageRef)
    context.restoreGState()

    try draw(
      blocks,
      for: sourcePage,
      in: context,
      pageIndex: index,
      fontName: fontName,
      serif: serif
    )
    context.endPDFPage()
    context.closePDF()

    guard let generatedDocument = PDFDocument(data: outputBytes as Data),
      let generatedPage = generatedDocument.page(at: 0),
      let page = generatedPage.copy() as? PDFPage
    else {
      throw TranslatedPDFExporterError.unableToRenderPage(index: index)
    }

    page.rotation = sourcePage.rotation
    for box in Self.displayBoxes {
      page.setBounds(sourcePage.bounds(for: box), for: box)
    }

    // The page content stream does not include PDF annotations. Copy them when possible so
    // an exported translated page keeps the P3 highlights/comments alongside vector content.
    for annotation in sourcePage.annotations {
      if let copy = annotation.copy() as? PDFAnnotation {
        page.addAnnotation(copy)
      }
    }
    return page
  }

  private func draw(
    _ blocks: [ExportParagraphBlock],
    for page: PDFPage,
    in context: CGContext,
    pageIndex: Int,
    fontName: String,
    serif: Bool
  ) throws {
    let cropBox = page.bounds(for: .cropBox)
    let rotation = normalizedRotation(page.rotation)
    let displayHeight = (rotation == 90 || rotation == 270) ? cropBox.width : cropBox.height
    let transform = displayToPageTransform(cropBox: cropBox, rotation: rotation)

    context.saveGState()
    context.concatenate(transform)
    for (blockIndex, block) in blocks.enumerated() {
      guard block.x.isFinite, block.y.isFinite, block.width.isFinite,
        block.height.isFinite, block.fontSize.isFinite,
        block.width > 0, block.height > 0, block.fontSize > 0
      else {
        context.restoreGState()
        throw TranslatedPDFExporterError.invalidParagraph(page: pageIndex, index: blockIndex)
      }

      let fontSize = CGFloat(block.fontSize)
      let padding = min(
        max(1.5, fontSize * 0.28),
        min(CGFloat(block.width), CGFloat(block.height)) * 0.25
      )
      let background = displayRect(
        x: CGFloat(block.x) - padding,
        y: CGFloat(block.y) - padding,
        width: CGFloat(block.width) + padding * 2,
        height: max(CGFloat(block.height), fontSize * 1.1) + padding * 2,
        displayHeight: CGFloat(displayHeight)
      )
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(background)

      let textRect = displayRect(
        x: CGFloat(block.x),
        y: CGFloat(block.y),
        width: CGFloat(block.width),
        height: max(CGFloat(block.height), fontSize * 1.1),
        displayHeight: CGFloat(displayHeight)
      )
      drawFittedText(
        block.translation,
        in: textRect,
        fontSize: fontSize,
        bold: block.bold,
        alignment: block.textAlign,
        context: context,
        fontName: fontName,
        serif: serif
      )
    }
    context.restoreGState()
  }

  private func drawFittedText(
    _ text: String,
    in rect: CGRect,
    fontSize: CGFloat,
    bold: Bool,
    alignment: String?,
    context: CGContext,
    fontName: String,
    serif: Bool
  ) {
    guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }

    var size = fontSize
    var framesetter = makeFramesetter(
      text: text,
      fontSize: size,
      bold: bold,
      alignment: alignment,
      fontName: fontName,
      serif: serif
    )
    while size > 0.5 {
      let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: 0, length: 0),
        nil,
        CGSize(width: rect.width, height: .greatestFiniteMagnitude),
        nil
      )
      if suggested.height <= rect.height + 0.5 { break }
      size -= 0.5
      framesetter = makeFramesetter(
        text: text,
        fontSize: size,
        bold: bold,
        alignment: alignment,
        fontName: fontName,
        serif: serif
      )
    }

    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(
      framesetter,
      CFRange(location: 0, length: 0),
      path,
      nil
    )
    CTFrameDraw(frame, context)
  }

  private func makeFramesetter(
    text: String,
    fontSize: CGFloat,
    bold: Bool,
    alignment: String?,
    fontName: String,
    serif: Bool
  ) -> CTFramesetter {
    let font = Self.resolveFont(
      name: fontName,
      serif: serif,
      size: fontSize,
      bold: bold
    )

    var textAlignment: CTTextAlignment
    switch alignment?.lowercased() {
    case "center", "centre":
      textAlignment = .center
    case "right", "end":
      textAlignment = .right
    default:
      textAlignment = .left
    }
    let paragraphStyle = withUnsafePointer(to: &textAlignment) { pointer -> CTParagraphStyle in
      var setting = CTParagraphStyleSetting(
        spec: .alignment,
        valueSize: MemoryLayout<CTTextAlignment>.size,
        value: pointer
      )
      return CTParagraphStyleCreate(&setting, 1)
    }
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
    ]
    return CTFramesetterCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes)
    )
  }

  private func displayRect(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    displayHeight: CGFloat
  ) -> CGRect {
    CGRect(x: x, y: displayHeight - y - height, width: width, height: height)
  }

  private func displayToPageTransform(cropBox: CGRect, rotation: Int) -> CGAffineTransform {
    switch rotation {
    case 90:
      return CGAffineTransform(
        a: 0,
        b: 1,
        c: -1,
        d: 0,
        tx: cropBox.maxX,
        ty: cropBox.minY
      )
    case 180:
      return CGAffineTransform(
        a: -1,
        b: 0,
        c: 0,
        d: -1,
        tx: cropBox.maxX,
        ty: cropBox.maxY
      )
    case 270:
      return CGAffineTransform(
        a: 0,
        b: -1,
        c: 1,
        d: 0,
        tx: cropBox.minX,
        ty: cropBox.maxY
      )
    default:
      return CGAffineTransform(
        a: 1,
        b: 0,
        c: 0,
        d: 1,
        tx: cropBox.minX,
        ty: cropBox.minY
      )
    }
  }

  private func normalizedRotation(_ rotation: Int) -> Int {
    let normalized = ((rotation % 360) + 360) % 360
    switch normalized {
    case 90, 180, 270:
      return normalized
    default:
      return 0
    }
  }

  private func copyOutline(
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
      if index < sourceDocument.pageCount, let outputPage = outputDocument.page(at: index) {
        let destination = PDFDestination(page: outputPage, at: sourceDestination.point)
        destination.zoom = sourceDestination.zoom
        copy.destination = destination
      }
    }

    for childIndex in 0..<sourceOutline.numberOfChildren {
      guard let child = sourceOutline.child(at: childIndex) else { continue }
      copy.insertChild(
        copyOutline(child, sourceDocument: sourceDocument, outputDocument: outputDocument),
        at: copy.numberOfChildren
      )
    }
    return copy
  }

  private static let displayBoxes: [PDFDisplayBox] = [
    .mediaBox,
    .cropBox,
    .bleedBox,
    .trimBox,
    .artBox,
  ]

  /// Resolves saved names without importing UIKit: a saved name may be either an installed
  /// family name or an installed PostScript name. CoreText silently substitutes Helvetica
  /// for unknown names, so availability is checked before creation.
  private static func resolveFont(
    name: String,
    serif: Bool,
    size: CGFloat,
    bold: Bool
  ) -> CTFont {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackName: String
    if serif {
      fallbackName = ["Iowan Old Style", "Georgia", "Times New Roman", "TimesNewRomanPSMT"]
        .first { Self.availableFontFamilies.contains($0) || Self.availablePostScriptNames.contains($0) }
        ?? Self.preferredCJKFontName
        ?? "Helvetica"
    } else {
      fallbackName = Self.preferredCJKFontName ?? "Helvetica"
    }

    let resolvedName: String
    if let family = Self.availableFontFamilies.first(where: {
      $0.caseInsensitiveCompare(trimmedName) == .orderedSame
    }) {
      resolvedName = family
    } else if let postScript = Self.availablePostScriptNames.first(where: {
      $0.caseInsensitiveCompare(trimmedName) == .orderedSame
    }) {
      resolvedName = postScript
    } else {
      resolvedName = fallbackName
    }

    let baseFont = CTFontCreateWithName(resolvedName as CFString, size, nil)
    guard bold,
      let boldFont = CTFontCreateCopyWithSymbolicTraits(
        baseFont,
        size,
        nil,
        .traitBold,
        .traitBold
      )
    else {
      return baseFont
    }
    return boldFont
  }

  private static let availableFontFamilies: [String] =
    (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []

  private static let availablePostScriptNames: [String] =
    (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []

  private static let preferredCJKFontName: String? = {
    let available = Set(
      (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
    )
    for candidate in [
      "HiraginoSansGB-W3",
      "PingFangSC-Regular",
      "STHeitiSC-Light",
      "ArialUnicodeMS",
    ] where available.contains(candidate) {
      return candidate
    }
    return nil
  }()
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
