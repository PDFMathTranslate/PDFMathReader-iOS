import SwiftUI

#if canImport(Translation)
import Translation
#endif

/// Settings row for Apple on-device translation: shows whether the selected
/// language pair is downloaded and offers the system download prompt.
struct AppleTranslationLanguagesRow: View {
  let sourceLanguage: String
  let targetLanguage: String

  var body: some View {
    #if canImport(Translation)
    if #available(iOS 26.0, *) {
      AppleTranslationLanguagesStatus(
        languages: AppleTranslationLanguages(source: sourceLanguage, target: targetLanguage)
      )
    }
    #endif
  }
}

/// Keep download permission inside a visible reader's SwiftUI lifecycle.
/// The paragraph provider uses installed-only sessions after preparation.
struct ReaderAppleTranslationPreparation: View {
  @ObservedObject var coordinator: ReaderTranslationCoordinator

  var body: some View {
    #if canImport(Translation)
    if #available(iOS 26.0, *), let languages = coordinator.appleTranslationLanguages,
       languages.source != languages.target {
      AppleTranslationPreparation(languages: languages) {
        coordinator.appleTranslationPrepared(languages)
      }
      .id(languages)
    }
    #endif
  }
}

#if canImport(Translation)
@available(iOS 26.0, *)
private struct AppleTranslationPreparation: View {
  let languages: AppleTranslationLanguages
  let onPrepared: @MainActor () -> Void

  private var configuration: TranslationSession.Configuration {
    if #available(iOS 26.4, *) {
      return .init(source: languages.source, target: languages.target, preferredStrategy: .lowLatency)
    }
    return .init(source: languages.source, target: languages.target)
  }

  var body: some View {
    Color.clear
      .translationTask(configuration) { session in
        nonisolated(unsafe) let session = session
        do {
          try await session.prepareTranslation()
          try Task.checkCancellation()
          onPrepared()
        } catch {
          // The paragraph provider displays the actionable download/error
          // message. A dismissed system prompt must not restart it in a loop.
        }
      }
  }
}
#endif

#if canImport(Translation)
@available(iOS 26.0, *)
private struct AppleTranslationLanguagesStatus: View {
  let languages: AppleTranslationLanguages
  @State private var status: LanguageAvailability.Status?
  @State private var configuration: TranslationSession.Configuration?

  var body: some View {
    Group {
      switch status {
      case .installed:
        Label(L10n.string("ios.appleTranslationLanguagesReady"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      case .supported:
        Button {
          if configuration == nil {
            if #available(iOS 26.4, *) {
              configuration = .init(
                source: languages.source, target: languages.target, preferredStrategy: .lowLatency
              )
            } else {
              configuration = .init(source: languages.source, target: languages.target)
            }
          } else {
            configuration?.invalidate()
          }
        } label: {
          Label(L10n.string("ios.appleTranslationDownload"), systemImage: "arrow.down.circle")
        }
      case .unsupported:
        Label(L10n.string("ios.appleTranslationLanguagesUnsupported"), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      case nil:
        ProgressView()
      @unknown default:
        EmptyView()
      }
    }
    .accessibilityIdentifier("settings.appleTranslationLanguages")
    .task(id: languages) { await refresh() }
    .translationTask(configuration) { session in
      // The framework owns the session and hands it only to this closure.
      nonisolated(unsafe) let session = session
      try? await session.prepareTranslation()
      await refresh()
    }
  }

  private func refresh() async {
    let availability: LanguageAvailability
    if #available(iOS 26.4, *) {
      availability = LanguageAvailability(preferredStrategy: .lowLatency)
    } else {
      availability = LanguageAvailability()
    }
    status = await availability.status(from: languages.source, to: languages.target)
  }
}
#endif
