import Foundation
import Testing

@testable import ReaderCore

private struct TranslationMockHTTPResponse: Sendable {
  var statusCode: Int = 200
  var headers: [String: String] = [:]
  var body = Data()
  var delayNanoseconds: UInt64 = 0
  var cancellationProbe: TranslationCancellationProbe?
}

private final class TranslationCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func waitUntilCancelled(timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if isCancelled { return true }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return isCancelled
  }
}

private final class TranslationRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func record(_ path: String) {
    lock.lock()
    counts[path, default: 0] += 1
    lock.unlock()
  }

  func count(_ path: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[path, default: 0]
  }
}

private final class TranslationURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> TranslationMockHTTPResponse)?
  private var cancellationProbe: TranslationCancellationProbe?

  static func install(_ handler: @escaping @Sendable (URLRequest) -> TranslationMockHTTPResponse) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  static func uninstall() {
    lock.lock()
    handler = nil
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.handler
    Self.lock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    let response = handler(request)
    cancellationProbe = response.cancellationProbe
    if let probe = response.cancellationProbe {
      DispatchQueue.global().async { [weak self] in
        guard let self else { return }
        _ = probe.waitUntilCancelled()
        self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
      }
      return
    }
    if response.delayNanoseconds > 0 {
      Thread.sleep(forTimeInterval: Double(response.delayNanoseconds) / 1_000_000_000)
    }
    guard let url = request.url,
          let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
          ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    cancellationProbe?.cancel()
  }
}

private func translationTestSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TranslationURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func openAIResponse(_ content: String, statusCode: Int = 200) -> TranslationMockHTTPResponse {
  let body: Data
  if statusCode == 200 {
    body = try! JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["role": "assistant", "content": content]]],
    ])
  } else {
    body = Data(#"{"error":"mock"}"#.utf8)
  }
  return TranslationMockHTTPResponse(statusCode: statusCode, body: body)
}

private func translationCacheDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-translation-(UUID().uuidString)", isDirectory: true)
}

@Suite(.serialized)
struct TranslationServiceTests {
  init() {
    TranslationURLProtocol.uninstall()
  }

  @Test
  func successfulTranslationIsReturnedAndPersisted() async throws {
    let recorder = TranslationRequestRecorder()
    TranslationURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      return openAIResponse("Bonjour")
    }
    let cacheDirectory = translationCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let provider = try OpenAICompatibleProvider(
      baseURL: URL(string: "https://example.test/v1")!,
      apiKey: "test-key",
      session: translationTestSession()
    )
    let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)

    let result = try await service.translate(
      TranslationRequest(text: "Hello", language: "French")
    )
    #expect(result?.translation == "Bonjour")
    #expect(result?.cached == false)
    #expect(recorder.count("/v1/chat/completions") == 1)
  }

  @Test
  func emptyResponseIsNotCached() async throws {
    let recorder = TranslationRequestRecorder()
    TranslationURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      if recorder.count("/v1/chat/completions") == 1 {
        return openAIResponse("")
      }
      return openAIResponse("Bonjour")
    }
    let cacheDirectory = translationCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let provider = try OpenAICompatibleProvider(
      baseURL: URL(string: "https://example.test/v1")!,
      apiKey: "test-key",
      session: translationTestSession()
    )
    let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
    let request = TranslationRequest(text: "Hello", language: "French")

    do {
      _ = try await service.translate(request)
      Issue.record("expected the empty response to fail")
    } catch {
      #expect(error as? TranslationServiceError == .provider("Empty translation"))
    }
    let second = try await service.translate(request)
    #expect(second?.translation == "Bonjour")
    #expect(recorder.count("/v1/chat/completions") == 2)
  }

  @Test
  func cacheHitAvoidsNetwork() async throws {
    let recorder = TranslationRequestRecorder()
    TranslationURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      return openAIResponse("Bonjour")
    }
    let cacheDirectory = translationCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let provider = try OpenAICompatibleProvider(
      baseURL: URL(string: "https://example.test/v1")!,
      apiKey: "test-key",
      session: translationTestSession()
    )
    let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
    let request = TranslationRequest(text: "Hello", language: "French")

    _ = try await service.translate(request)
    let cached = try await service.translate(request)
    #expect(cached?.translation == "Bonjour")
    #expect(cached?.cached == true)
    #expect(recorder.count("/v1/chat/completions") == 1)
  }

  @Test
  func concurrentIdenticalRequestsShareOneNetworkCall() async throws {
    let recorder = TranslationRequestRecorder()
    TranslationURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      return TranslationMockHTTPResponse(
        body: try! JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["role": "assistant", "content": "Bonjour"]]],
        ]),
        delayNanoseconds: 150_000_000
      )
    }
    let cacheDirectory = translationCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let provider = try OpenAICompatibleProvider(
      baseURL: URL(string: "https://example.test/v1")!,
      apiKey: "test-key",
      session: translationTestSession()
    )
    let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
    let request = TranslationRequest(text: "Hello", language: "French")
    let first = Task { try await service.translate(request) }
    let second = Task { try await service.translate(request) }
    let firstResult = try await first.value
    let secondResult = try await second.value
    #expect(firstResult?.translation == "Bonjour")
    #expect(secondResult?.translation == "Bonjour")
    #expect(recorder.count("/v1/chat/completions") == 1)
  }

  @Test
  func freeProxyRetries429AndStripsThinkBlock() async throws {
    let recorder = TranslationRequestRecorder()
    TranslationURLProtocol.install { request in
      let path = request.url?.path ?? ""
      recorder.record(path)
      switch path {
      case "/chatproxy/check":
        return TranslationMockHTTPResponse(body: Data(#"{"status":"ok"}"#.utf8))
      case "/chatproxy/config":
        return TranslationMockHTTPResponse(body: Data(#"{"status":"ok","qps":100}"#.utf8))
      case "/chatproxy":
        if recorder.count("/chatproxy") == 1 {
          return TranslationMockHTTPResponse(statusCode: 429, body: Data(#"{"error":"busy"}"#.utf8))
        }
        return TranslationMockHTTPResponse(
          body: Data(#"{"content":"<think>internal</think>\n\n  你好  "}"#.utf8)
        )
      default:
        return TranslationMockHTTPResponse(statusCode: 404)
      }
    }
    let provider = SiliconFlowFreeProvider(
      language: "Simplified Chinese",
      session: translationTestSession(),
      endpoints: [URL(string: "https://free.example/chatproxy")!],
      retryDelay: { _ in 0 }
    )
    let response = try await provider.complete(
      TranslationProviderRequest(messages: [TranslationMessage(content: "Hello")])
    )
    #expect(response.translationContent() == "你好")
    #expect(recorder.count("/chatproxy") == 2)
    #expect(recorder.count("/chatproxy/check") == 1)
    #expect(recorder.count("/chatproxy/config") == 1)
  }

  @Test
  func cancellationCancelsTheUnderlyingURLProtocolRequest() async throws {
    let recorder = TranslationRequestRecorder()
    let probe = TranslationCancellationProbe()
    TranslationURLProtocol.install { request in
      recorder.record(request.url?.path ?? "")
      return TranslationMockHTTPResponse(cancellationProbe: probe)
    }
    let cacheDirectory = translationCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let provider = try OpenAICompatibleProvider(
      baseURL: URL(string: "https://example.test/v1")!,
      apiKey: "test-key",
      session: translationTestSession()
    )
    let service = TranslationService(provider: provider, cacheDirectory: cacheDirectory)
    let task = Task {
      try await service.translate(TranslationRequest(text: "Hello", language: "French"))
    }
    for _ in 0..<100 where recorder.count("/v1/chat/completions") == 0 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("expected the translation task to be cancelled")
    } catch {
      #expect(probe.isCancelled)
    }
    #expect(probe.isCancelled)
  }
}
