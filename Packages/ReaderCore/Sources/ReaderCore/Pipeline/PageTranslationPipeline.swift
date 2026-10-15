import Foundation
import PDFKit

public enum PageTranslationStatus: String, Codable, Sendable {
  case idle
  case queued
  case extracting
  case translating
  case ready
  case error
  case cancelled
}

public enum PageTranslationParagraphStatus: String, Codable, Sendable {
  case queued
  case translating
  case ready
  case skipped
  case error
}

public struct PageTranslationSettings: Hashable, Sendable {
  public var documentID: String
  public var sourceLanguage: String?
  public var targetLanguage: String
  public var engine: ReaderEngine
  public var glossary: [GlossaryEntry]
  public var paragraphConcurrency: Int
  public var translationMode: TranslationMode
  public var forceRetranslation: Bool
  public var reuseTranslations: Bool
  public var cacheScope: String
  public var minimumTextLength: Int

  public init(
    documentID: String = "",
    sourceLanguage: String? = "en",
    targetLanguage: String = "en",
    engine: ReaderEngine = .ultraFast,
    glossary: [GlossaryEntry] = [],
    paragraphConcurrency: Int = 2,
    translationMode: TranslationMode = .readingAhead,
    forceRetranslation: Bool = false,
    reuseTranslations: Bool = false,
    cacheScope: String = "",
    minimumTextLength: Int = 2
  ) {
    self.documentID = documentID
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.engine = engine
    self.glossary = glossary
    self.paragraphConcurrency = max(1, min(12, paragraphConcurrency))
    self.translationMode = translationMode
    self.forceRetranslation = forceRetranslation
    self.reuseTranslations = reuseTranslations
    self.cacheScope = cacheScope
    self.minimumTextLength = max(0, minimumTextLength)
  }

  public var queueContext: TranslationQueueContext {
    TranslationQueueContext(
      documentID: documentID,
      language: targetLanguage,
      engine: "\(engine.rawValue):\(cacheScope)"
    )
  }
}

public struct PageTranslationParagraph: Codable, Equatable, Sendable {
  public let paragraph: LayoutParagraph
  public var translation: String?
  public var status: PageTranslationParagraphStatus
  public var error: String?

  public init(
    paragraph: LayoutParagraph,
    translation: String? = nil,
    status: PageTranslationParagraphStatus,
    error: String? = nil
  ) {
    self.paragraph = paragraph
    self.translation = translation
    self.status = status
    self.error = error
  }
}

public struct PageTranslationState: Codable, Equatable, Sendable {
  /// Zero-based PDFKit page index.
  public let pageIndex: Int
  public var status: PageTranslationStatus
  public var paragraphs: [PageTranslationParagraph]
  public var error: String?

  public init(
    pageIndex: Int,
    status: PageTranslationStatus = .idle,
    paragraphs: [PageTranslationParagraph] = [],
    error: String? = nil
  ) {
    self.pageIndex = pageIndex
    self.status = status
    self.paragraphs = paragraphs
    self.error = error
  }

  public var completedCount: Int {
    paragraphs.filter { [.ready, .skipped, .error].contains($0.status) }.count
  }

  public var translatedCount: Int {
    paragraphs.filter { $0.translation?.isEmpty == false }.count
  }

  public var progress: Double {
    guard !paragraphs.isEmpty else { return status == .ready ? 1 : 0 }
    return Double(completedCount) / Double(paragraphs.count)
  }
}

public enum PageTranslationPipelineError: Error, LocalizedError, Sendable, Equatable {
  case invalidDocument
  case invalidPage
  case closed

  public var errorDescription: String? {
    switch self {
    case .invalidDocument: return "The PDF document could not be loaded."
    case .invalidPage: return "The requested PDF page is out of range."
    case .closed: return "The translation pipeline is closed."
    }
  }
}

private final class PageTranslationQueueRouter: @unchecked Sendable {
  weak var pipeline: PageTranslationPipeline?

  func run(page: Int) async throws {
    guard let pipeline else { throw PageTranslationPipelineError.closed }
    try await pipeline.processQueuedPage(page)
  }
}

/// Extracts, lays out, and translates PDF pages while publishing each paragraph
/// as soon as its request finishes. Page-level scheduling remains delegated to
/// TranslationQueue so visible pages always outrank document-wide work.
public actor PageTranslationPipeline {
  public static let defaultLayoutMaxPages = 32
  public static let defaultLayoutMaxBytes = 8 * 1024 * 1024

  private struct LayoutCacheEntry {
    let items: [TextItem]
    let bytes: Int
  }

  private struct PageStreamKey: Hashable {
    let page: Int
    let id: UUID
  }

  private let documentData: Data
  private let translationService: TranslationService
  private let extractor: PDFKitTextExtractor
  private let pageCount: Int
  private let layoutMaxPages: Int
  private let layoutMaxBytes: Int
  private let queue: TranslationQueue
  private let router: PageTranslationQueueRouter
  private var activeSettings: PageTranslationSettings
  private var states: [Int: PageTranslationState] = [:]
  private var streams: [PageStreamKey: AsyncStream<PageTranslationState>.Continuation] = [:]
  private var layoutCache: [Int: LayoutCacheEntry] = [:]
  private var layoutOrder: [Int] = []
  private var layoutBytes = 0
  private var isClosed = false

  public init(
    documentData: Data,
    translationService: TranslationService,
    pageConcurrency: Int = 2,
    layoutMaxPages: Int = PageTranslationPipeline.defaultLayoutMaxPages,
    layoutMaxBytes: Int = PageTranslationPipeline.defaultLayoutMaxBytes
  ) throws {
    guard let document = PDFDocument(data: documentData) else {
      throw PageTranslationPipelineError.invalidDocument
    }
    guard layoutMaxPages > 0, layoutMaxBytes > 0 else {
      throw PageTranslationPipelineError.invalidDocument
    }
    self.documentData = documentData
    self.translationService = translationService
    self.extractor = PDFKitTextExtractor()
    self.pageCount = document.pageCount
    self.layoutMaxPages = layoutMaxPages
    self.layoutMaxBytes = layoutMaxBytes
    self.activeSettings = PageTranslationSettings()
    let router = PageTranslationQueueRouter()
    self.router = router
    self.queue = TranslationQueue(pageConcurrency: max(1, pageConcurrency)) { page in
      try await router.run(page: page)
    }
    router.pipeline = self
  }

  deinit {
    for continuation in streams.values { continuation.finish() }
  }

  public func stream(
    pageIndex: Int,
    settings: PageTranslationSettings,
    automaticallySchedule: Bool = true
  ) async -> AsyncStream<PageTranslationState> {
    let streamID = UUID()
    let key = PageStreamKey(page: pageIndex, id: streamID)
    let initial: PageTranslationState
    if pageIndex < 0 || pageIndex >= pageCount {
      initial = PageTranslationState(
        pageIndex: pageIndex,
        status: .error,
        error: PageTranslationPipelineError.invalidPage.localizedDescription
      )
    } else {
      initial = state(for: pageIndex)
    }
    let stream = AsyncStream<PageTranslationState> { continuation in
      continuation.yield(initial)
      self.streams[key] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { await self?.removeStream(key) }
      }
    }
    if automaticallySchedule, pageIndex >= 0, pageIndex < pageCount {
      await schedule(
        settings: settings,
        currentPageIndex: pageIndex,
        visiblePageIndices: [pageIndex]
      )
    }
    return stream
  }

  public func schedule(
    settings: PageTranslationSettings,
    currentPageIndex: Int? = nil,
    visiblePageIndices: [Int] = [],
    aheadPageIndices: [Int] = [],
    direction: Int = 1,
    moving: Bool = false,
    excludedPageIndices: Set<Int> = []
  ) async {
    guard !isClosed else { return }
    activeSettings = settings
    let excluded = Set(excludedPageIndices.filter { (0..<pageCount).contains($0) })
    let context = settings.queueContext
    let current = currentPageIndex.map { $0 + 1 }
    let visible = visiblePageIndices.map { $0 + 1 }
    let ahead = aheadPageIndices.map { $0 + 1 }
    let mode = settings.translationMode
    await queue.schedule(
      totalPages: pageCount,
      currentPage: current,
      mode: mode,
      visiblePages: visible,
      aheadPages: ahead,
      direction: direction,
      moving: moving,
      excludedPages: Set(excluded.map { $0 + 1 }),
      context: context
    )
    let pages = prioritizedTranslationPages(
      mode: mode,
      currentPage: current,
      totalPages: pageCount,
      visiblePages: visible,
      aheadPages: ahead,
      direction: direction,
      moving: moving
    )
    for page in pages where page > 0 && !excluded.contains(page - 1) {
      var value = state(for: page - 1)
      if [.idle, .error, .cancelled].contains(value.status) {
        value.status = .queued
      }
      states[page - 1] = value
      publish(value)
    }
  }

  public func cancel(pageIndex: Int? = nil) async {
    guard !isClosed else { return }
    if let pageIndex {
      await queue.cancel(page: pageIndex + 1)
      if var value = states[pageIndex] {
        value.status = .cancelled
        publish(value)
      }
    } else {
      await queue.cancelAll()
      for page in states.keys {
        guard var value = states[page], value.status != .ready else { continue }
        value.status = .cancelled
        publish(value)
      }
    }
  }

  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    await queue.cancelAll(resetCompleted: true)
    for continuation in streams.values { continuation.finish() }
    streams.removeAll()
    states.removeAll()
    layoutCache.removeAll()
    layoutOrder.removeAll()
    layoutBytes = 0
  }

  public func state(pageIndex: Int) -> PageTranslationState? {
    states[pageIndex]
  }

  public func layoutCacheStats() -> (pages: Int, bytes: Int) {
    (layoutCache.count, layoutBytes)
  }

  public static func shouldSkipTranslation(_ text: String, minimumLength: Int = 2) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf16.count >= max(0, minimumLength) else { return true }
    let scalars = value.unicodeScalars
    let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
    let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
    let mathSymbols = scalars.filter {
      CharacterSet(charactersIn: "=+−-*/^√∑∫≈≠≤≥∞()[]{}<>_%·")
        .contains($0)
    }.count
    if letters == 0 { return true }
    let nonWhitespace = scalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    if nonWhitespace > 0 && Double(digits) / Double(nonWhitespace) >= 0.8 && letters <= 1 {
      return true
    }
    // Formula-only runs may contain a variable name, so require a dominant
    // math alphabet rather than filtering ordinary hyphenated prose.
    let words = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    let hasProseWord = words.contains { word in
      word.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3 &&
        word.unicodeScalars.filter { CharacterSet(charactersIn: "=+−-*/^√∑∫≈≠≤≥∞()[]{}<>_%·").contains($0) }.count == 0
    }
    if !hasProseWord && mathSymbols >= max(3, nonWhitespace / 3) { return true }
    return false
  }

  fileprivate func processQueuedPage(_ oneBasedPage: Int) async throws {
    let pageIndex = oneBasedPage - 1
    guard !isClosed else { throw PageTranslationPipelineError.closed }
    guard pageIndex >= 0, pageIndex < pageCount else {
      throw PageTranslationPipelineError.invalidPage
    }
    do {
      try Task.checkCancellation()
      update(pageIndex: pageIndex, status: .extracting, error: nil)
      let document = try loadDocument()
      guard let page = document.page(at: pageIndex) else {
        throw PageTranslationPipelineError.invalidPage
      }
      let bounds = page.bounds(for: .cropBox)
      let items = try layoutItems(pageIndex: pageIndex, page: page)
      let paragraphs = LayoutEngine.paragraphs(items: items, pageHeight: Double(bounds.height))
      var values = paragraphs.map { paragraph in
        PageTranslationParagraph(
          paragraph: paragraph,
          translation: nil,
          status: Self.shouldSkipTranslation(
            paragraph.text,
            minimumLength: activeSettings.minimumTextLength
          ) ? .skipped : .queued
        )
      }
      update(pageIndex: pageIndex, status: .translating, paragraphs: values, error: nil)
      try await translate(
        pageIndex: pageIndex,
        paragraphs: &values,
        settings: activeSettings
      )
      let hasErrors = values.contains { $0.status == .error }
      update(
        pageIndex: pageIndex,
        status: hasErrors ? .error : .ready,
        paragraphs: values,
        error: values.first(where: { $0.status == .error })?.error
      )
    } catch is CancellationError {
      update(pageIndex: pageIndex, status: .cancelled)
      throw CancellationError()
    } catch {
      update(pageIndex: pageIndex, status: .error, error: error.localizedDescription)
      throw error
    }
  }

  private func loadDocument() throws -> PDFDocument {
    guard let document = PDFDocument(data: documentData) else {
      throw PageTranslationPipelineError.invalidDocument
    }
    return document
  }

  private func layoutItems(pageIndex: Int, page: PDFPage) throws -> [TextItem] {
    if let cached = layoutCache[pageIndex] {
      touchLayout(pageIndex)
      return cached.items
    }
    let items = extractor.extract(page: page, pageNumber: pageIndex + 1)
    let bytes = (try? JSONEncoder().encode(items).count) ?? 0
    guard bytes <= layoutMaxBytes else { return items }
    while layoutCache.count >= layoutMaxPages || layoutBytes + bytes > layoutMaxBytes {
      guard let oldest = layoutOrder.first else { break }
      layoutOrder.removeFirst()
      if let removed = layoutCache.removeValue(forKey: oldest) { layoutBytes -= removed.bytes }
    }
    layoutCache[pageIndex] = LayoutCacheEntry(items: items, bytes: bytes)
    layoutOrder.append(pageIndex)
    layoutBytes += bytes
    return items
  }

  private func touchLayout(_ pageIndex: Int) {
    layoutOrder.removeAll { $0 == pageIndex }
    layoutOrder.append(pageIndex)
  }

  private func translate(
    pageIndex: Int,
    paragraphs: inout [PageTranslationParagraph],
    settings: PageTranslationSettings
  ) async throws {
    let candidates = paragraphs.indices.filter { paragraphs[$0].status == .queued }
    guard !candidates.isEmpty else { return }
    let limit = max(1, min(12, settings.paragraphConcurrency))
    var next = 0
    await withTaskGroup(of: (Int, Result<TranslationResult?, Error>).self) { group in
      func add(_ index: Int) {
        let paragraph = paragraphs[index].paragraph
        group.addTask { [translationService] in
          do {
            let result = try await translationService.translate(
              TranslationRequest(
                text: paragraph.text,
                language: settings.targetLanguage,
                sourceLanguage: settings.sourceLanguage,
                glossary: settings.glossary,
                concurrency: settings.paragraphConcurrency,
                reuseTranslations: settings.reuseTranslations,
                forceRetranslation: settings.forceRetranslation,
                cacheScope: settings.cacheScope.isEmpty ? settings.documentID : settings.cacheScope
              )
            )
            return (index, .success(result))
          } catch {
            return (index, .failure(error))
          }
        }
      }
      while next < min(limit, candidates.count) {
        add(candidates[next])
        next += 1
      }
      while let (index, result) = await group.next() {
        switch result {
        case let .success(value):
          if let value, !value.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paragraphs[index].translation = value.translation
            paragraphs[index].status = .ready
            paragraphs[index].error = nil
          } else {
            paragraphs[index].status = .error
            paragraphs[index].error = TranslationServiceError.provider("Empty translation").localizedDescription
          }
        case let .failure(error):
          paragraphs[index].status = .error
          paragraphs[index].error = error.localizedDescription
        }
        update(pageIndex: pageIndex, status: .translating, paragraphs: paragraphs, error: nil)
        if next < candidates.count {
          add(candidates[next])
          next += 1
        }
      }
    }
  }

  private func state(for pageIndex: Int) -> PageTranslationState {
    states[pageIndex] ?? PageTranslationState(pageIndex: pageIndex)
  }

  private func update(
    pageIndex: Int,
    status: PageTranslationStatus,
    paragraphs: [PageTranslationParagraph]? = nil,
    error: String? = nil
  ) {
    var value = state(for: pageIndex)
    value.status = status
    if let paragraphs { value.paragraphs = paragraphs }
    value.error = error
    states[pageIndex] = value
    publish(value)
  }

  private func publish(_ value: PageTranslationState) {
    for (key, continuation) in streams where key.page == value.pageIndex {
      continuation.yield(value)
    }
  }

  private func removeStream(_ key: PageStreamKey) {
    streams.removeValue(forKey: key)
  }
}
