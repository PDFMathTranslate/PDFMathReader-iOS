import CoreText
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderDrawingPDFTests: XCTestCase {
  func testEmbedPreservesPDFContentAnnotationsAndDrawingRoundTrip() throws {
    let source = sourceData(rotations: [0], addAnnotations: true)
    let drawing = sampleDrawing()

    let output = try ReaderDrawingPDF.embed([0: drawing], in: source)
    let document = try XCTUnwrap(PDFDocument(data: output))
    let page = try XCTUnwrap(document.page(at: 0))

    XCTAssertTrue(page.string?.contains("Original vector text 1") == true)
    XCTAssertTrue(page.annotations.contains { $0.contents == "Original comment" })
    let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
    XCTAssertEqual(
      (link.action as? PDFActionURL)?.url,
      URL(string: "https://example.com/original")
    )
    XCTAssertEqual(
      document.documentAttributes?[PDFDocumentAttribute(rawValue: "Title")] as? String,
      "preserve-me"
    )

    let managed = try XCTUnwrap(
      page.annotations.first { $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) != nil }
    )
    XCTAssertTrue(managed.hasAppearanceStream)

    let decoded = try ReaderDrawingPDF.drawings(in: output)
    try assertDrawingMatches(decoded[0], drawing)
  }

  func testEmbedReplacesManagedStampsAndCanRemoveThem() throws {
    let source = sourceData(rotations: [0, 90])
    let first = sampleDrawing(offset: .zero)
    let second = sampleDrawing(offset: CGPoint(x: 25, y: 10))

    let withFirst = try ReaderDrawingPDF.embed([0: first, 1: first], in: source)
    let withSecond = try ReaderDrawingPDF.embed([0: second], in: withFirst)
    let replaced = try XCTUnwrap(PDFDocument(data: withSecond))
    let managed = replaced.page(at: 0)?.annotations.filter {
      $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) != nil
    } ?? []
    XCTAssertEqual(managed.count, 1)
    XCTAssertTrue(
      replaced.page(at: 1)?.annotations.allSatisfy {
        $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) == nil
      } == true
    )
    try assertDrawingMatches(ReaderDrawingPDF.drawings(in: withSecond)[0], second)

    let stripped = try ReaderDrawingPDF.embed([:], in: withSecond)
    let strippedDocument = try XCTUnwrap(PDFDocument(data: stripped))
    XCTAssertTrue(
      (0..<strippedDocument.pageCount).allSatisfy { index in
        strippedDocument.page(at: index)?.annotations.allSatisfy {
          $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) == nil
        } == true
      }
    )
    XCTAssertTrue(try ReaderDrawingPDF.drawings(in: stripped).isEmpty)
  }

  func testEmbedUsesReaderAnnotationPDFCoordinatesForRotatedPages() throws {
    let rotations = [0, 90, 180, 270]
    let source = sourceData(rotations: rotations)
    let sourceDocument = try XCTUnwrap(PDFDocument(data: source))
    let drawing = sampleDrawing()
    let output = try ReaderDrawingPDF.embed(
      Dictionary(uniqueKeysWithValues: rotations.indices.map { ($0, drawing) }),
      in: source
    )
    let outputDocument = try XCTUnwrap(PDFDocument(data: output))

    for pageIndex in rotations.indices {
      let sourcePage = try XCTUnwrap(sourceDocument.page(at: pageIndex))
      let outputPage = try XCTUnwrap(outputDocument.page(at: pageIndex))
      let managed = try XCTUnwrap(
        outputPage.annotations.first { $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) != nil }
      )
      let expected = expectedPDFBounds(for: drawing.bounds, on: sourcePage)
      XCTAssertEqual(managed.bounds.minX, expected.minX, accuracy: 0.5)
      XCTAssertEqual(managed.bounds.minY, expected.minY, accuracy: 0.5)
      XCTAssertEqual(managed.bounds.width, expected.width, accuracy: 0.5)
      XCTAssertEqual(managed.bounds.height, expected.height, accuracy: 0.5)
    }
  }

  func testRotatedAppearanceRendersDrawingPixelsAndPreservesPressureData() throws {
    let source = sourceData(rotations: [90])
    let drawing = pressureDrawing()
    let output = try ReaderDrawingPDF.embed([0: drawing], in: source)
    let document = try XCTUnwrap(PDFDocument(data: output))
    let page = try XCTUnwrap(document.page(at: 0))
    let image = page.thumbnail(of: CGSize(width: 600, height: 600), for: .cropBox)
    let pixels = try XCTUnwrap(image.cgImage)
    let redBounds = try XCTUnwrap(redPixelBounds(in: pixels))

    // A 200 × 300 page rotated by 90 degrees is displayed landscape. The
    // red drawing's bounds also swap axes, proving PDFKit applied page rotation
    // to the persisted appearance stream.
    XCTAssertGreaterThan(image.size.width, image.size.height)
    XCTAssertGreaterThan(redBounds.width, redBounds.height)
    XCTAssertGreaterThan(redBounds.width, 4)
    XCTAssertGreaterThan(redBounds.height, 4)

    // The marker stores the original PencilKit representation, including the
    // pressure values that the raster appearance has already rendered.
    try assertDrawingMatches(ReaderDrawingPDF.drawings(in: output)[0], drawing)
  }

  func testMaskedStrokeRoundTripsThroughPrivateMarker() throws {
    let source = sourceData(rotations: [0])
    let drawing = maskedDrawing()
    let output = try ReaderDrawingPDF.embed([0: drawing], in: source)
    let decodedDrawings = try ReaderDrawingPDF.drawings(in: output)
    let decoded = try XCTUnwrap(decodedDrawings[0])

    try assertDrawingMatches(decoded, drawing)
    XCTAssertNotNil(decoded.strokes.first?.mask)
  }

  func testEmptyValidPDFIsReadableAndEmptyEmbedIsNoOp() throws {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let source = try XCTUnwrap(document.dataRepresentation())

    XCTAssertTrue(try ReaderDrawingPDF.drawings(in: source).isEmpty)
    XCTAssertEqual(try ReaderDrawingPDF.embed([:], in: source), source)
  }

  private func assertDrawingMatches(_ actual: PKDrawing?, _ expected: PKDrawing, file: StaticString = #filePath, line: UInt = #line) throws {
    let actual = try XCTUnwrap(actual, file: file, line: line)
    // PencilKit normalizes its archive when decoding. Compare the editable
    // stroke data rather than requiring byte-identical reserialization.
    XCTAssertEqual(actual.bounds, expected.bounds, file: file, line: line)
    XCTAssertEqual(actual.strokes.count, expected.strokes.count, file: file, line: line)
    for (a, b) in zip(actual.strokes, expected.strokes) {
      XCTAssertEqual(a.ink.inkType, b.ink.inkType, file: file, line: line)
      var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
      var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
      XCTAssertTrue(a.ink.color.getRed(&ar, green: &ag, blue: &ab, alpha: &aa), file: file, line: line)
      XCTAssertTrue(b.ink.color.getRed(&br, green: &bg, blue: &bb, alpha: &ba), file: file, line: line)
      for (x, y) in zip([ar, ag, ab, aa], [br, bg, bb, ba]) {
        XCTAssertEqual(x, y, accuracy: 0.001, file: file, line: line)
      }
      XCTAssertEqual(a.transform, b.transform, file: file, line: line)
      XCTAssertEqual(a.mask?.bounds, b.mask?.bounds, file: file, line: line)
      XCTAssertEqual(a.path.count, b.path.count, file: file, line: line)
      for (p, q) in zip(a.path, b.path) {
        XCTAssertEqual(p.location, q.location, file: file, line: line)
        XCTAssertEqual(p.size, q.size, file: file, line: line)
        XCTAssertEqual(p.force, q.force, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(p.opacity, q.opacity, accuracy: 0.001, file: file, line: line)
      }
    }
  }

  private func sampleDrawing(offset: CGPoint = .zero) -> PKDrawing {
    let points = [
      CGPoint(x: 20 + offset.x, y: 30 + offset.y),
      CGPoint(x: 80 + offset.x, y: 100 + offset.y),
    ].enumerated().map { index, point in
      PKStrokePoint(
        location: point,
        timeOffset: Double(index) * 0.1,
        size: CGSize(width: 3, height: 3),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      )
    }
    return PKDrawing(strokes: [
      PKStroke(
        ink: PKInk(.pen, color: .systemRed),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
      )
    ])
  }

  private func pressureDrawing() -> PKDrawing {
    let points = [
      PKStrokePoint(
        location: CGPoint(x: 20, y: 30),
        timeOffset: 0,
        size: CGSize(width: 3, height: 3),
        opacity: 1,
        force: 0.25,
        azimuth: 0,
        altitude: .pi / 2
      ),
      PKStrokePoint(
        location: CGPoint(x: 80, y: 100),
        timeOffset: 0.1,
        size: CGSize(width: 14, height: 14),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      ),
    ]
    return PKDrawing(strokes: [
      PKStroke(
        ink: PKInk(.pen, color: .systemRed),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
      )
    ])
  }

  private func maskedDrawing() -> PKDrawing {
    let points = [
      PKStrokePoint(
        location: CGPoint(x: 20, y: 30),
        timeOffset: 0,
        size: CGSize(width: 3, height: 3),
        opacity: 1,
        force: 0.25,
        azimuth: 0,
        altitude: .pi / 2
      ),
      PKStrokePoint(
        location: CGPoint(x: 80, y: 100),
        timeOffset: 0.1,
        size: CGSize(width: 14, height: 14),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      ),
    ]
    let mask = UIBezierPath(ovalIn: CGRect(x: 45, y: 45, width: 14, height: 14))
    let stroke = PKStroke(
      ink: PKInk(.pen, color: .systemRed),
      path: PKStrokePath(controlPoints: points, creationDate: Date()),
      transform: .identity,
      mask: mask
    )
    return PKDrawing(strokes: [stroke])
  }

  private func sourceData(rotations: [Int], addAnnotations: Bool = false) -> Data {
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data)!
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font
    ]

    for (index, _) in rotations.enumerated() {
      context.beginPDFPage(nil)
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "Original vector text \(index + 1)", attributes: attributes)
      )
      context.textPosition = CGPoint(x: 10, y: 200)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()

    let document = PDFDocument(data: data as Data)!
    for (index, rotation) in rotations.enumerated() {
      document.page(at: index)!.rotation = rotation
    }
    if addAnnotations, let page = document.page(at: 0) {
      let comment = PDFAnnotation(
        bounds: CGRect(x: 20, y: 210, width: 20, height: 20),
        forType: .text,
        withProperties: nil
      )
      comment.contents = "Original comment"
      page.addAnnotation(comment)

      let link = PDFAnnotation(
        bounds: CGRect(x: 50, y: 210, width: 30, height: 20),
        forType: .link,
        withProperties: nil
      )
      link.action = PDFActionURL(url: URL(string: "https://example.com/original")!)
      page.addAnnotation(link)
    }
    var documentAttributes = document.documentAttributes ?? [:]
    documentAttributes[PDFDocumentAttribute(rawValue: "Title")] = "preserve-me"
    document.documentAttributes = documentAttributes
    return document.dataRepresentation()!
  }

  private func expectedPDFBounds(for viewportRect: CGRect, on page: PDFPage) -> CGRect {
    let crop = page.bounds(for: .cropBox)
    let corners = [
      CGPoint(x: viewportRect.minX, y: viewportRect.minY),
      CGPoint(x: viewportRect.maxX, y: viewportRect.minY),
      CGPoint(x: viewportRect.minX, y: viewportRect.maxY),
      CGPoint(x: viewportRect.maxX, y: viewportRect.maxY),
    ].map { CGPoint(x: crop.minX + $0.x, y: crop.maxY - $0.y) }
    let xValues = corners.map(\.x)
    let yValues = corners.map(\.y)
    let minX = xValues.min()!
    let maxX = xValues.max()!
    let minY = yValues.min()!
    let maxY = yValues.max()!
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private func redPixelBounds(in image: CGImage) -> CGRect? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        let alpha = Int(pixels[index + 3])
        guard alpha > 16, red > 120, red > green + 35, red > blue + 35 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(
      x: minX,
      y: minY,
      width: maxX - minX + 1,
      height: maxY - minY + 1
    )
  }
}
