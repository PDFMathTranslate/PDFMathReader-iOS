import CoreText
import Foundation
import PDFKit
import Testing

@testable import ReaderCore

@Test
func pdfKitExtractionHasCloseDesktopTextAndParagraphParity() throws {
  for fileName in ["sample.pdf", "precise-compaction.pdf"] {
    let fixtureName = fileName.replacingOccurrences(of: ".pdf", with: ".json")
    let fixture = try LayoutTestSupport.decode(LayoutFixture.self, resource: fixtureName)
    guard let pdfURL = LayoutTestSupport.fixtureURL(fileName),
      let document = PDFDocument(url: pdfURL) else {
      Issue.record("Could not load PDF or fixture for \(fileName)")
      continue
    }

    for expectedPage in fixture.pages {
      guard let page = document.page(at: expectedPage.page - 1) else {
        Issue.record("Could not load page \(expectedPage.page) for \(fileName)")
        continue
      }
      let actualItems = PDFKitTextExtractor.extract(page: page, pageNumber: expectedPage.page)
      let actualParagraphs = LayoutEngine.paragraphs(
        items: actualItems,
        pageHeight: expectedPage.height
      )
      let expectedText = normalizedText(expectedPage.items)
      let actualText = normalizedText(actualItems)
      let ratio = editRatio(expectedText, actualText)
      let paragraphTolerance = max(4, Int(ceil(Double(expectedPage.paragraphs.count) * 0.15)))
      let paragraphDelta = abs(actualParagraphs.count - expectedPage.paragraphs.count)
      let ratioText = String(format: "%.4f", ratio)

      print(
        "[layout extraction] \(fileName) page \(expectedPage.page): " +
          "items \(actualItems.count)/\(expectedPage.items.count), " +
          "paragraphs \(actualParagraphs.count)/\(expectedPage.paragraphs.count), " +
          "text edit ratio \(ratioText)"
      )

      #expect(abs(page.bounds(for: .mediaBox).width - expectedPage.width) <= 1)
      #expect(abs(page.bounds(for: .mediaBox).height - expectedPage.height) <= 1)
      #expect(ratio < 0.12, "PDFKit text differs too much for \(fileName) page \(expectedPage.page)")
      #expect(
        paragraphDelta <= paragraphTolerance,
        "PDFKit paragraph count differs too much for \(fileName) page \(expectedPage.page)"
      )
    }
  }
}

@Test
func pdfKitExtractionKeepsGlyphBoundsAlignedAfterLineBreaks() throws {
  // PDFKit inserts a line break with no glyph slot before the second line of
  // sample.pdf; unaligned bounds put "R" at the next glyph and lose the final "s".
  let url = try #require(LayoutTestSupport.fixtureURL("sample.pdf"))
  let page = try #require(PDFDocument(url: url)?.page(at: 0))
  let paragraphs = LayoutEngine.paragraphs(
    items: PDFKitTextExtractor.extract(page: page),
    pageHeight: 842
  )
  let attribution = try #require(paragraphs.first { $0.text.hasPrefix("Rabindranath") })
  #expect(attribution.text == "Rabindranath Tagore, Stray Birds")
  #expect(abs(attribution.x - 76.381) < 1)
}

@Test
func pdfKitExtractionPreservesUnicodeAndFontChanges() throws {
  let bytes = NSMutableData()
  let consumer = try #require(CGDataConsumer(data: bytes))
  var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 300)
  let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
  context.beginPDFPage(nil)
  let regular = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
  let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
  let text = NSMutableAttributedString(
    string: "Café scientific text ",
    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): regular]
  )
  text.append(NSAttributedString(
    string: "Bold result",
    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): bold]
  ))
  context.textPosition = CGPoint(x: 30, y: 220)
  CTLineDraw(CTLineCreateWithAttributedString(text), context)
  context.endPDFPage()
  context.closePDF()
  let page = try #require(PDFDocument(data: bytes as Data)?.page(at: 0))
  let items = PDFKitTextExtractor.extract(page: page)
  #expect(items.map(\.text).joined(separator: " ") == "Café scientific text Bold result")
  #expect(items.filter { $0.text == "Bold" || $0.text == "result" }.allSatisfy { $0.isBold })
  #expect(items.filter { $0.text == "scientific" }.allSatisfy { !$0.isBold })
  #expect(items.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.width > 0 && $0.height > 0 })
}

private func normalizedText(_ items: [TextItem]) -> String {
  items
    .filter { $0.itemType != "Image" }
    .map(\.text)
    .joined()
    .lowercased()
    .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
}

private func editRatio(_ lhs: String, _ rhs: String) -> Double {
  let left = Array(lhs.utf16)
  let right = Array(rhs.utf16)
  guard !left.isEmpty || !right.isEmpty else { return 0 }
  var previous = Array(0...right.count)
  for (leftIndex, leftValue) in left.enumerated() {
    var current = Array(repeating: 0, count: right.count + 1)
    current[0] = leftIndex + 1
    for rightIndex in right.indices {
      let substitution = leftValue == right[rightIndex] ? 0 : 1
      current[rightIndex + 1] = min(
        previous[rightIndex + 1] + 1,
        current[rightIndex] + 1,
        previous[rightIndex] + substitution
      )
    }
    previous = current
  }
  return Double(previous[right.count]) / Double(max(left.count, right.count))
}
