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

struct SettingsView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ReaderPreferences()
  @State private var apiKey = ""
  @State private var didLoadAPIKey = false
  @State private var kernelHealth: RemoteKernelHealth?
  @State private var isCheckingKernel = false
  private let credentialStore = KeychainCredentialStore()

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("appearance.interface")) {
          Picker(L10n.string("appearance.interfaceLanguage"), selection: $draft.uiLanguage) {
            Text(L10n.string("appearance.system")).tag("system")
            Text(L10n.string("appearance.english")).tag("en")
            Text(L10n.string("appearance.simplifiedChinese")).tag("zh-Hans")
          }
          Picker(L10n.string("ios.theme"), selection: $draft.theme) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
              Text(theme.displayName).tag(theme)
            }
          }
        }

        Section {
          Picker(L10n.string("settings.sourceLanguage"), selection: $draft.sourceLanguage) {
            Text(L10n.string("settings.automaticDetection")).tag("")
            ForEach(translationLanguageOptions) { option in
              Text(translationLanguageLabel(option.name, locale: Locale.current.identifier)).tag(option.code)
            }
          }
          Picker(L10n.string("recentStatus.language"), selection: $draft.targetLanguage) {
            ForEach(translationLanguageOptions) { option in
              Text(translationLanguageLabel(option.name, locale: Locale.current.identifier)).tag(option.code)
            }
          }
          Picker(L10n.string("recentStatus.engine"), selection: $draft.engine) {
            ForEach(ReaderEngine.allCases, id: \.self) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
          Picker(L10n.string("settings.translationService"), selection: $draft.translationService) {
            ForEach(availableServices, id: \.self) { service in
              Text(service.displayName).tag(service)
            }
          }
          Toggle(L10n.string("toolbar.showTranslatedText"), isOn: $draft.showTranslations)
          Picker(L10n.string("settings.interactionMode"), selection: $draft.interactionMode) {
            Text(L10n.string("settings.readingMode")).tag(ReaderInteractionMode.reading)
            Text(L10n.string("settings.comparisonMode")).tag(ReaderInteractionMode.comparison)
          }
          Toggle(L10n.string("translation.full"), isOn: $draft.translateFullDocument)
          NavigationLink {
            GlossaryEditorView(libraries: $draft.glossaries)
          } label: {
            Label(L10n.string("ios.terminologyGlossary"), systemImage: "text.book.closed")
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

          Section {
            TextField(L10n.string("ios.serverURL"), text: $draft.remoteKernelURL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .keyboardType(.URL)
            HStack {
              Button {
                checkRemoteKernel()
              } label: {
                if isCheckingKernel {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Text(L10n.string("ios.check"))
                }
              }
              .disabled(isCheckingKernel)
              if let kernelHealth {
                Label(
                  kernelHealth.ok ? L10n.string("engine.ready") : kernelHealth.reason,
                  systemImage: kernelHealth.ok ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(kernelHealth.ok ? .green : .secondary)
                .font(.footnote)
                .lineLimit(1)
              }
            }
          } header: {
            Text(L10n.string("ios.remoteKernel"))
          } footer: {
            Text(L10n.string("ios.remoteKernelDescription"))
          }
        } header: {
          Text(L10n.string("settings.translation"))
        } footer: {
          Text(translationDataDisclosure)
        }

        ReadingAidsSettingsSection(preferences: $draft)
      }
      .navigationTitle(L10n.string("settings.title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("search.done")) { dismiss() }
        }
      }
    }
    .preferredColorScheme(draft.theme.colorScheme)
    .onAppear {
      draft = library.preferences
      if !availableServices.contains(draft.translationService) {
        draft.translationService = .siliconFlowFree
      }
      Task {
        apiKey = (try? await credentialStore.read(account: openAIAPIKeyAccount)) ?? ""
        didLoadAPIKey = true
      }
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

  private func checkRemoteKernel() {
    isCheckingKernel = true
    let url = draft.remoteKernelURL
    Task {
      let health = await RemoteKernelClient().health(url, force: true)
      kernelHealth = health
      isCheckingKernel = false
    }
  }
}
