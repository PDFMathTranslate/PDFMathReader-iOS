import CryptoKit
import Foundation

/// The on-disk annotation store mirrors the desktop `userData/annotations` layout.
/// The injected directory is useful for tests and keeps the production location
/// under Application Support/PDFMathReader.
public final class ReaderAnnotationStore: @unchecked Sendable {
  public let directory: URL

  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    directory: URL = LibraryDirectory.default.appendingPathComponent("annotations", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public func metadataURL(for key: String) throws -> URL {
    let normalized = try ReaderAnnotationValidator.validateDocumentKey(key)
    return directory.appendingPathComponent(Self.digest(normalized)).appendingPathExtension("json")
  }

  public func cacheURL(for key: String) throws -> URL {
    let normalized = try ReaderAnnotationValidator.validateDocumentKey(key)
    return directory.appendingPathComponent(Self.digest(normalized)).appendingPathExtension("pdf")
  }

  /// Loads a metadata snapshot. Missing or malformed annotation metadata is
  /// treated as empty, matching the desktop store's recovery behavior.
  public func load(_ key: String) throws -> ReaderAnnotationState {
    let metadata = try metadataURL(for: key)
    return lock.withLock {
      guard let data = try? Data(contentsOf: metadata) else {
        return ReaderAnnotationState(annotations: [])
      }
      let decoder = JSONDecoder()
      if let record = try? decoder.decode(ReaderAnnotationStoreRecord.self, from: data),
        record.key == key,
        let annotations = try? ReaderAnnotationValidator.validate(record.annotations)
      {
        // Desktop loading validates the annotation array; native references
        // are carried by loadState but do not invalidate an otherwise usable
        // sidecar when an older build left them malformed.
        let nativeRefs = (try? ReaderAnnotationValidator.validateNativeReferences(record.nativeRefs)) ?? []
        return ReaderAnnotationState(annotations: annotations, nativeRefs: nativeRefs)
      }
      // Older desktop builds stored the annotation array directly.
      if let annotations = try? decoder.decode([ReaderAnnotation].self, from: data),
        let normalized = try? ReaderAnnotationValidator.validate(annotations)
      {
        return ReaderAnnotationState(annotations: normalized)
      }
      return ReaderAnnotationState(annotations: [])
    }
  }

  public func hasMetadata(for key: String) throws -> Bool {
    fileManager.fileExists(atPath: try metadataURL(for: key).path)
  }

  /// Imports embedded annotations when no sidecar exists. Callers can opt into
  /// writing the imported snapshot and rewritten PDF immediately.
  public func loadOrImport(
    _ key: String,
    sourceData: Data,
    persistImported: Bool = false
  ) throws -> ReaderAnnotationState {
    if try hasMetadata(for: key) { return try load(key) }
    let imported = try ReaderAnnotationPDF.importAnnotations(from: sourceData)
    let state = ReaderAnnotationState(
      annotations: imported.annotations,
      nativeRefs: imported.nativeRefs
    )
    if persistImported {
      _ = try save(state, for: key, sourceData: sourceData)
    }
    return state
  }

  /// Saves the JSON sidecar and, when source bytes are available, the embedded
  /// PDF cache and source file. The returned value is the rewritten PDF bytes.
  @discardableResult
  public func save(
    _ state: ReaderAnnotationState,
    for key: String,
    sourceURL: URL? = nil,
    sourceData: Data? = nil
  ) throws -> Data? {
    let normalizedKey = try ReaderAnnotationValidator.validateDocumentKey(key)
    let annotations = try ReaderAnnotationValidator.validate(state.annotations)
    let nativeRefs = try ReaderAnnotationValidator.validateNativeReferences(state.nativeRefs)
    let metadata = try metadataURL(for: normalizedKey)
    let cache = try cacheURL(for: normalizedKey)

    return try lock.withLock {
      var input = sourceData
      if input == nil, let sourceURL {
        input = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe])
      }
      if input == nil {
        input = try? Data(contentsOf: cache, options: [.mappedIfSafe])
      }

      var rewritten: Data?
      if let input {
        rewritten = try ReaderAnnotationPDF.embedAnnotations(
          annotations,
          in: input,
          nativeRefs: nativeRefs
        )
        try writeAtomically(rewritten!, to: cache)
        if let sourceURL {
          try writeAtomically(rewritten!, to: sourceURL)
        }
      }

      let record = ReaderAnnotationStoreRecord(
        key: normalizedKey,
        annotations: annotations,
        nativeRefs: nativeRefs,
        updatedAt: ISO8601DateFormatter().string(from: Date())
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try writeAtomically(try encoder.encode(record), to: metadata)
      return rewritten
    }
  }

  @discardableResult
  public func save(
    _ annotations: [ReaderAnnotation],
    nativeRefs: [String] = [],
    for key: String,
    sourceURL: URL? = nil,
    sourceData: Data? = nil
  ) throws -> Data? {
    try save(
      ReaderAnnotationState(annotations: annotations, nativeRefs: nativeRefs),
      for: key,
      sourceURL: sourceURL,
      sourceData: sourceData
    )
  }

  private func writeAtomically(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: [.atomic])
  }

  private static func digest(_ key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ReaderQuickLinkBox: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct ReaderQuickLinkEndpoint: Codable, Hashable, Sendable {
  public var page: Int
  public var box: ReaderQuickLinkBox
  public var blockID: ReaderAnnotationBlockID?
  public var translationVersion: ReaderAnnotationTranslationVersion?

  public init(
    page: Int,
    box: ReaderQuickLinkBox,
    blockID: ReaderAnnotationBlockID? = nil,
    translationVersion: ReaderAnnotationTranslationVersion? = nil
  ) {
    self.page = page
    self.box = box
    self.blockID = blockID
    self.translationVersion = translationVersion
  }

  private enum CodingKeys: String, CodingKey {
    case page, box
    case blockID = "blockId"
    case translationVersion
  }
}

public struct ReaderQuickLink: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var origin: ReaderQuickLinkEndpoint
  public var result: ReaderQuickLinkEndpoint

  public init(
    id: String,
    origin: ReaderQuickLinkEndpoint,
    result: ReaderQuickLinkEndpoint
  ) {
    self.id = id
    self.origin = origin
    self.result = result
  }
}

public enum ReaderQuickLinkValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidLinks
  case invalidDocumentKey

  public var errorDescription: String? {
    switch self {
    case .invalidLinks: ReaderLocalization.resolve("Invalid quick links.")
    case .invalidDocumentKey: ReaderLocalization.resolve("Invalid quick-link document key.")
    }
  }
}

public enum ReaderQuickLinkValidator {
  public static let maximumLinks = 10_000

  public static func validate(_ links: [ReaderQuickLink]) throws -> [ReaderQuickLink] {
    guard links.count <= maximumLinks else {
      throw ReaderQuickLinkValidationError.invalidLinks
    }
    for link in links {
      guard link.origin.page >= 1,
        link.result.page >= 1,
        valid(link.origin.box),
        valid(link.result.box)
      else {
        throw ReaderQuickLinkValidationError.invalidLinks
      }
    }
    return links
  }

  private static func valid(_ box: ReaderQuickLinkBox) -> Bool {
    [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite)
  }
}

public final class ReaderQuickLinkStore: @unchecked Sendable {
  public let directory: URL

  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    directory: URL = LibraryDirectory.default.appendingPathComponent("quick-links", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public func url(for key: String) throws -> URL {
    guard !key.isEmpty, key.utf16.count <= ReaderAnnotationLimits.maximumKeyLength else {
      throw ReaderQuickLinkValidationError.invalidDocumentKey
    }
    let normalized = key
    return directory.appendingPathComponent(Self.digest(normalized)).appendingPathExtension("json")
  }

  public func load(_ key: String) throws -> [ReaderQuickLink] {
    let file = try url(for: key)
    return try lock.withLock {
      guard let data = try? Data(contentsOf: file) else { return [] }
      let links = try JSONDecoder().decode([ReaderQuickLink].self, from: data)
      return try ReaderQuickLinkValidator.validate(links)
    }
  }

  public func save(_ links: [ReaderQuickLink], for key: String) throws {
    let normalized = try ReaderQuickLinkValidator.validate(links)
    let file = try url(for: key)
    try lock.withLock {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(normalized).write(to: file, options: [.atomic])
    }
  }

  private static func digest(_ key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
