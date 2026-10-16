import Foundation

public enum ReaderScaleMode: String, Codable, CaseIterable, Sendable {
  case fitPage
  case fitWidth
  case actualSize
  case custom
}

public enum ReaderDisplayMode: String, Codable, CaseIterable, Sendable {
  case singlePage
  case twoPages
  /// PDFKit renders this as a compact two-up view; see the iOS reader UI.
  case fourPages
}

public enum ReaderScrollDirection: String, Codable, CaseIterable, Sendable {
  case vertical
  case horizontal
}

public struct ReadingState: Codable, Hashable, Sendable {
  public var page: Int
  public var zoom: Double
  public var scaleMode: ReaderScaleMode
  public var displayMode: ReaderDisplayMode
  public var scrollDirection: ReaderScrollDirection
  public var sidebarVisible: Bool
  public var pageCrop: PageCrop?
  public var lastUpdated: Date

  public init(
    page: Int = 1,
    zoom: Double = 1,
    scaleMode: ReaderScaleMode = .fitPage,
    displayMode: ReaderDisplayMode = .singlePage,
    scrollDirection: ReaderScrollDirection = .vertical,
    sidebarVisible: Bool = true,
    lastUpdated: Date = .now,
    pageCrop: PageCrop? = nil
  ) {
    self.page = max(1, page)
    self.zoom = max(0.1, zoom)
    self.scaleMode = scaleMode
    self.displayMode = displayMode
    self.scrollDirection = scrollDirection
    self.sidebarVisible = sidebarVisible
    self.pageCrop = pageCrop
    self.lastUpdated = lastUpdated
  }
}

public final class ReadingStateStore: @unchecked Sendable {
  public let directory: URL

  private let file: JSONFile<[String: ReadingState]>
  private let lock = NSLock()

  public init(directory: URL = LibraryDirectory.default, fileManager: FileManager = .default) {
    self.directory = directory
    self.file = JSONFile(
      url: directory.appendingPathComponent("reading-state.json"),
      fileManager: fileManager
    )
  }

  public func state(for documentID: String) -> ReadingState {
    lock.withLock {
      file.read()?[documentID] ?? ReadingState()
    }
  }

  public func save(_ state: ReadingState, for documentID: String) throws {
    try lock.withLock {
      var states = file.read() ?? [:]
      var updated = state
      updated.lastUpdated = .now
      states[documentID] = updated
      try file.write(states)
    }
  }

  public func remove(documentID: String) throws {
    try lock.withLock {
      var states = file.read() ?? [:]
      states.removeValue(forKey: documentID)
      try file.write(states)
    }
  }

  public func clear() throws {
    try lock.withLock { try file.write([:]) }
  }
}
