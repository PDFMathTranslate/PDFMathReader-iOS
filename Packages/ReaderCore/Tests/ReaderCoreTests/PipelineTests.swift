import Foundation
import PDFKit
import Testing

@testable import ReaderCore

private final class PipelineFakeProvider: TranslationProvider, @unchecked Sendable {
  let id = "pipeline-test"
  let model = "pipeline-test"
  let cacheIdentity: [String: String]? = ["service": "pipeline-test"]
  private let lock = NSLock()
  private var recordedTexts: [String] = []

  var calls: [String] {
    lock.withLock { recordedTexts }
  }

  func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    let source = request.messages.last?.content ?? ""
    lock.withLock { recordedTexts.append(source) }
    let body: [String: Any] = [
      "choices": [[
        "message": ["content": "Translated: (source)"],
      ]],
    ]
    return TranslationProviderResponse(
      statusCode: 200,
      data: try JSONSerialization.data(withJSONObject: body)
    )
  }
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
