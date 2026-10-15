import Foundation

public enum BionicReadingMode: String, Codable, CaseIterable, Sendable {
  case off
  case fixed
  case root
}

public struct BionicReadingOptions: Codable, Equatable, Sendable {
  public var mode: BionicReadingMode
  public var fixedLength: Int

  public init(mode: BionicReadingMode = .off, fixedLength: Int = 3) {
    self.mode = mode
    self.fixedLength = fixedLength
  }
}

public enum BionicReading {
  public static let fixedLengthMinimum = 1
  public static let fixedLengthMaximum = 6
  public static let fixedLengthDefault = 3

  public static func normalize(
    mode: BionicReadingMode?,
    fixedLength: Double?
  ) -> BionicReadingOptions {
    let rounded: Int
    if let fixedLength, fixedLength.isFinite {
      rounded = Int(fixedLength.rounded(.toNearestOrAwayFromZero))
    } else {
      rounded = fixedLengthDefault
    }
    return BionicReadingOptions(
      mode: mode ?? .off,
      fixedLength: min(fixedLengthMaximum, max(fixedLengthMinimum, rounded))
    )
  }

  public static func normalize(_ options: BionicReadingOptions? = nil) -> BionicReadingOptions {
    guard let options else { return BionicReadingOptions() }
    return normalize(mode: options.mode, fixedLength: Double(options.fixedLength))
  }

  public static func active(_ options: BionicReadingOptions? = nil) -> Bool {
    normalize(options).mode != .off
  }

  public static func fixationLength(_ word: String, options: BionicReadingOptions? = nil) -> Int {
    let options = normalize(options)
    guard options.mode != .off, word.unicodeScalars.contains(where: isLetter) else { return 0 }
    let letters = word.count
    if isCJK(word) {
      if letters <= 1 { return 0 }
      return options.mode == .fixed ? min(options.fixedLength, letters - 1) : 1
    }
    if letters == 1 { return 1 }
    return options.mode == .fixed
      ? min(options.fixedLength, letters - 1)
      : rootLength(word, letters: letters)
  }

  /// Returns UTF-16 ranges in the unchanged source text.
  public static func ranges(
    in text: String,
    options: BionicReadingOptions? = nil
  ) -> [ReadingRange] {
    guard !text.isEmpty, active(options) else { return [] }
    var result: [ReadingRange] = []
    for segment in readingWordSegments(text) {
      let word = segment.text
      guard word.unicodeScalars.contains(where: isLetter),
        word.unicodeScalars.contains(where: isWordScalar)
      else { continue }
      let count = fixationLength(word, options: options)
      guard count > 0 else { continue }
      let start = text.utf16Offset(of: segment.range.lowerBound)
      let end = start + String(word.prefix(count)).utf16.count
      result.append(ReadingRange(start: start, end: end))
    }
    return result
  }

  public static func runRanges(
    _ runs: [ReadingTextRun],
    options: BionicReadingOptions? = nil
  ) -> [ReadingRunRange] {
    guard active(options) else { return [] }
    let joined = joinLogicalRuns(runs)
    return splitLogicalRanges(ranges(in: joined.logical, options: options), parts: joined.parts)
  }

  public static func segments(
    _ parts: [ReadingTextSegment],
    ranges: [ReadingRange]
  ) -> [ReadingTextSegment] {
    guard !ranges.isEmpty else { return parts.map { part in
      var copy = part
      copy.bionic = false
      return copy
    } }
    return parts.flatMap { part in
      let cuts = Set([part.start, part.end] + ranges.flatMap { [$0.start, $0.end] })
        .filter { $0 > part.start && $0 < part.end }
        .sorted()
      let boundaries = [part.start] + cuts + [part.end]
      return boundaries.dropLast().indices.map { index in
        let start = boundaries[index]
        let end = boundaries[index + 1]
        guard let startIndex = part.text.indexAtUTF16Offset(start - part.start),
          let endIndex = part.text.indexAtUTF16Offset(end - part.start)
        else { return ReadingTextSegment(text: "", start: start, end: end) }
        var copy = part
        copy.text = String(part.text[startIndex..<endIndex])
        copy.start = start
        copy.end = end
        copy.bionic = ranges.contains { start >= $0.start && start < $0.end }
        return copy
      }
    }
  }

  private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
      .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
      return true
    default:
      return false
    }
  }

  private static func isLetter(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default:
      return false
    }
  }

  private static func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      let value = scalar.value
      return (0x1100...0x11FF).contains(value) ||
        (0x2E80...0x2FFF).contains(value) ||
        (0x3000...0x30FF).contains(value) ||
        (0x3130...0x318F).contains(value) ||
        (0xA960...0xA97F).contains(value) ||
        (0xAC00...0xD7FF).contains(value) ||
        (0xF900...0xFAFF).contains(value) ||
        (0x3400...0x4DBF).contains(value) ||
        (0x4E00...0x9FFF).contains(value)
    }
  }

  private static func rootLength(_ word: String, letters: Int) -> Int {
    if letters <= 3 { return 1 }
    let ascii = word.unicodeScalars.allSatisfy { scalar in
      scalar.value < 128 && (scalar == "'" || scalar == "’" || isASCIILetter(scalar))
    }
    if ascii {
      let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
      let stem = EnglishStemmer.stem(lower)
      var common = 0
      let stemChars = Array(stem)
      let lowerChars = Array(lower)
      while common < stemChars.count && common < lowerChars.count && stemChars[common] == lowerChars[common] {
        common += 1
      }
      if common >= 2 && common < letters { return common }
    }
    return letters <= 3 ? 1 : Int(ceil(Double(letters) * 0.4))
  }

  private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }
}

public func normalizeBionicReading(
  mode: BionicReadingMode? = nil,
  fixedLength: Double? = nil
) -> BionicReadingOptions {
  BionicReading.normalize(mode: mode, fixedLength: fixedLength)
}

public func bionicFixationLength(
  _ word: String,
  options: BionicReadingOptions? = nil
) -> Int {
  BionicReading.fixationLength(word, options: options)
}

public func bionicReadingRanges(
  _ text: String = "",
  options: BionicReadingOptions? = nil
) -> [ReadingRange] {
  BionicReading.ranges(in: text, options: options)
}

public func bionicRunRanges(
  _ runs: [ReadingTextRun] = [],
  options: BionicReadingOptions? = nil
) -> [ReadingRunRange] {
  BionicReading.runRanges(runs, options: options)
}

private struct LogicalRunParts {
  var logical: String
  var parts: [(index: Int, start: Int, end: Int)]
}

private func joinLogicalRuns(_ runs: [ReadingTextRun]) -> LogicalRunParts {
  var logical = ""
  var parts: [(index: Int, start: Int, end: Int)] = []
  for index in runs.indices {
    let text = runs[index].text
    if index > 0, !logical.isEmpty, !text.isEmpty,
      !logical.last!.isWhitespace, !text.first!.isWhitespace {
      let previous = runs[index - 1]
      let height = max(1, min(previous.height == 0 ? 12 : previous.height, runs[index].height == 0 ? 12 : runs[index].height))
      let sameLine = abs(previous.y - runs[index].y) < height * 0.5
      let gap = runs[index].x - previous.x - previous.width
      if !sameLine, (logical.last == "-" || logical.last == "‐"), text.first?.isASCII == true,
        text.first?.isLetter == true {
        logical.removeLast()
      } else if !sameLine || gap > max(0.5, height * 0.08) {
        logical.append(" ")
      }
    }
    let start = logical.utf16.count
    logical.append(contentsOf: text)
    parts.append((index: index, start: start, end: logical.utf16.count))
  }
  return LogicalRunParts(logical: logical, parts: parts)
}

private func splitLogicalRanges(
  _ matches: [ReadingRange],
  parts: [(index: Int, start: Int, end: Int)]
) -> [ReadingRunRange] {
  var result: [ReadingRunRange] = []
  for match in matches {
    for part in parts {
      let start = max(match.start, part.start)
      let end = min(match.end, part.end)
      if end > start {
        result.append(ReadingRunRange(index: part.index, start: start - part.start, end: end - part.start))
      }
    }
  }
  return result
}

private enum EnglishStemmer {
  private static let exceptions: [String: String] = [
    "skis": "ski", "skies": "sky", "dying": "die", "lying": "lie", "tying": "tie",
    "idly": "idl", "gently": "gentl", "ugly": "ugli", "early": "earli", "only": "onli",
    "singly": "singl", "sky": "sky", "news": "news", "howe": "howe", "atlas": "atlas",
    "cosmos": "cosmos", "bias": "bias", "andes": "andes",
  ]
  private static let post1A: Set<String> = ["inning", "outing", "canning", "herring", "earring", "proceed", "exceed", "succeed"]
  private static let doubles = ["bb", "dd", "ff", "gg", "mm", "nn", "pp", "rr", "tt"]
  private static let liEnding = "cdeghkmnrt"

  static func stem(_ input: String) -> String {
    var word = input.lowercased().replacingOccurrences(of: "’", with: "'")
    if word.count <= 2 { return word }
    if let exception = exceptions[word] { return exception }
    if word.first == "'" { word.removeFirst() }
    word = word.replacingOccurrences(of: #"^y"#, with: "Y", options: .regularExpression)
      .replacingOccurrences(of: #"([aeiouy])y"#, with: "$1Y", options: .regularExpression)
    let prefix = ["gener", "commun", "arsen"].first { word.hasPrefix($0) }
    let r1 = prefix?.count ?? regionAfter(word, from: 0)
    let r2 = regionAfter(word, from: r1)
    func inRegion(_ suffix: String, _ region: Int) -> Bool { word.count - suffix.count >= region }
    func cut(_ suffix: String, _ add: String = "") { word = String(word.dropLast(suffix.count)) + add }
    func vowel(_ character: Character?) -> Bool { guard let character else { return false }; return "aeiouy".contains(character) }
    func hasVowel(_ value: String) -> Bool { value.contains { vowel($0) } }
    func shortSyllableAt(_ end: Int) -> Bool {
      let chars = Array(word)
      guard end <= chars.count else { return false }
      if end == 2 { return vowel(chars[0]) && !vowel(chars[1]) }
      guard end >= 3 else { return false }
      let a = chars[end - 3], b = chars[end - 2], c = chars[end - 1]
      return !vowel(a) && vowel(b) && !vowel(c) && !"wxY".contains(c)
    }
    func longest(_ suffixes: [String]) -> String {
      suffixes.filter { word.hasSuffix($0) }.max { $0.count < $1.count } ?? ""
    }

    let s0 = longest(["'s'", "'s", "'"])
    if !s0.isEmpty { cut(s0) }
    let s1a = longest(["sses", "ied", "ies", "s", "us", "ss"])
    if s1a == "sses" { cut(s1a, "ss") }
    else if s1a == "ied" || s1a == "ies" { cut(s1a, word.count > 4 ? "i" : "ie") }
    else if s1a == "s", hasVowel(String(word.dropLast(2))) { cut(s1a) }
    if post1A.contains(word) { return word.replacingOccurrences(of: "Y", with: "y") }

    let s1b = longest(["eed", "eedly", "ed", "edly", "ing", "ingly"])
    if s1b == "eed" || s1b == "eedly" {
      if inRegion(s1b, r1) { cut(s1b, "ee") }
    } else if !s1b.isEmpty, hasVowel(String(word.dropLast(s1b.count))) {
      cut(s1b)
      if word.hasSuffix("at") || word.hasSuffix("bl") || word.hasSuffix("iz") { word += "e" }
      else if doubles.contains(where: { word.hasSuffix($0) }) { word.removeLast() }
      else if r1 >= word.count && shortSyllableAt(word.count) { word += "e" }
    }
    if word.hasSuffix("y"), word.count > 2 {
      let chars = Array(word)
      if !vowel(chars[chars.count - 2]) { word = String(word.dropLast()) + "i" }
    }

    let step2: [(String, String)] = [
      ("tional", "tion"), ("enci", "ence"), ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
      ("izer", "ize"), ("ization", "ize"), ("ational", "ate"), ("ation", "ate"), ("ator", "ate"),
      ("alism", "al"), ("aliti", "al"), ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"),
      ("ousness", "ous"), ("iveness", "ive"), ("iviti", "ive"), ("biliti", "ble"), ("bli", "ble"),
      ("ogi", "og"), ("fulli", "ful"), ("lessli", "less"), ("li", ""),
    ]
    if let pair = step2.filter({ word.hasSuffix($0.0) }).max(by: { $0.0.count < $1.0.count }), inRegion(pair.0, r1) {
      let beforeIndex = word.index(word.endIndex, offsetBy: -pair.0.count - 1)
      let before = beforeIndex >= word.startIndex ? word[beforeIndex] : nil
      if pair.0 == "ogi" { if before == "l" { cut(pair.0, "og") } }
      else if pair.0 == "li" { if let before, liEnding.contains(before) { cut(pair.0) } }
      else { cut(pair.0, pair.1) }
    }

    let step3: [(String, String)] = [("tional", "tion"), ("ational", "ate"), ("alize", "al"), ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"), ("ful", ""), ("ness", ""), ("ative", "")]
    if let pair = step3.filter({ word.hasSuffix($0.0) }).max(by: { $0.0.count < $1.0.count }), inRegion(pair.0, r1), pair.0 != "ative" || inRegion(pair.0, r2) { cut(pair.0, pair.1) }

    let step4 = ["al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ism", "ate", "iti", "ous", "ive", "ize", "ion"]
    if let suffix = step4.filter({ word.hasSuffix($0) }).max(by: { $0.count < $1.count }), inRegion(suffix, r2) {
      if suffix != "ion" || word.dropLast(3).last.map({ $0 == "s" || $0 == "t" }) == true { cut(suffix) }
    }
    if word.hasSuffix("e") {
      if inRegion("e", r2) || (inRegion("e", r1) && !shortSyllableAt(word.count - 1)) { cut("e") }
    } else if word.hasSuffix("ll"), inRegion("l", r2) { word.removeLast() }
    return word.replacingOccurrences(of: "Y", with: "y")
  }

  private static func regionAfter(_ word: String, from: Int) -> Int {
    let chars = Array(word)
    func vowel(_ c: Character) -> Bool { "aeiouy".contains(c) }
    guard from + 1 < chars.count else { return chars.count }
    for index in (from + 1)..<chars.count where !vowel(chars[index]) && vowel(chars[index - 1]) {
      return index + 1
    }
    return chars.count
  }
}
