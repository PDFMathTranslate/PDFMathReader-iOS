import Foundation

public let importantInformationKeywords: [String: [String]] = [
  "results": [
    "result", "results", "finding", "findings", "outcome", "outcomes", "evidence",
    "significant", "significantly", "insignificant", "nonsignificant", "non-significant",
    "statistical significance", "statistically significant", "not statistically significant",
    "null result", "null results", "effect size", "effect sizes", "robust", "robustness",
    "结果", "結果", "研究结果", "研究結果", "研究发现", "研究發現", "证据", "證據", "显著",
    "顯著", "不显著", "不顯著", "统计显著", "統計顯著", "统计显著性", "統計顯著性", "效应量",
    "效應量", "稳健", "穩健",
  ],
  "ordinals": [
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
    "tenth", "firstly", "secondly", "thirdly", "fourthly", "finally", "首先", "其次", "再次",
    "最后", "最後", "第一", "第二", "第三", "第四", "第五", "第六", "第七", "第八", "第九", "第十",
  ],
  "logic": [
    "however", "therefore", "thus", "hence", "consequently", "nevertheless", "nonetheless",
    "although", "whereas", "because", "despite", "conversely", "moreover", "furthermore",
    "in contrast", "by contrast", "in addition", "as a result", "on the other hand", "然而", "但是",
    "因此", "因而", "所以", "由此", "从而", "從而", "不过", "不過", "尽管", "儘管", "虽然", "雖然",
    "因为", "因為", "由于", "由於", "相反", "此外", "进一步", "進一步", "一方面", "另一方面",
    "与此同时", "與此同時",
  ],
  "discovery": [
    "support", "supports", "supported", "supporting", "do not support", "does not support",
    "falsify", "falsifies", "falsified", "falsifying", "falsification", "refute", "refutes",
    "refuted", "refuting", "reject", "rejects", "rejected", "rejecting", "suggest", "suggests",
    "suggested", "suggesting", "indicate", "indicates", "indicated", "indicating", "demonstrate",
    "demonstrates", "demonstrated", "demonstrating", "reveal", "reveals", "revealed", "revealing",
    "discover", "discovers", "discovered", "discovering", "find", "finds", "found", "show", "shows",
    "showed", "shown", "showing", "confirm", "confirms", "confirmed", "confirming", "corroborate",
    "corroborates", "corroborated", "contradict", "contradicts", "contradicted", "contradicting",
    "observe", "observes", "observed", "observing", "establish", "establishes", "established", "支持",
    "不支持", "证伪", "證偽", "反对", "反對", "反驳", "反駁", "否定", "拒绝", "拒絕", "表明", "显示",
    "顯示", "提示", "说明", "說明", "证明", "證明", "证实", "證實", "验证", "驗證", "发现", "發現",
    "揭示", "观察到", "觀察到", "印证", "印證",
  ],
  "comparison": [
    "higher", "lower", "greater", "smaller", "larger", "better", "worse", "stronger", "weaker",
    "increase", "increases", "increased", "increasing", "decrease", "decreases", "decreased",
    "decreasing", "reduce", "reduces", "reduced", "reducing", "reduction", "improve", "improves",
    "improved", "improvement", "similar", "similarly", "different", "difference", "differences",
    "equivalent", "compared with", "compared to", "relative to", "greater than", "less than",
    "no difference", "more likely", "less likely", "at least", "at most", "相比", "相较", "相較",
    "相对于", "相對於", "高于", "高於", "低于", "低於", "大于", "大於", "小于", "小於", "更多", "更少",
    "更高", "更低", "更强", "更強", "更弱", "增加", "增大", "上升", "减少", "減少", "下降", "降低", "改善",
    "提高", "优于", "優於", "劣于", "劣於", "相似", "不同", "差异", "差異", "无差异", "無差異", "没有差异",
    "沒有差異", "更可能", "更不可能", "至少", "至多",
  ],
]

public struct InformationRange: Codable, Equatable, Sendable {
  public var start: Int
  public var end: Int
  public var category: String

  public init(start: Int, end: Int, category: String) {
    self.start = start
    self.end = end
    self.category = category
  }
}

private let informationGroups: [String: String] = [
  "results": "research", "comparison": "research", "ordinals": "ordinals",
  "discovery": "verbs", "logic": "logic",
]

private struct InformationPattern {
  var word: String
  var category: String
  var english: Bool
  var regex: NSRegularExpression
}

private let informationPatterns: [InformationPattern] = {
  importantInformationKeywords.flatMap { category, words in
    words.compactMap { word in
      let escaped = NSRegularExpression.escapedPattern(for: word).replacingOccurrences(of: " ", with: "\\s+")
      guard let regex = try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive]) else { return nil }
      return InformationPattern(word: word, category: category, english: word.first?.isASCII == true && word.first?.isLetter == true, regex: regex)
    }
  }.sorted { $0.word.utf16.count > $1.word.utf16.count }
}()

public func importantInformationRanges(
  _ text: String = "",
  categories: [String: Bool]? = nil
) -> [InformationRange] {
  guard !text.isEmpty else { return [] }
  var matches: [InformationRange] = []
  let fullRange = NSRange(text.startIndex..., in: text)
  for entry in informationPatterns {
    if categories?[informationGroups[entry.category] ?? ""] == false { continue }
    for match in entry.regex.matches(in: text, range: fullRange) {
      let start = match.range.location
      let end = start + match.range.length
      if entry.english,
        isWordCharacter(in: text, utf16Offset: start - 1) ||
          isWordCharacter(in: text, utf16Offset: end) {
        continue
      }
      matches.append(InformationRange(start: start, end: end, category: entry.category))
    }
  }
  matches.sort { lhs, rhs in
    lhs.start == rhs.start ? (lhs.end - lhs.start) > (rhs.end - rhs.start) : lhs.start < rhs.start
  }
  var selected: [InformationRange] = []
  for match in matches where selected.last.map({ match.start >= $0.end }) ?? true {
    selected.append(match)
  }
  return selected
}

public func informationTextSegments(
  _ text: String = "",
  topicEnd: Int = 0,
  emphasizeInformation: Bool = false,
  ranges: [InformationRange]? = nil,
  categories: [String: Bool]? = nil
) -> [ReadingTextSegment] {
  let sourceLength = text.utf16.count
  let topic = max(0, min(sourceLength, topicEnd))
  let keywords = emphasizeInformation ? (ranges ?? importantInformationRanges(text, categories: categories)) : []
  var boundaries = Set([0, sourceLength, topic])
  for range in keywords {
    boundaries.insert(range.start)
    boundaries.insert(range.end)
  }
  let sorted = boundaries.filter { $0 >= 0 && $0 <= sourceLength }.sorted()
  return zip(sorted, sorted.dropFirst()).compactMap { start, end in
    guard let value = text.substringUTF16(start..<end) else { return nil }
    return ReadingTextSegment(
      text: value,
      start: start,
      end: end,
      topic: start < topic,
      important: keywords.contains { start >= $0.start && start < $0.end }
    )
  }
}

public func informationRunRanges(
  _ runs: [ReadingTextRun] = [],
  categories: [String: Bool]? = nil
) -> [ReadingRunRange] {
  let joined = joinReadingRuns(runs)
  let matches = importantInformationRanges(joined.logical, categories: categories)
  return splitReadingRanges(matches.map {
    ReadingRunRange(index: 0, start: $0.start, end: $0.end, category: $0.category)
  }, parts: joined.parts)
}

public let tfidfSamplePages = 12
public let tfidfMinimumDocuments = 3
public let tfidfMaximumDocumentFrequency = 0.5
public let tfidfEmphasizedShare = 0.3
public let tfidfLevels = [1.0, 0.7, 0.4]

public struct TfidfToken: Codable, Equatable, Sendable {
  public var term: String
  public var start: Int
  public var end: Int

  public init(term: String, start: Int, end: Int) {
    self.term = term
    self.start = start
    self.end = end
  }
}

public struct TfidfRange: Codable, Equatable, Sendable {
  public var start: Int
  public var end: Int
  public var strength: Double

  public init(start: Int, end: Int, strength: Double) {
    self.start = start
    self.end = end
    self.strength = strength
  }
}

public func tfidfTerm(_ word: String = "") -> String {
  let term = word.precomposedStringWithCompatibilityMapping.lowercased()
  let length = term.unicodeScalars.count
  guard (2...127).contains(length), term.unicodeScalars.contains(where: isLetterScalar) else { return "" }
  return term
}

public func tfidfTokens(_ text: String = "") -> [TfidfToken] {
  guard !text.isEmpty else { return [] }
  var result: [TfidfToken] = []
  for word in readingWordSegments(text) {
    guard word.text.unicodeScalars.contains(where: isWordScalar), !word.text.isEmpty
    else { continue }
    let term = tfidfTerm(word.text)
    guard !term.isEmpty else { continue }
    let start = text.utf16Offset(of: word.range.lowerBound)
    result.append(TfidfToken(term: term, start: start, end: start + word.text.utf16.count))
  }
  return result
}

public func tfidfTermSet(_ texts: [String] = []) -> [String] {
  var terms = Set<String>()
  var result: [String] = []
  for text in texts {
    for token in tfidfTokens(text) where terms.insert(token.term).inserted {
      result.append(token.term)
    }
  }
  return result
}

public func sampleTfidfPageNumbers(
  count: Int,
  size: Int = tfidfSamplePages,
  random: () -> Double = { Double.random(in: 0..<1) }
) -> [Int] {
  var pages = count > 0 ? Array(1...count) : []
  let take = min(max(0, size), pages.count)
  if take > 0 {
    for index in 0..<take {
      let remaining = pages.count - index
      let offset = min(remaining - 1, max(0, Int(random() * Double(remaining))))
      pages.swapAt(index, index + offset)
    }
  }
  return Array(pages.prefix(take)).sorted()
}

public func tfidfInverseDocumentFrequency(_ df: Double, documents: Double) -> Double {
  log(documents / df) + 1
}

public func tfidfRanges(
  _ text: String,
  documents: Int,
  frequency: (String) -> Int
) -> [TfidfRange] {
  let tokens = tfidfTokens(text)
  guard !tokens.isEmpty, documents >= tfidfMinimumDocuments else { return [] }
  var counts: [String: Int] = [:]
  for token in tokens { counts[token.term, default: 0] += 1 }
  let totalDocuments = Double(documents + 1)
  var scored = counts.compactMap { term, count -> (term: String, score: Double)? in
    let df = Double(max(0, frequency(term))) + 1
    guard df / totalDocuments <= tfidfMaximumDocumentFrequency else { return nil }
    return (term: term, score: Double(count) * tfidfInverseDocumentFrequency(df, documents: totalDocuments))
  }
  scored.sort { lhs, rhs in lhs.score == rhs.score ? lhs.term < rhs.term : lhs.score > rhs.score }
  let emphasized = min(scored.count, Int(ceil(Double(counts.count) * tfidfEmphasizedShare)))
  guard emphasized > 0 else { return [] }
  var strengths: [String: Double] = [:]
  for index in 0..<emphasized {
    strengths[scored[index].term] = tfidfLevels[(index * tfidfLevels.count) / emphasized]
  }
  return tokens.compactMap { token in
    guard let strength = strengths[token.term] else { return nil }
    return TfidfRange(start: token.start, end: token.end, strength: strength)
  }
}

public struct TfidfRunText: Codable, Equatable, Sendable {
  public var logical: String
  public var parts: [ReadingRunPart]
  public var terms: [String]

  public init(logical: String, parts: [ReadingRunPart], terms: [String]) {
    self.logical = logical
    self.parts = parts
    self.terms = terms
  }
}

public struct ReadingRunPart: Codable, Equatable, Sendable {
  public var index: Int
  public var start: Int
  public var end: Int

  public init(index: Int, start: Int, end: Int) {
    self.index = index
    self.start = start
    self.end = end
  }
}

public func tfidfRunText(_ runs: [ReadingTextRun] = []) -> TfidfRunText {
  let joined = joinReadingRuns(runs)
  return TfidfRunText(
    logical: joined.logical,
    parts: joined.parts.map { ReadingRunPart(index: $0.index, start: $0.start, end: $0.end) },
    terms: tfidfTermSet([joined.logical])
  )
}

public func tfidfRunRanges(
  _ runs: [ReadingTextRun],
  documents: Int,
  frequency: @escaping (String) -> Int,
  text: TfidfRunText? = nil
) -> [ReadingRunRange] {
  let value = text ?? tfidfRunText(runs)
  let ranges = tfidfRanges(value.logical, documents: documents, frequency: frequency)
  return ranges.flatMap { match in
    value.parts.compactMap { part in
      let start = max(match.start, part.start)
      let end = min(match.end, part.end)
      guard end > start else { return nil }
      return ReadingRunRange(index: part.index, start: start - part.start, end: end - part.start, strength: match.strength)
    }
  }
}

private func isLetterScalar(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
    return true
  default:
    return false
  }
}

private func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
    .decimalNumber, .letterNumber, .otherNumber:
    return true
  default:
    return false
  }
}

private func isWordCharacter(in text: String, utf16Offset offset: Int) -> Bool {
  guard offset >= 0, offset < text.utf16.count,
    let index = text.indexAtUTF16Offset(offset), index < text.endIndex
  else { return false }
  return text[index].unicodeScalars.contains { isWordScalar($0) || $0 == "_" }
}

private func joinReadingRuns(_ runs: [ReadingTextRun]) -> (logical: String, parts: [ReadingRunPart]) {
  var logical = ""
  var parts: [ReadingRunPart] = []
  for index in runs.indices {
    let text = runs[index].text
    if index > 0, !logical.isEmpty, !text.isEmpty,
      !logical.last!.isWhitespace, !text.first!.isWhitespace {
      let previous = runs[index - 1]
      let height = max(1, min(previous.height == 0 ? 12 : previous.height, runs[index].height == 0 ? 12 : runs[index].height))
      let sameLine = abs(previous.y - runs[index].y) < height * 0.5
      let gap = runs[index].x - previous.x - previous.width
      let lower = text.first.map { $0.isASCII && $0.isLetter } == true
      if !sameLine, (logical.last == "-" || logical.last == "‐"), lower {
        logical.removeLast()
      } else if !sameLine || gap > max(0.5, height * 0.08) {
        logical.append(" ")
      }
    }
    let start = logical.utf16.count
    logical.append(contentsOf: text)
    parts.append(ReadingRunPart(index: index, start: start, end: logical.utf16.count))
  }
  return (logical, parts)
}

private func splitReadingRanges(
  _ matches: [ReadingRunRange],
  parts: [ReadingRunPart]
) -> [ReadingRunRange] {
  var result: [ReadingRunRange] = []
  for match in matches {
    for part in parts {
      let start = max(match.start, part.start)
      let end = min(match.end, part.end)
      guard end > start else { continue }
      result.append(ReadingRunRange(
        index: part.index,
        start: start - part.start,
        end: end - part.start,
        category: match.category,
        strength: match.strength
      ))
    }
  }
  return result
}

private extension String {
  func substringUTF16(_ range: Range<Int>) -> String? {
    guard let start = indexAtUTF16Offset(range.lowerBound), let end = indexAtUTF16Offset(range.upperBound) else { return nil }
    return String(self[start..<end])
  }
}
