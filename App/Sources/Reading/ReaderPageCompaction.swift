import CoreGraphics
import PDFKit
import ReaderCore
import UIKit

/// A page whose large vertical gaps are represented by a shorter display page.
///
/// Coordinates used by the reading models are top down and relative to the
/// crop box. PDFKit points and rectangles remain in page space and use the
/// usual bottom left origin. The source page is copied when this value is
/// created so display compaction never mutates the document being read.
@MainActor
struct ReaderPageCompaction {
  let sourcePage: PDFPage
  let cuts: [CompactCut]
  let sourceBounds: CGRect
  let displayBounds: CGRect

  /// Keep the copied source page alive. PDFPage's document property is weak.
  private let sourceDocument: PDFDocument

  private init(
    sourcePage: PDFPage,
    sourceDocument: PDFDocument,
    cuts: [CompactCut],
    sourceBounds: CGRect
  ) {
    self.sourcePage = sourcePage
    self.sourceDocument = sourceDocument
    self.cuts = cuts
    self.sourceBounds = sourceBounds
    let removed = cuts.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
    self.displayBounds = CGRect(
      x: sourceBounds.minX,
      y: sourceBounds.minY,
      width: sourceBounds.width,
      height: max(0, sourceBounds.height - CGFloat(removed))
    )
  }

  /// Builds compaction from `page`, optionally using another page's content
  /// for occupancy analysis (for example, a translated remote PDF).
  static func make(
    page: PDFPage,
    analysisPage: PDFPage? = nil,
    protecting: [CGRect] = []
  ) -> ReaderPageCompaction? {
    guard page.rotation % 360 == 0 else { return nil }
    let sourceBounds = page.bounds(for: .cropBox).standardized
    guard validBounds(sourceBounds) else { return nil }

    // PDFPage has a single-page PDF representation. Keeping that document,
    // rather than the caller's live document, avoids retaining a whole reader
    // session when a compacted page is replaced.
    let sourceDocument: PDFDocument
    let sourcePage: PDFPage
    if let data = page.dataRepresentation,
      let document = PDFDocument(data: data),
      let copiedPage = document.page(at: 0)
    {
      sourceDocument = document
      sourcePage = copiedPage
    } else if let copiedPage = page.copy() as? PDFPage {
      let document = PDFDocument()
      document.insert(copiedPage, at: 0)
      sourceDocument = document
      sourcePage = copiedPage
    } else {
      return nil
    }

    let analyzed = analysisPage ?? sourcePage
    guard analyzed.rotation % 360 == 0 else { return nil }
    let analysisBounds = analyzed.bounds(for: .cropBox).standardized
    guard validBounds(analysisBounds),
      abs(analysisBounds.width - sourceBounds.width) < 0.5,
      abs(analysisBounds.height - sourceBounds.height) < 0.5
    else { return nil }

    guard let lineHeight = estimatedLineHeight(for: analyzed) else { return nil }
    guard let raster = rasterOccupancy(for: analyzed, bounds: analysisBounds) else {
      return nil
    }

    var occupied = raster.rows
    let scale = raster.scale
    let protectedRects = protecting + annotationProtectionRects(on: page)
      + annotationProtectionRects(on: analyzed)
    markProtected(protectedRects, occupied: &occupied, bounds: sourceBounds, scale: scale)

    let cuts = compactBands(
      occupied,
      rowScale: Double(scale),
      pageHeight: Double(sourceBounds.height),
      lineHeight: Double(lineHeight)
    )
    guard !cuts.isEmpty else { return nil }
    return ReaderPageCompaction(
      sourcePage: sourcePage,
      sourceDocument: sourceDocument,
      cuts: cuts,
      sourceBounds: sourceBounds
    )
  }

  /// Maps a top down source rectangle into the compact display coordinate
  /// system. The returned rectangle remains relative to the crop box.
  func displayRect(_ rect: ReadingRectangle) -> ReadingRectangle {
    mapCompactRect(rect, cuts: cuts) ?? rect
  }

  /// Maps a compact display rectangle back into source top down coordinates.
  func sourceRect(_ rect: ReadingRectangle) -> ReadingRectangle {
    mapCompactRect(rect, cuts: cuts, inverse: true) ?? rect
  }

  /// Maps an absolute PDF page point from the source page into the compact
  /// display page. Both the input and result use PDFKit's bottom left origin.
  func displayPoint(_ point: CGPoint) -> CGPoint {
    let sourceTop = Double(sourceBounds.maxY - point.y)
    let displayTop = mapCompactY(sourceTop, cuts: cuts)
    return CGPoint(
      x: displayBounds.minX + (point.x - sourceBounds.minX),
      y: displayBounds.maxY - CGFloat(displayTop)
    )
  }

  /// Maps an absolute PDF page point from the compact display page back to
  /// the source page. Both the input and result use PDFKit's bottom left
  /// origin.
  func sourcePoint(_ point: CGPoint) -> CGPoint {
    let displayTop = Double(displayBounds.maxY - point.y)
    let sourceTop = mapCompactY(displayTop, cuts: cuts, inverse: true)
    return CGPoint(
      x: sourceBounds.minX + (point.x - displayBounds.minX),
      y: sourceBounds.maxY - CGFloat(sourceTop)
    )
  }

  /// Restore the latest live annotations, including visibility and ink, when
  /// switching back from the temporary display page.
  func synchronizeAnnotations(from page: PDFPage) {
    for annotation in sourcePage.annotations { sourcePage.removeAnnotation(annotation) }
    for annotation in page.annotations {
      guard let copy = annotation.copy() as? PDFAnnotation else { continue }
      let lower = sourcePoint(annotation.bounds.origin)
      let upper = sourcePoint(CGPoint(x: annotation.bounds.maxX, y: annotation.bounds.maxY))
      copy.bounds = CGRect(x: lower.x, y: lower.y, width: upper.x - lower.x, height: upper.y - lower.y)
      if let points = annotation.quadrilateralPoints {
        copy.quadrilateralPoints = points.map {
          let point = sourcePoint(CGPoint(x: annotation.bounds.minX + $0.cgPointValue.x,
                                          y: annotation.bounds.minY + $0.cgPointValue.y))
          return NSValue(cgPoint: CGPoint(x: point.x - copy.bounds.minX, y: point.y - copy.bounds.minY))
        }
      }
      sourcePage.addAnnotation(copy)
    }
  }

  /// Returns a vector PDF with the same content as `page`, shortened by the
  /// cuts. The page must have the same crop box dimensions as the analyzed
  /// source page. PDF annotations are copied from `sourcePage` after the
  /// vector content is drawn because CGPDFPage drawing excludes annotations.
  func pdfData(for page: PDFPage) -> Data? {
    guard page.rotation % 360 == 0,
      let pageRef = page.pageRef
    else { return nil }

    let inputBounds = page.bounds(for: .cropBox).standardized
    guard Self.validBounds(inputBounds),
      abs(inputBounds.width - sourceBounds.width) < 0.5,
      abs(inputBounds.height - sourceBounds.height) < 0.5
    else { return nil }

    let outputBounds = CGRect(
      x: inputBounds.minX,
      y: inputBounds.minY,
      width: inputBounds.width,
      height: displayBounds.height
    )
    let bytes = NSMutableData()
    var mediaBox = outputBounds
    guard let consumer = CGDataConsumer(data: bytes),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { return nil }

    context.beginPDFPage(nil)
    drawRetainedBands(
      pageRef: pageRef,
      inputBounds: inputBounds,
      outputBounds: outputBounds,
      in: context
    )
    context.endPDFPage()
    context.closePDF()

    guard let document = ReaderPDFDocument(data: bytes as Data),
      let generated = document.page(at: 0)
    else { return nil }

    generated.rotation = page.rotation
    for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
      generated.setBounds(outputBounds, for: box)
    }
    copyAnnotations(from: sourcePage, to: generated, outputBounds: outputBounds)
    return document.dataRepresentation()
  }

  /// Creates a display page for immediate insertion into the reader document.
  func makePage() -> ReaderPDFPage? {
    guard let data = pdfData(for: sourcePage),
      let document = ReaderPDFDocument(data: data),
      let page = document.detachedPage(at: 0) as? ReaderPDFPage
    else { return nil }
    page.configureCompactedText(source: sourcePage, mapPoint: displayPoint)
    page.compaction = self
    return page
  }
}

private extension ReaderPageCompaction {
  struct RasterOccupancy {
    let rows: [Bool]
    let scale: CGFloat
  }

  static func validBounds(_ bounds: CGRect) -> Bool {
    bounds.width > 0 && bounds.height > 0 && bounds.width.isFinite && bounds.height.isFinite
      && bounds.minX.isFinite && bounds.minY.isFinite
      && bounds.maxX.isFinite && bounds.maxY.isFinite
  }

  static func estimatedLineHeight(for page: PDFPage) -> CGFloat? {
    guard let text = page.string,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    let items = PDFKitTextExtractor.extract(page: page)
    if let lineHeight = typicalLineHeight(items.map(ReadingTextRun.init)),
      lineHeight.isFinite, lineHeight > 0
    {
      return CGFloat(lineHeight)
    }

    // Some PDFs expose an attributed string but no usable character geometry.
    // Use its median font size, with the same 4...60 point safety bounds as
    // the shared desktop heuristic, and a conventional leading factor.
    guard let attributed = page.attributedString else { return nil }
    var sizes: [CGFloat] = []
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) {
      value, _, _ in
      #if os(iOS)
      if let font = value as? UIFont, font.pointSize > 4, font.pointSize < 60 {
        sizes.append(font.pointSize)
      }
      #elseif os(macOS)
      if let font = value as? NSFont, font.pointSize > 4, font.pointSize < 60 {
        sizes.append(font.pointSize)
      }
      #endif
    }
    guard let median = sizes.sorted().dropFirst(max(0, (sizes.count - 1) / 2)).first,
      median.isFinite
    else { return nil }
    return median * 1.2
  }

  static func rasterOccupancy(for page: PDFPage, bounds: CGRect) -> RasterOccupancy? {
    let scale = min(1, 768 / bounds.width)
    let width = Int(ceil(bounds.width * scale))
    let height = Int(ceil(bounds.height * scale))
    guard width > 0, height > 0, height <= 8192 else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    ).image { renderer in
      let context = renderer.cgContext
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      context.saveGState()
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: scale, y: -scale)
      context.translateBy(x: -bounds.minX, y: -bounds.minY)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    guard let cgImage = image.cgImage else { return nil }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var rows = Array(repeating: false, count: height)
    for pixelY in 0..<height {
      let row = pixelY
      var occupied = false
      for pixelX in 0..<width {
        let offset = (pixelY * width + pixelX) * 4
        let alpha = pixels[offset + 3]
        let minimum = min(pixels[offset], pixels[offset + 1], pixels[offset + 2])
        if alpha > 32 && minimum < 238 {
          occupied = true
          break
        }
      }
      rows[row] = occupied
    }
    return RasterOccupancy(rows: rows, scale: scale)
  }

  static func annotationProtectionRects(on page: PDFPage) -> [CGRect] {
    page.annotations.flatMap { annotation in
      var rects: [CGRect] = []
      let bounds = annotation.bounds.standardized
      if validBounds(bounds) { rects.append(bounds) }
      if let points = annotation.quadrilateralPoints {
        var quad = CGRect.null
        for point in points {
          quad = quad.union(CGRect(origin: CGPoint(x: bounds.minX + point.cgPointValue.x,
                                                     y: bounds.minY + point.cgPointValue.y), size: .zero))
        }
        if !quad.isNull {
          rects.append(quad.insetBy(dx: -0.5, dy: -0.5))
        }
      }
      return rects
    }
  }

  static func markProtected(
    _ rects: [CGRect],
    occupied: inout [Bool],
    bounds: CGRect,
    scale: CGFloat
  ) {
    guard !occupied.isEmpty, scale > 0 else { return }
    for rect in rects {
      let clipped = rect.standardized.intersection(bounds)
      guard !clipped.isNull, clipped.width >= 0, clipped.height >= 0 else { continue }
      let top = max(0, Int(floor((bounds.maxY - clipped.maxY) * scale)) - 1)
      let bottom = min(
        occupied.count,
        Int(ceil((bounds.maxY - clipped.minY) * scale)) + 1
      )
      guard top < bottom else { continue }
      for row in top..<bottom { occupied[row] = true }
    }
  }

  func drawRetainedBands(
    pageRef: CGPDFPage,
    inputBounds: CGRect,
    outputBounds: CGRect,
    in context: CGContext
  ) {
    var sourceTop = 0.0
    for cut in cuts {
      drawBand(
        pageRef: pageRef,
        sourceTop: sourceTop,
        sourceBottom: cut.start,
        inputBounds: inputBounds,
        outputBounds: outputBounds,
        in: context
      )
      sourceTop = cut.end
    }
    drawBand(
      pageRef: pageRef,
      sourceTop: sourceTop,
      sourceBottom: Double(sourceBounds.height),
      inputBounds: inputBounds,
      outputBounds: outputBounds,
      in: context
    )
  }

  func drawBand(
    pageRef: CGPDFPage,
    sourceTop: Double,
    sourceBottom: Double,
    inputBounds: CGRect,
    outputBounds: CGRect,
    in context: CGContext
  ) {
    guard sourceBottom > sourceTop else { return }
    let mappedTop = mapCompactY(sourceTop, cuts: cuts)
    let mappedBottom = mapCompactY(sourceBottom, cuts: cuts)
    let sourceY = inputBounds.maxY - CGFloat(sourceBottom)
    let destinationY = outputBounds.maxY - CGFloat(mappedBottom)
    let height = CGFloat(mappedBottom - mappedTop)
    guard height > 0, sourceY.isFinite, destinationY.isFinite else { return }

    context.saveGState()
    context.clip(to: CGRect(
      x: outputBounds.minX,
      y: destinationY,
      width: outputBounds.width,
      height: height
    ))
    context.translateBy(x: 0, y: destinationY - sourceY)
    context.drawPDFPage(pageRef)
    context.restoreGState()
  }

  func copyAnnotations(from page: PDFPage, to generated: PDFPage, outputBounds: CGRect) {
    for annotation in page.annotations {
      guard let copy = annotation.copy() as? PDFAnnotation else { continue }
      copy.bounds = displayPDFRect(annotation.bounds, outputBounds: outputBounds)
      if let points = annotation.quadrilateralPoints {
        copy.quadrilateralPoints = points.map { point in
          let absolute = CGPoint(x: annotation.bounds.minX + point.cgPointValue.x,
                                 y: annotation.bounds.minY + point.cgPointValue.y)
          let mapped = displayPoint(absolute)
          return NSValue(cgPoint: CGPoint(x: mapped.x - copy.bounds.minX, y: mapped.y - copy.bounds.minY))
        }
      }
      generated.addAnnotation(copy)
    }
  }

  func displayPDFRect(_ rect: CGRect, outputBounds: CGRect) -> CGRect {
    let normalized = rect.standardized
    let sourceTop = sourceBounds.maxY - normalized.maxY
    let reading = ReadingRectangle(
      x: Double(normalized.minX - sourceBounds.minX),
      y: Double(sourceTop),
      width: Double(normalized.width),
      height: Double(normalized.height)
    )
    let mapped = displayRect(reading)
    return CGRect(
      x: outputBounds.minX + CGFloat(mapped.x),
      y: outputBounds.maxY - CGFloat(mapped.y + mapped.height),
      width: CGFloat(mapped.width),
      height: CGFloat(mapped.height)
    )
  }
}
