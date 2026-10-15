import Foundation

public let maxDetectedLinks = 5

private let urlRegex = try! NSRegularExpression(
  pattern: #"\b(?:https?://|www\.)[^\s<>"，。；：、（）【】《》]+|\bdoi:\s*10\.\d{4,9}/[^\s<>"，。；：、（）【】《》]+"#,
  options: [.caseInsensitive]
)
private let emailRegex = try! NSRegularExpression(
  pattern: #"(?<![\w.%+-])[A-Za-z0-9][\w.%+-]*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}\b"#,
  options: []
)

public func detectLinks(_ text: String) -> [String] {
  guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
  let joined = rejoinWrappedURLs(text)
  let range = NSRange(joined.startIndex..., in: joined)
  var links: [String] = []
  for match in urlRegex.matches(in: joined, range: range) {
    guard let candidate = joined.substring(nsRange: match.range),
      let url = normalizeURL(trimURL(candidate)), !links.contains(url) else { continue }
    links.append(url)
    if links.count == maxDetectedLinks { break }
  }
  return links
}

public func detectEmails(_ text: String) -> [String] {
  guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
  let range = NSRange(text.startIndex..., in: text)
  var emails: [String] = []
  for match in emailRegex.matches(in: text, range: range) {
    guard let value = text.substring(nsRange: match.range), let at = value.lastIndex(of: "@") else { continue }
    let email = String(value[..<at]) + String(value[at...]).lowercased()
    if !emails.contains(email) { emails.append(email) }
    if emails.count == maxDetectedLinks { break }
  }
  return emails
}

public func linkLabel(_ url: String, maxLength: Int = 48) -> String {
  guard let parsed = URL(string: url), let host = parsed.host else { return url }
  var text = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  if parsed.path != "/" { text += parsed.path }
  if let query = parsed.query, !query.isEmpty { text += "?" + query }
  if let fragment = parsed.fragment, !fragment.isEmpty { text += "#" + fragment }
  guard text.count > maxLength, maxLength > 1 else { return text }
  return String(text.prefix(maxLength - 1)) + "…"
}

private func rejoinWrappedURLs(_ input: String) -> String {
  var text = input
  let pattern = try! NSRegularExpression(pattern: #"(\S+)[^\S\n]*\n\s*(?=(\S+))"#)
  for _ in 0..<8 {
    var changed = false
    let range = NSRange(text.startIndex..., in: text)
    let matches = pattern.matches(in: text, range: range)
    for match in matches.reversed() {
      guard let whole = text.substring(nsRange: match.range),
        let before = text.substring(nsRange: match.range(at: 1)),
        let after = text.substring(nsRange: match.range(at: 2)) else { continue }
      guard before.range(of: #"(?:https?://|www\.|doi:)"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
      let continuation = before.hasSuffix("/") || before.hasSuffix("-") || before.hasSuffix("_") || before.hasSuffix("=") || before.hasSuffix("&") || before.hasSuffix("?") || before.hasSuffix("#") || before.hasSuffix("%") || before.hasSuffix("~") || (before.hasSuffix(".") && (after.contains("/") || after.contains(".")))
      guard continuation else { continue }
      let replacement = before
      if whole != replacement {
        let start = String.Index(utf16Offset: match.range.location, in: text)
        let end = String.Index(utf16Offset: match.range.location + match.range.length, in: text)
        text.replaceSubrange(start..<end, with: replacement)
        changed = true
      }
    }
    if !changed { break }
  }
  return text
}

private func trimURL(_ candidate: String) -> String {
  var value = candidate
  while true {
    let trimmed = value.replacingOccurrences(of: #"[.,;:!?\'"“”‘’]+$"#, with: "", options: .regularExpression)
    guard let last = trimmed.last else { return trimmed }
    let opener: Character? = [")": "(", "]": "[", "}": "{", ">": "<"][last]
    if let opener, trimmed.filter({ $0 == opener }).count <= trimmed.filter({ $0 == last }).count - 1 {
      value = String(trimmed.dropLast())
      continue
    }
    if trimmed == value { return value }
    value = trimmed
  }
}

private func normalizeURL(_ candidate: String) -> String? {
  guard !candidate.isEmpty else { return nil }
  var raw = candidate
  if let range = raw.range(of: #"^doi:\s*(10\..+)$"#, options: [.regularExpression, .caseInsensitive]) {
    let value = String(raw[range]).replacingOccurrences(of: #"^doi:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    raw = "https://doi.org/" + value
  } else if raw.lowercased().hasPrefix("www.") {
    raw = "https://" + raw
  }
  guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, host.contains(".") else { return nil }
  return url.absoluteString
}

private extension String {
  func substring(nsRange: NSRange) -> String? {
    guard let range = Range(nsRange, in: self) else { return nil }
    return String(self[range])
  }
}
