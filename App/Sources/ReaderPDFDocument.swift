import CoreImage
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
  private struct BionicPageRegions: @unchecked Sendable {
    weak var page: PDFPage?
    var rects: [CGRect]
  }
  private struct BionicState: Sendable {
    var options = BionicReadingOptions()
    var regions: [ObjectIdentifier: BionicPageRegions] = [:]
  }
  private let bionicLock = OSAllocatedUnfairLock(uncheckedState: BionicState())

  var bionicOptions: BionicReadingOptions {
    get { bionicLock.withLock { $0.options } }
    set {
      bionicLock.withLock {
        let next = BionicReading.normalize(newValue)
        guard next != $0.options else { return }
        $0.options = next
        $0.regions.removeAll()
      }
    }
  }

  func bionicRegions(on page: PDFPage) -> [CGRect] {
    // The synchronous closure stays on the drawing thread; PDFKit objects
    // are not transferred to another executor. Serialize geometry extraction.
    bionicLock.withLockUnchecked { state in
      guard BionicReading.active(state.options) else { return [] }
      let key = ObjectIdentifier(page)
      if let cached = state.regions[key], cached.page === page { return cached.rects }
      let regions = BionicReading.ranges(in: page.string ?? "", options: state.options).flatMap { range -> [CGRect] in
        let start = min(page.numberOfCharacters, max(0, range.start))
        let end = min(page.numberOfCharacters, max(start, range.end))
        let glyphs = (start..<end)
          .map { page.characterBounds(at: $0) }
          .filter { !$0.isNull && !$0.isEmpty }
        return page.selection(for: NSRange(location: range.start, length: range.end - range.start))?
          .selectionsByLine().map { line in
            let bounds = line.bounds(for: page)
            // Selection boxes include advance widths and can extend into the
            // next letter's ink. Restrict replacement to the prefix glyphs.
            let ink = glyphs.filter { $0.intersects(bounds) }
              .reduce(CGRect.null) { $0.union($1) }
            return bounds.intersection(ink)
          } ?? []
      }.filter { (rect: CGRect) in !rect.isEmpty && !rect.isNull && !rect.isInfinite }
      // Compaction replaces page objects. Bound geometry retained for retired pages.
      if state.regions.count >= max(8, pageCount) { state.regions.removeAll() }
      state.regions[key] = BionicPageRegions(page: page, rects: regions)
      return regions
    }
  }

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

  /// Display compaction never becomes the source of annotation saves or exports.
  @MainActor
  func uncompactedData() -> Data? {
    guard (0..<pageCount).contains(where: { (page(at: $0) as? ReaderPDFPage)?.compaction != nil })
    else { return dataRepresentation() }
    let output = PDFDocument()
    output.documentAttributes = documentAttributes
    for index in 0..<pageCount {
      guard let page = page(at: index) else { return nil }
      let source = (page as? ReaderPDFPage)?.compaction?.sourcePage ?? page
      guard let copy = source.copy() as? PDFPage else { return nil }
      output.insert(copy, at: index)
    }
    return output.dataRepresentation()
  }
}

private nonisolated(unsafe) var compactedTextKey: UInt8 = 0

private final class CompactedTextIndices: NSObject {
  let indices: IndexSet
  init(_ indices: IndexSet) { self.indices = indices }
}

final class ReaderPDFPage: PDFPage {
  @MainActor var compaction: ReaderPageCompaction?
  override var dataRepresentation: Data? {
    ReaderPDFSerialization.withOriginalBoxes { super.dataRepresentation }
  }
  // PDFKit creates page subclasses through Objective-C; Swift stored-property
  // initializers are not guaranteed to run on that path.
  private var visibleText: IndexSet? {
    (objc_getAssociatedObject(self, &compactedTextKey) as? CompactedTextIndices)?.indices
  }

  /// PDFKit extracts even text hidden by a PDF clipping path. Match extracted
  /// characters to their actual displayed source positions before selecting.
  func configureCompactedText(source: PDFPage, mapPoint: (CGPoint) -> CGPoint) {
    var centers: [Int: [CGPoint]] = [:]
    for index in 0..<source.numberOfCharacters {
      let rect = source.characterBounds(at: index)
      guard !rect.isEmpty, !rect.isNull else { continue }
      let point = mapPoint(CGPoint(x: rect.midX, y: rect.midY))
      centers[Int(point.y.rounded()), default: []].append(point)
    }
    var indices = IndexSet()
    for index in 0..<numberOfCharacters {
      let rect = characterBounds(at: index)
      guard !rect.isEmpty, !rect.isNull else { continue }
      let row = Int(rect.midY.rounded())
      if (row - 1...row + 1).contains(where: { key in
        centers[key, default: []].contains {
          abs($0.x - rect.midX) < 0.75 && abs($0.y - rect.midY) < 0.75
        }
      }) { indices.insert(index) }
    }
    // Spaces and line separators often have no character rectangle. Retain
    // them between visible characters so selection does not split every word.
    var cursor = 0
    while cursor < numberOfCharacters {
      let rect = characterBounds(at: cursor)
      guard rect.isEmpty || rect.isNull else { cursor += 1; continue }
      let start = cursor
      repeat { cursor += 1 } while cursor < numberOfCharacters
        && (characterBounds(at: cursor).isEmpty || characterBounds(at: cursor).isNull)
      if start > 0, indices.contains(start - 1), indices.contains(cursor) {
        indices.insert(integersIn: start..<cursor)
      }
    }
    // PDFKit's character geometry omits inserted line separators, while
    // selection ranges index the string including those separators.
    var selectionIndices = IndexSet()
    var glyph = 0
    for (offset, unit) in (string ?? "").utf16.enumerated() {
      if unit == 10 || unit == 13 {
        if glyph > 0, indices.contains(glyph - 1), indices.contains(glyph) {
          selectionIndices.insert(offset)
        }
      } else {
        if indices.contains(glyph) { selectionIndices.insert(offset) }
        glyph += 1
      }
    }
    objc_setAssociatedObject(self, &compactedTextKey, CompactedTextIndices(selectionIndices), .OBJC_ASSOCIATION_RETAIN)
  }

  private func visibleSelection(_ selection: PDFSelection?) -> PDFSelection? {
    guard let selection, let indices = visibleText,
      let document else { return selection }
    let result = PDFSelection(document: document)
    var added = false
    for index in 0..<selection.numberOfTextRanges(on: self) {
      let range = selection.range(at: index, on: self)
      guard range.location != NSNotFound else { continue }
      let selected = indices.intersection(IndexSet(integersIn: range.location..<NSMaxRange(range)))
      for run in selected.rangeView {
        if let part = super.selection(for: NSRange(run)) {
          result.add(part)
          added = true
        }
      }
    }
    return added ? result : nil
  }

  override func selection(for rect: CGRect) -> PDFSelection? {
    visibleSelection(super.selection(for: rect))
  }

  override func selection(for range: NSRange) -> PDFSelection? {
    visibleSelection(super.selection(for: range))
  }

  override func selectionForWord(at point: CGPoint) -> PDFSelection? {
    visibleSelection(super.selectionForWord(at: point))
  }

  override func selectionForLine(at point: CGPoint) -> PDFSelection? {
    visibleSelection(super.selectionForLine(at: point))
  }

  override func selection(from startPoint: CGPoint, to endPoint: CGPoint) -> PDFSelection? {
    visibleSelection(super.selection(from: startPoint, to: endPoint))
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
      drawReadingContent(with: box, to: context)
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
    drawReadingContent(with: box, to: context)
    ReaderDarkPDF.invert(area, in: context)
  }

  private func drawReadingContent(with box: PDFDisplayBox, to context: CGContext) {
    guard !ReaderPDFSerialization.usesOriginalBoxes else {
      super.draw(with: box, to: context)
      return
    }
    let regions = (document as? ReaderPDFDocument)?.bionicRegions(on: self) ?? []
    guard !regions.isEmpty,
      ReaderBionicPDF.draw(in: context, bounds: super.bounds(for: box), regions: regions,
        source: { super.draw(with: box, to: $0) })
    else {
      super.draw(with: box, to: context)
      return
    }
  }

  func drawUninverted(with box: PDFDisplayBox, to context: CGContext) {
    super.draw(with: box, to: context)
  }
}

/// Embolden the PDF's own ink during tile rendering. No substitute font is
/// drawn over existing letters. Prefix pixels replace their source pixels;
/// everything outside those regions keeps PDFKit's normal vector drawing.
enum ReaderBionicPDF {
  private static let imageContext = CIContext(options: [.cacheIntermediates: false])

  static func draw(
    in context: CGContext, bounds: CGRect, regions: [CGRect], source: (CGContext) -> Void
  ) -> Bool {
    let clip = context.boundingBoxOfClipPath.intersection(bounds)
    let visible = regions.filter { $0.intersects(clip) }
    guard !visible.isEmpty else { return false }
    let transform = context.ctm
    let deviceScale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
    guard deviceScale.isFinite, deviceScale > 0 else { return false }
    // Morphology kernels use whole pixels. Supersample low zoom levels so
    // their smallest kernel still represents a quarter-point of source ink.
    let scale = max(4, deviceScale)
    // Padding supplies neighboring ink to the filter at tile boundaries.
    let area = clip.insetBy(dx: -1, dy: -1).intersection(bounds)
    let width = ceil(area.width * scale), height = ceil(area.height * scale)
    guard width > 0, height > 0, width <= 8192, height <= 8192,
      width * height <= 16_777_216,
      let bitmap = CGContext(data: nil, width: Int(width), height: Int(height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Account for pixel rounding so the filtered tile maps back exactly.
    bitmap.scaleBy(x: width / area.width, y: height / area.height)
    bitmap.translateBy(x: -area.minX, y: -area.minY)
    source(bitmap)
    guard let original = bitmap.makeImage() else { return false }
    let image = CIImage(cgImage: original)
    let bold = image.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [
      kCIInputRadiusKey: max(1, 0.22 * scale),
    ])
    guard let rendered = imageContext.createCGImage(bold, from: image.extent) else { return false }

    // Union the rectangles first: overlapping holes in an even-odd path
    // would otherwise restore the original ink in their intersections.
    var remainder = [clip]
    for region in visible {
      remainder = remainder.flatMap { subtract(region, from: $0) }
    }
    context.saveGState()
    context.clip(to: remainder)
    source(context)
    context.restoreGState()
    context.saveGState()
    context.clip(to: visible)
    context.draw(rendered, in: area)
    context.restoreGState()
    return true
  }

  private static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
    let cut = rect.intersection(hole)
    guard !cut.isNull, !cut.isEmpty else { return [rect] }
    return [
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
      CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
      CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
      CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
    ].filter { !$0.isEmpty }
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
  private var pdfData: Data?
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
    guard data != pdfData else { return }
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider) else { return }
    pdfData = data
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
