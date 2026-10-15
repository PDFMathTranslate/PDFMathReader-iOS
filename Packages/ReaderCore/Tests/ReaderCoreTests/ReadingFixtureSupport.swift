import Foundation

@testable import ReaderCore

enum ReadingFixtureSupport {
  static func fixture() throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: "Fixtures/reading/reading-fixtures", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  }

  static func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  static func jsonEqual(_ actual: Any, _ expected: Any) throws -> Bool {
    try json(actual) == json(expected)
  }

  static func run(_ value: [String: Any]) -> ReadingTextRun {
    ReadingTextRun(
      text: value["text"] as? String ?? "",
      x: value["x"] as? Double ?? 0,
      y: value["y"] as? Double ?? 0,
      width: value["width"] as? Double ?? 0,
      height: value["height"] as? Double ?? 0
    )
  }

  static func runs(_ value: Any) -> [ReadingTextRun] {
    (value as! [[String: Any]]).map(run)
  }

  static func rangeJSON(_ range: ReadingRange) -> [String: Any] {
    ["start": range.start, "end": range.end]
  }

  static func runRangeJSON(_ range: ReadingRunRange) -> [String: Any] {
    var value: [String: Any] = ["index": range.index, "start": range.start, "end": range.end]
    if let category = range.category { value["category"] = category }
    if let strength = range.strength { value["strength"] = strength }
    return value
  }
}
