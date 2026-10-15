import Foundation
import Testing

@testable import ReaderCore

@Test
func informationEmphasisMatchesDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  for input in fixture["information"] as! [[String: Any]] {
    let text = input["text"] as! String
    let ranges = importantInformationRanges(text).map {
      ["start": $0.start, "end": $0.end, "category": $0.category] as [String: Any]
    }
    #expect(try ReadingFixtureSupport.jsonEqual(ranges, input["ranges"] as! [[String: Any]]))
    let segments = informationTextSegments(text, topicEnd: min(text.utf16.count, 12), emphasizeInformation: true).map {
      ["text": $0.text, "start": $0.start, "end": $0.end, "topic": $0.topic, "important": $0.important] as [String: Any]
    }
    #expect(try ReadingFixtureSupport.jsonEqual(segments, input["segments"] as! [[String: Any]]))
  }
  let runs = ReadingFixtureSupport.runs((fixture["bionicRuns"] as! [String: Any])["input"] as Any)
  let actual = informationRunRanges(runs).map(ReadingFixtureSupport.runRangeJSON)
  #expect(try ReadingFixtureSupport.jsonEqual(actual, fixture["informationRuns"] as! [[String: Any]]))
}

@Test
func tfidfEmphasisMatchesDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  for input in fixture["tfidf"] as! [[String: Any]] {
    let text = input["text"] as! String
    let tokens = tfidfTokens(text).map { ["term": $0.term, "start": $0.start, "end": $0.end] as [String: Any] }
    #expect(try ReadingFixtureSupport.jsonEqual(tokens, input["term"] as! [[String: Any]]))
    #expect(tfidfTermSet([text]) == input["set"] as! [String])
    let ranges = tfidfRanges(text, documents: 4) { $0 == "common" ? 3 : 0 }.map {
      ["start": $0.start, "end": $0.end, "strength": $0.strength] as [String: Any]
    }
    #expect(try ReadingFixtureSupport.jsonEqual(ranges, input["ranges"] as! [[String: Any]]))
  }
  let sample = sampleTfidfPageNumbers(count: 0, size: 12, random: { 0.5 })
  #expect(sample == fixture["tfidfSample"] as! [Int])
  let value = fixture["tfidfRuns"] as! [String: Any]
  let runs = ReadingFixtureSupport.runs((fixture["bionicRuns"] as! [String: Any])["input"] as Any)
  let text = tfidfRunText(runs)
  let textJSON: [String: Any] = [
    "logical": text.logical,
    "parts": text.parts.map { ["index": $0.index, "start": $0.start, "end": $0.end] as [String: Any] },
    "terms": text.terms,
  ]
  #expect(try ReadingFixtureSupport.jsonEqual(textJSON, value["text"] as! [String: Any]))
  let ranges = tfidfRunRanges(runs, documents: 4, frequency: { _ in 0 }).map(ReadingFixtureSupport.runRangeJSON)
  #expect(try ReadingFixtureSupport.jsonEqual(ranges, value["ranges"] as! [[String: Any]]))
}
