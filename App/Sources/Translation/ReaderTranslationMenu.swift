import ReaderCore
import SwiftUI
import Translation

/// Connectivity is separate from the saved engine choice: losing a connection
/// hides that choice without silently changing the user's preferred kernel.
@MainActor
final class ReaderKernelMenuAvailability: ObservableObject {
  @Published private(set) var engines: [ReaderEngine] = [.ultraFast]
  @Published private(set) var remotePreciseAvailable = false
  @Published private(set) var appleLanguages: Set<String> = []
  private let companion: CompanionKernelClient
  private let remote: RemoteKernelClient
  private let readPairingCode: @Sendable () async -> String?
  @Published private(set) var computerHealth: CompanionHealth?

  init(
    companion: CompanionKernelClient = .init(), remote: RemoteKernelClient = .init(),
    readPairingCode: @escaping @Sendable () async -> String? = {
      try? await KeychainCredentialStore().read(account: companionPairingCodeAccount)
    }
  ) {
    self.companion = companion
    self.remote = remote
    self.readPairingCode = readPairingCode
  }

  func usesComputer(_ preferences: ReaderPreferences) -> Bool {
    preferences.engine != .ultraFast && !(preferences.engine == .precise && remotePreciseAvailable)
  }

  func services(_ preferences: ReaderPreferences) -> [CompanionTranslationService] {
    guard usesComputer(preferences), computerHealth?.ok == true else { return [] }
    if let translation = computerHealth?.translation {
      let engine = preferences.engine == .fast ? CompanionKernel.fast : CompanionKernel.precise
      return translation.services.filter { service in
        service.kernels.map { $0.contains(where: { $0.id == engine }) } ?? true
      }
    }
    // Compatibility with computers predating capability sharing.
    return [
      .init(id: "auto", name: "Automatic"),
      .init(id: "siliconflow-free", name: ReaderTranslationService.siliconFlowFree.displayName),
      .init(id: "apple-local", name: ReaderTranslationService.appleOnDevice.displayName)
    ]
  }

  func languages(_ preferences: ReaderPreferences, direction: String) -> [TranslationLanguageOption] {
    let engine = preferences.engine == .ultraFast ? "pdf_inspector"
      : preferences.engine == .fast ? CompanionKernel.fast : CompanionKernel.precise
    if usesComputer(preferences), computerHealth?.ok == true,
       let translation = computerHealth?.translation {
      return translation.languages(engine: engine, service: preferences.companionService, direction: direction)
    }
    let supported = translationLanguagesForKernel(engine, direction: direction)
    return translationLanguageOptions.filter { supported.contains($0.name) }
  }

  func hasComputerOptions(_ preferences: ReaderPreferences) -> Bool {
    usesComputer(preferences) && computerHealth?.ok == true && computerHealth?.translation != nil
  }

  func normalizeSelection(_ preferences: inout ReaderPreferences) {
    guard hasComputerOptions(preferences) else { return }
    let providers = services(preferences)
    if !providers.contains(where: { $0.id == preferences.companionService }) {
      preferences.companionService = providers.first(where: { $0.id == "auto" })?.id ?? providers.first?.id ?? "auto"
    }
    let targets = languages(preferences, direction: "target")
    if !targets.contains(where: { $0.code == preferences.targetLanguage }), let first = targets.first {
      preferences.targetLanguage = first.code
    }
    if !preferences.sourceLanguage.isEmpty,
       !languages(preferences, direction: "source").contains(where: { $0.code == preferences.sourceLanguage }) {
      preferences.sourceLanguage = ""
    }
  }

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

  func reset() {
    engines = [.ultraFast]
    remotePreciseAvailable = false
    computerHealth = nil
  }

  func refresh(_ preferences: ReaderPreferences) async {
    async let computer = computerHealth(preferences.companionURL)
    async let server = remoteHealth(preferences)
    // A paired computer may be asleep. Publish the remote result immediately,
    // rather than withholding it until the unrelated computer probe finishes.
    let serverHealth = await server
    guard !Task.isCancelled else { return }
    remotePreciseAvailable = serverHealth?.ok == true
    engines = ReaderKernelAvailability.availableEngines(
      companion: computerHealth, remote: serverHealth, remoteEnabled: preferences.remoteKernelEnabled
    )
    let computerHealth = await computer
    guard !Task.isCancelled else { return }
    self.computerHealth = computerHealth
    engines = ReaderKernelAvailability.availableEngines(
      companion: computerHealth,
      remote: serverHealth,
      remoteEnabled: preferences.remoteKernelEnabled
    )
  }

  private func computerHealth(_ address: String) async -> CompanionHealth? {
    let url = normalizeCompanionURL(address)
    guard !url.isEmpty,
      let code = await readPairingCode(),
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
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var library: LibraryModel
  @ObservedObject var availability: ReaderKernelMenuAvailability
  @State private var pairingRevision = 0
  @State private var lastConnectionID: [String] = []

  private var connectionID: [String] {
    let preferences = library.preferences
    return [preferences.companionURL, preferences.remoteKernelURL,
            String(preferences.remoteKernelEnabled), String(pairingRevision)]
  }

  var body: some View {
    Color.clear
      .task { await availability.loadAppleLanguages() }
      .task(id: connectionID + [String(scenePhase == .active)]) {
        // Poll only in the foreground; becoming active again refreshes at once.
        guard scenePhase == .active else { return }
        // Only invalidate results when the server or pairing actually changes.
        // Transient scene inactivity must not erase a successful health check.
        if lastConnectionID != connectionID {
          availability.reset()
          lastConnectionID = connectionID
        }
        while !Task.isCancelled {
          await availability.refresh(library.preferences)
          var preferences = library.preferences
          availability.normalizeSelection(&preferences)
          if preferences != library.preferences { library.savePreferences(preferences) }
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
      // Individual toggles preserve selection marks alongside option icons,
      // including when the saved kernel is currently unavailable.
      Menu {
        ForEach(availability.engines, id: \.self) { engine in
          Toggle(isOn: Binding(
            get: { engine == library.preferences.engine },
            set: { selected in
              guard selected else { return }
              selectEngine(engine)
            }
          )) {
            Label(engineLabel(engine), systemImage: engineSymbol(engine))
          }
          .accessibilityIdentifier("reader.kernel.\(engine.rawValue)")
        }
      } label: {
        Label(L10n.string("recentStatus.engine"), systemImage: "cpu")
      }
      .accessibilityIdentifier("reader.kernel")

      Menu {
        choice(L10n.string("settings.automaticDetection"), systemImage: "sparkle.magnifyingglass", value: "", keyPath: \.sourceLanguage)
        languageChoices(direction: "source", current: library.preferences.sourceLanguage)
      } label: {
        Label(L10n.string("settings.sourceLanguage"), systemImage: "arrow.left")
      }
      .accessibilityIdentifier("reader.sourceLanguage")

      Menu {
        languageChoices(direction: "target", current: library.preferences.targetLanguage)
      } label: {
        Label(L10n.string("menu.extra.messages.Target Language"), systemImage: "arrow.right")
      }
      .accessibilityIdentifier("reader.targetLanguage")

      Divider()

      if !availability.services(library.preferences).isEmpty {
        Menu {
          ForEach(availability.services(library.preferences)) { service in
            choice(service.id == "auto" ? L10n.string("settings.translationServiceAuto") : service.name, systemImage: service.id == "auto" ? "wand.and.stars" : "desktopcomputer", value: service.id, keyPath: \.companionService)
          }
        } label: {
          Label(L10n.string("settings.translationService"), systemImage: "desktopcomputer")
        }
        .accessibilityIdentifier("reader.companionService")
      }

      Menu {
        ForEach(TranslationMode.allCases, id: \.self) { mode in
          choice(mode.displayName, systemImage: "text.bubble", value: mode, keyPath: \.translationMode)
        }
      } label: {
        Label(L10n.string("settings.translationMode"), systemImage: "text.bubble")
      }
      .accessibilityIdentifier("reader.translationMode")

      Divider()

      Toggle(isOn: preference(\.reuseTranslations)) {
        Label(L10n.string("settings.reuseTranslations"), systemImage: "arrow.triangle.2.circlepath")
      }
      .accessibilityIdentifier("reader.reuseTranslations")

      Toggle(isOn: preference(\.ignoreCache)) {
        Label(L10n.string("advanced.options.ignore_cache.label"), systemImage: "arrow.clockwise.circle")
      }
      .accessibilityIdentifier("reader.ignoreCache")
    }
  }

  private func selectEngine(_ engine: ReaderEngine) {
    var value = library.preferences
    value.engine = engine
    let languages = availability.languages(value, direction: "target").map(\.name)
    if let current = translationLanguageOptions.first(where: { $0.code == value.targetLanguage }),
       !languages.contains(current.name),
       let fallback = translationLanguageOptions.first(where: { languages.contains($0.name) }) {
      value.targetLanguage = fallback.code
    }
    availability.normalizeSelection(&value)
    onChange(value)
  }

  private func engineSymbol(_ engine: ReaderEngine) -> String {
    switch engine {
    case .ultraFast: "bolt.fill"
    case .fast: "hare"
    case .precise: "scope"
    }
  }

  private func engineLabel(_ engine: ReaderEngine) -> String {
    if engine == .precise, availability.remotePreciseAvailable {
      return "\(engine.displayName) (\(L10n.string("ios.remoteKernel")))"
    }
    return engine.displayName
  }

  @ViewBuilder
  private func languageChoices(direction: String, current: String) -> some View {
    let appleOnly = library.preferences.engine == .ultraFast && library.preferences.translationService == .appleOnDevice
    let options = availability.languages(library.preferences, direction: direction).filter { option in
      guard appleOnly else { return true }
      let language = AppleTranslationLanguages(source: option.code, target: option.code).target
      return availability.appleLanguages.contains(language.minimalIdentifier)
    }
    // Custom codes remain usable by the general translation services.
    if !current.isEmpty, !appleOnly, !availability.hasComputerOptions(library.preferences),
       !translationLanguageOptions.contains(where: { $0.code == current }) {
      choice(languageLabel(current), systemImage: "globe", value: current, keyPath: direction == "source" ? \.sourceLanguage : \.targetLanguage)
    }
    ForEach(options) { option in
      choice(translationLanguageLabel(option.name, locale: Locale.current.identifier), systemImage: "globe", value: option.code, keyPath: direction == "source" ? \.sourceLanguage : \.targetLanguage)
    }
  }

  private func choice<Value: Equatable>(
    _ title: String, systemImage: String, value: Value,
    keyPath: WritableKeyPath<ReaderPreferences, Value>
  ) -> some View {
    Toggle(isOn: Binding(
      get: { library.preferences[keyPath: keyPath] == value },
      set: { selected in
        guard selected else { return }
        preference(keyPath).wrappedValue = value
      }
    )) {
      Label(title, systemImage: systemImage)
    }
  }

  private func languageLabel(_ code: String) -> String {
    guard let option = translationLanguageOptions.first(where: { $0.code == code }) else { return code }
    return translationLanguageLabel(option.name, locale: Locale.current.identifier)
  }

  private func preference<Value>(_ keyPath: WritableKeyPath<ReaderPreferences, Value>) -> Binding<Value> {
    Binding(
      get: { library.preferences[keyPath: keyPath] },
      set: { selection in
        var value = library.preferences
        value[keyPath: keyPath] = selection
        availability.normalizeSelection(&value)
        onChange(value)
      }
    )
  }

}
