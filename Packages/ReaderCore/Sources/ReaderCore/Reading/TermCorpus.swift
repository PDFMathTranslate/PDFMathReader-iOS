import Foundation

public enum TermCorpusError: Error, Equatable, Sendable {
  case invalidDocumentID
  case invalidTerms
}

public struct TermCorpusFrequencies: Codable, Equatable, Sendable {
  public var documents: Int
  public var frequencies: [Int]

  public init(documents: Int, frequencies: [Int]) {
    self.documents = documents
    self.frequencies = frequencies
  }
}

/// In-memory document-frequency corpus used by the TF-IDF reader aid.
public final class TermCorpus: @unchecked Sendable {
  public static let maxLookupTerms = 20_000
  public static let maxTermLength = 256

  private struct Entry {
    var seen: Int64
    var terms: Set<String>
  }

  private var documents: [String: Entry] = [:]
  private var frequency: [String: Int] = [:]
  private let maxDocuments: Int
  private let maxTerms: Int
  private let random: () -> Double
  private let now: () -> Int64

  public init(
    maxDocuments: Int = 300,
    maxTerms: Int = 3_000,
    random: @escaping () -> Double = { Double.random(in: 0..<1) },
    now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
  ) {
    self.maxDocuments = max(0, maxDocuments)
    self.maxTerms = max(0, maxTerms)
    self.random = random
    self.now = now
  }

  public func touch(_ id: String) throws -> Bool {
    guard Self.isDocumentID(id) else { throw TermCorpusError.invalidDocumentID }
    guard var entry = documents[id] else { return false }
    entry.seen = now()
    documents[id] = entry
    return true
  }

  public func add(_ id: String, terms: [String]) throws -> (documents: Int, terms: Int) {
    guard Self.isDocumentID(id) else { throw TermCorpusError.invalidDocumentID }
    try Self.validateTerms(terms)
    var distinct: [String] = []
    var seen = Set<String>()
    for term in terms where seen.insert(term).inserted { distinct.append(term) }
    // Preserve the desktop corpus's uniform random subset when the sample is large.
    if distinct.count > maxTerms {
      for index in 0..<min(maxTerms, distinct.count) {
        let remaining = distinct.count - index
        let offset = min(remaining - 1, max(0, Int(random() * Double(remaining))))
        distinct.swapAt(index, index + offset)
      }
    }
    forget(id)
    let entry = Entry(seen: now(), terms: Set(distinct.prefix(maxTerms)))
    documents[id] = entry
    count(entry.terms, delta: 1)
    if documents.count > maxDocuments {
      let ids = documents.filter { $0.key != id }.sorted { $0.value.seen < $1.value.seen }.prefix(documents.count - maxDocuments).map(\.key)
      ids.forEach(forget)
    }
    return (documents.count, entry.terms.count)
  }

  public func frequencies(excluding id: String? = nil, terms: [String]) throws -> TermCorpusFrequencies {
    if let id, !Self.isDocumentID(id) { throw TermCorpusError.invalidDocumentID }
    try Self.validateTerms(terms)
    let own = id.flatMap { documents[$0]?.terms }
    return TermCorpusFrequencies(
      documents: documents.count - (own == nil ? 0 : 1),
      frequencies: terms.map { frequency[$0, default: 0] - (own?.contains($0) == true ? 1 : 0) }
    )
  }

  public func documentCount() -> Int { documents.count }

  public static func isDocumentID(_ id: String) -> Bool {
    guard id.count >= 32, id.count <= 64 else { return false }
    return id.unicodeScalars.allSatisfy { scalar in
      (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }
  }

  private static func validateTerms(_ terms: [String]) throws {
    guard terms.count <= maxLookupTerms else { throw TermCorpusError.invalidTerms }
    guard terms.allSatisfy({ !$0.isEmpty && $0.utf16.count <= maxTermLength }) else { throw TermCorpusError.invalidTerms }
  }

  private func count(_ terms: Set<String>, delta: Int) {
    for term in terms {
      let value = (frequency[term] ?? 0) + delta
      if value > 0 { frequency[term] = value } else { frequency.removeValue(forKey: term) }
    }
  }

  private func forget(_ id: String) {
    guard let entry = documents.removeValue(forKey: id) else { return }
    count(entry.terms, delta: -1)
  }
}
