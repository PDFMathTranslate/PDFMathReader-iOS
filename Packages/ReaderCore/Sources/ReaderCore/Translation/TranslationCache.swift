import Foundation

public enum TranslationCacheKey {
  public static func paragraph(
    text: String,
    language: String,
    sourceLanguage: String?,
    model: String?,
    serviceIdentity: [String: String]?,
    glossary: [GlossaryEntry],
    cacheScope: String = ""
  ) throws -> String {
    var value: [String: Any] = [
      "text": text,
      "language": language,
      "prompt": 1,
    ]
    if let sourceLanguage, !sourceLanguage.isEmpty, sourceLanguage != "English" {
      value["sourceLanguage"] = sourceLanguage
    }
    if let model { value["model"] = model }
    if let serviceIdentity { value["service"] = serviceIdentity }
    if !glossary.isEmpty {
      value["glossary"] = glossary.map { ["source": $0.source, "target": $0.target] }
    }
    if !cacheScope.isEmpty { value["cacheScope"] = cacheScope }
    return try stableSHA256Hex(value)
  }

  public static func compatibleParagraph(
    text: String,
    language: String,
    sourceLanguage: String?,
    glossary: [GlossaryEntry],
    cacheScope: String = ""
  ) throws -> String {
    var value: [String: Any] = [
      "text": text,
      "language": language,
      "compatible": 1,
      "prompt": 1,
    ]
    if let sourceLanguage, !sourceLanguage.isEmpty, sourceLanguage != "English" {
      value["sourceLanguage"] = sourceLanguage
    }
    if !glossary.isEmpty {
      value["glossary"] = glossary.map { ["source": $0.source, "target": $0.target] }
    }
    if !cacheScope.isEmpty { value["cacheScope"] = cacheScope }
    return try stableSHA256Hex(value)
  }

  /// Key used by the desktop `server/translation/translation-provider.mjs`
  /// text cache. Credentials are intentionally excluded.
  public static func provider(
    service: String,
    baseURL: String?,
    model: String,
    body: [String: Any],
    cacheScope: String = ""
  ) throws -> String {
    var value: [String: Any] = ["version": 1]
    if !cacheScope.isEmpty { value["cacheScope"] = cacheScope }
    value["service"] = service
    if let baseURL, !baseURL.isEmpty { value["baseUrl"] = baseURL }
    value["model"] = model
    value["body"] = body
    return try stableSHA256Hex(value)
  }
}

struct CachedTranslation: Codable, Sendable {
  let translation: String
  let key: String
  let model: String
}

struct TranslationCacheStore: Sendable {
  let directory: URL

  func read(_ key: String) -> CachedTranslation? {
    guard isCacheKey(key) else { return nil }
    let path = directory.appendingPathComponent(key).appendingPathExtension("json")
    guard let data = try? Data(contentsOf: path),
          let value = try? JSONDecoder().decode(CachedTranslation.self, from: data),
          !value.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  func write(_ value: CachedTranslation) {
    guard isCacheKey(value.key) else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(value)
      let path = directory.appendingPathComponent(value.key).appendingPathExtension("json")
      try data.write(to: path, options: [.atomic])
    } catch {
      // A full or read-only cache must not discard a valid translation.
    }
  }

  func readPointer(_ key: String) -> (model: String, key: String)? {
    guard isCacheKey(key) else { return nil }
    let path = directory.appendingPathComponent(key).appendingPathExtension("translation.json")
    guard let data = try? Data(contentsOf: path),
          let value = try? JSONDecoder().decode(CachePointer.self, from: data),
          !value.model.isEmpty, isCacheKey(value.key) else { return nil }
    return (value.model, value.key)
  }

  func writePointer(_ pointer: CachePointer, key: String) {
    guard isCacheKey(key), isCacheKey(pointer.key) else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(pointer)
      let path = directory.appendingPathComponent(key).appendingPathExtension("translation.json")
      try data.write(to: path, options: [.atomic])
    } catch {}
  }

  private func isCacheKey(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }
}

struct CachePointer: Codable, Sendable {
  let model: String
  let key: String
}
