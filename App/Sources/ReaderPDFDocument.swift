import PDFKit
import ReaderCore
import UIKit
import os

/// Dark appearance dims PDF pages like the desktop reader's
/// `filter: invert(0.75)`: every sRGB channel c becomes 0.75 - 0.5 c, so white
/// paper turns dark gray and black ink turns light gray.
enum ReaderDarkPDF {
  static let amount: CGFloat = 0.75

  static func invert(_ channel: CGFloat) -> CGFloat {
    amount - (2 * amount - 1) * channel
  }

  static func invert(_ color: UIColor) -> UIColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
    return UIColor(red: invert(red), green: invert(green), blue: invert(blue), alpha: alpha)
  }

  /// PDFKit composites highlight annotations above the page drawing, so
  /// they multiply over the dimmed paper instead of being inverted. Marks
  /// drawn on translation covers use the same result to match them.
  static func markOnDimmedPaper(_ color: UIColor) -> UIColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
    let paper = invert(1)
    return UIColor(red: red * paper, green: green * paper, blue: blue * paper, alpha: 1)
  }

  /// `light` as drawn on a page in light mode, and its inverted value in dark mode.
  static func pageColor(_ light: UIColor) -> UIColor {
    UIColor { traits in
      let resolved = light.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceStyle = .light })
      return traits.userInterfaceStyle == .dark ? invert(resolved) : resolved
    }
  }

  /// Applies the inversion to what is already drawn in `rect`, using blend
  /// modes: difference with white gives 1 - c, multiply by 0.5 halves it, and
  /// adding 0.25 lands on 0.75 - 0.5 c.
  static func invert(_ rect: CGRect, in context: CGContext) {
    context.saveGState()
    context.setBlendMode(.difference)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(rect)
    context.setBlendMode(.multiply)
    context.setFillColor(gray: 2 * amount - 1, alpha: 1)
    context.fill(rect)
    context.setBlendMode(.plusLighter)
    context.setFillColor(gray: 1 - amount, alpha: 1)
    context.fill(rect)
    context.restoreGState()
  }

  static func inverted(_ image: UIImage) -> UIImage {
    let format = UIGraphicsImageRendererFormat(for: UITraitCollection(displayScale: image.scale))
    format.opaque = true
    return UIGraphicsImageRenderer(size: image.size, format: format).image { renderer in
      let rect = CGRect(origin: .zero, size: image.size)
      UIColor.white.setFill()
      renderer.fill(rect)
      image.draw(in: rect)
      invert(rect, in: renderer.cgContext)
    }
  }

  /// `light` in light mode and its inverted copy in dark mode, resolved by
  /// UIKit from the displaying view's traits.
  static func appearanceImage(_ light: UIImage) -> UIImage {
    let asset = UIImageAsset()
    asset.register(light, with: UITraitCollection(userInterfaceStyle: .light))
    asset.register(inverted(light), with: UITraitCollection(userInterfaceStyle: .dark))
    return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
  }

  /// Renders a page thumbnail directly, so the result does not depend on
  /// whether PDFKit's own thumbnail path calls `draw(with:to:)`.
  static func thumbnail(of page: PDFPage, fitting size: CGSize, box: PDFDisplayBox, inverted: Bool) -> UIImage {
    let bounds = page.bounds(for: box)
    let rotated = page.rotation % 180 != 0
    let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    guard pageSize.width > 0, pageSize.height > 0 else { return UIImage() }
    let scale = min(size.width / pageSize.width, size.height / pageSize.height)
    let imageSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = true
    return UIGraphicsImageRenderer(size: imageSize, format: format).image { renderer in
      let rect = CGRect(origin: .zero, size: imageSize)
      let context = renderer.cgContext
      UIColor.white.setFill()
      renderer.fill(rect)
      context.saveGState()
      context.translateBy(x: 0, y: imageSize.height)
      context.scaleBy(x: scale, y: -scale)
      page.transform(context, for: box)
      if let page = page as? ReaderPDFPage {
        page.drawUninverted(with: box, to: context)
      } else {
        page.draw(with: box, to: context)
      }
      context.restoreGState()
      if inverted { invert(rect, in: context) }
    }
  }
}

/// The reader's document type. Its pages invert themselves while
/// `invertsPages` is on; exports and cached previews use other documents or
/// draw before the flag is set, so they stay unchanged.
private enum ReaderPDFSerialization {
  static let key = "PDFMathReader.originalPageBoxes"

  static var usesOriginalBoxes: Bool { Thread.current.threadDictionary[key] != nil }

  static func withOriginalBoxes<T>(_ body: () -> T) -> T {
    let dictionary = Thread.current.threadDictionary
    let previous = dictionary[key]
    dictionary[key] = true
    defer { dictionary[key] = previous }
    return body()
  }
}

final class ReaderPDFDocument: PDFDocument {
  private let invertsLock = OSAllocatedUnfairLock(initialState: false)

  private let cropLock = OSAllocatedUnfairLock(initialState: PageCrop())

  /// A virtual display box: the PDF's stored boxes and export data stay intact.
  var pageCrop: PageCrop {
    get { cropLock.withLock { $0 } }
    set { cropLock.withLock { $0 = newValue } }
  }

  /// PDFKit renders page tiles off the main thread, so access is locked.
  var invertsPages: Bool {
    get { invertsLock.withLock { $0 } }
    set { invertsLock.withLock { $0 = newValue } }
  }

  override var pageClass: AnyClass { ReaderPDFPage.self }

  override func dataRepresentation() -> Data? {
    ReaderPDFSerialization.withOriginalBoxes { super.dataRepresentation() }
  }

  override func dataRepresentation(options: [AnyHashable: Any] = [:]) -> Data? {
    ReaderPDFSerialization.withOriginalBoxes { super.dataRepresentation(options: options) }
  }

}

final class ReaderPDFPage: PDFPage {
  override var dataRepresentation: Data? {
    ReaderPDFSerialization.withOriginalBoxes { super.dataRepresentation }
  }
  override func bounds(for box: PDFDisplayBox) -> CGRect {
    guard box == .artBox, !ReaderPDFSerialization.usesOriginalBoxes,
      let document = document as? ReaderPDFDocument else {
      return super.bounds(for: box)
    }
    let source = super.bounds(for: .cropBox)
    let crop = document.pageCrop
    // Fractions describe the total removed in each direction, split equally
    // between opposite edges. Swap axes for a visually rotated page.
    let rotated = rotation % 180 != 0
    return source.insetBy(
      dx: source.width * CGFloat(rotated ? crop.y : crop.x) / 2,
      dy: source.height * CGFloat(rotated ? crop.x : crop.y) / 2
    )
  }

  override func draw(with box: PDFDisplayBox, to context: CGContext) {
    let box: PDFDisplayBox = box == .artBox ? .cropBox : box
    guard (document as? ReaderPDFDocument)?.invertsPages == true else {
      super.draw(with: box, to: context)
      return
    }
    // Tiles clip to the part of the page being rendered; fall back to the
    // page box when the context is unclipped.
    var area = context.boundingBoxOfClipPath
    if area.isNull || area.isInfinite || area.width > 100_000 || area.height > 100_000 {
      area = bounds(for: box)
    }
    // Paper first, so transparent page areas invert to dark gray, not black.
    context.saveGState()
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(area)
    context.restoreGState()
    super.draw(with: box, to: context)
    ReaderDarkPDF.invert(area, in: context)
  }

  func drawUninverted(with box: PDFDisplayBox, to context: CGContext) {
    super.draw(with: box, to: context)
  }
}

/// Keep kernel output as PDF vectors. A full-page UIImage both loses detail
/// when PDFKit zooms its overlay and retains a large bitmap for every page.
final class ReaderPDFTileLayer: CATiledLayer {
  // Core Graphics PDF handles are immutable here and retained together. Only
  // this snapshot crosses into CATiledLayer drawing; view state stays on MainActor.
  struct Content: @unchecked Sendable {
    let document: CGPDFDocument
    let page: CGPDFPage
    let bounds: CGRect
    let inverted: Bool
  }

  let content = OSAllocatedUnfairLock<Content?>(initialState: nil)

  override class func fadeDuration() -> CFTimeInterval { 0 }

  override func draw(in context: CGContext) {
    guard let content = content.withLock({ $0 }) else { return }
    context.saveGState()
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(content.bounds)
    context.translateBy(x: 0, y: content.bounds.height)
    context.scaleBy(x: 1, y: -1)
    context.concatenate(content.page.getDrawingTransform(
      .cropBox, rect: content.bounds, rotate: 0, preserveAspectRatio: true
    ))
    context.drawPDFPage(content.page)
    context.restoreGState()
    if content.inverted { ReaderDarkPDF.invert(content.bounds, in: context) }
    withExtendedLifetime(content.document) {}
  }
}

@MainActor
final class ReaderTiledPDFView: UIView {
  override class var layerClass: AnyClass { ReaderPDFTileLayer.self }
  private var document: CGPDFDocument?
  private var inverted = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    isUserInteractionEnabled = false
    let tiles = layer as! ReaderPDFTileLayer
    tiles.tileSize = CGSize(width: 512, height: 512)
    tiles.levelsOfDetail = 1
    tiles.levelsOfDetailBias = 4
  }

  required init?(coder: NSCoder) { nil }

  func setPDFData(_ data: Data) {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider) else { return }
    self.document = document
    updateContent()
  }

  func setInverted(_ inverted: Bool) {
    guard self.inverted != inverted else { return }
    self.inverted = inverted
    updateContent()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateContent()
  }

  private func updateContent() {
    guard let document, let page = document.page(at: 1), !bounds.isEmpty else { return }
    let tiles = layer as! ReaderPDFTileLayer
    let next = ReaderPDFTileLayer.Content(document: document, page: page, bounds: bounds, inverted: inverted)
    let changed = tiles.content.withLock { content in
      guard content?.document !== next.document || content?.bounds != next.bounds || content?.inverted != next.inverted
      else { return false }
      content = next
      return true
    }
    if changed { tiles.setNeedsDisplay() }
  }
}
