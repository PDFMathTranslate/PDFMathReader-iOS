import Foundation

public enum ReaderEngine: String, Codable, CaseIterable, Sendable {
  case ultraFast
  case fast
  case precise
}

public enum ReaderTranslationService: String, Codable, CaseIterable, Sendable {
  case siliconFlowFree
  case openAICompatible
  case appleOnDevice
}

public enum ReaderTheme: String, Codable, CaseIterable, Sendable {
  case system
  case light
  case dark
}

public struct ReaderPreferences: Codable, Hashable, Sendable {
  public var uiLanguage: String
  public var sourceLanguage: String
  public var targetLanguage: String
  public var engine: ReaderEngine
  public var translationService: ReaderTranslationService
  public var openAIBaseURL: String
  public var openAIModel: String
  public var remoteKernelURL: String
  public var showTranslations: Bool
  public var translateFullDocument: Bool
  public var theme: ReaderTheme

  public init(
    uiLanguage: String = "system",
    sourceLanguage: String = "en",
    targetLanguage: String = "en",
    engine: ReaderEngine = .ultraFast,
    translationService: ReaderTranslationService = .siliconFlowFree,
    openAIBaseURL: String = "https://api.openai.com/v1",
    openAIModel: String = "gpt-4.1-mini",
    remoteKernelURL: String = "",
    showTranslations: Bool = true,
    translateFullDocument: Bool = false,
    theme: ReaderTheme = .system
  ) {
    self.uiLanguage = uiLanguage
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.engine = engine
    self.translationService = translationService
    self.openAIBaseURL = openAIBaseURL
    self.openAIModel = openAIModel
    self.remoteKernelURL = remoteKernelURL
    self.showTranslations = showTranslations
    self.translateFullDocument = translateFullDocument
    self.theme = theme
  }

  private enum CodingKeys: String, CodingKey {
    case uiLanguage
    case sourceLanguage
    case targetLanguage
    case engine
    case translationService
    case openAIBaseURL
    case openAIModel
    case remoteKernelURL
    case showTranslations
    case translateFullDocument
    case theme
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      uiLanguage: try container.decodeIfPresent(String.self, forKey: .uiLanguage) ?? "system",
      sourceLanguage: try container.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? "en",
      targetLanguage: try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "en",
      engine: try container.decodeIfPresent(ReaderEngine.self, forKey: .engine) ?? .ultraFast,
      translationService: try container.decodeIfPresent(ReaderTranslationService.self, forKey: .translationService) ?? .siliconFlowFree,
      openAIBaseURL: try container.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? "https://api.openai.com/v1",
      openAIModel: try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4.1-mini",
      remoteKernelURL: try container.decodeIfPresent(String.self, forKey: .remoteKernelURL) ?? "",
      showTranslations: try container.decodeIfPresent(Bool.self, forKey: .showTranslations) ?? true,
      translateFullDocument: try container.decodeIfPresent(Bool.self, forKey: .translateFullDocument) ?? false,
      theme: try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .system
    )
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
