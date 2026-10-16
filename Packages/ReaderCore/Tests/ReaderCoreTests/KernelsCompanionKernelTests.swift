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
  func companionServicePersistsAndDefaultsToAutoForLegacyPreferences() throws {
    let defaults = ReaderPreferences()
    let encoded = try JSONEncoder().encode(defaults)
    let encodedObject = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(encodedObject["companionService"] as? String == "auto")

    let decoder = JSONDecoder()
    let restored = try decoder.decode(ReaderPreferences.self, from: encoded)
    #expect(restored.companionService == "auto")

    let legacy = try decoder.decode(
      ReaderPreferences.self,
      from: Data(#"{"companionURL":"http://host:8891"}"#.utf8)
    )
    #expect(legacy.companionService == "auto")

    let custom = ReaderPreferences(
      companionURL: "http://host:8891",
      companionService: "custom-provider"
    )
    let customRestored = try decoder.decode(
      ReaderPreferences.self,
      from: JSONEncoder().encode(custom)
    )
    #expect(customRestored.companionService == "custom-provider")
  }

  @Test
  func normalizesAddressesAndPairingCodes() {
    #expect(normalizeCompanionURL(" my-mac.local ") == "http://my-mac.local:8891")
    #expect(normalizeCompanionURL("192.168.1.20") == "http://192.168.1.20:8891")
    #expect(normalizeCompanionURL("192.168.1.20:9000") == "http://192.168.1.20:9000")
    #expect(normalizeCompanionURL("[fd7a:115c:a1e0::1]") == "http://[fd7a:115c:a1e0::1]:8891")
    #expect(normalizeCompanionURL("http://my-mac.local:8891/") == "http://my-mac.local:8891")
    #expect(normalizeCompanionURL("") == "")
    #expect(normalizeCompanionURL(nil) == "")
    #expect(normalizeCompanionPairingCode(" abcd-efgh ijkl_mnop ") == "ABCDEFGHIJKLMNOP")
  }

  @Test
  func recognizesOnlyTailscaleLiteralRanges() {
    #expect(isTailscaleHost("100.64.0.0"))
    #expect(isTailscaleHost("100.127.255.255"))
    #expect(!isTailscaleHost("100.63.255.255"))
    #expect(!isTailscaleHost("100.128.0.0"))
    #expect(!isTailscaleHost("100.100.100.100"))
    #expect(isTailscaleHost("fd7a:115c:a1e0::"))
    #expect(isTailscaleHost("fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"))
    #expect(!isTailscaleHost("fd7a:115c:a1df::1"))
    #expect(!isTailscaleHost("fd7a:115c:a1e1::1"))
    #expect(isTailscaleHost("[fd7a:115c:a1e0::1]"))
    #expect(!isTailscaleHost("desktop.ts.net"))
  }

  @Test
  func validatesAndNormalizesTailscaleCompanionURLs() {
    #expect(tailscaleCompanionURL("100.64.0.1") == "http://100.64.0.1:8891")
    #expect(tailscaleCompanionURL("http://100.64.0.1") == "http://100.64.0.1:8891")
    #expect(tailscaleCompanionURL("https://[fd7a:115c:a1e0::1]") == "https://[fd7a:115c:a1e0::1]:8891")
    #expect(tailscaleCompanionURL("https://desktop.ts.net/") == "https://desktop.ts.net:8891")
    #expect(tailscaleCompanionURL("desktop.ts.net") == "http://desktop.ts.net:8891")
    #expect(tailscaleCompanionURL("http://desktop.ts.net:65535") == "http://desktop.ts.net:65535")
    #expect(tailscaleCompanionURL("http://desktop.ts.net.evil") == nil)
    #expect(tailscaleCompanionURL("http://192.168.1.20") == nil)
    #expect(tailscaleCompanionURL("ftp://100.64.0.1") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1:0") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1:65536") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1:") == nil)
    #expect(tailscaleCompanionURL("http://user@100.64.0.1") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1/") != nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1/?query=1") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1#fragment") == nil)
    #expect(tailscaleCompanionURL("http://100.64.0.1/path") == nil)
  }

  @Test
  func healthReportsKernelsAndCaches() async {
    let deviceName = await CompanionDeviceIdentity.name
    companionMock.install { request in
      #expect(request.value(forHTTPHeaderField: "X-PDFMathReader-Device-Name") == deviceName)
      return CompanionMockResponse(body: healthyBody)
    }
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
  func healthParsesOptionalComputerMetadataAndLegacyHealthRemainsCompatible() async throws {
    let metadataBody = Data(
      #"{"status":"ok","app":"PDFMathReader","protocol":1,"version":"0.1.12","computer":{"name":"Office Mac","addresses":["http://100.64.0.9:8891"]},"kernels":[]}"#.utf8
    )
    companionMock.install { request in
      let body = request.url?.host == "metadata.test"
        ? metadataBody
        : healthyBody
      return CompanionMockResponse(body: body)
    }
    let client = CompanionKernelClient(session: companionSession())
    let metadata = await client.health("metadata.test", pairingCode: "AAAA")
    #expect(
      metadata.computer == CompanionComputer(
        name: "Office Mac",
        addresses: ["http://100.64.0.9:8891"]
      )
    )

    let legacy = await client.health("legacy.test", pairingCode: "AAAA")
    #expect(legacy.computer == nil)

    let encoded = try JSONEncoder().encode(metadata)
    #expect(try JSONDecoder().decode(CompanionHealth.self, from: encoded) == metadata)
    let old = try JSONDecoder().decode(
      CompanionHealth.self,
      from: Data(#"{"ok":true,"version":"0.1.12","reason":"","kernels":[]}"#.utf8)
    )
    #expect(old.computer == nil)
  }

  @Test
  func healthParsesOptionalTranslationCapabilitiesAndLegacyHealthRemainsCompatible() async throws {
    let translationBody = Data(
      #"{"status":"ok","app":"PDFMathReader","protocol":1,"version":"0.1.12","kernels":[],"translation":{"services":[{"id":"custom-provider","name":"Custom Provider","sourceLanguages":null,"targetLanguages":[{"name":"Klingon","code":"tlh"}]}],"kernels":[{"id":"pdf_math_fast","sourceLanguages":[{"name":"Klingon","code":"tlh"}],"targetLanguages":[{"name":"Klingon","code":"tlh"}]}]}}"#.utf8
    )
    let legacyBody = Data(
      #"{"status":"ok","app":"PDFMathReader","protocol":1,"version":"0.1.12","kernels":[]}"#.utf8
    )
    companionMock.install { request in
      let body = request.url?.host == "translation.test" ? translationBody : legacyBody
      return CompanionMockResponse(body: body)
    }
    let client = CompanionKernelClient(session: companionSession())

    let translated = await client.health("translation.test", pairingCode: "AAAA")
    #expect(translated.translation?.services.first?.id == "custom-provider")
    #expect(translated.translation?.services.first?.sourceLanguages == nil)
    #expect(translated.translation?.services.first?.targetLanguages?.map(\.code) == ["tlh"])
    #expect(translated.translation?.kernels.first?.targetLanguages.map(\.code) == ["tlh"])

    let legacy = await client.health("legacy-translation.test", pairingCode: "AAAA")
    #expect(legacy.translation == nil)

    let old = try JSONDecoder().decode(
      CompanionHealth.self,
      from: Data(#"{"ok":true,"version":"0.1.12","reason":"","kernels":[]}"#.utf8)
    )
    #expect(old.translation == nil)
  }

  @Test
  func translationLanguagesIntersectKernelAndServiceWhileKeepingCustomAndEmptyCapabilities() {
    let custom = TranslationLanguageOption(name: "Klingon", code: "tlh")
    let english = TranslationLanguageOption(name: "English", code: "en")
    let options = CompanionTranslationOptions(
      services: [
        CompanionTranslationService(id: "inherited", name: "Inherited"),
        CompanionTranslationService(
          id: "filtered",
          name: "Filtered",
          targetLanguages: [TranslationLanguageOption(name: "Custom Klingon", code: "tlh")]
        ),
        CompanionTranslationService(id: "empty", name: "Empty", targetLanguages: [])
      ],
      kernels: [
        CompanionTranslationKernel(
          id: CompanionKernel.fast,
          sourceLanguages: [custom, english],
          targetLanguages: [custom, english]
        )
      ]
    )

    #expect(options.languages(engine: CompanionKernel.fast, service: "inherited", direction: "target") == [custom, english])
    #expect(options.languages(engine: CompanionKernel.fast, service: "filtered", direction: "target") == [custom])
    #expect(options.languages(engine: CompanionKernel.fast, service: "filtered", direction: "source") == [custom, english])
    #expect(options.languages(engine: CompanionKernel.fast, service: "empty", direction: "target").isEmpty)
  }

  @Test
  func translationLanguagesUsePerKernelServiceLimitsAndRejectUnavailableKernels() {
    let english = TranslationLanguageOption(name: "English", code: "en")
    let chinese = TranslationLanguageOption(name: "Simplified Chinese", code: "zh")
    let japanese = TranslationLanguageOption(name: "Japanese", code: "ja")
    let unavailable = "pdf_math_unavailable"
    let options = CompanionTranslationOptions(
      services: [
        CompanionTranslationService(
          id: "per-kernel",
          name: "Per Kernel",
          kernels: [
            CompanionTranslationKernel(
              id: CompanionKernel.fast,
              sourceLanguages: [english, chinese],
              targetLanguages: [chinese]
            ),
            CompanionTranslationKernel(
              id: CompanionKernel.precise,
              sourceLanguages: [japanese],
              targetLanguages: [english, chinese]
            )
          ]
        )
      ],
      kernels: [
        CompanionTranslationKernel(
          id: CompanionKernel.fast,
          sourceLanguages: [english, chinese],
          targetLanguages: [chinese, japanese]
        ),
        CompanionTranslationKernel(
          id: CompanionKernel.precise,
          sourceLanguages: [english, japanese],
          targetLanguages: [english, chinese]
        ),
        CompanionTranslationKernel(
          id: unavailable,
          sourceLanguages: [english],
          targetLanguages: [english]
        )
      ]
    )

    #expect(options.languages(engine: CompanionKernel.fast, service: "per-kernel", direction: "source") == [english, chinese])
    #expect(options.languages(engine: CompanionKernel.fast, service: "per-kernel", direction: "target") == [chinese])
    #expect(options.languages(engine: CompanionKernel.precise, service: "per-kernel", direction: "source") == [japanese])
    #expect(options.languages(engine: CompanionKernel.precise, service: "per-kernel", direction: "target") == [english, chinese])
    #expect(options.languages(engine: unavailable, service: "per-kernel", direction: "target").isEmpty)
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
  func customCompanionServiceIDIsForwardedVerbatim() async throws {
    let serviceID = "com.example.custom-provider/v2"
    companionMock.install { request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("POST", "/companion/v1/jobs"):
        return CompanionMockResponse(statusCode: 202, body: Data(#"{"id":"custom-service-job"}"#.utf8))
      case ("GET", "/companion/v1/jobs/custom-service-job"):
        return CompanionMockResponse(body: Data(#"{"state":"done","percent":100}"#.utf8))
      case ("GET", "/companion/v1/jobs/custom-service-job/result"):
        return CompanionMockResponse(body: companionPDF(pageCount: 1))
      default:
        return CompanionMockResponse(statusCode: 404)
      }
    }
    let client = CompanionKernelClient(
      session: companionSession(),
      configuration: CompanionKernelConfiguration(pollInterval: 0.001)
    )
    _ = try await client.translatePage(
      url: "mac.test",
      pairingCode: "ABCD",
      bytes: companionPDF(pageCount: 1),
      engine: CompanionKernel.fast,
      language: "zh",
      service: serviceID
    )

    let submit = try #require(companionMock.first("POST", "/companion/v1/jobs"))
    let body = try #require(try JSONSerialization.jsonObject(with: submit.body) as? [String: Any])
    #expect(body["service"] as? String == serviceID)
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
