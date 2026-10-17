import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderPageWidthNormalizerTests: XCTestCase {
  func testMixedWidthsUseDesktopModalTieAndPreserveTextAndNativeLink() async throws {
    let fixtures = [
      PageFixture(
        media: CGRect(x: 10, y: 20, width: 600, height: 800),
        crop: CGRect(x: 30, y: 50, width: 560, height: 740),
        rotation: 0,
        text: "first page text"
      ),
      PageFixture(
        media: CGRect(x: -8, y: 12, width: 500, height: 700),
        crop: CGRect(x: -4, y: 25, width: 300, height: 400),
        rotation: 90,
        text: "second page text"
      ),
      PageFixture(
        media: CGRect(x: 2, y: 4, width: 300, height: 500),
        crop: CGRect(x: 5, y: 30, width: 200, height: 300),
        rotation: 90,
        text: "third page text"
      ),
    ]
    let input = try makePDF(fixtures, linkPage: 1)
    let baselineDocument = try XCTUnwrap(PDFDocument(data: input))
    let baselinePages = try fixtures.indices.map { index in
      try XCTUnwrap(baselineDocument.page(at: index))
    }

    let normalizedResult = try await ReaderPageWidthNormalizer.normalize(data: input)
    let normalized = try XCTUnwrap(normalizedResult)
    XCTAssertEqual(normalized.scales.count, 3)
    XCTAssertEqual(normalized.scales[0], 1, accuracy: 0.0000001)
    XCTAssertEqual(normalized.scales[1], 1.4, accuracy: 0.0000001)
    XCTAssertEqual(normalized.scales[2], 560.0 / 300.0, accuracy: 0.0000001)

    let document = try XCTUnwrap(PDFDocument(data: normalized.data))
    let first = try XCTUnwrap(document.page(at: 0))
    let second = try XCTUnwrap(document.page(at: 1))
    let third = try XCTUnwrap(document.page(at: 2))

    assertRect(
      first.bounds(for: .cropBox),
      equals: baselinePages[0].bounds(for: .cropBox)
    )
    assertRect(
      second.bounds(for: .cropBox),
      equals: scaledRect(baselinePages[1].bounds(for: .cropBox), by: 1.4),
      accuracy: 0.0001
    )
    assertRect(
      third.bounds(for: .cropBox),
      equals: scaledRect(
        baselinePages[2].bounds(for: .cropBox),
        by: 560.0 / 300.0
      ),
      accuracy: 0.0001
    )
    XCTAssertEqual(second.rotation, 90)
    XCTAssertTrue(first.string?.contains("first page text") == true)
    XCTAssertTrue(second.string?.contains("second page text") == true)
    let link = try XCTUnwrap(second.annotations.first)
    XCTAssertEqual(
      link.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      "Link"
    )
    XCTAssertEqual(link.url?.absoluteString, "https://example.com/reader-width-test")
  }

  func testModalUsesOneDecimalBucketsAndFirstPageOnTie() async throws {
    let bucketedInput = try makePDF([
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 2, y: 3, width: 500.01, height: 700),
        rotation: 0,
        text: "bucket first"
      ),
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 4, y: 5, width: 500.04, height: 700),
        rotation: 0,
        text: "bucket second"
      ),
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 6, y: 7, width: 600.01, height: 700),
        rotation: 0,
        text: "bucket third"
      ),
    ])
    let bucketedResult = try await ReaderPageWidthNormalizer.normalize(data: bucketedInput)
    let bucketed = try XCTUnwrap(bucketedResult)
    XCTAssertEqual(bucketed.scales[0], 1, accuracy: 0.0000001)
    XCTAssertEqual(bucketed.scales[1], 500.01 / 500.04, accuracy: 0.0000001)
    XCTAssertEqual(bucketed.scales[2], 500.01 / 600.01, accuracy: 0.0000001)

    let tieInput = try makePDF([
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 2, y: 3, width: 500.01, height: 700),
        rotation: 0,
        text: "tie first"
      ),
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 800, height: 800),
        crop: CGRect(x: 4, y: 5, width: 600.01, height: 700),
        rotation: 0,
        text: "tie second"
      ),
    ])
    let tieResult = try await ReaderPageWidthNormalizer.normalize(data: tieInput)
    let tie = try XCTUnwrap(tieResult)
    XCTAssertEqual(tie.scales[0], 1, accuracy: 0.0000001)
    XCTAssertEqual(tie.scales[1], 500.01 / 600.01, accuracy: 0.0000001)
  }

  func testUniformWidthBucketReturnsNil() async throws {
    let input = try makePDF([
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 2, y: 3, width: 560.01, height: 700),
        rotation: 0,
        text: "already aligned first"
      ),
      PageFixture(
        media: CGRect(x: 0, y: 0, width: 700, height: 800),
        crop: CGRect(x: 4, y: 5, width: 560.04, height: 700),
        rotation: 0,
        text: "already aligned second"
      ),
    ])

    let normalized = try await ReaderPageWidthNormalizer.normalize(data: input)
    XCTAssertNil(normalized)
  }
}

private struct PageFixture {
  let media: CGRect
  let crop: CGRect
  let rotation: Int
  let text: String
}

private func makePDF(_ fixtures: [PageFixture], linkPage: Int? = nil) throws -> Data {
  guard let first = fixtures.first else { throw PDFFixtureError.empty }
  var initialMedia = first.media
  let output = NSMutableData()
  guard let consumer = CGDataConsumer(data: output),
    let context = CGContext(consumer: consumer, mediaBox: &initialMedia, nil)
  else { throw PDFFixtureError.context }

  for fixture in fixtures {
    let info: [CFString: Any] = [
      kCGPDFContextMediaBox: NSValue(cgRect: fixture.media),
      kCGPDFContextCropBox: NSValue(cgRect: fixture.crop),
    ]
    context.beginPDFPage(info as CFDictionary)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: fixture.text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key:
          CTFontCreateWithName("Helvetica" as CFString, 20, nil),
      ])
    )
    context.textPosition = CGPoint(x: fixture.crop.minX + 20, y: fixture.crop.minY + 100)
    CTLineDraw(line, context)
    context.endPDFPage()
  }
  context.closePDF()

  let document = try XCTUnwrap(PDFDocument(data: output as Data))
  for (index, fixture) in fixtures.enumerated() {
    let page = try XCTUnwrap(document.page(at: index))
    page.setBounds(fixture.media, for: .mediaBox)
    page.setBounds(fixture.crop, for: .cropBox)
    page.rotation = fixture.rotation
    guard index == linkPage else { continue }
    let annotation = PDFAnnotation(
      bounds: CGRect(x: fixture.crop.minX + 10, y: fixture.crop.minY + 10, width: 80, height: 30),
      forType: .link,
      withProperties: nil
    )
    annotation.url = URL(string: "https://example.com/reader-width-test")
    page.addAnnotation(annotation)
  }
  return try XCTUnwrap(document.dataRepresentation())
}

private enum PDFFixtureError: Error {
  case empty
  case context
}

private func assertRect(
  _ actual: CGRect,
  equals expected: CGRect,
  accuracy: CGFloat = 0.000001,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, file: file, line: line)
  XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, file: file, line: line)
  XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
  XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
}

private func scaledRect(_ rect: CGRect, by scale: CGFloat) -> CGRect {
  CGRect(
    x: rect.origin.x * scale,
    y: rect.origin.y * scale,
    width: rect.width * scale,
    height: rect.height * scale
  )
}
