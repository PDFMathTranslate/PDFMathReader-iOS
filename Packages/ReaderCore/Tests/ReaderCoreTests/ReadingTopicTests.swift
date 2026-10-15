import Foundation
import Testing

@testable import ReaderCore

@Test
func topicSentenceLengthsMatchDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  for input in fixture["topic"] as! [[String: Any]] {
    let text = input["text"] as! String
    #expect(firstSentenceLength(text) == input["first"] as! Int)
    #expect(topicSentenceLength(text) == input["length"] as! Int)
  }
}

@Test
func topicSentenceParagraphsMatchDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  let runs = ReadingFixtureSupport.runs(fixture["topicRuns"] as Any)
  let boxes = (fixture["topicBoxes"] as! [[String: Any]]).map { box in
    TopicParagraphBox(
      id: box["id"] as! Int,
      x: box["x"] as! Double,
      y: box["y"] as! Double,
      width: box["width"] as! Double,
      height: box["height"] as! Double,
      eligible: box["eligible"] as? Bool ?? true
    )
  }
  let paragraphs = topicSentenceParagraphs(runs, boxes: boxes)
  let actual = paragraphs.map { paragraph in
    [
      "text": paragraph.text,
      "firstSentence": paragraph.firstSentence,
      "ranges": paragraph.ranges.map(ReadingFixtureSupport.runRangeJSON),
    ] as [String: Any]
  }
  #expect(try ReadingFixtureSupport.jsonEqual(actual, fixture["topicParagraphs"] as! [[String: Any]]))
}
