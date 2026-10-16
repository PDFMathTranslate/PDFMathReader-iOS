import Foundation
import PDFKit
import Testing

@testable import ReaderCore

private final class PipelineFakeProvider: TranslationProvider, @unchecked Sendable {
  let id = "pipeline-test"
  let model = "pipeline-test"
  let cacheIdentity: [String: String]? = ["service": "pipeline-test"]
  private let delayNanoseconds: UInt64
  private let failingCalls: Set<Int>
  private let lock = NSLock()
  private var recordedTexts: [String] = []
  private var callNumber = 0

  init(delayNanoseconds: UInt64 = 0, failingCalls: Set<Int> = []) {
    self.delayNanoseconds = delayNanoseconds
    self.failingCalls = failingCalls
  }

  var calls: [String] {
    lock.withLock { recordedTexts }
  }

  func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    let source = request.messages.last?.content ?? ""
    let shouldFail = lock.withLock {
      callNumber += 1
      recordedTexts.append(source)
      return failingCalls.contains(callNumber)
    }
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    if shouldFail {
      throw PipelineFakeProviderError()
    }
    let body: [String: Any] = [
      "choices": [[
        "message": ["content": "Translated: \(source)"],
      ]],
    ]
    return TranslationProviderResponse(
      statusCode: 200,
      data: try JSONSerialization.data(withJSONObject: body)
    )
  }
}

private struct PipelineFakeProviderError: Error, LocalizedError, Sendable {
  var errorDescription: String? { "Pipeline fake provider failed" }
}

private func pipelineFixtureData() throws -> Data {
  guard let pdfURL = Bundle.module.url(forResource: "Fixtures/layout/sample.pdf", withExtension: nil) else {
    throw PipelineFakeProviderError()
  }
  return try Data(contentsOf: pdfURL)
}

private func waitForProviderCalls(
  _ provider: PipelineFakeProvider,
  count: Int,
  attempts: Int = 200
) async throws -> Bool {
  for _ in 0..<attempts {
    if provider.calls.count >= count { return true }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
  return false
}

@Test
func pageTranslationPipelinePublishesIncrementalParagraphResults() async throws {
  guard let pdfURL = Bundle.module.url(forResource: "Fixtures/layout/sample.pdf", withExtension: nil) else {
    Issue.record("Missing layout fixture PDF")
    return
  }
  let data = try Data(contentsOf: pdfURL)
  let provider = PipelineFakeProvider()
  let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-pipeline-\(UUID().uuidString)", isDirectory: true)
  let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
  let pipeline = try PageTranslationPipeline(
    documentData: data,
    translationService: service,
    pageConcurrency: 1,
    layoutMaxPages: 1,
    layoutMaxBytes: 1_000_000
  )
  let settings = PageTranslationSettings(
    documentID: "fixture",
    sourceLanguage: "en",
    targetLanguage: "fr",
    paragraphConcurrency: 2,
    translationMode: .reading
  )

  let stream = await pipeline.stream(pageIndex: 0, settings: settings)
  var states: [PageTranslationState] = []
  for await state in stream {
    states.append(state)
    if state.status == .ready || state.status == .error { break }
  }

  #expect(states.contains(where: { $0.status == .extracting }))
  #expect(states.contains(where: { $0.status == .translating }))
  let final = states.last
  #expect(final?.status == .ready)
  #expect(final?.paragraphs.isEmpty == false)
  #expect(final?.translatedCount ?? 0 > 0)
  #expect(provider.calls.isEmpty == false)
  let cacheStats = await pipeline.layoutCacheStats()
  #expect(cacheStats.pages == 1)
  await pipeline.close()
}

@Test
func pageTranslationPipelineSkipsNonProseParagraphs() {
  #expect(PageTranslationPipeline.shouldSkipTranslation("12345"))
  #expect(PageTranslationPipeline.shouldSkipTranslation("x^2 + y^2 = z^2"))
  #expect(PageTranslationPipeline.shouldSkipTranslation("A"))
  #expect(!PageTranslationPipeline.shouldSkipTranslation("A short sentence."))
}

@Test
func pageTranslationPipelineRetriesOnlyFailedParagraphs() async throws {
  let data = try pipelineFixtureData()
  let provider = PipelineFakeProvider(failingCalls: [2])
  let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-pipeline-retry-\(UUID().uuidString)", isDirectory: true)
  let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
  let pipeline = try PageTranslationPipeline(
    documentData: data,
    translationService: service,
    pageConcurrency: 1,
    layoutMaxPages: 1,
    layoutMaxBytes: 1_000_000
  )
  let settings = PageTranslationSettings(
    documentID: "fixture-retry",
    sourceLanguage: "en",
    targetLanguage: "fr",
    paragraphConcurrency: 1,
    translationMode: .reading
  )

  let stream = await pipeline.stream(pageIndex: 0, settings: settings)
  var iterator = stream.makeAsyncIterator()
  var failedState: PageTranslationState?
  while let state = await iterator.next() {
    if state.status == .error {
      failedState = state
      break
    }
  }

  #expect(failedState?.paragraphs.filter { $0.status == .ready }.count == 1)
  #expect(failedState?.paragraphs.filter { $0.status == .error }.count == 1)
  let callsAfterFailure = provider.calls.count

  await pipeline.schedule(
    settings: settings,
    currentPageIndex: 0,
    visiblePageIndices: [0]
  )

  var retriedState: PageTranslationState?
  while let state = await iterator.next() {
    if state.status == .ready || state.status == .error {
      retriedState = state
      break
    }
  }

  #expect(retriedState?.status == .ready)
  #expect(provider.calls.count == callsAfterFailure + 1)
  #expect(retriedState?.paragraphs.allSatisfy { $0.status == .ready || $0.status == .skipped } == true)
  await pipeline.close()
}

@Test
func pageTranslationPipelineCancellationStopsNewParagraphRequests() async throws {
  let data = try pipelineFixtureData()
  let provider = PipelineFakeProvider(delayNanoseconds: 500_000_000)
  let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-pipeline-cancel-\(UUID().uuidString)", isDirectory: true)
  let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
  let pipeline = try PageTranslationPipeline(
    documentData: data,
    translationService: service,
    pageConcurrency: 1,
    layoutMaxPages: 1,
    layoutMaxBytes: 1_000_000
  )
  let settings = PageTranslationSettings(
    documentID: "fixture-cancel",
    sourceLanguage: "en",
    targetLanguage: "fr",
    paragraphConcurrency: 1,
    translationMode: .reading
  )

  let stream = await pipeline.stream(pageIndex: 0, settings: settings)
  var iterator = stream.makeAsyncIterator()
  #expect(try await waitForProviderCalls(provider, count: 1))
  await pipeline.cancel(pageIndex: 0)

  var statuses: [PageTranslationStatus] = []
  for _ in 0..<20 {
    guard let state = await iterator.next() else { break }
    statuses.append(state.status)
    if state.status == .cancelled { break }
  }
  try await Task.sleep(nanoseconds: 50_000_000)

  #expect(statuses.contains(.cancelled))
  #expect(!statuses.contains(.ready))
  #expect(!statuses.contains(.error))
  #expect(provider.calls.count == 1)
  #expect(await pipeline.state(pageIndex: 0)?.status == .cancelled)
  await pipeline.close()
}

@Test
func pageTranslationPipelineCloseDoesNotRepopulateCancelledState() async throws {
  let data = try pipelineFixtureData()
  let provider = PipelineFakeProvider(delayNanoseconds: 500_000_000)
  let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-pipeline-close-\(UUID().uuidString)", isDirectory: true)
  let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
  let pipeline = try PageTranslationPipeline(
    documentData: data,
    translationService: service,
    pageConcurrency: 1,
    layoutMaxPages: 1,
    layoutMaxBytes: 1_000_000
  )
  let settings = PageTranslationSettings(
    documentID: "fixture-close",
    sourceLanguage: "en",
    targetLanguage: "fr",
    paragraphConcurrency: 1,
    translationMode: .reading
  )

  _ = await pipeline.stream(pageIndex: 0, settings: settings)
  #expect(try await waitForProviderCalls(provider, count: 1))
  await pipeline.close()
  #expect(await pipeline.state(pageIndex: 0) == nil)
  try await Task.sleep(nanoseconds: 50_000_000)
  #expect(await pipeline.state(pageIndex: 0) == nil)
}
