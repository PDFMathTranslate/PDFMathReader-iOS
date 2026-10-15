import ReaderCore
import SwiftUI

extension ReaderEngine {
  var displayName: String {
    switch self {
    case .ultraFast: "Ultra fast"
    case .fast: "Fast"
    case .precise: "Precise"
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
          Picker("Target language", selection: $draft.targetLanguage) {
            Text("English").tag("en")
            Text("简体中文").tag("zh-Hans")
            Text("日本語").tag("ja")
            Text("Deutsch").tag("de")
          }
          Picker("Engine", selection: $draft.engine) {
            ForEach(ReaderEngine.allCases, id: \.self) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
          Text("Translation engines are reserved for a later phase; this setting is persisted now.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
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
    .onAppear { draft = library.preferences }
    .onDisappear { library.savePreferences(draft) }
  }
}
