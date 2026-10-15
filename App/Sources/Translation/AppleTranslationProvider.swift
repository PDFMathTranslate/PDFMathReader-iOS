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
      throw TranslationProviderError.network("Apple Translation requires iOS 26 or later.")
    }
    let source = Locale.Language(identifier: sourceLanguage ?? "en")
    let target = Locale.Language(identifier: targetLanguage)
    do {
      let session = TranslationSession(installedSource: source, target: target)
      let response = try await session.translate(text)
      let body: [String: Any] = [
        "choices": [[
          "message": ["content": response.targetText],
        ]],
      ]
      return TranslationProviderResponse(
        statusCode: 200,
        data: try JSONSerialization.data(withJSONObject: body)
      )
    } catch is CancellationError {
      throw TranslationProviderError.cancelled
    } catch {
      throw TranslationProviderError.network(error.localizedDescription)
    }
    #else
    throw TranslationProviderError.network("Apple Translation is unavailable in this SDK.")
    #endif
  }
}
