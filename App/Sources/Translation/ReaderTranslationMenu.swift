import ReaderCore
import SwiftUI
import Translation

/// Connectivity is separate from the saved engine choice: losing a connection
/// hides that choice without silently changing the user's preferred kernel.
@MainActor
final class ReaderKernelMenuAvailability: ObservableObject {
  @Published private(set) var engines: [ReaderEngine] = [.ultraFast]
  @Published private(set) var appleLanguages: Set<String> = []
  private let companion = CompanionKernelClient()
  private let remote = RemoteKernelClient()

  func loadAppleLanguages() async {
    let languages = await Self.supportedAppleLanguages()
    guard !Task.isCancelled else { return }
    appleLanguages = languages
  }

  private nonisolated static func supportedAppleLanguages() async -> Set<String> {
    let availability: LanguageAvailability
    if #available(iOS 26.4, *) {
      availability = LanguageAvailability(preferredStrategy: .lowLatency)
    } else {
      availability = LanguageAvailability()
    }
    let languages = await availability.supportedLanguages
    return Set(languages.map(\.minimalIdentifier))
  }

  func reset() { engines = [.ultraFast] }

  func refresh(_ preferences: ReaderPreferences) async {
    async let computer = computerHealth(preferences.companionURL)
    async let server = remoteHealth(preferences)
    let (computerHealth, serverHealth) = await (computer, server)
    guard !Task.isCancelled else { return }
    engines = ReaderKernelAvailability.availableEngines(
      companion: computerHealth,
      remote: serverHealth,
      remoteEnabled: preferences.remoteKernelEnabled
    )
  }

  private func computerHealth(_ address: String) async -> CompanionHealth? {
    let url = normalizeCompanionURL(address)
    guard !url.isEmpty,
      let code = try? await KeychainCredentialStore().read(account: companionPairingCodeAccount),
      !code.isEmpty else { return nil }
    return await companion.health(url, pairingCode: code, force: true)
  }

  private func remoteHealth(_ preferences: ReaderPreferences) async -> RemoteKernelHealth? {
    guard preferences.remoteKernelEnabled,
      !normalizeRemoteKernelUrl(preferences.remoteKernelURL).isEmpty else { return nil }
    return await remote.health(preferences.remoteKernelURL, force: true)
  }
}

/// Lives in the reader, rather than inside the lazily presented native menu,
/// so its first opening already has connection results.
struct ReaderKernelAvailabilityMonitor: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var availability: ReaderKernelMenuAvailability
  @Environment(\.scenePhase) private var scenePhase
  @State private var pairingRevision = 0

  private var connectionID: [String] {
    let preferences = library.preferences
    return [preferences.companionURL, preferences.remoteKernelURL,
            String(preferences.remoteKernelEnabled), String(pairingRevision), String(describing: scenePhase)]
  }

  var body: some View {
    Color.clear
      .task { await availability.loadAppleLanguages() }
      .task(id: connectionID) {
        availability.reset()
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
          await availability.refresh(library.preferences)
          do { try await Task.sleep(for: .seconds(15)) }
          catch { return }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .companionPairingCodeDidChange)) { _ in
        pairingRevision &+= 1
      }
  }
}

struct ReaderTranslationMenu: View {
  @ObservedObject var library: LibraryModel
  @ObservedObject var availability: ReaderKernelMenuAvailability
  let onChange: (ReaderPreferences) -> Void

  var body: some View {
    Section {
      Picker(L10n.string("settings.sourceLanguage"), selection: preference(\.sourceLanguage)) {
        Text(L10n.string("settings.automaticDetection")).tag("")
        languageChoices(direction: "source", current: library.preferences.sourceLanguage)
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("reader.sourceLanguage")

      Picker(L10n.string("menu.extra.messages.Target Language"), selection: preference(\.targetLanguage)) {
        languageChoices(direction: "target", current: library.preferences.targetLanguage)
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("reader.targetLanguage")

      // Buttons permit an unavailable saved selection to have no checkmark;
      // a Picker would require keeping that unavailable option in its list.
      Menu {
        ForEach(availability.engines, id: \.self) { engine in
          Button {
            var value = library.preferences
            value.engine = engine
            let languages = translationLanguagesForKernel(kernelID(engine))
            if let current = translationLanguageOptions.first(where: { $0.code == value.targetLanguage }),
               !languages.contains(current.name),
               let fallback = translationLanguageOptions.first(where: { languages.contains($0.name) }) {
              value.targetLanguage = fallback.code
            }
            onChange(value)
          } label: {
            if engine == library.preferences.engine {
              Label(engine.displayName, systemImage: "checkmark")
            } else {
              Text(engine.displayName)
            }
          }
          .accessibilityIdentifier("reader.kernel.\(engine.rawValue)")
        }
      } label: {
        Label(L10n.string("recentStatus.engine"), systemImage: "cpu")
      }
      .accessibilityIdentifier("reader.kernel")
    }
  }

  @ViewBuilder
  private func languageChoices(direction: String, current: String) -> some View {
    let supported = translationLanguagesForKernel(kernelID(library.preferences.engine), direction: direction)
    let appleOnly = library.preferences.engine == .ultraFast && library.preferences.translationService == .appleOnDevice
    let options = translationLanguageOptions.filter { option in
      guard supported.contains(option.name) else { return false }
      guard appleOnly else { return true }
      let language = AppleTranslationLanguages(source: option.code, target: option.code).target
      return availability.appleLanguages.contains(language.minimalIdentifier)
    }
    // Custom codes remain usable by the general translation services.
    if !current.isEmpty, !appleOnly,
       !translationLanguageOptions.contains(where: { $0.code == current }) {
      Text(languageLabel(current)).tag(current)
    }
    ForEach(options) { option in
      Text(translationLanguageLabel(option.name, locale: Locale.current.identifier)).tag(option.code)
    }
  }

  private func languageLabel(_ code: String) -> String {
    guard let option = translationLanguageOptions.first(where: { $0.code == code }) else { return code }
    return translationLanguageLabel(option.name, locale: Locale.current.identifier)
  }

  private func preference(_ keyPath: WritableKeyPath<ReaderPreferences, String>) -> Binding<String> {
    Binding(
      get: { library.preferences[keyPath: keyPath] },
      set: { selection in
        var value = library.preferences
        value[keyPath: keyPath] = selection
        onChange(value)
      }
    )
  }

  private func kernelID(_ engine: ReaderEngine) -> String {
    switch engine {
    case .ultraFast: "pdf_inspector"
    case .fast: CompanionKernel.fast
    case .precise: CompanionKernel.precise
    }
  }
}
