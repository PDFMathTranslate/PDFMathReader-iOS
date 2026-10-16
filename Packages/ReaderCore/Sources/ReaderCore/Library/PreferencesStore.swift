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

public enum ReaderDocumentOpenMode: String, Codable, CaseIterable, Sendable {
  case original
  case originalWithBackgroundTranslation
  case translated
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
  public var remoteKernelEnabled: Bool
  public var remoteKernelService: String
  /// PDFMathReader on the user's computer, which serves its Fast and Precise kernels.
  public var companionURL: String
  /// Service configured on the paired computer; credentials stay on that computer.
  public var companionService: String
  public var showTranslations: Bool
  public var documentOpenMode: ReaderDocumentOpenMode
  public var restoreDocumentsOnLaunch: Bool
  public var autoHideTitleBar: Bool
  public var defaultPageCropEnabled: Bool
  public var defaultPageCropX: Double
  public var defaultPageCropY: Double
  public var reuseTranslations: Bool
  public var ignoreCache: Bool
  public var translationMode: TranslationMode
  /// Compatibility alias for callers that only distinguish full-document mode.
  /// Setting false selects reading-ahead mode, preserving the legacy behavior.
  public var translateFullDocument: Bool {
    get { translationMode == .full }
    set { translationMode = newValue ? .full : .readingAhead }
  }
  public var interactionMode: ReaderInteractionMode
  public var translationSerif: Bool
  public var translationFont: String
  public var theme: ReaderTheme
  /// "system" leaves the platform tint unchanged; custom colors use #RRGGBB.
  public var accentColor: String
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
  public var paragraphGapOptimization: Bool
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
    remoteKernelEnabled: Bool = false,
    remoteKernelService: String = "",
    companionURL: String = "",
    companionService: String = "auto",
    showTranslations: Bool = true,
    documentOpenMode: ReaderDocumentOpenMode = .original,
    restoreDocumentsOnLaunch: Bool = true,
    autoHideTitleBar: Bool = true,
    defaultPageCropEnabled: Bool = false,
    defaultPageCropX: Double = 0,
    defaultPageCropY: Double = 0,
    reuseTranslations: Bool = false,
    ignoreCache: Bool = false,
    translateFullDocument: Bool = false,
    interactionMode: ReaderInteractionMode = .reading,
    translationSerif: Bool = false,
    translationFont: String = "",
    theme: ReaderTheme = .system,
    accentColor: String = "system",
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
    paragraphGapOptimization: Bool = true,
    readingLinksEnabled: Bool = true,
    tocGenerationEnabled: Bool = false,
    translationMode: TranslationMode = .readingAhead
  ) {
    self.uiLanguage = uiLanguage
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.engine = engine
    self.translationService = translationService
    self.openAIBaseURL = openAIBaseURL
    self.openAIModel = openAIModel
    self.remoteKernelURL = remoteKernelURL
    self.remoteKernelEnabled = remoteKernelEnabled
    self.remoteKernelService = String(remoteKernelService.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    self.companionURL = companionURL
    self.companionService = companionService
    self.showTranslations = showTranslations
    self.documentOpenMode = documentOpenMode
    self.restoreDocumentsOnLaunch = restoreDocumentsOnLaunch
    self.autoHideTitleBar = autoHideTitleBar
    self.defaultPageCropEnabled = defaultPageCropEnabled
    self.defaultPageCropX = Self.normalizedDefaultPageCrop(defaultPageCropX)
    self.defaultPageCropY = Self.normalizedDefaultPageCrop(defaultPageCropY)
    self.reuseTranslations = reuseTranslations
    self.ignoreCache = ignoreCache
    self.translationMode = translateFullDocument ? .full : translationMode
    self.interactionMode = interactionMode
    self.translationSerif = translationSerif
    self.translationFont = String(translationFont.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    self.theme = theme
    self.accentColor = Self.normalizedAccentColor(accentColor)
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
    self.paragraphGapOptimization = paragraphGapOptimization
    self.readingLinksEnabled = readingLinksEnabled
    self.tocGenerationEnabled = tocGenerationEnabled
  }

  public static func normalizedAccentColor(_ value: String) -> String {
    guard value.count == 7, value.first == "#",
          value.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
    else { return "system" }
    return value.lowercased()
  }

  private static func normalizedDefaultPageCrop(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(0.5, max(0, value))
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
    case remoteKernelEnabled
    case remoteKernelService
    case companionURL
    case companionService
    case showTranslations
    case documentOpenMode
    case restoreDocumentsOnLaunch
    case autoHideTitleBar
    case defaultPageCropEnabled
    case defaultPageCropX
    case defaultPageCropY
    case reuseTranslations
    case ignoreCache
    case translationMode
    case interactionMode
    case translationSerif
    case translationFont
    case theme
    case accentColor
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
    case paragraphGapOptimization
    case readingLinksEnabled
    case tocGenerationEnabled
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case translateFullDocument
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
    let remoteKernelURL = try container.decodeIfPresent(String.self, forKey: .remoteKernelURL) ?? ""
    let translationMode: TranslationMode
    if container.contains(.translationMode) {
      // A future mode should not make the whole preferences file unreadable.
      translationMode = (try? container.decode(TranslationMode.self, forKey: .translationMode)) ?? .readingAhead
    } else {
      // Older files stored only this boolean; false historically meant the
      // bounded reading-ahead scheduler.
      let translateFullDocument = try legacyContainer.decodeIfPresent(Bool.self, forKey: .translateFullDocument) ?? false
      translationMode = translateFullDocument ? .full : .readingAhead
    }
    self.init(
      uiLanguage: try container.decodeIfPresent(String.self, forKey: .uiLanguage) ?? "system",
      sourceLanguage: try container.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? "",
      targetLanguage: try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh",
      engine: try container.decodeIfPresent(ReaderEngine.self, forKey: .engine) ?? .ultraFast,
      translationService: try container.decodeIfPresent(ReaderTranslationService.self, forKey: .translationService) ?? .siliconFlowFree,
      openAIBaseURL: try container.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? "https://api.openai.com/v1",
      openAIModel: try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4.1-mini",
      remoteKernelURL: remoteKernelURL,
      // Earlier versions used the remote kernel whenever a URL was saved.
      remoteKernelEnabled: try container.decodeIfPresent(Bool.self, forKey: .remoteKernelEnabled)
        ?? !remoteKernelURL.isEmpty,
      remoteKernelService: try container.decodeIfPresent(String.self, forKey: .remoteKernelService) ?? "",
      companionURL: try container.decodeIfPresent(String.self, forKey: .companionURL) ?? "",
      companionService: try container.decodeIfPresent(String.self, forKey: .companionService) ?? "auto",
      showTranslations: try container.decodeIfPresent(Bool.self, forKey: .showTranslations) ?? true,
      documentOpenMode: (try? container.decodeIfPresent(ReaderDocumentOpenMode.self, forKey: .documentOpenMode)) ?? .original,
      restoreDocumentsOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .restoreDocumentsOnLaunch) ?? true,
      autoHideTitleBar: try container.decodeIfPresent(Bool.self, forKey: .autoHideTitleBar) ?? true,
      defaultPageCropEnabled: try container.decodeIfPresent(Bool.self, forKey: .defaultPageCropEnabled) ?? false,
      defaultPageCropX: (try? container.decodeIfPresent(Double.self, forKey: .defaultPageCropX)) ?? 0,
      defaultPageCropY: (try? container.decodeIfPresent(Double.self, forKey: .defaultPageCropY)) ?? 0,
      reuseTranslations: try container.decodeIfPresent(Bool.self, forKey: .reuseTranslations) ?? false,
      ignoreCache: try container.decodeIfPresent(Bool.self, forKey: .ignoreCache) ?? false,
      interactionMode: (try? container.decodeIfPresent(ReaderInteractionMode.self, forKey: .interactionMode)) ?? .reading,
      translationSerif: try container.decodeIfPresent(Bool.self, forKey: .translationSerif) ?? false,
      translationFont: try container.decodeIfPresent(String.self, forKey: .translationFont) ?? "",
      theme: try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .system,
      accentColor: (try? container.decodeIfPresent(String.self, forKey: .accentColor)) ?? "system",
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
      paragraphGapOptimization: try container.decodeIfPresent(Bool.self, forKey: .paragraphGapOptimization) ?? true,
      readingLinksEnabled: try container.decodeIfPresent(Bool.self, forKey: .readingLinksEnabled) ?? true,
      tocGenerationEnabled: try container.decodeIfPresent(Bool.self, forKey: .tocGenerationEnabled) ?? false,
      translationMode: translationMode
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
