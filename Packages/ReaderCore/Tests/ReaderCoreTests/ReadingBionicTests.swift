import Foundation
import Testing

@testable import ReaderCore

@Test
func bionicReadingMatchesDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  for input in fixture["bionic"] as! [[String: Any]] {
    let optionsValue = input["options"] as! [String: Any]
    let options = BionicReadingOptions(
      mode: BionicReadingMode(rawValue: optionsValue["mode"] as? String ?? "off") ?? .off,
      fixedLength: optionsValue["fixedLength"] as? Int ?? 3
    )
    let text = input["text"] as! String
    let actualRanges = BionicReading.ranges(in: text, options: options).map(ReadingFixtureSupport.rangeJSON)
    #expect(try ReadingFixtureSupport.jsonEqual(actualRanges, input["ranges"] as! [[String: Any]]))
    let normalized = BionicReading.normalize(options)
    #expect(normalized.mode.rawValue == (input["normalized"] as! [String: Any])["mode"] as! String)
    #expect(normalized.fixedLength == (input["normalized"] as! [String: Any])["fixedLength"] as! Int)
    let expectedFixations = input["fixation"] as! [[String: Any]]
    for value in expectedFixations {
      #expect(BionicReading.fixationLength(value["word"] as! String, options: options) == value["length"] as! Int)
    }
    let source = [ReadingTextSegment(text: text, start: 0, end: text.utf16.count)]
    let segments = BionicReading.segments(source, ranges: BionicReading.ranges(in: text, options: options)).map {
      ["text": $0.text, "start": $0.start, "end": $0.end, "bionic": $0.bionic] as [String: Any]
    }
    #expect(try ReadingFixtureSupport.jsonEqual(segments, input["segments"] as! [[String: Any]]))
  }
}

@Test
func bionicRunRangesMatchDesktopFixtures() throws {
  let fixture = try ReadingFixtureSupport.fixture()
  let value = fixture["bionicRuns"] as! [String: Any]
  let runs = ReadingFixtureSupport.runs(value["input"] as Any)
  let fixed = BionicReading.runRanges(runs, options: BionicReadingOptions(mode: .fixed, fixedLength: 3)).map(ReadingFixtureSupport.runRangeJSON)
  let root = BionicReading.runRanges(runs, options: BionicReadingOptions(mode: .root)).map(ReadingFixtureSupport.runRangeJSON)
  #expect(try ReadingFixtureSupport.jsonEqual(fixed, value["fixed"] as! [[String: Any]]))
  #expect(try ReadingFixtureSupport.jsonEqual(root, value["root"] as! [[String: Any]]))
}
