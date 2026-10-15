import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

@MainActor
final class ReaderTranslationCoordinator: ObservableObject, ReaderPageOverlayProviding {
  private let document: PDFDocument
  private let documentData: Data
  private let documentID: String
  private let remoteClient = RemoteKernelClient()
  private lazy var mathTranslator = MathPageTranslator(client: remoteClient)
  private let credentialStore = KeychainCredentialStore()

  private var preferences: ReaderPreferences
  private var pipeline: PageTranslationPipeline?
  private var generation = 0
  private var pageTasks: [Int: Task<Void, Never>] = [:]
  private var remoteTasks: [Int: Task<Void, Never>] = [:]
  private var overlays: [Int: ReaderTranslationPageOverlay] = [:]
  private var latestStates: [Int: PageTranslationState] = [:]

  @Published private(set) var showTranslations: Bool
  @Published private(set) var configurationMessage: String?

  init(document: PDFDocument, documentID: String, preferences: ReaderPreferences) {
    self.document = document
    self.documentData = document.dataRepresentation() ?? Data()
    self.documentID = documentID
    self.preferences = preferences
    self.showTranslations = preferences.showTranslations
    configure()
  }

  deinit {
    pageTasks.values.forEach { $0.cancel() }
    remoteTasks.values.forEach { $0.cancel() }
    let pipeline = pipeline
    Task { await pipeline?.close() }
  }

  func updatePreferences(_ value: ReaderPreferences) {
    let visibilityChanged = showTranslations != value.showTranslations
    preferences = value
    showTranslations = value.showTranslations
    if visibilityChanged {
      overlays.values.forEach { overlay in
        if let state = currentState(for: overlay.pageIndex) {
          overlay.update(state: state, showTranslations: showTranslations)
        }
      }
    }
    configure()
  }

  func toggleTranslations() {
    showTranslations.toggle()
    overlays.values.forEach { overlay in
      if let state = currentState(for: overlay.pageIndex) {
        overlay.update(state: state, showTranslations: showTranslations)
      }
    }
  }

  func overlayView(for page: PDFPage, in pdfView: PDFView) -> UIView? {
    let index = document.index(for: page)
    guard index != NSNotFound else { return nil }
    let overlay: ReaderTranslationPageOverlay
    if let existing = overlays[index] {
      overlay = existing
    } else {
      overlay = ReaderTranslationPageOverlay(pageIndex: index, page: page, pdfView: pdfView)
      overlays[index] = overlay
    }
    if let state = currentState(for: index) {
      overlay.update(state: state, showTranslations: showTranslations)
    }
    startTranslation(for: index, overlay: overlay)
    return overlay
  }

  private func configure() {
    generation += 1
    let currentGeneration = generation
    pageTasks.values.forEach { $0.cancel() }
    remoteTasks.values.forEach { $0.cancel() }
    pageTasks.removeAll()
    remoteTasks.removeAll()
    let oldPipeline = pipeline
    pipeline = nil
    latestStates.removeAll()
    Task { await oldPipeline?.close() }

    guard !documentData.isEmpty else {
      configurationMessage = "This PDF could not be serialized for translation."
      return
    }
    configurationMessage = nil
    let selectedPreferences = preferences
    Task { @MainActor [weak self] in
      guard let self else { return }
      let apiKey = try? await credentialStore.read(account: openAIAPIKeyAccount)
      guard currentGeneration == generation else { return }
      do {
        let provider = try makeProvider(selectedPreferences, apiKey: apiKey)
        let service = TranslationService(
          provider: provider,
          cacheDirectory: LibraryDirectory.default.appendingPathComponent("translation-cache", isDirectory: true)
        )
        let nextPipeline = try PageTranslationPipeline(
          documentData: documentData,
          translationService: service,
          pageConcurrency: selectedPreferences.engine == .ultraFast ? 2 : 1
        )
        guard currentGeneration == generation else {
          await nextPipeline.close()
          return
        }
        pipeline = nextPipeline
        for (pageIndex, overlay) in overlays {
          startTranslation(for: pageIndex, overlay: overlay)
        }
      } catch {
        configurationMessage = error.localizedDescription
      }
    }
  }

  private func makeProvider(
    _ value: ReaderPreferences,
    apiKey: String?
  ) throws -> any TranslationProvider {
    switch value.translationService {
    case .siliconFlowFree:
      return SiliconFlowFreeProvider(language: value.targetLanguage, kernel: "pdf_inspector")
    case .openAICompatible:
      let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !key.isEmpty else {
        return UnavailableTranslationProvider(message: "Add an OpenAI-compatible API key in Settings.")
      }
      guard let url = URL(string: value.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw TranslationProviderError.invalidBaseURL
      }
      return try OpenAICompatibleProvider(
        baseURL: url,
        apiKey: key,
        model: value.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "gpt-4.1-mini"
          : value.openAIModel
      )
    case .appleOnDevice:
      return AppleTranslationProvider(
        sourceLanguage: value.sourceLanguage.isEmpty ? nil : value.sourceLanguage,
        targetLanguage: value.targetLanguage
      )
    }
  }

  private func startTranslation(for pageIndex: Int, overlay: ReaderTranslationPageOverlay) {
    switch preferences.engine {
    case .ultraFast:
      startUltraFast(for: pageIndex, overlay: overlay)
    case .fast, .precise:
      guard !preferences.remoteKernelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        startUltraFast(for: pageIndex, overlay: overlay)
        return
      }
      startRemoteTranslation(for: pageIndex, overlay: overlay)
    }
  }

  private func startUltraFast(for pageIndex: Int, overlay: ReaderTranslationPageOverlay) {
    guard pageTasks[pageIndex] == nil, let pipeline else { return }
    overlay.clearRemotePageData()
    let settings = makePipelineSettings()
    let currentGeneration = generation
    pageTasks[pageIndex] = Task { @MainActor [weak self, weak overlay] in
      guard let self else { return }
      let stream = await pipeline.stream(
        pageIndex: pageIndex,
        settings: settings,
        automaticallySchedule: true
      )
      for await state in stream {
        guard !Task.isCancelled, currentGeneration == generation else { break }
        latestStates[pageIndex] = state
        overlay?.update(state: state, showTranslations: showTranslations)
        if state.status == .ready || state.status == .error || state.status == .cancelled {
          break
        }
      }
      if currentGeneration == generation {
        pageTasks[pageIndex] = nil
      }
    }
  }

  private func startRemoteTranslation(for pageIndex: Int, overlay: ReaderTranslationPageOverlay) {
    guard remoteTasks[pageIndex] == nil else { return }
    overlay.beginRemoteTranslation()
    let currentGeneration = generation
    let value = preferences
    remoteTasks[pageIndex] = Task { @MainActor [weak self, weak overlay] in
      guard let self, let overlay else { return }
      let health = await remoteClient.health(value.remoteKernelURL)
      guard !Task.isCancelled, currentGeneration == generation else { return }
      guard health.ok else {
        startUltraFast(for: pageIndex, overlay: overlay)
        remoteTasks[pageIndex] = nil
        return
      }
      do {
        let data = try await mathTranslator.translatePage(
          document: document,
          pageIndex: pageIndex,
          serverURL: value.remoteKernelURL,
          language: value.targetLanguage,
          sourceLanguage: value.sourceLanguage.isEmpty ? nil : value.sourceLanguage,
          service: "",
          engine: value.engine == .fast ? "pdf_math_fast" : "pdf_math_precise",
          threads: 2,
          cacheScope: documentID,
          onProgress: { [weak self] progress in
            Task { @MainActor [weak self] in
              self?.overlays[pageIndex]?.setRemoteProgress(progress.percent / 100)
            }
          }
        )
        guard !Task.isCancelled, currentGeneration == generation else { return }
        overlay.setRemotePageData(data)
      } catch {
        await remoteClient.markUnhealthy(value.remoteKernelURL, reason: error.localizedDescription)
        guard !Task.isCancelled, currentGeneration == generation else { return }
        startUltraFast(for: pageIndex, overlay: overlay)
      }
      remoteTasks[pageIndex] = nil
    }
  }

  private func makePipelineSettings() -> PageTranslationSettings {
    let source = preferences.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let cacheScope = documentID.isEmpty ? "" : "\(documentID):paragraphs"
    return PageTranslationSettings(
      documentID: documentID,
      sourceLanguage: source.isEmpty ? nil : source,
      targetLanguage: preferences.targetLanguage,
      engine: .ultraFast,
      paragraphConcurrency: 2,
      translationMode: preferences.translateFullDocument ? .full : .readingAhead,
      cacheScope: cacheScope
    )
  }

  private func currentState(for pageIndex: Int) -> PageTranslationState? {
    latestStates[pageIndex]
  }
}
