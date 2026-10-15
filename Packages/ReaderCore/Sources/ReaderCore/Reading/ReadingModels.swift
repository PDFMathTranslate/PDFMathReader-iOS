import Foundation

/// A UTF-16 range, matching the offsets returned by JavaScript string APIs.
public struct ReadingRange: Codable, Equatable, Sendable {
  public var start: Int
  public var end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }
}

/// A range mapped back to one native PDF text run.
public struct ReadingRunRange: Codable, Equatable, Sendable {
  public var index: Int
  public var start: Int
  public var end: Int
  public var category: String?
  public var strength: Double?

  public init(
    index: Int,
    start: Int,
    end: Int,
    category: String? = nil,
    strength: Double? = nil
  ) {
    self.index = index
    self.start = start
    self.end = end
    self.category = category
    self.strength = strength
  }
}

/// The geometry needed by reading aids that join adjacent PDF runs.
public struct ReadingTextRun: Codable, Equatable, Sendable {
  public var text: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(
    text: String,
    x: Double = 0,
    y: Double = 0,
    width: Double = 0,
    height: Double = 0
  ) {
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public init(_ item: TextItem) {
    self.init(text: item.text, x: item.x, y: item.y, width: item.width, height: item.height)
  }
}

/// Plain text segments shared by information emphasis and UI reveal effects.
public struct ReadingTextSegment: Codable, Equatable, Sendable {
  public var text: String
  public var start: Int
  public var end: Int
  public var topic: Bool
  public var important: Bool
  public var bionic: Bool

  public init(
    text: String,
    start: Int,
    end: Int,
    topic: Bool = false,
    important: Bool = false,
    bionic: Bool = false
  ) {
    self.text = text
    self.start = start
    self.end = end
    self.topic = topic
    self.important = important
    self.bionic = bionic
  }
}

public struct ReadingRectangle: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

extension String {
  func utf16Offset(of index: String.Index) -> Int {
    index.utf16Offset(in: self)
  }

  func indexAtUTF16Offset(_ offset: Int) -> String.Index? {
    guard offset >= 0, offset <= utf16.count else { return nil }
    return String.Index(utf16Offset: offset, in: self)
  }
}

struct ReadingWordSegment {
  var text: String
  var range: Range<String.Index>
}

/// Keep the Foundation word breaker in one place so reading aids share the
/// same UTF-16 boundaries. Foundation and V8/ICU differ for this common
/// Japanese compound, so merge the split that the desktop reader preserves.
func readingWordSegments(_ text: String) -> [ReadingWordSegment] {
  guard !text.isEmpty else { return [] }
  var segments: [ReadingWordSegment] = []
  text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
    guard let substring else { return }
    segments.append(ReadingWordSegment(text: substring, range: range))
  }

  var merged: [ReadingWordSegment] = []
  for segment in segments {
    guard let previous = merged.last,
      previous.text == "日本",
      segment.text == "語",
      previous.range.upperBound == segment.range.lowerBound
    else {
      merged.append(segment)
      continue
    }
    merged[merged.index(before: merged.endIndex)] = ReadingWordSegment(
      text: String(text[previous.range.lowerBound..<segment.range.upperBound]),
      range: previous.range.lowerBound..<segment.range.upperBound
    )
  }
  return merged
}
