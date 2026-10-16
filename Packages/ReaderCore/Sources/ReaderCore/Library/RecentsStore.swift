import Foundation

public struct RecentDocument: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public var lastOpened: Date
  public var pageCount: Int?
  public var thumbnailCachePath: String?
  public var bookmarkData: Data
  public var pinned: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case lastOpened
    case pageCount
    case thumbnailCachePath
    case bookmarkData
    case pinned
  }

  public init(
    id: String,
    title: String,
    pinned: Bool = false,
    lastOpened: Date = .now,
    pageCount: Int? = nil,
    thumbnailCachePath: String? = nil,
    bookmarkData: Data
  ) {
    self.id = id
    self.title = title
    self.lastOpened = lastOpened
    self.pageCount = pageCount
    self.thumbnailCachePath = thumbnailCachePath
    self.bookmarkData = bookmarkData
    self.pinned = pinned
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
      sorted(file.read() ?? [])
    }
  }

  @discardableResult
  public func upsert(_ document: RecentDocument) throws -> [RecentDocument] {
    try lock.withLock {
      var documents = file.read() ?? []
      documents.removeAll { $0.id == document.id }
      documents.append(document)
      try file.write(documents)
      return sorted(documents)
    }
  }

  @discardableResult
  public func remove(id: String) throws -> [RecentDocument] {
    try lock.withLock {
      var documents = file.read() ?? []
      let removed = documents.first { $0.id == id }
      documents.removeAll { $0.id == id }
      try file.write(documents)
      if let path = removed?.thumbnailCachePath,
         !documents.contains(where: { document in
           guard let remainingPath = document.thumbnailCachePath else { return false }
           return canonicalPath(for: remainingPath) == canonicalPath(for: path)
         }) {
        removeThumbnailIfOwned(at: URL(fileURLWithPath: path))
      }
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

  public func clearHistory() throws {
    try lock.withLock {
      let documents = file.read() ?? []
      for path in documents.compactMap(\.thumbnailCachePath) {
        removeThumbnailIfOwned(at: URL(fileURLWithPath: path))
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

  private func canonicalPath(for path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
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
