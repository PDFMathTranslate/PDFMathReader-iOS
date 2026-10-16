import Foundation

/// Owns the on disk translation and remote math page caches.
///
/// The cache contents are disposable.  Document generations live beside the
/// cache roots so clearing a cache cannot make a subsequent request reuse an
/// artifact written before the clear.
public struct TranslationCacheManagement: Sendable {
  public static let defaultLimitBytes: Int64 = 1_024 * 1_024 * 1_024

  public let paragraphDirectory: URL
  public let mathDirectory: URL

  private let generationDirectory: URL
  private var fileManager: FileManager { .default }

  public init(
    paragraphDirectory: URL = LibraryDirectory.default
      .appendingPathComponent("translation-cache", isDirectory: true),
    mathDirectory: URL = TranslationCacheManagement.defaultMathDirectory
  ) {
    self.paragraphDirectory = paragraphDirectory
    self.mathDirectory = mathDirectory
    // Keep injected test caches self-contained while keeping generation files
    // outside both disposable cache roots in the app container.
    self.generationDirectory = paragraphDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("translation-cache-generations", isDirectory: true)
  }

  public static var defaultMathDirectory: URL {
    (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("PDFMathReader/remote-math-pages", isDirectory: true)
  }

  /// Returns the current cache scope for a document.
  ///
  /// A document has its plain identifier until a document or global clear
  /// creates a generation marker.  The returned value is a single path-safe
  /// component because callers use it in both paragraph and math cache keys.
  public func scope(documentID: String) -> String {
    let safeID = safeDocumentID(documentID)
    guard let marker = activeMarker(for: documentID) else { return safeID }
    return "\(safeID)-\(marker)"
  }

  /// Clears either one document's scoped cache or both cache roots.
  ///
  /// The generation marker is written before any cache files are removed.  A
  /// failed deletion therefore still prevents a future request from using the
  /// old scope.  Marker files are intentionally retained across clears.
  public func clear(documentID: String? = nil) throws {
    if let documentID {
      let oldScope = scope(documentID: documentID)
      try writeMarker(at: markerURL(for: documentID))

      let documentsDirectory = paragraphDirectory.appendingPathComponent("documents", isDirectory: true)
      try removeIfExists(documentsDirectory.appendingPathComponent(oldScope, isDirectory: true))

      // Remove the pre-generation path as well.  It covers caches written by
      // older builds before document scopes were persisted.
      let safeID = safeDocumentID(documentID)
      if safeID != oldScope {
        try removeIfExists(documentsDirectory.appendingPathComponent(safeID, isDirectory: true))
      }

      let mathDocumentsDirectory = mathDirectory
        .appendingPathComponent("documents", isDirectory: true)
      // Current callers hash the full cache scope.  Also remove the legacy
      // document-ID hash so a clear cleans caches created before generations.
      for scopeToRemove in Set([oldScope, documentID]) {
        try removeIfExists(
          mathDocumentsDirectory.appendingPathComponent(
            sha256Hex(Data(scopeToRemove.utf8)),
            isDirectory: true
          )
        )
      }
      return
    }

    try writeMarker(at: globalMarkerURL)
    try removeIfExists(paragraphDirectory)
    try removeIfExists(mathDirectory)
  }

  /// Returns the total size of regular files in both disposable cache roots.
  public func usageBytes() -> Int64 {
    cacheFiles().reduce(into: Int64(0)) { total, file in
      total += file.size
    }
  }

  /// Evicts the oldest regular cache files until the optional cap is met.
  /// Passing `nil` leaves the cache unlimited.  The default cap is one GiB.
  @discardableResult
  public func trim(toBytes limit: Int64? = TranslationCacheManagement.defaultLimitBytes) throws -> Int64 {
    guard let limit else { return usageBytes() }
    let cap = max(0, limit)
    var files = cacheFiles().sorted {
      if $0.modified == $1.modified { return $0.url.path < $1.url.path }
      return $0.modified < $1.modified
    }
    var total = files.reduce(into: Int64(0)) { $0 += $1.size }

    while total > cap, let file = files.first {
      files.removeFirst()
      guard fileManager.fileExists(atPath: file.url.path) else { continue }
      try fileManager.removeItem(at: file.url)
      total = max(0, total - file.size)
    }

    pruneEmptyDirectories()
    return total
  }

  private struct CacheFile: Sendable {
    let url: URL
    let size: Int64
    let modified: Date
  }

  private var globalMarkerURL: URL {
    generationDirectory.appendingPathComponent("global")
  }

  private func markerURL(for documentID: String) -> URL {
    generationDirectory.appendingPathComponent(sha256Hex(Data(documentID.utf8)))
  }

  private func activeMarker(for documentID: String) -> String? {
    let documentMarker = readMarker(at: markerURL(for: documentID))
    let globalMarker = readMarker(at: globalMarkerURL)
    switch (globalMarker, documentMarker) {
    case let (global?, document?):
      return "\(global)-\(document)"
    case let (global?, nil):
      return global
    case let (nil, document?):
      return document
    case (nil, nil):
      return nil
    }
  }

  private func readMarker(at url: URL) -> String? {
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return normalizedMarker(value)
  }

  private func writeMarker(at url: URL) throws {
    try fileManager.createDirectory(
      at: generationDirectory,
      withIntermediateDirectories: true
    )
    let marker = Data(UUID().uuidString.lowercased().utf8)
    try marker.write(to: url, options: [.atomic])
  }

  private func normalizedMarker(_ value: String) -> String? {
    let marker = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !marker.isEmpty,
          marker != ".",
          marker != "..",
          !marker.contains("/"),
          !marker.contains("\\"),
          !marker.contains(":") else {
      return nil
    }
    return marker
  }

  private func safeDocumentID(_ value: String) -> String {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty,
          candidate != ".",
          candidate != "..",
          !candidate.contains("/"),
          !candidate.contains("\\"),
          !candidate.contains(":") else {
      return sha256Hex(Data(value.utf8))
    }
    return candidate
  }

  private func removeIfExists(_ url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func cacheFiles() -> [CacheFile] {
    var seen = Set<URL>()
    var files: [CacheFile] = []

    for root in [paragraphDirectory, mathDirectory] {
      guard fileManager.fileExists(atPath: root.path) else { continue }
      if let attributes = regularFileAttributes(at: root) {
        if seen.insert(root.standardizedFileURL).inserted {
          files.append(CacheFile(url: root, size: attributes.size, modified: attributes.modified))
        }
        continue
      }
      guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      ) else { continue }
      for case let url as URL in enumerator {
        guard let attributes = regularFileAttributes(at: url) else { continue }
        let standardizedURL = url.standardizedFileURL
        guard seen.insert(standardizedURL).inserted else { continue }
        files.append(CacheFile(url: url, size: attributes.size, modified: attributes.modified))
      }
    }
    return files
  }

  private func regularFileAttributes(at url: URL) -> (size: Int64, modified: Date)? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType,
          type == .typeRegular else {
      return nil
    }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    return (size, modified)
  }

  private func pruneEmptyDirectories() {
    for root in [paragraphDirectory, mathDirectory] {
      guard fileManager.fileExists(atPath: root.path),
            let enumerator = fileManager.enumerator(
              at: root,
              includingPropertiesForKeys: [.isDirectoryKey],
              options: [.skipsHiddenFiles]
            ) else { continue }
      let directories = enumerator.compactMap { $0 as? URL }.filter { url in
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
          return false
        }
        return values.isDirectory == true
      }.sorted { $0.path.count > $1.path.count }
      for directory in directories {
        guard let entries = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: nil,
          options: []
        ), entries.isEmpty else { continue }
        try? fileManager.removeItem(at: directory)
      }
    }
  }
}

public extension Notification.Name {
  static let translationCacheDidClear = Notification.Name(
    "PDFMathReader.translationCacheDidClear"
  )
}

public enum TranslationCacheNotification {
  public static let documentIDKey = "documentID"
}
