import Combine
import Foundation
import NaturalLanguage
import PDFKit
import ReaderCore
import UIKit

struct ReaderTranslationExportSnapshot: Sendable {
  let pageCount: Int
  let paragraphsByPage: [[ExportParagraphBlock]]
  let replacementPDFDataByPage: [Data?]
  let statesByPage: [PageTranslationState?]

  var translatedPageCount: Int {
    paragraphsByPage.enumerated().reduce(into: 0) { count, value in
      let (index, blocks) = value
      if !blocks.isEmpty || replacementPDFDataByPage[index] != nil {
        count += 1
      }
    }
  }
}

private struct PreparedTranslationSource: Sendable {
  let data: Data
  let languageSample: String
}

@MainActor
final class ReaderTranslationCoordinator: ObservableObject, ReaderPageOverlayProviding {
  private let document: PDFDocument
  private var documentData: Data?
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
  private var remotePageDataByPage: [Int: Data] = [:]
  @Published private var remoteProgressByPage: [Int: Double] = [:]
  private var pairingCodeObserver: AnyCancellable?
  private var cacheObserver: AnyCancellable?
  private var cacheTrimTask: Task<Void, Never>?
  private var forceRetranslation = false
  private var ignoresCache: Bool { preferences.ignoreCache || forceRetranslation }
  private var cacheScope: String {
    TranslationCacheManagement().scope(documentID: documentID)
  }
  private var sourcePreparationTask: Task<Void, Never>?
  private var languageSample = ""
  private var currentPageIndex: Int?
  private var visiblePageIndices: [Int] = []
  private var readingDirection = 1
  private var schedulingTask: Task<Void, Never>?
  private var mathQueue: TranslationQueue?

  @Published private(set) var showTranslations: Bool
  @Published private(set) var configurationMessage: String?
  @Published private(set) var translationRevision = 0
  @Published private(set) var appleTranslationLanguages: AppleTranslationLanguages?

  /// The installed-only provider cannot ask for downloads. The reader's
  /// SwiftUI translation task prepares this exact pair before retrying pages.
  func appleTranslationPrepared(_ languages: AppleTranslationLanguages) {
    guard appleTranslationLanguages == languages else { return }
    configure()
  }

  private var appleSourceLanguage: String {
    let source = preferences.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    if !source.isEmpty { return source }
    return NLLanguageRecognizer.dominantLanguage(for: String(languageSample.prefix(10_000)))?.rawValue ?? "en"
  }

  init(
    document: PDFDocument,
    documentID: String,
    preferences: ReaderPreferences,
    sourceData: Data? = nil
  ) {
    self.document = document
    self.documentData = nil
    self.documentID = documentID.isEmpty ? UUID().uuidString : documentID
    self.preferences = preferences
    self.showTranslations = preferences.showTranslations
    // The pairing code lives in the Keychain, not in preferences, so a new
    // code would otherwise leave pages on their Ultra fast fallback.
    pairingCodeObserver = NotificationCenter.default
      .publisher(for: .companionPairingCodeDidChange)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.preferences.engine != .ultraFast else { return }
          self.configure()
        }
      }
    cacheObserver = NotificationCenter.default.publisher(for: .translationCacheDidClear)
      .sink { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self else { return }
          if let id = notification.userInfo?["documentID"] as? String, id != self.documentID { return }
          self.configure()
        }
      }
    let sourceURL = document.documentURL
    sourcePreparationTask = Task { @MainActor [weak self] in
      var prepared = await Self.prepareTranslationSource(data: sourceData, url: sourceURL)
      guard !Task.isCancelled, let self else { return }
      // Tests and transient in-memory documents have no URL to read. Give the
      // first render a chance to start, then serialize only this fallback on
      // the main actor and hand the resulting bytes to the detached parser.
      if prepared == nil, sourceData == nil, sourceURL == nil {
        await Task.yield()
        guard !Task.isCancelled else { return }
        if let data = self.document.dataRepresentation(), !data.isEmpty {
          prepared = await Self.prepareTranslationSource(data: data, url: nil)
        }
      }
      guard let prepared else {
        self.configurationMessage = L10n.string("ios.serializeTranslationFailed")
        return
      }
      self.documentData = prepared.data
      self.languageSample = prepared.languageSample
      self.configure()
    }
  }

  deinit {
    schedulingTask?.cancel()
    cacheTrimTask?.cancel()
    sourcePreparationTask?.cancel()
    pageTasks.values.forEach { $0.cancel() }
    remoteTasks.values.forEach { $0.cancel() }
    let pipeline = pipeline
    let mathQueue = mathQueue
    Task {
      await mathQueue?.cancelAll()
      await pipeline?.close()
    }
  }

  private static func prepareTranslationSource(
    data suppliedData: Data?,
    url: URL?
  ) async -> PreparedTranslationSource? {
    await Task.detached(priority: .utility) {
      let data: Data?
      if let suppliedData, !suppliedData.isEmpty {
        data = suppliedData
      } else if let url, url.isFileURL {
        data = try? Data(contentsOf: url, options: [.mappedIfSafe])
      } else {
        data = nil
      }
      guard let data, !data.isEmpty, let document = PDFDocument(data: data) else { return nil }
      let sample = (0..<min(document.pageCount, 3)).compactMap { document.page(at: $0)?.string }
        .joined(separator: "\n")
      return PreparedTranslationSource(data: data, languageSample: sample)
    }.value
  }

  func updatePreferences(_ value: ReaderPreferences) {
    let visibilityChanged = showTranslations != value.showTranslations
    let previousConfigurationID = translationConfigurationID
    let previousMode = preferences.translationMode
    preferences = value
    showTranslations = value.showTranslations
    if visibilityChanged {
      overlays.values.forEach { $0.setTranslationsVisible(showTranslations) }
    }
    overlays.values.forEach {
      $0.setInteractionMode(value.interactionMode)
      $0.setTranslationFont(
        name: value.translationFont,
        serif: value.translationSerif,
        language: value.targetLanguage
      )
    }
    // UI-only changes (visibility, theme, reading aids) must not restart the
    // pipeline: a restart clears the page states the overlays rely on.
    if translationConfigurationID != previousConfigurationID {
      configure()
    } else if preferences.translationMode != previousMode {
      scheduleViewport()
    }
  }

  func forceRetranslate() {
    forceRetranslation = true
    configure()
  }

  func clearDocumentCache() throws {
    try TranslationCacheManagement().clear(documentID: documentID)
    NotificationCenter.default.post(
      name: .translationCacheDidClear, object: nil, userInfo: ["documentID": documentID]
    )
  }

  private func trimCache() {
    let saved = UserDefaults.standard.object(forKey: "translationCacheLimitBytes") as? Int
    let limit = saved ?? 1_073_741_824
    guard limit > 0, cacheTrimTask == nil else { return }
    cacheTrimTask = Task { @MainActor [weak self] in
      await Task.detached(priority: .utility) {
        _ = try? TranslationCacheManagement().trim(toBytes: Int64(limit))
      }.value
      self?.cacheTrimTask = nil
    }
  }

  func toggleTranslations() {
    showTranslations.toggle()
    overlays.values.forEach { $0.setTranslationsVisible(showTranslations) }
  }

  var translationDocumentID: String { documentID }

  var translationPageCount: Int { document.pageCount }

  /// Visibility is independent of work: the toolbar keeps reporting progress
  /// even while the reader is showing the original text.
  var activeTranslationProgress: Double? {
    var fractions = remoteProgressByPage
    var isActive = !fractions.isEmpty
    for (pageIndex, state) in latestStates where fractions[pageIndex] == nil {
      switch state.status {
      case .queued, .extracting, .translating:
        guard pageTasks[pageIndex] != nil else { continue }
        fractions[pageIndex] = state.progress
        isActive = true
      case .ready, .error:
        fractions[pageIndex] = 1
      case .idle, .cancelled:
        continue
      }
    }
    for pageIndex in remotePageDataByPage.keys { fractions[pageIndex] = 1 }
    guard isActive, !fractions.isEmpty else { return nil }
    return fractions.values.reduce(0, +) / Double(fractions.count)
  }

  /// Identifies the settings that affect a document-wide translation cache.
  /// Credentials and UI-only preferences are deliberately excluded.
  var translationConfigurationID: String {
    let values = [
      preferences.engine.rawValue,
      cacheScope,
      String(forceRetranslation),
      String(preferences.reuseTranslations),
      String(preferences.ignoreCache),
      preferences.translationService.rawValue,
      preferences.sourceLanguage,
      preferences.targetLanguage,
      preferences.openAIBaseURL,
      preferences.openAIModel,
      preferences.remoteKernelURL,
      preferences.remoteKernelEnabled ? "remote-on" : "remote-off",
      preferences.remoteKernelService,
      preferences.companionURL,
      (try? JSONEncoder().encode(preferences.glossaries).base64EncodedString()) ?? ""
    ]
    return sha256Hex(Data(values.joined(separator: "\n").utf8))
  }

  var readyTranslationPageIndices: Set<Int> {
    let ready = latestStates.compactMap { pageIndex, state in
      state.status == .ready ? pageIndex : nil
    }
    return Set(ready)
  }

  #if DEBUG
  /// Translated paragraphs in page order, one per line; read by the UI test probe.
  var debugTranslations: String {
    latestStates.sorted { $0.key < $1.key }
      .flatMap(\.value.paragraphs)
      .compactMap(\.translation)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n")
  }

  /// Per-page pipeline status and errors; lets UI tests report why a page
  /// never produced a translation.
  var debugPipelineStatus: String {
    var lines = latestStates.sorted { $0.key < $1.key }.map { index, state in
      let paragraphErrors = state.paragraphs.compactMap(\.error)
      let errors = ([state.error].compactMap { $0 } + paragraphErrors).joined(separator: " | ")
      return "page \(index): \(state.status) paragraphs=\(state.paragraphs.count) \(errors)"
    }
    if pipeline == nil { lines.insert("pipeline not ready", at: 0) }
    if let configurationMessage { lines.insert("config: \(configurationMessage)", at: 0) }
    return lines.joined(separator: "\n")
  }

  /// Text the on-screen overlays show (translation or original), one
  /// paragraph per line; lets UI tests see what the reader displays.
  var debugDisplayedText: String {
    overlays.sorted { $0.key < $1.key }
      .flatMap(\.value.debugDisplayedText)
      .joined(separator: "\n")
  }
  #endif

  /// Schedules the remaining pages in full-document mode once the pipeline is ready.
  func scheduleFullDocumentTranslation(excluding pageIndices: Set<Int>) async -> Set<Int>? {
    if documentData == nil {
      let preparationTask = sourcePreparationTask
      await preparationTask?.value
    }
    guard !Task.isCancelled else { return nil }
    guard let documentData, !documentData.isEmpty, document.pageCount > 0 else { return nil }
    let validExcluded = Set(pageIndices.filter { (0..<document.pageCount).contains($0) })
    for _ in 0..<300 {
      guard !Task.isCancelled else { return nil }
      if let pipeline {
        var settings = makePipelineSettings()
        settings.translationMode = .full
        if !showTranslations {
          showTranslations = true
          overlays.values.forEach { $0.setTranslationsVisible(true) }
        }
        await pipeline.schedule(
          settings: settings,
          manual: true,
          excludedPageIndices: validExcluded
        )
        return Set((0..<document.pageCount).filter { !validExcluded.contains($0) })
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return nil
  }

  func translationStream(for pageIndex: Int) async -> AsyncStream<PageTranslationState>? {
    guard (0..<document.pageCount).contains(pageIndex), let pipeline else { return nil }
    var settings = makePipelineSettings()
    settings.translationMode = .full
    return await pipeline.stream(
      pageIndex: pageIndex,
      settings: settings,
      automaticallySchedule: false
    )
  }

  func cancelAllTranslations() async {
    schedulingTask?.cancel()
    let queueToCancel = mathQueue
    let pipelineToCancel = pipeline
    pageTasks.values.forEach { $0.cancel() }
    remoteTasks.values.forEach { $0.cancel() }
    pageTasks.removeAll()
    remoteTasks.removeAll()
    remoteProgressByPage.removeAll()
    await queueToCancel?.cancelAll()
    await pipelineToCancel?.cancel()
  }

  func exportedPDFData(originalPDFData: Data) throws -> Data {
    let snapshot = exportSnapshot()
    var replacements = snapshot.replacementPDFDataByPage
    if !preferences.translationFont.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || preferences.translationSerif {
      for index in replacements.indices {
        guard let data = replacements[index] else { continue }
        guard let translatedDocument = PDFDocument(data: data), translatedDocument.pageCount == 1,
          let translatedPage = translatedDocument.page(at: 0)
        else { throw TranslatedPDFExporterError.invalidReplacementPage(index: index) }
        replacements[index] = try ReaderRemoteTranslationFont(
          page: translatedPage, original: document.page(at: index)
        ).pdfData(
          name: preferences.translationFont,
          serif: preferences.translationSerif,
          language: preferences.targetLanguage
        )
      }
    }
    return try TranslatedPDFExporter().export(
      originalPDFData: originalPDFData,
      paragraphsByPage: snapshot.paragraphsByPage,
      replacementPDFDataByPage: replacements,
      fontName: preferences.translationFont,
      serif: preferences.translationSerif
    )
  }

  func exportSnapshot() -> ReaderTranslationExportSnapshot {
    var paragraphsByPage = [[ExportParagraphBlock]](repeating: [], count: document.pageCount)
    var statesByPage = [PageTranslationState?](repeating: nil, count: document.pageCount)
    for (pageIndex, state) in latestStates {
      guard pageIndex >= 0, pageIndex < document.pageCount else { continue }
      statesByPage[pageIndex] = state
      paragraphsByPage[pageIndex] = state.paragraphs.compactMap { value in
        guard let translation = value.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
          !translation.isEmpty
        else { return nil }
        return ExportParagraphBlock(
          x: value.paragraph.x,
          y: value.paragraph.y,
          width: value.paragraph.width,
          height: value.paragraph.height,
          translation: translation,
          fontSize: value.paragraph.fontSize,
          bold: value.paragraph.bold,
          textAlign: value.paragraph.textAlign
        )
      }
    }

    var replacements = [Data?](repeating: nil, count: document.pageCount)
    for (pageIndex, data) in remotePageDataByPage
      where pageIndex >= 0 && pageIndex < document.pageCount
    {
      replacements[pageIndex] = data
    }
    return ReaderTranslationExportSnapshot(
      pageCount: document.pageCount,
      paragraphsByPage: paragraphsByPage,
      replacementPDFDataByPage: replacements,
      statesByPage: statesByPage
    )
  }

  func overlayView(for page: PDFPage, in pdfView: PDFView) -> UIView? {
    // Annotation edits swap in a new PDFDocument with the same pages, so the
    // live view's document, not the original one, owns `page`.
    let index = pdfView.document?.index(for: page) ?? document.index(for: page)
    guard index != NSNotFound, index < document.pageCount else { return nil }
    let overlay: ReaderTranslationPageOverlay
    if let existing = overlays[index] {
      overlay = existing
      overlay.rebind(page: page, pdfView: pdfView)
    } else {
      overlay = ReaderTranslationPageOverlay(pageIndex: index, page: page, pdfView: pdfView)
      overlays[index] = overlay
    }
    overlay.setTranslationFont(
      name: preferences.translationFont,
      serif: preferences.translationSerif,
      language: preferences.targetLanguage
    )
    overlay.setInteractionMode(preferences.interactionMode)
    if let state = currentState(for: index) {
      overlay.update(state: state, showTranslations: showTranslations)
    }
    if let data = remotePageDataByPage[index] {
      overlay.setRemotePageData(data)
    }
    if let progress = remoteProgressByPage[index] {
      overlay.setRemoteProgress(progress)
    }
    // PDFKit creates overlays for offscreen pages too. Only the viewport
    // controls the request scope; attaching an overlay must not expand it.
    if preferences.engine == .ultraFast || latestStates[index] != nil {
      startUltraFast(for: index)
    }
    if currentPageIndex == nil {
      currentPageIndex = index
      visiblePageIndices = [index]
      scheduleViewport()
    }
    return overlay
  }

  private func configure() {
    appleTranslationLanguages = preferences.translationService == .appleOnDevice
      ? AppleTranslationLanguages(source: appleSourceLanguage, target: preferences.targetLanguage)
      : nil
    generation += 1
    let currentGeneration = generation
    pageTasks.values.forEach { $0.cancel() }
    remoteTasks.values.forEach { $0.cancel() }
    pageTasks.removeAll()
    remoteTasks.removeAll()
    schedulingTask?.cancel()
    let oldMathQueue = mathQueue
    mathQueue = nil
    Task { await oldMathQueue?.cancelAll() }
    let oldPipeline = pipeline
    pipeline = nil
    latestStates.removeAll()
    remotePageDataByPage.removeAll()
    remoteProgressByPage.removeAll()
    for (index, overlay) in overlays {
      overlay.clearRemotePageData()
      overlay.update(state: PageTranslationState(pageIndex: index), showTranslations: showTranslations)
    }
    translationRevision &+= 1
    Task { await oldPipeline?.close() }

    guard let documentData, !documentData.isEmpty else {
      configurationMessage = L10n.string("ios.serializeTranslationFailed")
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
        let cacheDirectory = LibraryDirectory.default
          .appendingPathComponent("translation-cache", isDirectory: true)
        let pageConcurrency = selectedPreferences.engine == .ultraFast ? 2 : 1
        let nextPipeline = try await Task.detached(priority: .utility) {
          let service = TranslationService(
            provider: provider,
            cacheDirectory: cacheDirectory
          )
          return try PageTranslationPipeline(
            documentData: documentData,
            translationService: service,
            pageConcurrency: pageConcurrency
          )
        }.value
        guard currentGeneration == generation else {
          await nextPipeline.close()
          return
        }
        pipeline = nextPipeline
        mathQueue = TranslationQueue(pageConcurrency: 1) { [weak self] page in
          try await self?.translateMathPage(page - 1)
        }
        if selectedPreferences.engine == .ultraFast {
          for pageIndex in overlays.keys { startUltraFast(for: pageIndex) }
        }
        scheduleViewport()
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
        return UnavailableTranslationProvider(message: L10n.string("ios.missingOpenAIAPIKey"))
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
        sourceLanguage: appleSourceLanguage,
        targetLanguage: value.targetLanguage
      )
    }
  }

  /// Called from PDFView state changes, using the display document's indices.
  func updateViewport(currentPageIndex: Int, visiblePageIndices: [Int]) {
    guard (0..<document.pageCount).contains(currentPageIndex) else { return }
    let visible = Array(Set(visiblePageIndices.filter { (0..<document.pageCount).contains($0) })).sorted()
    guard self.currentPageIndex != currentPageIndex || self.visiblePageIndices != visible else { return }
    if let previous = self.currentPageIndex, previous != currentPageIndex {
      readingDirection = currentPageIndex > previous ? 1 : -1
    }
    self.currentPageIndex = currentPageIndex
    self.visiblePageIndices = visible
    scheduleViewport()
  }

  private func scheduleViewport() {
    schedulingTask?.cancel()
    guard let pipeline, let currentPageIndex else { return }
    let settings = makePipelineSettings()
    let visible = visiblePageIndices
    let direction = readingDirection
    let engine = preferences.engine
    let mathQueue = mathQueue
    schedulingTask = Task {
      guard !Task.isCancelled else { return }
      if engine == .ultraFast {
        await pipeline.schedule(
          settings: settings, currentPageIndex: currentPageIndex,
          visiblePageIndices: visible, direction: direction
        )
        guard !Task.isCancelled else { return }
        for index in Set(visible + [currentPageIndex]) {
          startUltraFast(for: index)
        }
      } else {
        await mathQueue?.schedule(
          totalPages: document.pageCount, currentPage: currentPageIndex + 1,
          mode: settings.translationMode, visiblePages: visible.map { $0 + 1 },
          direction: direction
        )
      }
    }
  }

  private func translateMathPage(_ pageIndex: Int) async throws {
    guard !Task.isCancelled else { return }
    if remotePageDataByPage[pageIndex] != nil { return }
    startMathKernelTranslation(for: pageIndex)
    let task = remoteTasks[pageIndex]
    await withTaskCancellationHandler {
      await task?.value
    } onCancel: {
      task?.cancel()
    }
    try Task.checkCancellation()
    if let state = latestStates[pageIndex], state.status == .error {
      throw TranslationServiceError.provider(state.error ?? "Translation failed")
    }
  }

  /// Like the desktop, the zotero-pdf2zh server only replaces the Precise kernel.
  private func usesRemotePreciseKernel(_ value: ReaderPreferences) -> Bool {
    value.engine == .precise && value.remoteKernelEnabled
      && !normalizeRemoteKernelUrl(value.remoteKernelURL).isEmpty
  }

  private func startUltraFast(for pageIndex: Int, schedulePage: Bool = false) {
    guard pageTasks[pageIndex] == nil, let pipeline else { return }
    overlays[pageIndex]?.clearRemotePageData()
    let settings = makePipelineSettings()
    let currentGeneration = generation
    pageTasks[pageIndex] = Task { @MainActor [weak self] in
      guard let self else { return }
      if schedulePage {
        var pageSettings = settings
        pageSettings.translationMode = .reading
        await pipeline.schedule(
          settings: pageSettings, currentPageIndex: pageIndex,
          visiblePageIndices: [pageIndex], moving: true
        )
      }
      let stream = await pipeline.stream(
        pageIndex: pageIndex,
        settings: settings,
        automaticallySchedule: false
      )
      for await state in stream {
        guard !Task.isCancelled, currentGeneration == generation else { break }
        latestStates[pageIndex] = state
        translationRevision &+= 1
        overlays[pageIndex]?.update(state: state, showTranslations: showTranslations)
        if state.status == .ready || state.status == .error || state.status == .cancelled {
          if state.status == .ready { trimCache() }
          break
        }
      }
      if currentGeneration == generation {
        pageTasks[pageIndex] = nil
      }
    }
  }

  /// Precise tries the remote server first, then PDFMathReader on the user's
  /// computer; Fast only uses the computer. Anything else falls back to Ultra fast.
  private func startMathKernelTranslation(for pageIndex: Int) {
    guard remoteTasks[pageIndex] == nil else { return }
    remotePageDataByPage[pageIndex] = nil
    overlays[pageIndex]?.beginRemoteTranslation()
    let currentGeneration = generation
    remoteProgressByPage[pageIndex] = 0
    let value = preferences
    let ignoreCache = ignoresCache
    let documentCacheScope = cacheScope
    let kernel = value.engine == .fast ? CompanionKernel.fast : CompanionKernel.precise
    let sourceLanguage = value.sourceLanguage.isEmpty ? nil : value.sourceLanguage
    let onProgress: @Sendable (RemoteKernelProgress) -> Void = { [weak self] progress in
      Task { @MainActor [weak self] in
        guard let self, self.generation == currentGeneration,
          self.remoteProgressByPage[pageIndex] != nil else { return }
        let fraction = min(1, max(0, progress.percent / 100))
        self.remoteProgressByPage[pageIndex] = fraction
        self.overlays[pageIndex]?.setRemoteProgress(fraction)
      }
    }
    remoteTasks[pageIndex] = Task { @MainActor [weak self] in
      guard let self else { return }
      var result: Data?
      // Restore cached math pages before connectivity checks so reopening a
      // document can reuse completed pages while its server is offline.
      if !ignoreCache {
        if usesRemotePreciseKernel(value) {
          result = try? await mathTranslator.translatePage(
            document: document, pageIndex: pageIndex,
            serverURL: value.remoteKernelURL, language: value.targetLanguage,
            sourceLanguage: sourceLanguage, service: value.remoteKernelService,
            engine: kernel, cacheScope: documentCacheScope,
            reuseTranslations: value.reuseTranslations, cacheOnly: true
          )
        }
        if result == nil, !normalizeCompanionURL(value.companionURL).isEmpty {
          result = try? await mathTranslator.translatePage(
            document: document, pageIndex: pageIndex,
            companionURL: value.companionURL, pairingCode: "",
            language: value.targetLanguage, sourceLanguage: sourceLanguage,
            engine: kernel, service: value.translationService.companionService,
            glossary: glossaryEntries(value.glossaries), cacheScope: documentCacheScope,
            reuseTranslations: value.reuseTranslations, cacheOnly: true
          )
        }
      }
      guard !Task.isCancelled, currentGeneration == generation else { return }
      if result == nil, usesRemotePreciseKernel(value), await remoteClient.health(value.remoteKernelURL).ok {
        do {
          result = try await mathTranslator.translatePage(
            document: document,
            pageIndex: pageIndex,
            serverURL: value.remoteKernelURL,
            language: value.targetLanguage,
            sourceLanguage: sourceLanguage,
            service: value.remoteKernelService,
            engine: kernel,
            threads: 2,
            cacheScope: documentCacheScope,
            forceRetranslation: ignoreCache,
            reuseTranslations: value.reuseTranslations,
            onProgress: onProgress
          )
        } catch {
          guard !Task.isCancelled else { return }
          await remoteClient.markUnhealthy(value.remoteKernelURL, reason: error.localizedDescription)
        }
      }
      guard !Task.isCancelled, currentGeneration == generation else { return }

      let companionURL = normalizeCompanionURL(value.companionURL)
      let pairingCode = companionURL.isEmpty
        ? ""
        : (try? await credentialStore.read(account: companionPairingCodeAccount)) ?? ""
      let companion = mathTranslator.companionClient
      if result == nil, !pairingCode.isEmpty,
        await companion.health(companionURL, pairingCode: pairingCode).isAvailable(kernel)
      {
        do {
          result = try await mathTranslator.translatePage(
            document: document,
            pageIndex: pageIndex,
            companionURL: companionURL,
            pairingCode: pairingCode,
            language: value.targetLanguage,
            sourceLanguage: sourceLanguage,
            engine: kernel,
            service: value.translationService.companionService,
            glossary: glossaryEntries(value.glossaries),
            cacheScope: documentCacheScope,
            forceRetranslation: ignoreCache,
            reuseTranslations: value.reuseTranslations,
            onProgress: onProgress
          )
        } catch {
          guard !Task.isCancelled else { return }
          await companion.markUnhealthy(companionURL, pairingCode: pairingCode, reason: error.localizedDescription)
        }
      }
      guard !Task.isCancelled, currentGeneration == generation else { return }

      if let data = result {
        remotePageDataByPage[pageIndex] = data
        translationRevision &+= 1
        overlays[pageIndex]?.setRemotePageData(data)
        trimCache()
      } else {
        overlays[pageIndex]?.clearRemotePageData()
        startUltraFast(for: pageIndex, schedulePage: true)
        await pageTasks[pageIndex]?.value
      }
      remoteTasks[pageIndex] = nil
      remoteProgressByPage[pageIndex] = nil
    }
  }

  private func makePipelineSettings() -> PageTranslationSettings {
    let source = preferences.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let cacheScope = documentID.isEmpty ? "" : "\(self.cacheScope):paragraphs"
    return PageTranslationSettings(
      documentID: documentID,
      sourceLanguage: source.isEmpty ? nil : source,
      targetLanguage: preferences.targetLanguage,
      engine: .ultraFast,
      glossary: glossaryEntries(preferences.glossaries),
      paragraphConcurrency: 2,
      translationMode: preferences.translationMode,
      forceRetranslation: ignoresCache,
      reuseTranslations: preferences.reuseTranslations,
      cacheScope: cacheScope
    )
  }

  private func currentState(for pageIndex: Int) -> PageTranslationState? {
    latestStates[pageIndex]
  }
}
