import PDFKit
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
final class ReaderPDFDocument: PDFDocument {
  private let invertsLock = OSAllocatedUnfairLock(initialState: false)

  /// PDFKit renders page tiles off the main thread, so access is locked.
  var invertsPages: Bool {
    get { invertsLock.withLock { $0 } }
    set { invertsLock.withLock { $0 = newValue } }
  }

  override var pageClass: AnyClass { ReaderPDFPage.self }
}

final class ReaderPDFPage: PDFPage {
  override func draw(with box: PDFDisplayBox, to context: CGContext) {
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
