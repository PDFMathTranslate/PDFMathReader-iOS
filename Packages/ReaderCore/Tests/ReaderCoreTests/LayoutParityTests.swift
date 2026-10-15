import Foundation
import Testing

@testable import ReaderCore

struct LayoutFixture: Codable {
  var pages: [LayoutFixturePage]
}

struct LayoutFixturePage: Codable {
  var page: Int
  var width: Double
  var height: Double
  var items: [TextItem]
  var paragraphs: [LayoutParagraph]
}

struct SyntheticLayoutFixture: Codable {
  var cases: [SyntheticLayoutCase]
  var normalization: [NormalizationFixture]
}

struct SyntheticLayoutCase: Codable {
  var name: String
  var pageHeight: Double
  var items: [TextItem]
  var paragraphs: [LayoutParagraph]
}

struct NormalizationFixture: Codable {
  var name: String
  var items: [TextItem]
  var normalized: [TextItem]
}

enum LayoutTestSupport {
  static func fixtureURL(_ name: String) -> URL? {
    Bundle.module.url(forResource: "Fixtures/layout/\(name)", withExtension: nil)
  }

  static func decode<T: Decodable>(_ type: T.Type, resource name: String) throws -> T {
    guard let url = fixtureURL(name) else {
      throw FixtureError.missingResource(name)
    }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }

  static func assertParagraphs(
    _ actual: [LayoutParagraph],
    equal expected: [LayoutParagraph],
    source: String
  ) {
    #expect(actual.count == expected.count, "paragraph count mismatch in \(source)")
    guard actual.count == expected.count else { return }
    for (actualParagraph, expectedParagraph) in zip(actual, expected) {
      #expect(actualParagraph.id == expectedParagraph.id, "id mismatch in \(source)")
      #expect(actualParagraph.text == expectedParagraph.text, "text mismatch in \(source)")
      #expect(abs(actualParagraph.x - expectedParagraph.x) <= 0.01, "x mismatch in \(source)")
      #expect(abs(actualParagraph.y - expectedParagraph.y) <= 0.01, "y mismatch in \(source)")
      #expect(abs(actualParagraph.width - expectedParagraph.width) <= 0.01, "width mismatch in \(source)")
      #expect(abs(actualParagraph.height - expectedParagraph.height) <= 0.01, "height mismatch in \(source)")
      #expect(abs(actualParagraph.fontSize - expectedParagraph.fontSize) <= 0.01, "font size mismatch in \(source)")
      #expect(actualParagraph.bold == expectedParagraph.bold, "bold mismatch in \(source)")
      #expect(actualParagraph.textAlign == expectedParagraph.textAlign, "alignment mismatch in \(source)")
    }
  }

  static func assertItems(
    _ actual: [TextItem],
    equal expected: [TextItem],
    source: String
  ) {
    #expect(actual.count == expected.count, "item count mismatch in \(source)")
    guard actual.count == expected.count else { return }
    for (actualItem, expectedItem) in zip(actual, expected) {
      #expect(actualItem.page == expectedItem.page, "page mismatch in \(source)")
      #expect(actualItem.text == expectedItem.text, "text mismatch in \(source)")
      #expect(abs(actualItem.x - expectedItem.x) <= 0.01, "x mismatch in \(source)")
      #expect(abs(actualItem.y - expectedItem.y) <= 0.01, "y mismatch in \(source)")
      #expect(abs(actualItem.width - expectedItem.width) <= 0.01, "width mismatch in \(source)")
      #expect(abs(actualItem.height - expectedItem.height) <= 0.01, "height mismatch in \(source)")
      #expect(abs(actualItem.fontSize - expectedItem.fontSize) <= 0.01, "font size mismatch in \(source)")
      #expect(actualItem.isBold == expectedItem.isBold, "bold mismatch in \(source)")
      #expect(abs(actualItem.rotation - expectedItem.rotation) <= 0.01, "rotation mismatch in \(source)")
      #expect(actualItem.itemType == expectedItem.itemType, "item type mismatch in \(source)")
    }
  }

  enum FixtureError: Error {
    case missingResource(String)
  }
}

@Test
func desktopParagraphFixturesMatchSwiftPort() throws {
  for fileName in ["sample.json", "precise-compaction.json"] {
    let fixture = try LayoutTestSupport.decode(LayoutFixture.self, resource: fileName)
    for page in fixture.pages {
      let actual = LayoutEngine.paragraphs(items: page.items, pageHeight: page.height)
      LayoutTestSupport.assertParagraphs(
        actual,
        equal: page.paragraphs,
        source: fileName
      )
    }
  }
}

@Test
func syntheticParagraphFixturesAndOCRNormalizationMatchDesktop() throws {
  let fixture = try LayoutTestSupport.decode(
    SyntheticLayoutFixture.self,
    resource: "synthetic.json"
  )
  for value in fixture.cases {
    let actual = LayoutEngine.paragraphs(items: value.items, pageHeight: value.pageHeight)
    LayoutTestSupport.assertParagraphs(actual, equal: value.paragraphs, source: value.name)
  }
  for value in fixture.normalization {
    let actual = LayoutEngine.normalizeOcrItems(value.items)
    LayoutTestSupport.assertItems(actual, equal: value.normalized, source: value.name)
  }
}
