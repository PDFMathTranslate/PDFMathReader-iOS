import Foundation

private let openingPlaceholderPattern = #"<\s*([^\s<>/='\"]+)\s+id\s*=\s*(['\"]?)\s*\d+\s*\2\s*>"#
private let closingPlaceholderPattern = #"<\s*/\s*([^\s<>/='\"]+)\s*>"#
private let malformedFormulaPattern = #"\{\s*v\s*\*\s*\}|\{\s*\{\s*v[\d\s]+\}\s*\}"#

private func firstRegexMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
  guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
    return nil
  }
  return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
}

public func hasRichTextPlaceholders(_ text: String) -> Bool {
  firstRegexMatch(openingPlaceholderPattern, in: text) != nil
}

/// Drops recognized placeholder tags but keeps their enclosed text, matching
/// BabelDOC's behavior when a translated tag name cannot be matched upstream.
public func stripRichTextPlaceholders(_ text: String) -> String {
  guard hasRichTextPlaceholders(text),
        let opening = try? NSRegularExpression(pattern: openingPlaceholderPattern, options: [.caseInsensitive]) else {
    return text
  }
  let range = NSRange(text.startIndex..., in: text)
  var names = Set<String>()
  opening.enumerateMatches(in: text, range: range) { match, _, _ in
    guard let match, let nameRange = Range(match.range(at: 1), in: text) else { return }
    names.insert(String(text[nameRange]).lowercased())
  }
  let result = opening.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  guard let closing = try? NSRegularExpression(pattern: closingPlaceholderPattern, options: [.caseInsensitive]) else {
    return result
  }
  var stripped = ""
  var cursor = result.startIndex
  for match in closing.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
    guard let matchRange = Range(match.range, in: result),
          let nameRange = Range(match.range(at: 1), in: result) else { continue }
    stripped.append(contentsOf: result[cursor..<matchRange.lowerBound])
    if !names.contains(String(result[nameRange]).lowercased()) {
      stripped.append(contentsOf: result[matchRange])
    }
    cursor = matchRange.upperBound
  }
  stripped.append(contentsOf: result[cursor...])
  return stripped
}

public func hasUnparsedPlaceholders(_ text: String?) -> Bool {
  guard let text else { return false }
  if firstRegexMatch(malformedFormulaPattern, in: text) != nil { return true }
  guard let regex = try? NSRegularExpression(pattern: openingPlaceholderPattern, options: [.caseInsensitive]) else {
    return false
  }
  let canonical = try? NSRegularExpression(
    pattern: #"^<\s*style\s*id\s*=\s*'\s*\d+\s*'\s*>$"#,
    options: [.caseInsensitive]
  )
  let range = NSRange(text.startIndex..., in: text)
  return regex.matches(in: text, range: range).contains { match in
    let tag = String(text[Range(match.range, in: text)!])
    return canonical?.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) == nil
  }
}

/// Formula placeholder codec used by the paragraph path. It preserves the
/// desktop token spellings, including doubled braces and spaces in ids.
public enum FormulaPlaceholderCodec {
  private static let tokenPattern = #"\{+\s*v\s*([\d\s]+|\*)\s*\}+"#

  public static func encode(_ formula: String, id: Int) -> String {
    "{v\(id)}"
  }

  public static func decode(
    _ text: String,
    formulas: [String],
    sourceInput: String,
    fallbackText: String? = nil
  ) -> String {
    let translation = stripRichTextPlaceholders(text)
    let ids = formulaIDs(in: sourceInput)
    let wildcardID = ids.count == 1 ? ids.first : nil
    var ambiguous = false
    guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
      return text
    }
    let range = NSRange(translation.startIndex..., in: translation)
    var result = ""
    var cursor = translation.startIndex
    for match in regex.matches(in: translation, range: range) {
      guard let matchRange = Range(match.range, in: translation),
            let idRange = Range(match.range(at: 1), in: translation) else { continue }
      result.append(contentsOf: translation[cursor..<matchRange.lowerBound])
      let idText = String(translation[idRange])
      if idText == "*" {
        guard let wildcardID else {
          ambiguous = true
          result.append(contentsOf: translation[matchRange])
          cursor = matchRange.upperBound
          continue
        }
        result.append(wildcardID < formulas.count ? formulas[wildcardID] : "")
      } else {
        let normalized = idText.filter { !$0.isWhitespace }
        let id = Int(normalized) ?? -1
        result.append((id >= 0 && id < formulas.count) ? formulas[id] : "")
      }
      cursor = matchRange.upperBound
    }
    result.append(contentsOf: translation[cursor...])
    return ambiguous ? (fallbackText ?? translation) : result
  }

  private static func formulaIDs(in text: String) -> [Int] {
    guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
      return []
    }
    let range = NSRange(text.startIndex..., in: text)
    var ids = Set<Int>()
    for match in regex.matches(in: text, range: range) {
      guard let idRange = Range(match.range(at: 1), in: text) else { continue }
      let id = String(text[idRange])
      guard id != "*", let number = Int(id.filter { !$0.isWhitespace }) else { continue }
      ids.insert(number)
    }
    return ids.sorted()
  }
}

