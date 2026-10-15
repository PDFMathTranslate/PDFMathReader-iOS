import Foundation

public struct RecentDocument: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public var lastOpened: Date
  public var pageCount: Int?
  public var thumbnailCachePath: String?
  public var bookmarkData: Data

  public init(
    id: String,
    title: String,
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
      (file.read() ?? []).sorted { $0.lastOpened > $1.lastOpened }
    }
  }

  @discardableResult
  public func upsert(_ document: RecentDocument) throws -> [RecentDocument] {
    try lock.withLock {
      var documents = file.read() ?? []
      documents.removeAll { $0.id == document.id }
      documents.append(document)
      try file.write(documents)
      return documents.sorted { $0.lastOpened > $1.lastOpened }
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
    let root = directory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return }
    try? fileManager.removeItem(at: url)
  }
}
