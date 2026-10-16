import Foundation
import PDFKit
import Testing

@testable import ReaderCore

private struct CompanionMockResponse: Sendable {
  var statusCode: Int = 200
  var body = Data()
}

private final class CompanionMockState: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (URLRequest) -> CompanionMockResponse)?
  private var requests: [(method: String, path: String, auth: String, body: Data)] = []

  func install(_ handler: (@Sendable (URLRequest) -> CompanionMockResponse)?) {
    lock.lock()
    self.handler = handler
    requests = []
    lock.unlock()
  }

  func handle(_ request: URLRequest) -> CompanionMockResponse? {
    lock.lock()
    let handler = handler
    requests.append(
      (
        request.httpMethod ?? "GET",
        request.url?.path ?? "",
        request.value(forHTTPHeaderField: "Authorization") ?? "",
        companionRequestBody(request)
      )
    )
    lock.unlock()
    return handler?(request)
  }

  func count(_ method: String, _ path: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0.method == method && $0.path == path }.count
  }

  func first(_ method: String, _ path: String) -> (auth: String, body: Data)? {
    lock.lock()
    defer { lock.unlock() }
    return requests.first { $0.method == method && $0.path == path }.map { ($0.auth, $0.body) }
  }
}

private let companionMock = CompanionMockState()

private final class CompanionMockURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let response = companionMock.handle(request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let http = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: [:])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func companionSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [CompanionMockURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func companionRequestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var body = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    body.append(buffer, count: count)
  }
  return body
}

private func companionPDF(pageCount: Int) -> Data {
  let document = PDFDocument()
  for index in 0..<pageCount {
    document.insert(PDFPage(), at: index)
  }
  return document.dataRepresentation()!
}

private let healthyBody = Data(
  #"{"status":"ok","app":"PDFMathReader","protocol":1,"version":"0.1.12","kernels":[{"id":"pdf_math_fast","available":true,"version":"1","reason":""},{"id":"pdf_math_precise","available":false,"version":"","reason":"Not installed"}]}"#
    .utf8
)

@Suite(.serialized)
struct CompanionKernelClientTests {
  init() {
    companionMock.install(nil)
  }

  @Test
  func preferencesKeepRemoteKernelOnForExistingURLs() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(ReaderPreferences.self, from: Data(#"{"remoteKernelURL":"http://host:8890"}"#.utf8))
    let fresh = try decoder.decode(ReaderPreferences.self, from: Data("{}".utf8))
    let off = try decoder.decode(
      ReaderPreferences.self,
      from: Data(#"{"remoteKernelURL":"http://host:8890","remoteKernelEnabled":false}"#.utf8)
    )
    #expect(legacy.remoteKernelEnabled)
    #expect(!fresh.remoteKernelEnabled)
    #expect(!off.remoteKernelEnabled)
    #expect(fresh.companionURL.isEmpty)
  }

  @Test
  func normalizesAddressesAndPairingCodes() {
    #expect(normalizeCompanionURL(" my-mac.local ") == "http://my-mac.local:8891")
    #expect(normalizeCompanionURL("192.168.1.20") == "http://192.168.1.20:8891")
    #expect(normalizeCompanionURL("192.168.1.20:9000") == "http://192.168.1.20:9000")
    #expect(normalizeCompanionURL("http://my-mac.local:8891/") == "http://my-mac.local:8891")
    #expect(normalizeCompanionURL("") == "")
    #expect(normalizeCompanionURL(nil) == "")
    #expect(normalizeCompanionPairingCode(" abcd-efgh ijkl_mnop ") == "ABCDEFGHIJKLMNOP")
  }

  @Test
  func healthReportsKernelsAndCaches() async {
    companionMock.install { _ in CompanionMockResponse(body: healthyBody) }
    let client = CompanionKernelClient(session: companionSession())
    let first = await client.health("mac.test", pairingCode: "abcd-efgh")
    let second = await client.health("http://mac.test:8891", pairingCode: "ABCDEFGH")
    #expect(first.ok)
    #expect(first.version == "0.1.12")
    #expect(first.isAvailable(CompanionKernel.fast))
    #expect(!first.isAvailable(CompanionKernel.precise))
    #expect(second == first)
    #expect(companionMock.count("GET", "/companion/v1/health") == 1)
    #expect(companionMock.first("GET", "/companion/v1/health")?.auth == "Bearer ABCDEFGH")

    await client.markUnhealthy("mac.test", pairingCode: "ABCDEFGH", reason: "Gone")
    let marked = await client.health("mac.test", pairingCode: "ABCDEFGH")
    #expect(marked == CompanionHealth(ok: false, reason: "Gone"))
  }

  @Test
  func healthRejectsWrongCodeOldProtocolAndMissingCode() async {
    companionMock.install { request in
      if request.url?.host == "old.test" {
        return CompanionMockResponse(
          body: Data(#"{"status":"ok","app":"PDFMathReader","protocol":99,"kernels":[]}"#.utf8)
        )
      }
      return CompanionMockResponse(statusCode: 401, body: Data(#"{"error":"Unauthorized"}"#.utf8))
    }
    let client = CompanionKernelClient(session: companionSession())
    let wrong = await client.health("wrong.test", pairingCode: "AAAA")
    let old = await client.health("old.test", pairingCode: "AAAA")
    let missing = await client.health("wrong.test", pairingCode: " - ")
    #expect(!wrong.ok)
    #expect(wrong.reason == "Wrong pairing code")
    #expect(!old.ok)
    #expect(old.reason == CompanionKernelError.incompatibleVersion.localizedDescription)
    #expect(!missing.ok)
    #expect(!old.isAvailable(CompanionKernel.fast))
  }

  @Test
  func translatesThroughSubmitPollAndDownload() async throws {
    let polls = CompanionMockState()
    companionMock.install { request in
      let path = request.url?.path ?? ""
      switch (request.httpMethod ?? "GET", path) {
      case ("POST", "/companion/v1/jobs"):
        return CompanionMockResponse(statusCode: 202, body: Data(#"{"id":"job-1"}"#.utf8))
      case ("GET", "/companion/v1/jobs/job-1"):
        _ = polls.handle(request)
        if polls.count("GET", path) < 2 {
          return CompanionMockResponse(
            body: Data(#"{"state":"running","stage":"Typesetting","percent":40}"#.utf8)
          )
        }
        return CompanionMockResponse(body: Data(#"{"state":"done","stage":"Done","percent":100}"#.utf8))
      case ("GET", "/companion/v1/jobs/job-1/result"):
        return CompanionMockResponse(body: companionPDF(pageCount: 1))
      default:
        return CompanionMockResponse(statusCode: 404)
      }
    }
    let client = CompanionKernelClient(
      session: companionSession(),
      configuration: CompanionKernelConfiguration(pollInterval: 0.001)
    )
    let result = try await client.translatePage(
      url: "mac.test",
      pairingCode: "abcd-efgh",
      bytes: companionPDF(pageCount: 1),
      engine: CompanionKernel.precise,
      language: "zh",
      sourceLanguage: " en ",
      service: "apple-local",
      glossary: [GlossaryEntry(source: "kernel", target: "内核"), GlossaryEntry(source: "", target: "x")]
    )
    #expect(PDFDocument(data: result)?.pageCount == 1)

    let submit = try #require(companionMock.first("POST", "/companion/v1/jobs"))
    #expect(submit.auth == "Bearer ABCDEFGH")
    let body = try #require(try JSONSerialization.jsonObject(with: submit.body) as? [String: Any])
    #expect(body["engine"] as? String == CompanionKernel.precise)
    #expect(body["language"] as? String == "zh")
    #expect(body["sourceLanguage"] as? String == "en")
    #expect(body["service"] as? String == "apple-local")
    #expect((body["glossary"] as? [[String: String]])?.count == 1)
    let uploaded = Data(base64Encoded: body["pdf"] as? String ?? "")
    #expect(uploaded.flatMap { PDFDocument(data: $0) }?.pageCount == 1)
  }

  @Test
  func failedJobSurfacesTheComputerMessage() async {
    companionMock.install { request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("POST", "/companion/v1/jobs"):
        return CompanionMockResponse(statusCode: 202, body: Data(#"{"id":"job-2"}"#.utf8))
      case ("GET", "/companion/v1/jobs/job-2"):
        return CompanionMockResponse(body: Data(#"{"state":"failed","error":"Kernel crashed"}"#.utf8))
      default:
        return CompanionMockResponse(statusCode: 404)
      }
    }
    let client = CompanionKernelClient(
      session: companionSession(),
      configuration: CompanionKernelConfiguration(pollInterval: 0.001)
    )
    await #expect(throws: CompanionKernelError.translationFailed("Kernel crashed")) {
      try await client.translatePage(
        url: "mac.test",
        pairingCode: "ABCD",
        bytes: companionPDF(pageCount: 1),
        engine: CompanionKernel.fast,
        language: "zh"
      )
    }
  }

  @Test
  @MainActor
  func mathPageTranslatorCachesCompanionPages() async throws {
    companionMock.install { request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("POST", "/companion/v1/jobs"):
        return CompanionMockResponse(statusCode: 202, body: Data(#"{"id":"job-3"}"#.utf8))
      case ("GET", "/companion/v1/jobs/job-3"):
        return CompanionMockResponse(body: Data(#"{"state":"done","percent":100}"#.utf8))
      case ("GET", "/companion/v1/jobs/job-3/result"):
        return CompanionMockResponse(body: companionPDF(pageCount: 1))
      default:
        return CompanionMockResponse(statusCode: 404)
      }
    }
    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfmathreader-companion-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let translator = MathPageTranslator(
      client: RemoteKernelClient(session: companionSession()),
      companionClient: CompanionKernelClient(
        session: companionSession(),
        configuration: CompanionKernelConfiguration(pollInterval: 0.001)
      ),
      cacheDirectory: cacheDirectory
    )
    let document = PDFDocument(data: companionPDF(pageCount: 2))!
    func translate(code: String) async throws -> Data {
      try await translator.translatePage(
        document: document,
        pageIndex: 1,
        companionURL: "mac.test",
        pairingCode: code,
        language: "zh",
        engine: CompanionKernel.fast
      )
    }
    let first = try await translate(code: "AAAA")
    // A new pairing code reuses pages the computer already translated.
    let second = try await translate(code: "BBBB")
    #expect(first == second)
    #expect(companionMock.count("POST", "/companion/v1/jobs") == 1)
  }
}
