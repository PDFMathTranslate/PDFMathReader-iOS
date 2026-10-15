import Foundation
import Testing

@testable import ReaderCore

@Test
func linkAndFontUtilitiesMatchDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  for input in fixture["links"] as! [[String: Any]] {
    #expect(detectLinks(input["text"] as! String) == input["links"] as! [String])
    #expect(detectEmails(input["text"] as! String) == input["emails"] as! [String])
  }
  for input in fixture["fonts"] as! [[String: Any]] {
    let font = input["font"] as! String
    #expect(stripTranslationFont(font) == input["stripped"] as! String)
    #expect(isValidTranslationFont(font) == input["valid"] as! Bool)
    #expect(translationFontFamily(serif: input["serif"] as! Bool, font: font, language: input["language"] as! String) == input["family"] as! String)
  }
}

@Test
func paragraphCompactionMatchesDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  let value = fixture["compaction"] as! [String: Any]
  var occupied = Array(repeating: false, count: 32)
  [1, 2, 28, 29].forEach { occupied[$0] = true }
  var source = Array(repeating: false, count: 46)
  for index in 1..<source.count { source[index] = true }
  let cuts = compactBands(occupied, rowScale: 1, pageHeight: 100, lineHeight: 10)
  let cutJSON = cuts.map { ["start": $0.start, "end": $0.end] as [String: Any] }
  #expect(try ReadingFixtureSupport.jsonEqual(cutJSON, value["cuts"] as! [[String: Any]]))
  let trailing: Any = if let cut = trailingCut(source: source, occupied: occupied, rowScale: 1, lineHeight: 10) {
    ["start": cut.start, "end": cut.end] as [String: Any]
  } else {
    NSNull()
  }
  #expect(try ReadingFixtureSupport.jsonEqual(trailing, value["trailing"] as Any))
  let mapped = cuts.map { mapCompactY($0.end + 5, cuts: cuts) }
  #expect(try ReadingFixtureSupport.jsonEqual(mapped, value["mapped"] as! [Double]))
  let rect = mapCompactRect(ReadingRectangle(x: 1, y: 20, width: 10, height: 30), cuts: cuts)!
  #expect(try ReadingFixtureSupport.jsonEqual(["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height], value["rect"] as! [String: Any]))
  let typical = typicalLineHeight([
    CompactionTextItem(text: "one", transform: [10, 0, 0, 10, 0, 20]),
    CompactionTextItem(text: "two", transform: [10, 0, 0, 10, 0, 32]),
    CompactionTextItem(text: "three", transform: [10, 0, 0, 10, 0, 44]),
  ])!
  #expect(abs(typical - (value["typical"] as! Double)) < 0.0001)
}

@Test
func tocGeneratorMatchesDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  let value = fixture["toc"] as! [String: Any]
  let items = (value["syntheticItems"] as! [[String: Any]]).map { item in
    let topY = item["y"] as! Double
    let size = item["size"] as! Double
    return TextItem(page: 1, text: item["text"] as! String, x: item["x"] as! Double, y: 500 - topY - size, width: item["width"] as! Double, height: size, fontSize: size, isBold: item["bold"] as! Bool)
  }
  func lineJSON(_ line: TOCLine) -> [String: Any] {
    ["page": line.page, "pageWidth": line.pageWidth, "pageHeight": line.pageHeight, "text": line.text, "body": line.body ?? NSNull(), "printed": line.printed ?? NSNull(), "x": line.x, "right": line.right, "y": line.y, "size": line.size, "bold": line.bold, "chars": line.chars]
  }
  func line(_ value: [String: Any]) -> TOCLine {
    TOCLine(page: value["page"] as! Int, pageWidth: value["pageWidth"] as! Double, pageHeight: value["pageHeight"] as! Double, text: value["text"] as! String, body: value["body"] as? String, printed: value["printed"] as? String, x: value["x"] as! Double, right: value["right"] as! Double, y: value["y"] as! Double, size: value["size"] as! Double, bold: value["bold"] as! Bool, chars: value["chars"] as! Int)
  }
  func resultJSON(_ result: TOCResult) -> [String: Any] {
    ["items": result.items.map { ["id": $0.id, "title": $0.title, "depth": $0.depth, "page": $0.page, "source": $0.source] as [String: Any] }, "source": result.source ?? NSNull()]
  }
  let actualLines = TOCGenerator.buildLines(items, number: 1, width: 400, height: 500).map(lineJSON)
  #expect(try ReadingFixtureSupport.jsonEqual(actualLines, value["syntheticLines"] as! [[String: Any]]))

  let pages = (value["pages"] as! [[String: Any]]).map { page in
    TOCPage(number: page["number"] as! Int, width: page["width"] as! Double, height: page["height"] as! Double, lines: (page["lines"] as! [[String: Any]]).map(line))
  }
  let actual = TOCGenerator.generateToc(pages)
  let expected = value["generated"] as! [String: Any]
  #expect(try ReadingFixtureSupport.jsonEqual(resultJSON(actual), expected))

  for pdf in (fixture["pdfToc"] as! [String: Any]).values {
    let pdfValue = pdf as! [String: Any]
    let pdfPages = (pdfValue["pages"] as! [[String: Any]]).map { page in
      TOCPage(number: page["number"] as! Int, width: page["width"] as! Double, height: page["height"] as! Double, lines: (page["lines"] as! [[String: Any]]).map(line))
    }
    #expect(try ReadingFixtureSupport.jsonEqual(resultJSON(TOCGenerator.generateToc(pdfPages)), pdfValue["generated"] as! [String: Any]))
  }
}
