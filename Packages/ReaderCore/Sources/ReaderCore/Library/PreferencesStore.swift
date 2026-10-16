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

/// Desktop parity: reading mode keeps translations in place and lets a long
/// press select text for annotation; comparison mode toggles a paragraph
/// between translation and original on tap.
public enum ReaderInteractionMode: String, Codable, CaseIterable, Sendable {
  case reading
  case comparison
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
  public var interactionMode: ReaderInteractionMode
  public var theme: ReaderTheme
  public var glossaries: [GlossaryLibrary]
  public var bionicReading: BionicReadingMode
  public var bionicFixedLength: Int
  public var bionicOriginalOnly: Bool
  public var emphasizeInformation: Bool
  public var emphasizeResearchFindings: Bool
  public var emphasizeOrdinals: Bool
  public var emphasizeKeyVerbs: Bool
  public var emphasizeLogicalConnectives: Bool
  public var tfidfWeightingEnabled: Bool
  public var emphasizeTopicSentences: Bool
  public var readingLinksEnabled: Bool
  public var tocGenerationEnabled: Bool

  public init(
    uiLanguage: String = "system",
    sourceLanguage: String = "",
    targetLanguage: String = "zh",
    engine: ReaderEngine = .ultraFast,
    translationService: ReaderTranslationService = .siliconFlowFree,
    openAIBaseURL: String = "https://api.openai.com/v1",
    openAIModel: String = "gpt-4.1-mini",
    remoteKernelURL: String = "",
    showTranslations: Bool = true,
    translateFullDocument: Bool = false,
    interactionMode: ReaderInteractionMode = .reading,
    theme: ReaderTheme = .system,
    glossaries: [GlossaryLibrary] = [],
    bionicReading: BionicReadingMode = .off,
    bionicFixedLength: Int = BionicReading.fixedLengthDefault,
    bionicOriginalOnly: Bool = true,
    emphasizeInformation: Bool = false,
    emphasizeResearchFindings: Bool = true,
    emphasizeOrdinals: Bool = true,
    emphasizeKeyVerbs: Bool = true,
    emphasizeLogicalConnectives: Bool = true,
    tfidfWeightingEnabled: Bool = false,
    emphasizeTopicSentences: Bool = false,
    readingLinksEnabled: Bool = true,
    tocGenerationEnabled: Bool = false
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
    self.interactionMode = interactionMode
    self.theme = theme
    self.glossaries = cloneGlossaries(glossaries)
    let normalizedBionic = BionicReading.normalize(
      mode: bionicReading,
      fixedLength: Double(bionicFixedLength)
    )
    self.bionicReading = normalizedBionic.mode
    self.bionicFixedLength = normalizedBionic.fixedLength
    self.bionicOriginalOnly = bionicOriginalOnly
    self.emphasizeInformation = emphasizeInformation
    self.emphasizeResearchFindings = emphasizeResearchFindings
    self.emphasizeOrdinals = emphasizeOrdinals
    self.emphasizeKeyVerbs = emphasizeKeyVerbs
    self.emphasizeLogicalConnectives = emphasizeLogicalConnectives
    self.tfidfWeightingEnabled = tfidfWeightingEnabled
    self.emphasizeTopicSentences = emphasizeTopicSentences
    self.readingLinksEnabled = readingLinksEnabled
    self.tocGenerationEnabled = tocGenerationEnabled
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
    case interactionMode
    case theme
    case glossaries
    case bionicReading
    case bionicFixedLength
    case bionicOriginalOnly
    case emphasizeInformation
    case emphasizeResearchFindings
    case emphasizeOrdinals
    case emphasizeKeyVerbs
    case emphasizeLogicalConnectives
    case tfidfWeightingEnabled
    case emphasizeTopicSentences
    case readingLinksEnabled
    case tocGenerationEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      uiLanguage: try container.decodeIfPresent(String.self, forKey: .uiLanguage) ?? "system",
      sourceLanguage: try container.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? "",
      targetLanguage: try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh",
      engine: try container.decodeIfPresent(ReaderEngine.self, forKey: .engine) ?? .ultraFast,
      translationService: try container.decodeIfPresent(ReaderTranslationService.self, forKey: .translationService) ?? .siliconFlowFree,
      openAIBaseURL: try container.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? "https://api.openai.com/v1",
      openAIModel: try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4.1-mini",
      remoteKernelURL: try container.decodeIfPresent(String.self, forKey: .remoteKernelURL) ?? "",
      showTranslations: try container.decodeIfPresent(Bool.self, forKey: .showTranslations) ?? true,
      translateFullDocument: try container.decodeIfPresent(Bool.self, forKey: .translateFullDocument) ?? false,
      interactionMode: (try? container.decodeIfPresent(ReaderInteractionMode.self, forKey: .interactionMode)) ?? .reading,
      theme: try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .system,
      glossaries: try container.decodeIfPresent([GlossaryLibrary].self, forKey: .glossaries) ?? [],
      bionicReading: try container.decodeIfPresent(BionicReadingMode.self, forKey: .bionicReading) ?? .off,
      bionicFixedLength: try container.decodeIfPresent(Int.self, forKey: .bionicFixedLength) ?? BionicReading.fixedLengthDefault,
      bionicOriginalOnly: try container.decodeIfPresent(Bool.self, forKey: .bionicOriginalOnly) ?? true,
      emphasizeInformation: try container.decodeIfPresent(Bool.self, forKey: .emphasizeInformation) ?? false,
      emphasizeResearchFindings: try container.decodeIfPresent(Bool.self, forKey: .emphasizeResearchFindings) ?? true,
      emphasizeOrdinals: try container.decodeIfPresent(Bool.self, forKey: .emphasizeOrdinals) ?? true,
      emphasizeKeyVerbs: try container.decodeIfPresent(Bool.self, forKey: .emphasizeKeyVerbs) ?? true,
      emphasizeLogicalConnectives: try container.decodeIfPresent(Bool.self, forKey: .emphasizeLogicalConnectives) ?? true,
      tfidfWeightingEnabled: try container.decodeIfPresent(Bool.self, forKey: .tfidfWeightingEnabled) ?? false,
      emphasizeTopicSentences: try container.decodeIfPresent(Bool.self, forKey: .emphasizeTopicSentences) ?? false,
      readingLinksEnabled: try container.decodeIfPresent(Bool.self, forKey: .readingLinksEnabled) ?? true,
      tocGenerationEnabled: try container.decodeIfPresent(Bool.self, forKey: .tocGenerationEnabled) ?? false
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
