import Foundation

public struct RecentDocument: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public var lastOpened: Date
  public var pageCount: Int?
  public var thumbnailCachePath: String?
  public var bookmarkData: Data
  public var pinned: Bool
  public var contentHash: String?
  public var sourceIdentity: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case lastOpened
    case pageCount
    case thumbnailCachePath
    case bookmarkData
    case pinned
    case contentHash
    case sourceIdentity
  }

  public init(
    id: String,
    title: String,
    pinned: Bool = false,
    lastOpened: Date = .now,
    pageCount: Int? = nil,
    thumbnailCachePath: String? = nil,
    bookmarkData: Data,
    contentHash: String? = nil,
    sourceIdentity: String? = nil
  ) {
    self.id = id
    self.title = title
    self.lastOpened = lastOpened
    self.pageCount = pageCount
    self.thumbnailCachePath = thumbnailCachePath
    self.bookmarkData = bookmarkData
    self.pinned = pinned
    self.contentHash = contentHash
    self.sourceIdentity = sourceIdentity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    lastOpened = try container.decode(Date.self, forKey: .lastOpened)
    pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
    thumbnailCachePath = try container.decodeIfPresent(String.self, forKey: .thumbnailCachePath)
    bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
    pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    sourceIdentity = try container.decodeIfPresent(String.self, forKey: .sourceIdentity)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(lastOpened, forKey: .lastOpened)
    try container.encodeIfPresent(pageCount, forKey: .pageCount)
    try container.encodeIfPresent(thumbnailCachePath, forKey: .thumbnailCachePath)
    try container.encode(bookmarkData, forKey: .bookmarkData)
    try container.encode(pinned, forKey: .pinned)
    try container.encodeIfPresent(contentHash, forKey: .contentHash)
    try container.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
  }
}

public final class RecentsStore: @unchecked Sendable {
  public let directory: URL

  private let file: JSONFile<[RecentDocument]>
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(directory: URL = LibraryDirectory.default, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
    self.file = JSONFile(
      url: directory.appendingPathComponent("recents.json"),
      fileManager: fileManager
    )
  }

  public func list() -> [RecentDocument] {
    lock.withLock {
      let documents = file.read() ?? []
      let deduplicated = deduplicate(documents)
      if deduplicated != documents {
        try? file.write(deduplicated)
      }
      return sorted(deduplicated.map(resolveThumbnailPath(for:)))
    }
  }

  @discardableResult
  public func upsert(_ document: RecentDocument) throws -> [RecentDocument] {
    try lock.withLock {
      let documents = (file.read() ?? []).map(resolveThumbnailPath(for:))
      let incoming = resolveThumbnailPath(for: document)
      let allDocuments = documents + [incoming]
      let incomingIndex = allDocuments.count - 1
      let matchingIndices = connectedComponent(
        containing: incomingIndex,
        in: allDocuments
      )
      let merged = merge(
        allDocuments,
        indices: matchingIndices,
        preferredIndex: incomingIndex
      )
      var updated = allDocuments.enumerated()
        .filter { !matchingIndices.contains($0.offset) }
        .map(\.element)
      updated.append(merged)
      try file.write(updated)
      return sorted(updated.map(resolveThumbnailPath(for:)))
    }
  }

  @discardableResult
  public func remove(id: String) throws -> [RecentDocument] {
    try lock.withLock {
      var documents = file.read() ?? []
      let removed = documents.first { $0.id == id }
      documents.removeAll { $0.id == id }
      try file.write(documents)
      removeThumbnails(for: removed, remaining: documents)
      return sorted(documents)
    }
  }

  @discardableResult
  public func setPinned(_ pinned: Bool, for id: String) throws -> [RecentDocument] {
    try lock.withLock {
      var documents = file.read() ?? []
      guard let index = documents.firstIndex(where: { $0.id == id }) else {
        return sorted(documents)
      }
      documents[index].pinned = pinned
      try file.write(documents)
      return sorted(documents)
    }
  }

  public func updateMetadata(
    for id: String,
    pageCount: Int? = nil,
    thumbnailCachePath: String? = nil
  ) throws {
    try lock.withLock {
      var documents = file.read() ?? []
      guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
      if let pageCount { documents[index].pageCount = pageCount }
      if let thumbnailCachePath { documents[index].thumbnailCachePath = thumbnailCachePath }
      try file.write(documents)
    }
  }

  public func document(id: String) -> RecentDocument? {
    list().first { $0.id == id }
  }

  public func document(
    matching url: URL,
    contentHash: String? = nil,
    sourceIdentity: String? = nil
  ) -> RecentDocument? {
    lock.withLock {
      let documents = file.read() ?? []
      let deduplicated = deduplicate(documents)
      if deduplicated != documents {
        try? file.write(deduplicated)
      }

      let canonicalURL = canonicalURL(for: url)
      let candidates = deduplicated.enumerated().filter { _, document in
        let urlMatches = resolvedBookmarkURL(for: document) == canonicalURL
        let hashMatches = sourceIdentity == nil && document.sourceIdentity == nil
          && contentHash != nil && document.contentHash == contentHash
        let sourceMatches = sourceIdentity != nil && document.sourceIdentity == sourceIdentity
        return urlMatches || hashMatches || sourceMatches
      }
      guard let latest = candidates.min(by: isLater(_:_:)) else { return nil }
      return resolveThumbnailPath(for: latest.element)
    }
  }

  public func clearHistory() throws {
    try lock.withLock {
      let documents = file.read() ?? []
      for document in documents {
        for path in thumbnailPaths(for: document) {
          removeThumbnailIfOwned(at: URL(fileURLWithPath: path))
        }
      }
      try file.write([])
    }
  }

  public func thumbnailURL(for id: String) -> URL {
    directory
      .appendingPathComponent("Thumbnails", isDirectory: true)
      .appendingPathComponent(id)
      .appendingPathExtension("png")
  }

  public func bookmarkData(for url: URL) throws -> Data {
    #if os(macOS)
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    #else
    // iOS document-provider URLs are already security-scoped for the importing scene.
    try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
  }

  public func resolveBookmarkData(_ data: Data) throws -> URL {
    var isStale = false
    #if os(macOS)
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    #else
    let url = try URL(
      resolvingBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    #endif
    return url
  }

  private func removeThumbnailIfOwned(at url: URL) {
    let thumbnailRoot = directory
      .appendingPathComponent("Thumbnails", isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let path = canonicalPath(for: url.path)
    guard path.hasPrefix(thumbnailRoot + "/") else { return }
    try? fileManager.removeItem(at: url)
  }

  private func resolveThumbnailPath(for document: RecentDocument) -> RecentDocument {
    guard document.thumbnailCachePath != nil else { return document }
    let currentPath = thumbnailURL(for: document.id).path
    let path: String
    if fileManager.fileExists(atPath: currentPath) {
      path = currentPath
    } else if let legacyPath = document.thumbnailCachePath,
      fileManager.fileExists(atPath: legacyPath) {
      path = legacyPath
    } else {
      path = currentPath
    }

    guard document.thumbnailCachePath != path else { return document }
    var resolved = document
    resolved.thumbnailCachePath = path
    return resolved
  }

  private func thumbnailPaths(for document: RecentDocument) -> [String] {
    [thumbnailURL(for: document.id).path, document.thumbnailCachePath].compactMap { $0 }
  }

  private func removeThumbnails(for removed: RecentDocument?, remaining: [RecentDocument]) {
    guard let removed else { return }
    let remainingPaths = Set(
      remaining
        .flatMap(thumbnailPaths(for:))
        .map(canonicalPath(for:))
    )
    for path in thumbnailPaths(for: removed)
      where !remainingPaths.contains(canonicalPath(for: path)) {
      removeThumbnailIfOwned(at: URL(fileURLWithPath: path))
    }
  }

  private func canonicalPath(for path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
  }

  private func canonicalURL(for url: URL) -> URL {
    url.standardizedFileURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
  }

  private func resolvedBookmarkURL(for document: RecentDocument) -> URL? {
    guard let url = try? resolveBookmarkData(document.bookmarkData) else { return nil }
    return canonicalURL(for: url)
  }

  private func documentsMatch(
    _ lhs: RecentDocument,
    _ rhs: RecentDocument
  ) -> Bool {
    if lhs.id == rhs.id {
      return true
    }
    if let lhsURL = resolvedBookmarkURL(for: lhs),
       let rhsURL = resolvedBookmarkURL(for: rhs),
       lhsURL == rhsURL {
      return true
    }
    if let lhsSource = lhs.sourceIdentity,
       let rhsSource = rhs.sourceIdentity,
       lhsSource == rhsSource {
      return true
    }
    if lhs.sourceIdentity != nil || rhs.sourceIdentity != nil {
      return false
    }
    if let lhsHash = lhs.contentHash,
       let rhsHash = rhs.contentHash,
       lhsHash == rhsHash {
      return true
    }
    return false
  }

  private func connectedComponent(
    containing index: Int,
    in documents: [RecentDocument]
  ) -> Set<Int> {
    var component = Set([index])
    var pending = [index]
    while let current = pending.popLast() {
      for candidate in documents.indices where !component.contains(candidate) {
        guard documentsMatch(documents[current], documents[candidate]) else { continue }
        component.insert(candidate)
        pending.append(candidate)
      }
    }
    return component
  }

  private func isLater(
    _ lhs: (offset: Int, element: RecentDocument),
    _ rhs: (offset: Int, element: RecentDocument)
  ) -> Bool {
    if lhs.element.lastOpened != rhs.element.lastOpened {
      return lhs.element.lastOpened > rhs.element.lastOpened
    }
    return lhs.offset > rhs.offset
  }

  private func merge(
    _ documents: [RecentDocument],
    indices: Set<Int>,
    preferredIndex: Int
  ) -> RecentDocument {
    var merged = documents[preferredIndex]
    let orderedIndices = indices.sorted {
      isLater(
        (offset: $0, element: documents[$0]),
        (offset: $1, element: documents[$1])
      )
    }
    merged.pinned = indices.contains { documents[$0].pinned }
    if merged.pageCount == nil {
      merged.pageCount = orderedIndices.lazy.compactMap { documents[$0].pageCount }.first
    }
    if merged.thumbnailCachePath == nil {
      merged.thumbnailCachePath = orderedIndices.lazy
        .compactMap { documents[$0].thumbnailCachePath }
        .first
    }
    if merged.contentHash == nil {
      merged.contentHash = orderedIndices.lazy.compactMap { documents[$0].contentHash }.first
    }
    if merged.sourceIdentity == nil {
      merged.sourceIdentity = orderedIndices.lazy.compactMap { documents[$0].sourceIdentity }.first
    }
    return merged
  }

  private func deduplicate(_ documents: [RecentDocument]) -> [RecentDocument] {
    guard documents.count > 1 else { return documents }
    var visited = Set<Int>()
    var result: [RecentDocument] = []
    for index in documents.indices where !visited.contains(index) {
      let component = connectedComponent(containing: index, in: documents)
      visited.formUnion(component)
      if component.count == 1 {
        result.append(documents[index])
      } else {
        let latestIndex = component.min {
          isLater(
            (offset: $0, element: documents[$0]),
            (offset: $1, element: documents[$1])
          )
        } ?? index
        result.append(merge(documents, indices: component, preferredIndex: latestIndex))
      }
    }
    return result
  }

  private func sorted(_ documents: [RecentDocument]) -> [RecentDocument] {
    documents.sorted {
      if $0.pinned != $1.pinned {
        return $0.pinned
      }
      return $0.lastOpened > $1.lastOpened
    }
  }
}
