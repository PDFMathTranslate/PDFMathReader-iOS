import ReaderCore
import SwiftUI

extension ReaderEngine {
  var displayName: String {
    switch self {
    case .ultraFast: "Ultra fast on device"
    case .fast: "Fast via remote server"
    case .precise: "Precise via remote server"
    }
  }
}

extension ReaderTranslationService {
  var displayName: String {
    switch self {
    case .siliconFlowFree: "Free SiliconFlow proxy"
    case .openAICompatible: "OpenAI-compatible"
    case .appleOnDevice: "Apple on-device"
    }
  }
}

extension ReaderTheme {
  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
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
        Section("Interface") {
          Picker("UI language", selection: $draft.uiLanguage) {
            Text("System").tag("system")
            Text("English").tag("en")
            Text("简体中文").tag("zh-Hans")
          }
          Picker("Theme", selection: $draft.theme) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
              Text(theme.displayName).tag(theme)
            }
          }
        }

        Section("Translation") {
          Picker("Source language", selection: $draft.sourceLanguage) {
            Text("Detect automatically").tag("")
            ForEach(translationLanguageOptions) { option in
              Text(option.name).tag(option.code)
            }
          }
          Picker("Target language", selection: $draft.targetLanguage) {
            ForEach(translationLanguageOptions) { option in
              Text(option.name).tag(option.code)
            }
          }
          Picker("Engine", selection: $draft.engine) {
            ForEach(ReaderEngine.allCases, id: \.self) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
          Picker("Service", selection: $draft.translationService) {
            ForEach(availableServices, id: \.self) { service in
              Text(service.displayName).tag(service)
            }
          }
          Toggle("Show translations", isOn: $draft.showTranslations)
          Toggle("Translate the full document", isOn: $draft.translateFullDocument)
          NavigationLink {
            GlossaryEditorView(libraries: $draft.glossaries)
          } label: {
            Label("Terminology glossary", systemImage: "text.book.closed")
          }

          if draft.translationService == .openAICompatible {
            Section {
              TextField("Base URL", text: $draft.openAIBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              TextField("Model", text: $draft.openAIModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              SecureField("API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
              Text("OpenAI-compatible service")
            } footer: {
              Text("The API key is stored in the iOS Keychain and is never written to preferences.")
            }
          }

          Section {
            TextField("Server URL", text: $draft.remoteKernelURL)
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
                  Text("Check")
                }
              }
              .disabled(isCheckingKernel)
              if let kernelHealth {
                Label(
                  kernelHealth.ok ? "Available" : kernelHealth.reason,
                  systemImage: kernelHealth.ok ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(kernelHealth.ok ? .green : .secondary)
                .font(.footnote)
                .lineLimit(1)
              }
            }
          } header: {
            Text("Remote kernel")
          } footer: {
            Text("Fast and Precise use the remote kernel for visible pages and fall back to Ultra fast when it is unavailable.")
          }
        }

        ReadingAidsSettingsSection(preferences: $draft)
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
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
