import Foundation
import NaturalLanguage

private let sentenceMarks: Set<Character> = [".", "!", "?", "。", "！", "？", "｡", "．", "‼", "⁇", "⁈", "⁉", "…"]
private let closingMarks: Set<Character> = [
  "\"", "'", "”", "’", "»", "›", "）", "」", "』", "】", "〕", "〉", "》", "］", "｝", "〟", "〞", "〗", ")", "]", "}",
]
private let openingMarks: Set<Character> = ["\"", "'", "“", "‘", "«", "‹", "（", "【", "〔", "〈", "《", "［", "｛", "(", "[", "{"]
private let abbreviations: Set<String> = [
  "a.m", "approx", "aug", "cf", "dept", "dec", "dr", "e.g", "eq", "est", "etc", "fig", "feb", "jan", "jr",
  "jul", "jun", "mar", "mr", "mrs", "ms", "no", "nov", "oct", "p.m", "prof", "sep", "sept", "sr", "st",
  "vs", "inc", "i.e", "u.s", "u.k", "al",
]

public func firstSentenceLength(_ text: String, locale: String = "en") -> Int {
  guard !text.isEmpty else { return 0 }
  let chars = Array(text)
  guard let first = chars.firstIndex(where: { !$0.isWhitespace }) else { return 0 }
  let tokenizer = NLTokenizer(unit: .sentence)
  tokenizer.string = text
  var fallback = fallbackSentenceEnd(chars, first: first)
  var result: Int?
  tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
    guard result == nil else { return false }
    let segment = String(text[range])
    let end = text.utf16Offset(of: range.upperBound)
    if segment.isEmpty { return true }
    let segmentChars = Array(segment)
    guard let segmentFirst = segmentChars.firstIndex(where: { !$0.isWhitespace }) else { return true }
    let absoluteFirst = Array(text[..<range.lowerBound]).count + segmentFirst
    if absoluteFirst < first { return true }
    let boundaryChars = Array(text.prefix(absoluteFirst + (segmentChars.count - segmentFirst)))
    var boundary = boundaryChars.count
    while boundary > 0, boundaryChars[boundary - 1].isWhitespace { boundary -= 1 }
    var markIndex = boundary - 1
    while markIndex >= 0, closingMarks.contains(boundaryChars[markIndex]) { markIndex -= 1 }
    if end < text.utf16.count, markIndex >= 0, boundaryChars[markIndex] == ".",
      falsePeriodBoundary(boundaryChars, punctuation: markIndex, boundary: boundary) {
      fallback = fallbackSentenceEnd(chars, first: first)
      return true
    }
    result = text.utf16Offset(of: text.index(text.startIndex, offsetBy: boundary))
    return false
  }
  return result ?? fallback
}

public func topicSentenceLength(_ text: String, locale: String = "en") -> Int {
  let cjkCount = text.unicodeScalars.filter(isCJKScalar).count
  let tokenizer = NLTokenizer(unit: .word)
  tokenizer.string = text
  var words = 0
  tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
    let segment = String(text[range])
    if segment.unicodeScalars.contains(where: isWordScalar), !segment.unicodeScalars.allSatisfy(isCJKScalar) {
      words += 1
    }
    return true
  }
  guard Double(words) + Double(cjkCount) / 2 > 60 else { return 0 }
  let end = firstSentenceLength(text, locale: locale)
  guard end > 0, let rest = text.substringUTF16(end..<text.utf16.count), !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
  return end
}

public struct TopicParagraphBlock: Codable, Equatable, Sendable {
  public var id: Int
  public var text: String
  public var fontSize: Double
  public var sourceBox: ReadingRectangle?
  public var translatedBox: ReadingRectangle?
  public var paragraphGroupId: Int?
  public var paragraphSourceText: String?
  public var paragraphSourceOffset: Int

  public init(
    id: Int,
    text: String,
    fontSize: Double,
    sourceBox: ReadingRectangle? = nil,
    translatedBox: ReadingRectangle? = nil,
    paragraphGroupId: Int? = nil,
    paragraphSourceText: String? = nil,
    paragraphSourceOffset: Int = 0
  ) {
    self.id = id
    self.text = text
    self.fontSize = fontSize
    self.sourceBox = sourceBox
    self.translatedBox = translatedBox
    self.paragraphGroupId = paragraphGroupId
    self.paragraphSourceText = paragraphSourceText
    self.paragraphSourceOffset = max(0, paragraphSourceOffset)
  }
}

public struct TopicParagraphBox: Codable, Equatable, Sendable {
  public var id: Int
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var paragraphSourceText: String?
  public var paragraphSourceOffset: Int
  public var eligible: Bool

  public init(
    id: Int,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    paragraphSourceText: String? = nil,
    paragraphSourceOffset: Int = 0,
    eligible: Bool = true
  ) {
    self.id = id
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.paragraphSourceText = paragraphSourceText
    self.paragraphSourceOffset = max(0, paragraphSourceOffset)
    self.eligible = eligible
  }

  fileprivate var rectangle: ReadingRectangle {
    ReadingRectangle(x: x, y: y, width: width, height: height)
  }
}

public struct TopicSentenceParagraph: Codable, Equatable, Sendable {
  public var text: String
  public var firstSentence: String
  public var ranges: [ReadingRunRange]

  public init(text: String, firstSentence: String, ranges: [ReadingRunRange]) {
    self.text = text
    self.firstSentence = firstSentence
    self.ranges = ranges
  }
}

public func topicParagraphBoxes(
  _ blocks: [TopicParagraphBlock],
  translated: Bool = false
) -> [TopicParagraphBox] {
  let weights = Dictionary(grouping: blocks) { block in
    (block.fontSize * 2).rounded() / 2
  }.mapValues { group in
    group.reduce(0) { $0 + Double($1.text.count) * $1.fontSize * $1.fontSize }
  }
  let bodySize = weights.max { lhs, rhs in lhs.value < rhs.value }?.key
  let firstBody = blocks.first { block in
    block.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 &&
      (bodySize == nil || block.fontSize >= bodySize! * 0.9)
  }
  return blocks.compactMap { block in
    let box = (translated ? block.translatedBox : block.sourceBox) ?? block.sourceBox ?? block.translatedBox
    guard let box else { return nil }
    let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercaseCarry = firstBody.map { $0.id == block.id && trimmed.first?.isLowercase == true } ?? false
    let smallNumbered = bodySize.map {
      block.fontSize < $0 * 0.9 && trimmed.range(of: #"^\d{1,3}(?!\d)"#, options: .regularExpression) != nil
    } ?? false
    return TopicParagraphBox(
      id: block.id,
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      paragraphSourceText: block.paragraphSourceText,
      paragraphSourceOffset: block.paragraphSourceOffset,
      eligible: block.paragraphGroupId != nil || (!lowercaseCarry && !smallNumbered)
    )
  }
}

public func topicParagraphBoxes(
  _ paragraphs: [LayoutParagraph],
  translated: Bool = false
) -> [TopicParagraphBox] {
  topicParagraphBoxes(paragraphs.map {
    TopicParagraphBlock(
      id: $0.id,
      text: $0.text,
      fontSize: $0.fontSize,
      sourceBox: ReadingRectangle(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
    )
  }, translated: translated)
}

public func topicSentenceParagraphs(
  _ runs: [ReadingTextRun],
  boxes: [TopicParagraphBox] = [],
  locale: String = "en"
) -> [TopicSentenceParagraph] {
  let normalized = runs.map { TopicRun(text: $0.text, geometry: TopicGeometry(run: $0)) }
  var explicitGroups: [String: TopicGroup] = [:]
  var groupOrder: [String] = []
  var unmatched: [Int] = []
  for index in normalized.indices {
    guard let match = bestExplicitBox(normalized[index].geometry, boxes) else {
      unmatched.append(index)
      continue
    }
    let key = "id:\(match.id)"
    if explicitGroups[key] == nil {
      explicitGroups[key] = TopicGroup(indices: [], order: index, eligible: match.eligible, sourceText: match.paragraphSourceText, sourceOffset: match.paragraphSourceOffset)
      groupOrder.append(key)
    }
    explicitGroups[key]!.indices.append(index)
  }
  var groups: [TopicGroup] = groupOrder.compactMap { explicitGroups[$0] }
  for indices in fallbackGroups(unmatched, normalized: normalized) {
    groups.append(TopicGroup(indices: indices, order: indices[0], eligible: true, sourceText: nil, sourceOffset: 0))
  }
  return groups.sorted { $0.order < $1.order }.compactMap { group in
    guard group.eligible else { return nil }
    return rangesForIndices(group.indices, normalized: normalized, locale: locale, sourceText: group.sourceText, sourceOffset: group.sourceOffset)
  }
}

public func topicSentenceRanges(
  _ runs: [ReadingTextRun],
  boxes: [TopicParagraphBox] = [],
  locale: String = "en"
) -> [ReadingRunRange] {
  topicSentenceParagraphs(runs, boxes: boxes, locale: locale)
    .flatMap(\.ranges)
    .sorted { lhs, rhs in lhs.index == rhs.index ? lhs.start < rhs.start : lhs.index < rhs.index }
}

private struct TopicGeometry {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var fontSize: Double

  init(run: ReadingTextRun) {
    x = run.x
    y = run.y
    width = max(0, run.width)
    height = max(0, run.height)
    fontSize = max(run.height, 1)
  }
}

private struct TopicRun {
  var text: String
  var geometry: TopicGeometry
}

private struct TopicGroup {
  var indices: [Int]
  var order: Int
  var eligible: Bool
  var sourceText: String?
  var sourceOffset: Int
  var firstX: Double = 0
  var lineCount: Int = 1
}

private func bestExplicitBox(_ center: TopicGeometry, _ boxes: [TopicParagraphBox]) -> TopicParagraphBox? {
  let centerX = center.x + center.width / 2
  let centerY = center.y + center.height / 2
  return boxes.enumerated().filter { _, box in
    centerX >= box.x - 0.000001 && centerX <= box.x + box.width + 0.000001 &&
      centerY >= box.y - 0.000001 && centerY <= box.y + box.height + 0.000001
  }.sorted { lhs, rhs in
    let leftArea = lhs.element.width * lhs.element.height
    let rightArea = rhs.element.width * rhs.element.height
    return leftArea == rightArea ? lhs.offset < rhs.offset : leftArea < rightArea
  }.first?.element
}

private func sameLine(_ run: TopicRun, _ line: TopicLine) -> Bool {
  let minimum = max(1, min(run.geometry.height == 0 ? run.geometry.fontSize : run.geometry.height, line.height == 0 ? line.fontSize : line.height))
  let runCenter = run.geometry.y + (run.geometry.height == 0 ? run.geometry.fontSize : run.geometry.height) / 2
  let lineCenter = line.top + line.height / 2
  let overlap = min(run.geometry.y + (run.geometry.height == 0 ? run.geometry.fontSize : run.geometry.height), line.bottom) - max(run.geometry.y, line.top)
  guard overlap >= minimum * 0.25 || abs(runCenter - lineCenter) <= max(2, minimum * 0.45) else { return false }
  let gap = run.geometry.x > line.right ? run.geometry.x - line.right : line.x > run.geometry.x + run.geometry.width ? line.x - (run.geometry.x + run.geometry.width) : 0
  return gap <= max(12, line.fontSize * 2)
}

private struct TopicLine {
  var indices: [Int]
  var x: Double
  var right: Double
  var top: Double
  var bottom: Double
  var height: Double
  var fontSize: Double
}

private func fallbackGroups(_ indices: [Int], normalized: [TopicRun]) -> [[Int]] {
  var lines: [TopicLine] = []
  for index in indices {
    let run = normalized[index]
    var target: Int?
    var score = Double.infinity
    for lineIndex in lines.indices where sameLine(run, TopicLine(indices: lines[lineIndex].indices, x: lines[lineIndex].x, right: lines[lineIndex].right, top: lines[lineIndex].top, bottom: lines[lineIndex].bottom, height: lines[lineIndex].height, fontSize: lines[lineIndex].fontSize)) {
      let candidate = abs(run.geometry.y - lines[lineIndex].top) + abs(run.geometry.x - lines[lineIndex].right) * 0.01
      if candidate < score { target = lineIndex; score = candidate }
    }
    if let target {
      lines[target].indices.append(index)
      lines[target].x = min(lines[target].x, run.geometry.x)
      lines[target].right = max(lines[target].right, run.geometry.x + run.geometry.width)
      lines[target].top = min(lines[target].top, run.geometry.y)
      lines[target].bottom = max(lines[target].bottom, run.geometry.y + max(run.geometry.height, run.geometry.fontSize))
      lines[target].height = lines[target].bottom - lines[target].top
      lines[target].fontSize = (lines[target].fontSize + run.geometry.fontSize) / 2
    } else {
      lines.append(TopicLine(indices: [index], x: run.geometry.x, right: run.geometry.x + run.geometry.width, top: run.geometry.y, bottom: run.geometry.y + max(run.geometry.height, run.geometry.fontSize), height: max(run.geometry.height, run.geometry.fontSize), fontSize: run.geometry.fontSize))
    }
  }
  var groups: [TopicGroup] = []
  for line in lines {
    if var previous = groups.last, let lastLine = lineForGroup(previous, lines: lines), !paragraphBreak(lastLine, line, previous) {
      previous.indices.append(contentsOf: line.indices)
      previous.lineCount += 1
      groups[groups.count - 1] = previous
    } else {
      groups.append(TopicGroup(indices: line.indices, order: line.indices[0], eligible: true, sourceText: nil, sourceOffset: 0, firstX: line.x))
    }
  }
  return groups.map(\.indices)
}

private func lineForGroup(_ group: TopicGroup, lines: [TopicLine]) -> TopicLine? {
  lines.last { $0.indices.last == group.indices.last }
}

private func paragraphBreak(_ previous: TopicLine, _ line: TopicLine, _ paragraph: TopicGroup) -> Bool {
  let size = max(previous.fontSize, line.fontSize)
  let gap = line.top - previous.bottom
  if gap < -max(2, size * 0.45) || gap > max(3, size * 0.9) { return true }
  if abs(previous.fontSize - line.fontSize) > max(1.5, size * 0.2) { return true }
  let xJump = abs(line.x - previous.x)
  if paragraph.lineCount == 1, previous.x > line.x, xJump <= size * 3 { return false }
  if xJump > max(3, size * 1.35) { return true }
  let firstX = paragraph.firstX
  return abs(line.x - firstX) > max(3, size * 1.35) && xJump > max(2, size * 0.5)
}

private func rangesForIndices(
  _ indices: [Int],
  normalized: [TopicRun],
  locale: String,
  sourceText: String?,
  sourceOffset: Int
) -> TopicSentenceParagraph? {
  var logical = ""
  var parts: [ReadingRunPart] = []
  for index in indices {
    let text = normalized[index].text
    if !logical.isEmpty, needsSeparator(logical, text) { logical.append(" ") }
    let start = logical.utf16.count
    logical.append(contentsOf: text)
    parts.append(ReadingRunPart(index: index, start: start, end: logical.utf16.count))
  }
  let paragraphText = sourceText ?? logical
  let paragraphEnd = topicSentenceLength(paragraphText, locale: locale)
  var sentenceEnd = paragraphEnd - sourceOffset
  guard paragraphEnd > 0, sentenceEnd > 0 else { return nil }
  if sourceText != nil {
    let expected = significant(String(paragraphText.substringUTF16(sourceOffset..<paragraphEnd) ?? ""))
    var matched = 0
    var mapped = 0
    var mismatch = false
    var logicalOffset = 0
    for character in logical {
      logicalOffset += String(character).utf16.count
      if character.isWhitespace || character == "-" || character == "­" { continue }
      guard matched < expected.count, character == expected[matched] else { mismatch = true; break }
      matched += 1
      mapped = logicalOffset
      if matched == expected.count { break }
    }
    if !mismatch { sentenceEnd = matched == expected.count ? mapped : logical.utf16.count }
  }
  let ranges = parts.compactMap { part -> ReadingRunRange? in
    guard part.start < sentenceEnd else { return nil }
    let end = min(part.end, sentenceEnd) - part.start
    guard end > 0 else { return nil }
    return ReadingRunRange(index: part.index, start: 0, end: end)
  }
  return TopicSentenceParagraph(text: paragraphText, firstSentence: paragraphText.substringUTF16(0..<paragraphEnd) ?? "", ranges: ranges)
}

private func significant(_ text: String) -> [Character] {
  text.filter { !$0.isWhitespace && $0 != "-" && $0 != "­" }
}

private func needsSeparator(_ left: String, _ right: String) -> Bool {
  guard let last = left.last, let first = right.first, !last.isWhitespace, !first.isWhitespace else { return false }
  if isCJKLike(last) || isCJKLike(first) || last == "-" || last == "‐" || last == "‑" { return false }
  if sentenceMarks.contains(first) || ",;:)]}".contains(first) || closingMarks.contains(first) { return false }
  if openingMarks.contains(last) { return false }
  return true
}

private func isCJKLike(_ character: Character) -> Bool {
  character.unicodeScalars.contains { isCJKScalar($0) } || "，。！？、；：…「」『』（）【】《》".contains(character)
}

private func fallbackSentenceEnd(_ chars: [Character], first: Int) -> Int {
  for index in first..<chars.count where sentenceMarks.contains(chars[index]) {
    let end = afterClosingMarks(chars, punctuation: index)
    if chars[index] == ".", falsePeriodBoundary(chars, punctuation: index, boundary: end) { continue }
    return trimWhitespaceEnd(chars, end)
  }
  return trimWhitespaceEnd(chars, chars.count)
}

private func trimWhitespaceEnd(_ chars: [Character], _ end: Int) -> Int {
  var end = end
  while end > 0, chars[end - 1].isWhitespace { end -= 1 }
  return end
}

private func afterClosingMarks(_ chars: [Character], punctuation: Int) -> Int {
  var end = punctuation + 1
  while end < chars.count, closingMarks.contains(chars[end]) { end += 1 }
  return end
}

private func falsePeriodBoundary(_ chars: [Character], punctuation: Int, boundary: Int) -> Bool {
  let next = punctuation + 1 < chars.count ? chars[punctuation + 1] : nil
  let previous = punctuation > 0 ? chars[punctuation - 1] : nil
  if let next, let previous, next.isNumber, previous.isNumber { return true }
  if next == "." { return true }
  var start = punctuation
  while start > 0, chars[start - 1].isASCII && (chars[start - 1].isLetter || chars[start - 1] == ".") { start -= 1 }
  let token = String(chars[start...punctuation]).lowercased()
  let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
  if abbreviations.contains(normalized) || token.range(of: #"^(?:[A-Za-z]\.){2,}$"#, options: .regularExpression) != nil || token.range(of: #"^[A-Za-z]\.$"#, options: .regularExpression) != nil { return true }
  var nextIndex = boundary
  while nextIndex < chars.count, chars[nextIndex].isWhitespace { nextIndex += 1 }
  return nextIndex < chars.count && chars[nextIndex].isASCII && chars[nextIndex].isLetter && nextIndex > boundary
}

private func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (0x2E80...0x2FFF).contains(value) || (0x3000...0x30FF).contains(value) || (0x3130...0x318F).contains(value) || (0x31A0...0x31FF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0xAC00...0xD7AF).contains(value)
}

private func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
    return true
  default:
    return false
  }
}

private extension String {
  func substringUTF16(_ range: Range<Int>) -> String? {
    guard range.lowerBound >= 0, range.upperBound <= utf16.count,
      let start = indexAtUTF16Offset(range.lowerBound), let end = indexAtUTF16Offset(range.upperBound) else { return nil }
    return String(self[start..<end])
  }
}
