import Foundation

public struct GlossaryEntry: Codable, Hashable, Sendable {
  public var source: String
  public var target: String

  public init(source: String, target: String) {
    self.source = source
    self.target = target
  }
}

public struct GlossaryLibrary: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var enabled: Bool
  public var entries: [GlossaryEntry]

  public init(id: String, name: String, enabled: Bool, entries: [GlossaryEntry]) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.entries = entries
  }
}

public enum GlossaryError: Error, LocalizedError, Sendable {
  case missingToken(String)

  public var errorDescription: String? {
    switch self {
    case .missingToken:
      return "Translation did not preserve a required glossary term. Retry translation."
    }
  }
}

public func validGlossaries(_ value: [GlossaryLibrary]) -> Bool {
  value.count <= 50 && value.allSatisfy { library in
    library.name.utf16.count <= 200 &&
      library.entries.count <= 1000 &&
      library.entries.allSatisfy {
        $0.source.utf16.count <= 500 && $0.target.utf16.count <= 500
      }
  }
}

public func cloneGlossaries(_ value: [GlossaryLibrary]) -> [GlossaryLibrary] {
  validGlossaries(value) ? value : []
}

public func glossaryEntries(_ libraries: [GlossaryLibrary]) -> [GlossaryEntry] {
  var entries: [GlossaryEntry] = []
  for library in cloneGlossaries(libraries) where library.enabled {
    for entry in library.entries {
      let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
      let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
      if !source.isEmpty && !target.isEmpty && !entries.contains(where: { $0.source == source }) {
        entries.append(GlossaryEntry(source: source, target: target))
      }
    }
  }
  return entries.sorted { $0.source.utf16.count > $1.source.utf16.count }
}

public struct ProtectedGlossaryText: Sendable {
  public let text: String
  private let replacements: [(token: String, target: String)]

  init(text: String, replacements: [(token: String, target: String)]) {
    self.text = text
    self.replacements = replacements
  }

  public func restore(_ output: String) throws -> String {
    var result = output
    for replacement in replacements {
      guard result.range(of: replacement.token) != nil else {
        throw GlossaryError.missingToken(replacement.token)
      }
      result = result.replacingOccurrences(of: replacement.token, with: replacement.target)
    }
    return result
  }
}

public func protectTerms(_ text: String, _ entries: [GlossaryEntry]) -> ProtectedGlossaryText {
  var prefix = "PMRGLOSSARY"
  while text.contains(prefix) { prefix += "X" }
  guard !entries.isEmpty else { return ProtectedGlossaryText(text: text, replacements: []) }

  // The desktop uses one alternation sorted by longest source phrase. Scanning
  // from left to right with the same ordering gives the same non-overlapping
  // regex matches while keeping literal terms literal.
  var result = ""
  var replacements: [(token: String, target: String)] = []
  var cursor = text.startIndex
  while cursor < text.endIndex {
    var match: (range: Range<String.Index>, target: String)?
    for entry in entries {
      guard let range = text.range(of: entry.source, range: cursor..<text.endIndex) else { continue }
      if match == nil || range.lowerBound < match!.range.lowerBound {
        match = (range, entry.target)
      } else if range.lowerBound == match!.range.lowerBound,
                entry.source.utf16.count > text[match!.range].utf16.count {
        match = (range, entry.target)
      }
    }
    guard let selected = match else {
      result.append(contentsOf: text[cursor..<text.endIndex])
      break
    }
    result.append(contentsOf: text[cursor..<selected.range.lowerBound])
    let token = "\(prefix)\(replacements.count)END"
    result.append(token)
    replacements.append((token: token, target: selected.target))
    cursor = selected.range.upperBound
  }
  return ProtectedGlossaryText(text: result, replacements: replacements)
}

public func validGlossaryEntries(_ value: [GlossaryEntry]) -> Bool {
  value.count <= 5000 && value.allSatisfy {
    !$0.source.isEmpty && $0.source.utf16.count <= 500 &&
      !$0.target.isEmpty && $0.target.utf16.count <= 500
  }
}
