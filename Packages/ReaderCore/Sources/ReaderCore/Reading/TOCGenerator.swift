import Foundation

public struct TOCLine: Codable, Equatable, Sendable {
  public var page: Int
  public var pageWidth: Double
  public var pageHeight: Double
  public var text: String
  public var body: String?
  public var printed: String?
  public var x: Double
  public var right: Double
  public var y: Double
  public var size: Double
  public var bold: Bool
  public var chars: Int

  public init(page: Int, pageWidth: Double, pageHeight: Double, text: String, body: String? = nil, printed: String? = nil, x: Double, right: Double, y: Double, size: Double, bold: Bool, chars: Int) {
    self.page = page
    self.pageWidth = pageWidth
    self.pageHeight = pageHeight
    self.text = text
    self.body = body
    self.printed = printed
    self.x = x
    self.right = right
    self.y = y
    self.size = size
    self.bold = bold
    self.chars = chars
  }
}

public struct TOCItem: Codable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var depth: Int
  public var page: Int
  public var source: String

  public init(id: String, title: String, depth: Int, page: Int, source: String) {
    self.id = id
    self.title = title
    self.depth = depth
    self.page = page
    self.source = source
  }
}

public struct TOCPage: Codable, Equatable, Sendable {
  public var number: Int
  public var width: Double
  public var height: Double
  public var lines: [TOCLine]

  public init(number: Int, width: Double, height: Double, lines: [TOCLine]) {
    self.number = number
    self.width = width
    self.height = height
    self.lines = lines
  }
}

public struct TOCResult: Codable, Equatable, Sendable {
  public var items: [TOCItem]
  public var source: String?

  public init(items: [TOCItem], source: String?) {
    self.items = items
    self.source = source
  }
}

public enum TOCGenerator {
  public static let minimumEntries = 3

  public static func buildLines(_ items: [TextItem], number: Int = 1, width: Double = 0, height: Double = 0) -> [TOCLine] {
    let positioned = items.map { item in
      var copy = item
      copy.y = height - item.y - item.height
      return TOCPositionedItem(text: copy.text, x: copy.x, y: copy.y, width: copy.width, size: item.fontSize == 0 ? item.height : item.fontSize, bold: item.isBold)
    }
    return buildPositionedLines(positioned, number: number, width: width, height: height)
  }

  public static func buildLines(_ paragraphs: [LayoutParagraph], number: Int = 1, width: Double = 0, height: Double = 0) -> [TOCLine] {
    return buildPositionedLines(paragraphs.map { TOCPositionedItem(text: $0.text, x: $0.x, y: $0.y, width: $0.width, size: $0.fontSize, bold: $0.bold) }, number: number, width: width, height: height)
  }

  public static func generateToc(_ pages: [TOCPage]) -> TOCResult {
    let ordered = pages.sorted { $0.number < $1.number }
    let tocPages = findTocPages(ordered)
    if !tocPages.isEmpty {
      let entries = parseTocPages(tocPages.map(\.lines))
      if entries.count >= minimumEntries, let offset = pageOffset(entries: entries, pages: ordered, tocEnd: tocPages.map(\.number).max() ?? 0) {
        let mapped = entries.compactMap { entry -> TOCParsedEntry? in
          guard let printed = entry.printed else { return nil }
          let page = printed + offset
          guard page >= 1, page <= (ordered.map(\.number).max() ?? page) else { return nil }
          var copy = entry
          copy.page = page
          return copy
        }
        if mapped.count >= minimumEntries {
          return TOCResult(items: withIDs(mapped, source: "toc-page"), source: "toc-page")
        }
      }
    }
    let headings = headingsFromFonts(ordered.map(\.lines))
    guard headings.count >= minimumEntries, headings.count <= max(12, ordered.count * 4) else { return TOCResult(items: [], source: nil) }
    return TOCResult(items: withIDs(headings, source: "heuristic"), source: "heuristic")
  }

  public static func numberingDepth(_ title: String) -> Int? {
    if title.range(of: #"^第\s*[\d一二三四五六七八九十百零〇]+\s*[章部篇]"#, options: .regularExpression) != nil { return 0 }
    if title.range(of: #"^第\s*[\d一二三四五六七八九十百零〇]+\s*节"#, options: .regularExpression) != nil { return 1 }
    if title.range(of: #"^(?:chapter|part|appendix|book)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return 0 }
    guard let match = title.range(of: #"^(\d{1,2}(?:\.\d{1,2}){0,4})\.?(?=\s|[)、:：])"#, options: .regularExpression) else { return nil }
    let value = String(title[match]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return value.split(separator: ".").count - 1
  }

  public static func titleKey(_ title: String) -> String {
    var value = clean(title).lowercased()
    value = value.replacingOccurrences(of: #"^第\s*[\d一二三四五六七八九十百零〇]+\s*[章节部篇]"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"^(?:chapter|part|appendix|section)\s+[\divxlc]+\b"#, with: "", options: [.regularExpression, .caseInsensitive])
    value = value.replacingOccurrences(of: #"^\d{1,2}(?:\.\d{1,2}){0,4}\.?\s"#, with: "", options: .regularExpression)
    return value.unicodeScalars.filter { $0.properties.generalCategory == .uppercaseLetter || $0.properties.generalCategory == .lowercaseLetter || $0.properties.generalCategory == .titlecaseLetter || $0.properties.generalCategory == .modifierLetter || $0.properties.generalCategory == .otherLetter || $0.properties.generalCategory == .decimalNumber || $0.properties.generalCategory == .letterNumber || $0.properties.generalCategory == .otherNumber }.map(String.init).joined()
  }
}

public func buildTOCLines(_ items: [TextItem], number: Int = 1, width: Double = 0, height: Double = 0) -> [TOCLine] {
  TOCGenerator.buildLines(items, number: number, width: width, height: height)
}

public func generateTOC(_ pages: [TOCPage]) -> TOCResult {
  TOCGenerator.generateToc(pages)
}

private struct TOCPositionedItem {
  var text: String
  var x: Double
  var y: Double
  var width: Double
  var size: Double
  var bold: Bool
}

private struct TOCParsedEntry {
  var title: String
  var printed: Int?
  var x: Double
  var page: Int = 0
  var depth: Int?
}

private let tocDotCharacters = ".·•‧…⋯"
private let tocPageNumber = try! NSRegularExpression(pattern: #"^(?:\d{1,4}|[ivxlc]{1,7})$"#, options: .caseInsensitive)
private let tocLeader = try! NSRegularExpression(pattern: #"^(.*?)\S\s*(?:(?:\.\s*){3,}|(?:[\.·•‧…⋯]\s*)+)(\d{1,4}|[ivxlc]{1,7})$"#, options: .caseInsensitive)
private let tocHeading = try! NSRegularExpression(pattern: #"^(?:[ivxlc\d]{1,6}\s+)?(?:table\s+of\s+contents|contents|目\s*录|目\s*次|inhalt(?:sverzeichnis)?|sommaire|table\s+des\s+mati[eè]res|[ií]ndice|contenido|inhaltsübersicht|목차)(?:\s+[ivxlc\d]{1,6})?$"#, options: .caseInsensitive)
private let tocListHeading = try! NSRegularExpression(pattern: #"^(?:list\s+of\s+(?:figures|tables|illustrations)|图表目录|图目录|表目录|圖目錄|表目錄)"#, options: .caseInsensitive)
private let tocCaption = try! NSRegularExpression(pattern: #"^(?:fig(?:ure)?\.?|table|algorithm|listing|图|表|圖)\s*[\dA-Z一二三四五六七八九十]"#, options: .caseInsensitive)

private func buildPositionedLines(_ items: [TOCPositionedItem], number: Int, width: Double, height: Double) -> [TOCLine] {
  let usable = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  return splitColumns(usable, width: width).flatMap { group in
    var rows: [TOCRow] = []
    for item in group.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
      if let index = rows.indices.last,
        abs(item.y - rows[index].y) <= 0.45 * min(item.size, rows[index].size) {
        rows[index].items.append(item)
        if item.text.utf16.count > rows[index].weight { rows[index].weight = item.text.utf16.count; rows[index].size = item.size }
      } else {
        rows.append(TOCRow(y: item.y, size: item.size, weight: item.text.utf16.count, items: [item]))
      }
    }
    return rows.map { row in
      let parts = row.items.sorted { $0.x < $1.x }
      var text = ""
      var end: Double?
      for part in parts {
        if let end, part.x - end > 0.15 * row.size, !text.hasSuffix(" ") { text += " " }
        text += part.text
        end = part.x + part.width
      }
      var body: String?
      var printed: String?
      if parts.count >= 2, let last = parts.last, let before = parts.dropLast().last,
        isPageNumber(last.text), last.x - (before.x + before.width) >= 2.5 * row.size {
        printed = clean(last.text)
        body = clean(parts.dropLast().map(\.text).joined(separator: " "))
      }
      return TOCLine(page: number, pageWidth: width, pageHeight: height, text: clean(text), body: body, printed: printed, x: parts.first?.x ?? 0, right: parts.map { $0.x + $0.width }.max() ?? 0, y: row.y, size: row.size, bold: parts.allSatisfy(\.bold), chars: parts.reduce(0) { $0 + $1.text.utf16.count })
    }
  }
}

private struct TOCRow {
  var y: Double
  var size: Double
  var weight: Int
  var items: [TOCPositionedItem]
}

private func splitColumns(_ items: [TOCPositionedItem], width: Double) -> [[TOCPositionedItem]] {
  guard width > 0, items.count >= 20 else { return [items] }
  let lower = width / 2 - 8
  let upper = width / 2 + 8
  var left: [TOCPositionedItem] = []
  var right: [TOCPositionedItem] = []
  var across: [TOCPositionedItem] = []
  for item in items {
    let end = item.x + item.width
    if item.x >= lower { right.append(item) }
    else if end <= upper { left.append(item) }
    else { across.append(item) }
  }
  let total = max(1, items.reduce(0) { $0 + $1.text.utf16.count })
  let share = { (group: [TOCPositionedItem]) in Double(group.reduce(0) { $0 + $1.text.utf16.count }) / Double(total) }
  guard share(across) <= 0.1, share(left) >= 0.25, share(right) >= 0.25 else { return [items] }
  let top = ([left, right].flatMap { $0 }.map(\.y).min() ?? 0)
  return [across.filter { $0.y < top }, left, right, across.filter { $0.y >= top }]
}

private func parseTocPages(_ pages: [[TOCLine]]) -> [TOCParsedEntry] {
  var entries: [TOCParsedEntry] = []
  var pending: [TOCLine] = []
  for lines in pages {
    for line in lines {
      if matches(tocHeading, line.text) || isPlainPageNumber(line.text) { pending.removeAll(); continue }
      if matches(tocListHeading, line.text) { return entries }
      guard let entry = tocEntry(line) else {
        if letterCount(line.text) >= 3, line.text.utf16.count <= 100, !matches(tocCaption, line.text) {
          if let last = pending.last, line.y - last.y > 2.2 * line.size { pending.removeAll() }
          pending = Array((pending + [line]).suffix(3))
        } else { pending.removeAll() }
        continue
      }
      let chain = pending + [line]
      var first = chain.count - 1
      if chain.count > 1 {
        for index in stride(from: chain.count - 1, through: 1, by: -1) {
          let above = chain[index - 1]
          let below = chain[index]
          if below.y - above.y <= 2.2 * below.size && (below.x > above.x + 2 || above.text.range(of: #"(?:[:,;–—-]|\b(?:and|or|of|the|for|in|on|to|a|an|with|from|at|by|as|via))$"#, options: [.regularExpression, .caseInsensitive]) != nil) { first = index - 1 } else { break }
        }
      }
      var result = entry
      if first < chain.count - 1 { result.title = clean(chain[first..<chain.count - 1].map(\.text).joined(separator: " ") + " " + entry.title); result.x = chain[first].x }
      pending.removeAll()
      entries.append(result)
    }
  }
  let starts = Array(Set(entries.map { Int($0.x.rounded()) })).sorted()
  var clusters: [Int] = []
  for start in starts where clusters.isEmpty || start - clusters.last! > 4 { clusters.append(start) }
  if clusters.count <= 1 {
    return entries.map { entry in
      var copy = entry
      copy.depth = min(3, TOCGenerator.numberingDepth(entry.title) ?? 0)
      return copy
    }
  }
  return entries.map { entry in
    var copy = entry
    var depth = 0
    for (index, start) in clusters.enumerated() where entry.x >= Double(start - 4) { depth = index }
    copy.depth = min(depth, 3)
    return copy
  }
}

private func tocEntry(_ line: TOCLine) -> TOCParsedEntry? {
  var title: String
  var printed: String
  if let body = line.body, let value = line.printed { title = body; printed = value }
  else {
    guard let match = firstMatch(tocLeader, line.text), match.count >= 3 else { return nil }
    title = match[1]; printed = match[2]
  }
  title = clean(title.replacingOccurrences(of: #"(?:[\.·•‧…⋯]\s*){2,}$"#, with: "", options: .regularExpression))
  guard letterCount(title) > 0 else { return nil }
  let roman = printed.range(of: #"^[ivxlc]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
  return TOCParsedEntry(title: title, printed: roman ? nil : Int(printed), x: line.x)
}

private func findTocPages(_ pages: [TOCPage]) -> [TOCPage] {
  var found: [TOCPage] = []
  for page in pages.prefix(40) {
    let entries = page.lines.compactMap(tocEntry)
    let head = Array(page.lines.prefix(6))
    let listing = head.contains { matches(tocListHeading, $0.text) }
    let titled = head.contains { matches(tocHeading, $0.text) }
    let isToc = !listing && (entries.count >= 6 || (titled && entries.count >= 3))
    let continues = !found.isEmpty && !listing && entries.count >= 2
    if isToc || continues { found.append(page) }
    else if !found.isEmpty { break }
  }
  return found
}

private func pageOffset(entries: [TOCParsedEntry], pages: [TOCPage], tocEnd: Int) -> Int? {
  let probes = entries.compactMap { entry -> (printed: Int, key: String)? in guard let printed = entry.printed else { return nil }; let key = TOCGenerator.titleKey(entry.title); return key.count >= 3 ? (printed, key) : nil }.prefix(20)
  guard !probes.isEmpty else { return nil }
  var votes: [Int: Int] = [:]
  for page in pages where page.number > tocEnd && page.number <= tocEnd + 100 {
    let keys = page.lines.map { TOCGenerator.titleKey($0.text) }
    for probe in probes where keys.contains(where: { keysMatch($0, probe.key) }) { votes[page.number - probe.printed, default: 0] += 1 }
    let ranked = votes.values.sorted(by: >)
    if ranked.first ?? 0 >= 3 && (ranked.first ?? 0) >= (ranked.dropFirst().first ?? 0) + 2 { break }
  }
  let ranked = votes.sorted { $0.value > $1.value }
  guard let top = ranked.first, top.value >= min(2, probes.count), top.value > (ranked.dropFirst().first?.value ?? 0) else { return nil }
  return top.key
}

private func headingsFromFonts(_ pages: [[TOCLine]]) -> [TOCParsedEntry] {
  let body = bodySize(pages)
  guard body > 0 else { return [] }
  let repeated = runningText(pages)
  var candidates: [(line: TOCLine, text: String, numbered: Bool, depth: Int?, size: Double)] = []
  for lines in pages {
    var previous: TOCLine?
    for line in lines {
      let gap = previous.map { line.y - $0.y } ?? .infinity
      previous = line
      let numbered = TOCGenerator.numberingDepth(line.text) != nil
      let larger = line.size >= body * 1.12
      let spaced = gap >= (numbered ? 1.6 : 1.8) * line.size
      let styled = line.bold && line.size >= body * 0.95
      guard larger || ((numbered || styled) && spaced && line.size >= body * 0.95) else { continue }
      let words = line.text.split(whereSeparator: { $0.isWhitespace }).count
      guard line.text.utf16.count >= 2, line.text.utf16.count <= 120, words <= 16, letterCount(line.text) >= 2, line.text.range(of: #"^[\d\s.,:;()[\]-]+$"#, options: .regularExpression) == nil, !matches(tocCaption, line.text), !(line.pageHeight > 0 && (line.y < line.pageHeight * 0.08 || line.y > line.pageHeight * 0.93)), !repeated(line), !matches(tocHeading, line.text), !matches(tocListHeading, line.text) else { continue }
      if line.text.hasSuffix(",") || line.text.hasSuffix(";") || line.text.hasSuffix("，") || line.text.hasSuffix("；") || (!numbered && (line.text.hasSuffix(".") || line.text.hasSuffix("。"))) { continue }
      candidates.append((line, line.text, numbered, TOCGenerator.numberingDepth(line.text), (line.size * 2).rounded() / 2))
    }
  }
  var headings: [(title: String, line: TOCLine, size: Double, depth: Int?)] = []
  for candidate in candidates {
    if let last = headings.last, last.line.page == candidate.line.page, last.size == candidate.size, !candidate.numbered, candidate.line.y - last.line.y <= 1.6 * candidate.line.size {
      headings[headings.count - 1].title = clean(last.title + " " + candidate.text)
    } else { headings.append((candidate.text, candidate.line, candidate.size, candidate.depth)) }
  }
  var later: [Double: Int] = [:]
  for heading in headings where heading.line.page > 1 { later[heading.size, default: 0] += 1 }
  let sections = headings.filter { $0.line.page > 1 || $0.depth != nil || (later[$0.size] ?? 0) >= 2 }
  guard !sections.isEmpty else { return [] }
  let counts = Dictionary(grouping: sections, by: \.size).mapValues(\.count)
  let largest = sections.map(\.size).max() ?? 0
  let dropTitle = counts.count > 1 && (counts[largest] ?? 0) <= 2 && sections.filter { $0.size == largest }.allSatisfy { $0.line.page <= 2 }
  let sizes = Array(counts.keys.filter { !(dropTitle && $0 == largest) }.sorted(by: >).prefix(4))
  return sections.filter { sizes.contains($0.size) || ($0.depth != nil && $0.size <= body * 1.12) }.map {
    let depth = min($0.depth ?? max(0, sizes.firstIndex(of: $0.size) ?? 0), 3)
    return TOCParsedEntry(title: $0.title, printed: nil, x: $0.line.x, page: $0.line.page, depth: depth)
  }
}

private func bodySize(_ pages: [[TOCLine]]) -> Double {
  var weights: [Double: Int] = [:]
  for line in pages.flatMap({ $0 }) { weights[(line.size * 2).rounded() / 2, default: 0] += line.chars }
  return weights.max { $0.value < $1.value }?.key ?? 0
}

private func runningText(_ pages: [[TOCLine]]) -> (TOCLine) -> Bool {
  var seen: [String: Int] = [:]
  for line in pages.flatMap({ $0 }) where line.pageHeight > 0 && (line.y < line.pageHeight * 0.15 || line.y > line.pageHeight * 0.88) { seen[runningKey(line), default: 0] += 1 }
  let threshold = max(3, Int(ceil(Double(pages.count) * 0.25)))
  return { line in line.pageHeight > 0 && (line.y < line.pageHeight * 0.15 || line.y > line.pageHeight * 0.88) && (seen[runningKey(line)] ?? 0) >= threshold }
}

private func withIDs(_ entries: [TOCParsedEntry], source: String) -> [TOCItem] {
  var path: [Int] = []
  var previous = -1
  return entries.map { entry in
    let requested = entry.depth ?? TOCGenerator.numberingDepth(entry.title) ?? 0
    let depth = max(0, min(requested, previous + 1))
    if path.count > depth + 1 { path = Array(path.prefix(depth + 1)) }
    if path.count < depth + 1 { path.append(contentsOf: repeatElement(-1, count: depth + 1 - path.count)) }
    path[depth] += 1
    if depth > 0 {
      for index in 0..<depth where path[index] < 0 { path[index] = 0 }
    }
    previous = depth
    return TOCItem(id: path.map(String.init).joined(separator: "."), title: entry.title, depth: depth, page: entry.page, source: source)
  }
}

private func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
  regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

private func firstMatch(_ regex: NSRegularExpression, _ value: String) -> [String]? {
  guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
  return (0..<match.numberOfRanges).compactMap { index in guard let range = Range(match.range(at: index), in: value) else { return nil }; return String(value[range]) }
}

private func isPageNumber(_ value: String) -> Bool { matches(tocPageNumber, clean(value)) }
private func isPlainPageNumber(_ value: String) -> Bool { clean(value).range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil }
private func letterCount(_ value: String) -> Int { value.unicodeScalars.filter { $0.properties.generalCategory == .uppercaseLetter || $0.properties.generalCategory == .lowercaseLetter || $0.properties.generalCategory == .titlecaseLetter || $0.properties.generalCategory == .modifierLetter || $0.properties.generalCategory == .otherLetter || $0.properties.generalCategory == .decimalNumber || $0.properties.generalCategory == .letterNumber || $0.properties.generalCategory == .otherNumber }.count }
private func clean(_ value: String) -> String { value.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
private func runningKey(_ line: TOCLine) -> String { line.text.lowercased().unicodeScalars.filter { $0.properties.generalCategory == .uppercaseLetter || $0.properties.generalCategory == .lowercaseLetter || $0.properties.generalCategory == .titlecaseLetter || $0.properties.generalCategory == .modifierLetter || $0.properties.generalCategory == .otherLetter }.map(String.init).joined() }
private func keysMatch(_ a: String, _ b: String) -> Bool { guard !a.isEmpty, !b.isEmpty else { return false }; let short = a.count <= b.count ? a : b; let long = a.count <= b.count ? b : a; return short == long || (short.count >= 6 && Double(short.count) / Double(long.count) >= 0.7 && long.contains(short)) }
