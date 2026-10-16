import ReaderCore
import SwiftUI

extension ReaderEngine {
  var displayName: String {
    switch self {
    case .ultraFast: L10n.string("ios.engineUltraFast")
    case .fast: L10n.string("ios.engineFast")
    case .precise: L10n.string("ios.enginePrecise")
    }
  }
}

extension ReaderTranslationService {
  var displayName: String {
    switch self {
    case .siliconFlowFree: L10n.string("settings.translationServiceSiliconFlowFree")
    case .openAICompatible: L10n.string("settings.translationServiceOpenAI")
    case .appleOnDevice: L10n.string("settings.translationServiceAppleLocal")
    }
  }
}

extension ReaderTheme {
  var displayName: String {
    switch self {
    case .system: L10n.string("appearance.system")
    case .light: L10n.string("appearance.light")
    case .dark: L10n.string("appearance.dark")
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

extension TranslationMode {
  var displayName: String {
    switch self {
    case .full: L10n.string("translation.full")
    case .reading: L10n.string("translation.reading")
    case .readingAhead: L10n.string("translation.readingAhead")
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ReaderPreferences()
  @State private var apiKey = ""
  @State private var didLoadAPIKey = false
  private let credentialStore = KeychainCredentialStore()

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("appearance.section")) {
          Picker(L10n.string("appearance.interfaceLanguage"), selection: $draft.uiLanguage) {
            Text(L10n.string("appearance.system")).tag("system")
            ForEach(L10n.supportedLanguages, id: \.code) { language in
              Text(verbatim: language.name).tag(language.code)
            }
          }
          .accessibilityIdentifier("settings.uiLanguage")
          Picker(L10n.string("ios.theme"), selection: $draft.theme) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
              Text(theme.displayName).tag(theme)
            }
          }
          AccentColorSettingsRow(selection: $draft.accentColor)
          AppIconSettingsRow()
        }

        Section {
          Picker(L10n.string("settings.sourceLanguage"), selection: $draft.sourceLanguage) {
            Text(L10n.string("settings.automaticDetection")).tag("")
            ForEach(translationLanguageOptions) { option in
              Text(translationLanguageLabel(option.name, locale: L10n.locale.identifier)).tag(option.code)
            }
          }
          Picker(L10n.string("settings.translationLanguage"), selection: $draft.targetLanguage) {
            ForEach(translationLanguageOptions) { option in
              Text(translationLanguageLabel(option.name, locale: L10n.locale.identifier)).tag(option.code)
            }
          }
          Picker(L10n.string("recentStatus.engine"), selection: $draft.engine) {
            ForEach(ReaderEngine.allCases, id: \.self) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
          Picker(L10n.string("settings.translationMode"), selection: $draft.translationMode) {
            ForEach(TranslationMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          Toggle(L10n.string("settings.reuseTranslations"), isOn: $draft.reuseTranslations)
            .accessibilityIdentifier("settings.reuseTranslations")
          Toggle(L10n.string("advanced.options.ignore_cache.label"), isOn: $draft.ignoreCache)
            .accessibilityIdentifier("settings.ignoreCache")
          NavigationLink {
            GlossaryEditorView(libraries: $draft.glossaries)
          } label: {
            Label(L10n.string("ios.terminologyGlossary"), systemImage: "text.book.closed")
          }
        } header: {
          Text(L10n.string("settings.translation"))
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("settings.reuseTranslationsDescription"))
            Text(L10n.string("advanced.options.ignore_cache.help"))
          }
        }

        Section {
          Picker(L10n.string("settings.translationService"), selection: $draft.translationService) {
            ForEach(availableServices, id: \.self) { service in
              Text(service.displayName).tag(service)
            }
          }
          if draft.translationService == .appleOnDevice {
            AppleTranslationLanguagesRow(
              sourceLanguage: draft.sourceLanguage,
              targetLanguage: draft.targetLanguage
            )
          }
        } header: {
          Text(L10n.string("settings.translationService"))
        } footer: {
          Text(translationDataDisclosure)
        }

        if draft.translationService == .openAICompatible {
          Section {
            TextField(L10n.string("ios.baseURL"), text: $draft.openAIBaseURL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            TextField(L10n.string("ios.model"), text: $draft.openAIModel)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField(L10n.string("settings.apiKey"), text: $apiKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } header: {
            Text(L10n.string("ios.openAIService"))
          } footer: {
            Text(L10n.string("ios.apiKeyStorage"))
          }
        }

        Section(L10n.string("settings.reading")) {
          Toggle(L10n.string("toolbar.showTranslatedText"), isOn: $draft.showTranslations)
          Picker(L10n.string("settings.interactionMode"), selection: $draft.interactionMode) {
            Text(L10n.string("settings.readingMode")).tag(ReaderInteractionMode.reading)
            Text(L10n.string("settings.comparisonMode")).tag(ReaderInteractionMode.comparison)
          }
        }

        TranslationCacheSettingsSection()

        TranslationFontSettingsSection(preferences: $draft)

        ReadingAidsSettingsSection(preferences: $draft)

        ComputerKernelSettingsSection(preferences: $draft)

        RemoteKernelSettingsSection(preferences: $draft)
      }
      .navigationTitle(L10n.string("settings.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("search.done")) { dismiss() }
            .accessibilityIdentifier("settings.done")
        }
      }
    }
    // UIKit's navigation bar captures direction when it is created. Rebuild
    // the stack when direction changes while keeping the draft in this view.
    .id(L10n.isRightToLeft)
    .environment(\.locale, L10n.locale)
    .environment(\.layoutDirection, L10n.isRightToLeft ? .rightToLeft : .leftToRight)
    .preferredColorScheme(draft.theme.colorScheme)
    .readerAccentColor(draft.accentColor)
    .onAppear {
      draft = library.preferences
      if draft.uiLanguage != "system" {
        draft.uiLanguage = L10n.resolveLanguage(choice: draft.uiLanguage, preferredLanguages: [])
      }
      if !availableServices.contains(draft.translationService) {
        draft.translationService = .siliconFlowFree
      }
      Task {
        apiKey = (try? await credentialStore.read(account: openAIAPIKeyAccount)) ?? ""
        didLoadAPIKey = true
      }
    }
    .onChange(of: draft.uiLanguage) { _, language in
      // Apply immediately while preserving the rest of the in-progress form.
      var preferences = library.preferences
      preferences.uiLanguage = language
      library.savePreferences(preferences)
    }
    .onDisappear {
      let savedPreferences = draft
      guard didLoadAPIKey else {
        library.savePreferences(savedPreferences)
        return
      }
      let savedAPIKey = apiKey
      Task { @MainActor in
        do {
          if savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await credentialStore.delete(account: openAIAPIKeyAccount)
          } else {
            try await credentialStore.save(savedAPIKey, account: openAIAPIKeyAccount)
          }
        } catch {
          // A Keychain failure should not prevent the rest of Settings from saving.
        }
        library.savePreferences(savedPreferences)
      }
    }
  }

  private var availableServices: [ReaderTranslationService] {
    var services: [ReaderTranslationService] = [.siliconFlowFree, .openAICompatible]
    if #available(iOS 26.0, *) {
      services.append(.appleOnDevice)
    }
    return services
  }

  private var translationDataDisclosure: String {
    var lines: [String] = []
    switch draft.translationService {
    case .siliconFlowFree: lines.append(L10n.string("ios.disclosureFreeProxy"))
    case .openAICompatible: lines.append(L10n.string("ios.disclosureOpenAI"))
    case .appleOnDevice: lines.append(L10n.string("ios.disclosureAppleOnDevice"))
    }
    if draft.engine != .ultraFast {
      lines.append(L10n.string("ios.disclosureRemoteKernel"))
    }
    return lines.joined(separator: " ")
  }
}
