import Foundation
import ReaderCore

#if canImport(Translation)
import Translation
#endif

/// Keychain account used by the OpenAI-compatible translation service.
let openAIAPIKeyAccount = "openai-api-key"

final class UnavailableTranslationProvider: TranslationProvider, @unchecked Sendable {
  let id = "unavailable"
  let model = "unavailable"
  let cacheIdentity: [String: String]? = nil
  let message: String

  init(message: String) {
    self.message = message
  }

  func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    throw TranslationProviderError.network(message)
  }
}

/// Adapter for Apple's on-device Translation framework. The framework is
/// optional so the app can still be built and run on older supported systems.
final class AppleTranslationProvider: TranslationProvider, @unchecked Sendable {
  let id = "apple-on-device"
  let model = "apple-translation"
  let cacheIdentity: [String: String]?
  private let sourceLanguage: String?
  private let targetLanguage: String

  init(sourceLanguage: String?, targetLanguage: String) {
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.cacheIdentity = [
      "service": "apple-on-device",
      "source": sourceLanguage ?? "auto",
      "target": targetLanguage,
    ]
  }

  func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    guard let text = request.messages.last?.content,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TranslationProviderError.invalidResponse
    }

    #if canImport(Translation)
    guard #available(iOS 26.0, *) else {
      throw TranslationProviderError.network(L10n.string("ios.appleTranslationRequires"))
    }
    let languages = AppleTranslationLanguages(source: sourceLanguage, target: targetLanguage)
    do {
      if languages.source == languages.target {
        return try providerResponse(text)
      }
      let session: TranslationSession
      if #available(iOS 26.4, *) {
        session = TranslationSession(
          installedSource: languages.source, target: languages.target, preferredStrategy: .lowLatency
        )
      } else {
        session = TranslationSession(installedSource: languages.source, target: languages.target)
      }
      // Like the desktop helper: report missing language models plainly
      // instead of the framework's generic "Unable to Translate".
      guard await session.isReady else {
        throw TranslationProviderError.network(
          L10n.string("ios.appleTranslationModelsMissing", languages.sourceName, languages.targetName)
        )
      }
      let response = try await session.translate(text)
      return try providerResponse(response.targetText)
    } catch is CancellationError {
      throw TranslationProviderError.cancelled
    } catch let error as TranslationProviderError {
      throw error
    } catch {
      let nsError = error as NSError
      let detail = [nsError.localizedDescription, nsError.localizedFailureReason]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      throw TranslationProviderError.network(L10n.string("ios.appleTranslationFailed", detail))
    }
    #else
    throw TranslationProviderError.network(L10n.string("ios.appleTranslationUnavailable"))
    #endif
  }

  private func providerResponse(_ text: String) throws -> TranslationProviderResponse {
    let body: [String: Any] = ["choices": [["message": ["content": text]]]]
    return TranslationProviderResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: body))
  }
}

/// Source and target languages for Apple Translation, resolved the same way
/// by the provider and by the Settings download row.
struct AppleTranslationLanguages: Hashable {
  let source: Locale.Language
  let target: Locale.Language

  init(source: String?, target: String) {
    let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.source = Self.language(trimmed.isEmpty ? "en" : trimmed)
    self.target = Self.language(target)
  }

  private static func language(_ value: String) -> Locale.Language {
    let code = translationLanguageCode(value) ?? value
    // Apple distinguishes the Chinese models by script, not region.
    switch code {
    case "zh", "zh-CN": return Locale.Language(identifier: "zh-Hans")
    case "zh-TW", "zh-HK": return Locale.Language(identifier: "zh-Hant")
    default: return Locale.Language(identifier: code)
    }
  }

  var sourceName: String { Self.name(source) }
  var targetName: String { Self.name(target) }

  private static func name(_ language: Locale.Language) -> String {
    let code = language.minimalIdentifier
    return Locale.current.localizedString(forIdentifier: code) ?? code
  }
}
