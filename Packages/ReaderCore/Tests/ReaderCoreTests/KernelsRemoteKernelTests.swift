import Foundation
import CryptoKit
import PDFKit
import Testing

@testable import ReaderCore

private final class SerializationTrackingPDFDocument: PDFDocument {
  var serializationCount = 0

  override func dataRepresentation() -> Data? {
    serializationCount += 1
    return super.dataRepresentation()
  }
}

private struct MockHTTPResponse: Sendable {
  var statusCode: Int = 200
  var headers: [String: String] = [:]
  var body = Data()
}

private final class MockHandlerBox: @unchecked Sendable {
  var value: (@Sendable (URLRequest) -> MockHTTPResponse)?
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static let handlerBox = MockHandlerBox()

  static func install(_ handler: @escaping @Sendable (URLRequest) -> MockHTTPResponse) {
    lock.lock()
    handlerBox.value = handler
    lock.unlock()
  }

  static func uninstall() {
    lock.lock()
    handlerBox.value = nil
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.handlerBox.value
    Self.lock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    let response = handler(request)
    let http = HTTPURLResponse(
      url: request.url!,
      statusCode: response.statusCode,
      httpVersion: nil,
      headerFields: response.headers
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var uploads: [[String: Any]] = []
  private var counters: [String: Int] = [:]

  func record(_ path: String) {
    lock.lock()
    values.append(path)
    counters[path, default: 0] += 1
    lock.unlock()
  }

  func recordUpload(_ value: [String: Any]) {
    lock.lock()
    uploads.append(value)
    lock.unlock()
  }

  func count(_ path: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counters[path, default: 0]
  }

  func firstUpload() -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return uploads.first
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RemoteKernelProgress] = []

  func append(_ value: RemoteKernelProgress) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func snapshot() -> [RemoteKernelProgress] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private func testSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func requestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
  defer { buffer.deallocate() }
  var body = Data()
  while stream.hasBytesAvailable {
    let count = stream.read(buffer, maxLength: 4_096)
    guard count > 0 else { break }
    body.append(buffer, count: count)
  }
  return body
}

private func testPDF(pageCount: Int = 2) -> Data {
  let document = PDFDocument()
  for index in 0..<pageCount {
    document.insert(PDFPage(), at: index)
  }
  return document.dataRepresentation()!
}

private func legacyRemoteCacheKey(
  sourceData: Data,
  pageNumber: Int,
  serverURL: String,
  language: String,
  engine: String,
  cacheScope: String
) throws -> String {
  let descriptor: [String: Any] = [
    "remote": 1,
    "id": engine,
    "url": serverURL,
    "service": "",
    "page": pageNumber,
    "language": language,
    "sourceLanguage": "English",
    "layoutSchema": 3,
    "cacheScope": cacheScope,
  ]
  let descriptorData = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
  let text = String(decoding: sourceData, as: UTF8.self)
  let expression = try NSRegularExpression(pattern: #"/ID\s*\[\s*<[^>]*>\s*<[^>]*>\s*\]"#)
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  let normalized = expression.stringByReplacingMatches(
    in: text, range: range, withTemplate: "/ID []"
  )
  var input = Data(normalized.utf8)
  input.append(descriptorData)
  return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private func installSuccessfulTranslationHandler(
  recorder: RequestRecorder,
  translatedPDF: Data = testPDF(pageCount: 1),
  submissionDelay: TimeInterval = 0
) {
  MockURLProtocol.install { request in
    let path = request.url?.path ?? ""
    recorder.record(path)
    if path == "/translate" {
      if submissionDelay > 0 {
        Thread.sleep(forTimeInterval: submissionDelay)
      }
      return MockHTTPResponse(
        body: Data(#"{"status":"accepted","fileList":["result.mono.pdf"]}"#.utf8)
      )
    }
    if path == "/translatedFile/result.mono.pdf" {
      return MockHTTPResponse(body: translatedPDF)
    }
    return MockHTTPResponse(statusCode: 404)
  }
}

@Suite(.serialized)
struct RemoteKernelClientTests {
  init() {
    MockURLProtocol.uninstall()
  }

  @Test
  func normalizesDesktopURLCases() {
    #expect(normalizeRemoteKernelUrl(" http://host:8890/ ") == "http://host:8890")
    #expect(normalizeRemoteKernelUrl("https://host/base/?x=1#y") == "https://host/base")
    #expect(normalizeRemoteKernelUrl("") == "")
    #expect(normalizeRemoteKernelUrl("ftp://host") == "")
    #expect(normalizeRemoteKernelUrl("host:8890") == "")
    #expect(normalizeRemoteKernelUrl("http://user:pw@host") == "")
    #expect(normalizeRemoteKernelUrl(nil) == "")
  }

  @Test
  func healthAcceptsOnlyOKAndCachesWithinTTL() async {
    let recorder = RequestRecorder()
    MockURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      if request.url?.host == "unhealthy.test" {
        return MockHTTPResponse(body: Data(#"{"status":"starting"}"#.utf8))
      }
      return MockHTTPResponse(body: Data(#"{"status":"ok","version":"2.4.3"}"#.utf8))
    }
    let session = testSession()
    let client = RemoteKernelClient(
      session: session,
      configuration: RemoteKernelConfiguration(healthTTL: 60)
    )
    let first = await client.health("https://healthy.test/")
    let second = await client.health("https://healthy.test")
    let odd = await client.health("https://unhealthy.test")
    #expect(first == RemoteKernelHealth(ok: true, version: "2.4.3"))
    #expect(second == first)
    #expect(!odd.ok)
    #expect(recorder.count("/health") == 2)
  }

  @Test
  func completesUploadPollingDownloadAndReportsMonotonicProgress() async {
    let recorder = RequestRecorder()
    MockURLProtocol.install { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path == "/health" {
        return MockHTTPResponse(body: Data(#"{"status":"ok"}"#.utf8))
      }
      if path == "/translate" {
        let body = try! JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        recorder.recordUpload(body)
        return MockHTTPResponse(body: Data(#"{"status":"accepted","taskId":"task-1"}"#.utf8))
      }
      if path == "/api/tasks" {
        let count = recorder.count(path)
        if count == 1 {
          return MockHTTPResponse(body: Data(#"{"tasks":[{"taskId":"task-1","finished":false,"status":"running","progress":0,"message":"Typesetting"}]}"#.utf8))
        }
        return MockHTTPResponse(body: Data(#"{"tasks":[]}"#.utf8))
      }
      if path == "/api/history" {
        let body = #"{"history":[{"taskId":"task-1","finished":true,"status":"success","fileList":["result.mono.pdf"]}]}"#
        return MockHTTPResponse(body: Data(body.utf8))
      }
      if path.hasPrefix("/translatedFile/") {
        return MockHTTPResponse(body: testPDF(pageCount: 2))
      }
      return MockHTTPResponse(statusCode: 404)
    }
    let client = RemoteKernelClient(
      session: testSession(),
      configuration: RemoteKernelConfiguration(pollInterval: 0.001)
    )
    let progress = ProgressRecorder()
    let result = try! await client.translatePage(
      url: "https://kernel.test/",
      bytes: testPDF(pageCount: 3),
      page: 2,
      language: "zh-CN",
      sourceLanguage: "en",
      service: "siliconflowfree",
      threads: 3,
      onProgress: { progress.append($0) }
    )
    let upload = recorder.firstUpload()!
    let uploaded = PDFDocument(data: Data(base64Encoded: upload["fileContent"] as! String)!)
    #expect((upload["engine"] as? String) == "pdf2zh_next")
    #expect((upload["targetLang"] as? String) == "zh-CN")
    #expect((upload["next_service"] as? String) == "siliconflowfree")
    #expect(uploaded?.pageCount == 1)
    #expect(PDFDocument(data: result)?.pageCount == 1)
    let values = progress.snapshot()
    #expect(values.count >= 2)
    #expect(values.map(\.percent) == values.map(\.percent).sorted())
    #expect(values.allSatisfy { $0.percent < 100 })
    #expect(values.last?.stage == "Typesetting")
  }

  @Test
  func stopsAfterPollFailures() async {
    MockURLProtocol.install { request in
      switch request.url?.path {
      case "/health":
        return MockHTTPResponse(body: Data(#"{"status":"ok"}"#.utf8))
      case "/translate":
        return MockHTTPResponse(body: Data(#"{"status":"accepted","taskId":"task-1"}"#.utf8))
      case "/api/tasks", "/api/history":
        return MockHTTPResponse(statusCode: 503)
      default:
        return MockHTTPResponse(statusCode: 404)
      }
    }
    let client = RemoteKernelClient(
      session: testSession(),
      configuration: RemoteKernelConfiguration(
        pollInterval: 0.001,
        pollTimeout: 0.01,
        maxPollFailures: 5
      )
    )
    do {
      _ = try await client.translatePage(
        url: "https://kernel.test",
        bytes: testPDF(pageCount: 1),
        page: 1,
        language: "zh"
      )
      Issue.record("expected polling to stop after repeated failures")
    } catch {
      #expect(error as? RemoteKernelError == .stoppedResponding)
    }
  }

  @Test
  func rejectsOversizedDownloadBeforeAcceptingIt() async {
    MockURLProtocol.install { request in
      switch request.url?.path {
      case "/translate":
        return MockHTTPResponse(body: Data(#"{"status":"accepted","fileList":["result.mono.pdf"]}"#.utf8))
      case "/translatedFile/result.mono.pdf":
        return MockHTTPResponse(
          headers: ["Content-Length": "11"],
          body: testPDF(pageCount: 1)
        )
      default:
        return MockHTTPResponse(statusCode: 404)
      }
    }
    let client = RemoteKernelClient(
      session: testSession(),
      configuration: RemoteKernelConfiguration(maxResponseBytes: 10)
    )
    do {
      _ = try await client.translatePage(
        url: "https://kernel.test",
        bytes: testPDF(pageCount: 1),
        page: 1,
        language: "zh"
      )
      Issue.record("expected oversized response rejection")
    } catch {
      #expect(error as? RemoteKernelError == .resultTooLarge)
    }
  }

  @Test
  func honorsTaskCancellationBeforeNetworkWork() async {
    let recorder = RequestRecorder()
    MockURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      return MockHTTPResponse(statusCode: 500)
    }
    let client = RemoteKernelClient(session: testSession())
    let task = Task {
      try await client.translatePage(
        url: "https://kernel.test",
        bytes: testPDF(pageCount: 1),
        page: 1,
        language: "zh"
      )
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("expected cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("unexpected cancellation error: \(error)")
    }
    #expect(recorder.count("/translate") == 0)
  }

  @Test
  func cancelsAnInFlightPollingJob() async {
    let recorder = RequestRecorder()
    MockURLProtocol.install { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      switch path {
      case "/translate":
        return MockHTTPResponse(body: Data(#"{"status":"accepted","taskId":"task-1"}"#.utf8))
      case "/api/tasks":
        return MockHTTPResponse(
          body: Data(#"{"tasks":[{"taskId":"task-1","finished":false,"status":"running"}]}"#.utf8)
        )
      case "/api/history":
        return MockHTTPResponse(body: Data(#"{"history":[]}"#.utf8))
      default:
        return MockHTTPResponse(statusCode: 404)
      }
    }

    let client = RemoteKernelClient(
      session: testSession(),
      configuration: RemoteKernelConfiguration(pollInterval: 10)
    )
    let operation = Task {
      try await client.translatePage(
        url: "https://kernel.test",
        bytes: testPDF(pageCount: 1),
        page: 1,
        language: "zh"
      )
    }
    for _ in 0..<100 where recorder.count("/api/tasks") == 0 {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    operation.cancel()
    do {
      _ = try await operation.value
      Issue.record("expected in-flight cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("unexpected cancellation error: \(error)")
    }
  }

  @Test
  @MainActor
  func mathPageTranslatorCachesByPageAndKernelConfiguration() async throws {
    let recorder = RequestRecorder()
    MockURLProtocol.install { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      if path == "/translate" {
        return MockHTTPResponse(
          body: Data(#"{"status":"accepted","fileList":["result.mono.pdf"]}"#.utf8)
        )
      }
      if path == "/translatedFile/result.mono.pdf" {
        return MockHTTPResponse(body: testPDF(pageCount: 1))
      }
      return MockHTTPResponse(statusCode: 404)
    }

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let client = RemoteKernelClient(session: testSession())
    let translator = MathPageTranslator(client: client, cacheDirectory: cacheDirectory)
    let document = PDFDocument(data: testPDF(pageCount: 2))!

    let first = try await translator.translatePage(
      document: document,
      pageIndex: 1,
      serverURL: "https://kernel.test/",
      language: "zh-CN",
      engine: "pdf_math_precise"
    )
    let second = try await translator.translatePage(
      document: document,
      pageIndex: 1,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise"
    )

    #expect(first == second)
    #expect(recorder.count("/translate") == 1)
    #expect(PDFDocument(data: second)?.pageCount == 1)
    #expect(FileManager.default.fileExists(atPath: cacheDirectory.path))
  }

  @Test
  @MainActor
  func mathPageTranslatorStableDocumentScopeReusesAcrossRecreatedDocuments() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let firstDocument = PDFDocument(data: testPDF(pageCount: 2))!
    let secondDocument = PDFDocument(data: testPDF(pageCount: 2))!

    let first = try await translator.translatePage(
      document: firstDocument,
      pageIndex: 1,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: "documenthash:stable-document"
    )
    let second = try await translator.translatePage(
      document: secondDocument,
      pageIndex: 1,
      serverURL: "https://kernel.test/",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: "documenthash:stable-document"
    )

    #expect(first == second)
    #expect(recorder.count("/translate") == 1)
  }

  @Test
  @MainActor
  func mathPageTranslatorCompatibleReuseRequiresOptIn() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: testPDF(pageCount: 1))!

    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel-a.test",
      language: "zh-CN",
      service: "service-a",
      engine: "pdf_math_precise"
    )
    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel-b.test",
      language: "zh-CN",
      service: "service-b",
      engine: "pdf_math_precise",
      reuseTranslations: false
    )
    let reused = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel-c.test",
      language: "zh-CN",
      service: "service-c",
      engine: "pdf_math_precise",
      reuseTranslations: true
    )

    #expect(PDFDocument(data: reused)?.pageCount == 1)
    #expect(recorder.count("/translate") == 2)
  }

  @Test
  @MainActor
  func mathPageTranslatorCacheIsolatedByLanguageEngineAndDocumentScope() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: testPDF(pageCount: 1))!

    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: "documenthash:scope-a"
    )
    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "ja",
      engine: "pdf_math_precise",
      cacheScope: "documenthash:scope-a"
    )
    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_fast",
      cacheScope: "documenthash:scope-a"
    )
    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: "documenthash:scope-b"
    )

    #expect(recorder.count("/translate") == 4)
  }

  @Test
  @MainActor
  func mathPageTranslatorCacheOnlyMissDoesNotUseNetwork() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: testPDF(pageCount: 1))!

    do {
      _ = try await translator.translatePage(
        document: document,
        pageIndex: 0,
        serverURL: "https://kernel.test",
        language: "zh-CN",
        engine: "pdf_math_precise",
        cacheOnly: true
      )
      Issue.record("expected a cache-only miss")
    } catch {
      #expect(error as? MathPageTranslatorError == .cacheMiss)
    }
    #expect(recorder.count("/translate") == 0)
  }

  @Test
  @MainActor
  func scopedCacheMissWithoutLegacyFilesDoesNotSerializeBook() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A populated modern cache directory must not count as a legacy entry.
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("documents"), withIntermediateDirectories: true
    )
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()), cacheDirectory: directory
    )
    let document = SerializationTrackingPDFDocument(data: testPDF(pageCount: 2))!
    for page in 0..<2 {
      do {
        _ = try await translator.translatePage(
          document: document, pageIndex: page, serverURL: "https://kernel.test",
          language: "zh-CN", cacheScope: "book-with-modern-cache", cacheOnly: true
        )
        Issue.record("expected a cache-only miss")
      } catch {
        #expect(error as? MathPageTranslatorError == .cacheMiss)
      }
    }
    #expect(document.serializationCount == 0)
  }

  @Test
  @MainActor
  func scopedLegacyLookupWithUnrelatedRootPDFDoesNotSerializeURLBackedDocument() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-legacy-\(UUID().uuidString)", isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.pdf")
    let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try testPDF(pageCount: 2).write(to: sourceURL)
    // Keep an unrelated root PDF present so this exercises the legacy lookup
    // branch that previously serialized the live book before checking its key.
    try testPDF(pageCount: 1).write(to: cacheDirectory.appendingPathComponent("unrelated.pdf"))

    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()), cacheDirectory: cacheDirectory
    )
    for page in 0..<2 {
      let document = SerializationTrackingPDFDocument(url: sourceURL)!
      do {
        _ = try await translator.translatePage(
          document: document,
          pageIndex: page,
          serverURL: "https://kernel.test",
          language: "zh-CN",
          cacheScope: "documenthash:url-backed-source",
          cacheOnly: true
        )
        Issue.record("expected a cache-only miss")
      } catch {
        #expect(error as? MathPageTranslatorError == .cacheMiss)
      }

      #expect(document.serializationCount == 0)
    }
  }

  @Test
  @MainActor
  func scopedLegacyLookupMigratesURLBackedDocument() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-legacy-hit-\(UUID().uuidString)", isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.pdf")
    let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try testPDF(pageCount: 2).write(to: sourceURL)

    let sourceDocument = PDFDocument(url: sourceURL)!
    let cacheScope = "documenthash:url-backed-source"
    let legacyKey = try legacyRemoteCacheKey(
      sourceData: sourceDocument.dataRepresentation()!,
      pageNumber: 1,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: cacheScope
    )
    try testPDF(pageCount: 1).write(
      to: cacheDirectory.appendingPathComponent(legacyKey).appendingPathExtension("pdf")
    )

    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()), cacheDirectory: cacheDirectory
    )
    let document = SerializationTrackingPDFDocument(url: sourceURL)!
    let result = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      cacheScope: cacheScope,
      cacheOnly: true
    )

    #expect(PDFDocument(data: result)?.pageCount == 1)
    #expect(document.serializationCount == 0)
  }

  @Test
  @MainActor
  func scopedCacheURLDoesNotSerializeURLBackedDocument() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-url-\(UUID().uuidString)", isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.pdf")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try testPDF(pageCount: 1).write(to: sourceURL)

    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()), cacheDirectory: root
    )
    let document = SerializationTrackingPDFDocument(url: sourceURL)!
    _ = try translator.cacheURL(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      cacheScope: "documenthash:url-backed-source"
    )

    #expect(document.serializationCount == 0)
  }

  @Test
  @MainActor
  func mathPageTranslatorForceRetranslationIssuesFreshRequest() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: testPDF(pageCount: 1))!

    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise"
    )
    _ = try await translator.translatePage(
      document: document,
      pageIndex: 0,
      serverURL: "https://kernel.test",
      language: "zh-CN",
      engine: "pdf_math_precise",
      forceRetranslation: true
    )

    #expect(recorder.count("/translate") == 2)
  }

  @Test
  @MainActor
  func mathPageTranslatorsCoalesceConcurrentRequestsForSharedCache() async throws {
    let recorder = RequestRecorder()
    installSuccessfulTranslationHandler(recorder: recorder, submissionDelay: 0.1)

    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translatorA = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let translatorB = MathPageTranslator(
      client: RemoteKernelClient(session: testSession()),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: testPDF(pageCount: 1))!

    let first = Task { @MainActor in
      try await translatorA.translatePage(
        document: document,
        pageIndex: 0,
        serverURL: "https://kernel.test",
        language: "zh-CN",
        engine: "pdf_math_precise"
      )
    }
    let second = Task { @MainActor in
      try await translatorB.translatePage(
        document: document,
        pageIndex: 0,
        serverURL: "https://kernel.test",
        language: "zh-CN",
        engine: "pdf_math_precise"
      )
    }
    let results = try await (first.value, second.value)

    #expect(results.0 == results.1)
    #expect(recorder.count("/translate") == 1)
  }
}
