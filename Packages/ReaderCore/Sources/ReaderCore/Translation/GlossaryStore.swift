import Foundation

public enum GlossaryStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidGlossary
  case unableToEncode

  public var errorDescription: String? {
    switch self {
    case .invalidGlossary:
      return ReaderLocalization.resolve("The glossary contains too many entries or an entry is too long.")
    case .unableToEncode:
      return ReaderLocalization.resolve("The glossary could not be encoded.")
    }
  }
}

/// Persists the desktop-compatible array of glossary libraries as JSON.
public final class GlossaryStore: @unchecked Sendable {
  public let fileURL: URL

  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    directory: URL = LibraryDirectory.default,
    fileName: String = "glossaries.json",
    fileManager: FileManager = .default
  ) {
    self.fileURL = directory.appendingPathComponent(fileName)
    self.fileManager = fileManager
  }

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func load() -> [GlossaryLibrary] {
    lock.withLock {
      guard let data = try? Data(contentsOf: fileURL),
        let value = try? Self.decoder.decode([GlossaryLibrary].self, from: data)
      else { return [] }
      return cloneGlossaries(value)
    }
  }

  public func save(_ libraries: [GlossaryLibrary]) throws {
    guard validGlossaries(libraries) else {
      throw GlossaryStoreError.invalidGlossary
    }
    let data: Data
    do {
      data = try Self.encoder.encode(libraries)
    } catch {
      throw GlossaryStoreError.unableToEncode
    }

    try lock.withLock {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: [.atomic])
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder { JSONDecoder() }
}
