import CoreText
import PDFKit
import ReaderCore
import UIKit

/// Resolve both installed family names and PostScript names, falling back
/// safely when a saved font is unavailable on this device.
enum ReaderTranslationFont {
  static func resolve(name: String, serif: Bool, size: CGFloat, bold: Bool = false,
                      language: String = "") -> UIFont {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let system = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let fallback = serif
      ? UIFont(descriptor: system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor, size: size)
      : system
    let family = UIFont.familyNames.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    let installed = family.map {
      UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: $0]), size: size)
    } ?? UIFont(name: name, size: size)
    let primary = installed ?? fallback
    var traits = primary.fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    var descriptor = primary.fontDescriptor.withSymbolicTraits(traits) ?? primary.fontDescriptor
    if serif {
      // Latin fonts such as Times do not contain Han glyphs. Without an explicit
      // cascade iOS substitutes PingFang, even when the serif setting is enabled.
      // Bundle this fallback because Songti is not installed on every iOS device.
      let cjkName = bold ? "NotoSerifCJKtc-Bold" : "NotoSerifCJKtc-Regular"
      if let cjk = UIFont(name: cjkName, size: size) {
        descriptor = descriptor.addingAttributes([
          .cascadeList: [cjk.fontDescriptor.addingAttributes(
            language.isEmpty ? [:] : [UIFontDescriptor.AttributeName(rawValue: kCTFontLanguagesAttribute as String): [language]]
          )]
        ])
      }
    }
    if !language.isEmpty { descriptor = descriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontLanguagesAttribute as String): [language]]) }
    return UIFont(descriptor: descriptor, size: size)
  }
}

/// Restyles selectable translated words locally. Unchanged source words and
/// math fonts retain their kernel appearance, along with diagrams and rules.
@MainActor
struct ReaderRemoteTranslationFont {
  struct Run {
    let text: String
    let rect: CGRect
    let font: UIFont
    let color: UIColor
  }

  let page: PDFPage
  let runs: [Run]
  // PDFPage only weakly references its document. PDFKit requires the owning
  // document to remain alive when generating subsequent thumbnails.
  private let document: PDFDocument?

  init(page: PDFPage, original: PDFPage?) {
    self.page = page
    document = page.document
    let source = Dictionary(grouping: original.map(Self.words) ?? [], by: \.text)
    runs = Self.words(page).filter { run in
      let fontName = run.font.fontName.lowercased()
      guard !["math", "symbol", "cmmi", "cmsy", "cmex", "cmr", "stix", "msam", "msbm"].contains(where: fontName.contains),
        !run.text.unicodeScalars.contains(where: { $0.properties.generalCategory == .mathSymbol }),
        run.text.unicodeScalars.contains(where: CharacterSet.letters.contains)
      else { return false }
      // Kernel PDFs retain source equations and untranslated text. Compare in
      // page space, rather than excluding every occurrence of a source word.
      return !(source[run.text] ?? []).contains { candidate in
        abs(candidate.rect.minX - run.rect.minX) < 2 &&
          abs(candidate.rect.midY - run.rect.midY) < 2 &&
          abs(candidate.rect.width - run.rect.width) < 2
      }
    }
  }

  func image(size: CGSize, name: String, serif: Bool, language: String = "") -> UIImage {
    defer { withExtendedLifetime(document) {} }
    let original = page.thumbnail(of: size, for: .cropBox)
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || serif,
      !runs.isEmpty
    else { return original }
    // PDFPage's crop/rotation can differ from its underlying CGPDFPage after
    // edits. Use the PDFKit geometry, just as its thumbnail does.
    let imageBounds = CGRect(origin: .zero, size: original.size)
    let crop = page.bounds(for: .cropBox)
    guard crop.width > 0, crop.height > 0 else { return original }
    let transform = pageToImageTransform(size: original.size)
    let format = UIGraphicsImageRendererFormat()
    format.scale = original.scale
    return UIGraphicsImageRenderer(size: original.size, format: format).image { renderer in
      original.draw(in: imageBounds)
      renderer.cgContext.saveGState()
      renderer.cgContext.concatenate(transform)
      drawRuns(in: renderer.cgContext, background: original, transform: transform, name: name, serif: serif, language: language)
      renderer.cgContext.restoreGState()
    }
  }

  /// Keep the kernel's vector content and add selectable text in the chosen font.
  /// Only the background color is sampled from a thumbnail; the PDF is not rasterized.
  func pdfData(name: String, serif: Bool, language: String = "") throws -> Data {
    defer { withExtendedLifetime(document) {} }
    guard let pageRef = page.pageRef else { throw TranslatedPDFExporterError.unableToSerialize }
    let bytes = NSMutableData()
    var mediaBox = page.bounds(for: .mediaBox)
    guard let consumer = CGDataConsumer(data: bytes),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw TranslatedPDFExporterError.unableToSerialize }
    context.beginPDFPage(nil)
    context.drawPDFPage(pageRef)
    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || serif {
      let crop = page.bounds(for: .cropBox)
      let background = page.thumbnail(of: crop.size, for: .cropBox)
      UIGraphicsPushContext(context)
      drawRuns(in: context, background: background,
               transform: pageToImageTransform(size: background.size), name: name, serif: serif, language: language)
      UIGraphicsPopContext()
    }
    context.endPDFPage()
    context.closePDF()
    guard let output = PDFDocument(data: bytes as Data), let generated = output.page(at: 0) else {
      throw TranslatedPDFExporterError.unableToSerialize
    }
    generated.rotation = page.rotation
    for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
      generated.setBounds(page.bounds(for: box), for: box)
    }
    for annotation in page.annotations {
      if let copy = annotation.copy() as? PDFAnnotation { generated.addAnnotation(copy) }
    }
    guard let data = output.dataRepresentation() else { throw TranslatedPDFExporterError.unableToSerialize }
    return data
  }

  private func pageToImageTransform(size: CGSize) -> CGAffineTransform {
    let crop = page.bounds(for: .cropBox)
    let imageBounds = CGRect(origin: .zero, size: size)
    let rotation = ((page.rotation % 360) + 360) % 360
    let rotated = rotation == 90 || rotation == 270
    let sx = imageBounds.width / (rotated ? crop.height : crop.width)
    let sy = imageBounds.height / (rotated ? crop.width : crop.height)
    let transform: CGAffineTransform
    switch rotation {
    case 90:
      transform = CGAffineTransform(a: 0, b: sy, c: sx, d: 0, tx: -crop.minY * sx, ty: -crop.minX * sy)
    case 180:
      transform = CGAffineTransform(a: -sx, b: 0, c: 0, d: sy, tx: crop.maxX * sx, ty: -crop.minY * sy)
    case 270:
      transform = CGAffineTransform(a: 0, b: -sy, c: -sx, d: 0, tx: crop.maxY * sx, ty: crop.maxX * sy)
    default:
      transform = CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: -crop.minX * sx, ty: crop.maxY * sy)
    }
    return transform
  }

  private func drawRuns(in context: CGContext, background: UIImage, transform: CGAffineTransform,
                        name: String, serif: Bool, language: String) {
    let regular = ReaderTranslationFont.resolve(name: name, serif: serif, size: 1, language: language)
    let bold = ReaderTranslationFont.resolve(name: name, serif: serif, size: 1, bold: true, language: language)
    for run in runs {
      let rect = CGRect(origin: .zero, size: run.rect.size)
      guard rect.width > 0, rect.height > 0 else { continue }
      let isBold = run.font.fontDescriptor.symbolicTraits.contains(.traitBold)
        || run.font.fontName.localizedCaseInsensitiveContains("bold")
      var font = (isBold ? bold : regular).withSize(run.font.pointSize)
      let measured = (run.text as NSString).size(withAttributes: [.font: font])
      let fit = min(1, rect.width / max(1, measured.width), rect.height / max(1, measured.height))
      font = font.withSize(font.pointSize * fit)
      context.saveGState()
      context.translateBy(x: run.rect.minX, y: run.rect.maxY)
      context.scaleBy(x: 1, y: -1)
      context.clip(to: rect.insetBy(dx: -0.5, dy: -0.5))
      backgroundColor(in: background, beside: run.rect.applying(transform).standardized).setFill()
      context.fill(rect.insetBy(dx: -0.5, dy: -0.5))
      let height = (run.text as NSString).size(withAttributes: [.font: font]).height
      (run.text as NSString).draw(
        at: CGPoint(x: rect.minX, y: rect.midY - height / 2),
        withAttributes: [.font: font, .foregroundColor: run.color]
      )
      context.restoreGState()
    }
  }

  /// Sample just outside the glyph box so tinted paper and solid caption
  /// backgrounds do not acquire white rectangles when their text is replaced.
  private func backgroundColor(in image: UIImage, beside rect: CGRect) -> UIColor {
    guard let cgImage = image.cgImage else { return .white }
    let x = max(0, min(cgImage.width - 1, Int((rect.minX - 1) * image.scale)))
    let y = max(0, min(cgImage.height - 1, Int((rect.minY - 1) * image.scale)))
    guard let sample = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return .white }
    var pixel = [UInt8](repeating: 0, count: 4)
    return pixel.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return .white }
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      let values = bytes.bindMemory(to: UInt8.self)
      let alpha = CGFloat(values[3]) / 255
      guard alpha > 0 else { return .clear }
      return UIColor(red: CGFloat(values[0]) / 255 / alpha, green: CGFloat(values[1]) / 255 / alpha,
                     blue: CGFloat(values[2]) / 255 / alpha, alpha: alpha)
    }
  }

  private static func words(_ page: PDFPage) -> [Run] {
    guard let text = page.attributedString else { return [] }
    let string = text.string as NSString
    guard let expression = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
    var result: [Run] = []
    for word in expression.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
      text.enumerateAttribute(.font, in: word.range) { value, range, _ in
        guard let font = value as? UIFont,
          let selection = page.selection(for: range)
        else { return }
        let rect = selection.bounds(for: page)
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return }
        result.append(Run(text: string.substring(with: range), rect: rect, font: font,
                          color: text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor ?? .black))
      }
    }
    return result
  }
}
