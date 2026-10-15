import Foundation

public enum ReaderEngine: String, Codable, CaseIterable, Sendable {
  case ultraFast
  case fast
  case precise
}

public enum ReaderTheme: String, Codable, CaseIterable, Sendable {
  case system
  case light
  case dark
}

public struct ReaderPreferences: Codable, Hashable, Sendable {
  public var uiLanguage: String
  public var targetLanguage: String
  public var engine: ReaderEngine
  public var theme: ReaderTheme

  public init(
    uiLanguage: String = "system",
    targetLanguage: String = "en",
    engine: ReaderEngine = .ultraFast,
    theme: ReaderTheme = .system
  ) {
    self.uiLanguage = uiLanguage
    self.targetLanguage = targetLanguage
    self.engine = engine
    self.theme = theme
  }
}

public final class PreferencesStore: @unchecked Sendable {
  public let directory: URL

  private let file: JSONFile<ReaderPreferences>
  private let lock = NSLock()

  public init(directory: URL = LibraryDirectory.default, fileManager: FileManager = .default) {
    self.directory = directory
    self.file = JSONFile(
      url: directory.appendingPathComponent("preferences.json"),
      fileManager: fileManager
    )
  }

  public func load() -> ReaderPreferences {
    lock.withLock { file.read() ?? ReaderPreferences() }
  }

  public func save(_ preferences: ReaderPreferences) throws {
    try lock.withLock { try file.write(preferences) }
  }
}
