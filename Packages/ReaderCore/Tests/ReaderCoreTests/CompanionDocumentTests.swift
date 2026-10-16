import Foundation

@preconcurrency import PDFKit
import Testing

@testable import ReaderCore

private struct DocumentMockResponse: Sendable {
  var statusCode: Int = 200
  var body = Data()
}

private final class DocumentMockState: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (URLRequest) -> DocumentMockResponse)?
  private var requests: [URLRequest] = []

  func install(_ handler: (@Sendable (URLRequest) -> DocumentMockResponse)?) {
    lock.lock()
    self.handler = handler
    requests.removeAll()
    lock.unlock()
  }

  func handle(_ request: URLRequest) -> DocumentMockResponse? {
    lock.lock()
    requests.append(request)
    let handler = handler
    lock.unlock()
    return handler?(request)
  }

  func requestsSnapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private let documentMock = DocumentMockState()

private final class DocumentMockURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let response = documentMock.handle(request), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func documentSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DocumentMockURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func requestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    result.append(buffer, count: count)
  }
  return result
}

private func documentPDF(pageCount: Int) -> Data {
  let document = PDFDocument()
  for index in 0..<pageCount {
    document.insert(PDFPage(), at: index)
  }
  return document.dataRepresentation()!
}

private func jsonData(_ value: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func acquiredBody(
  sessionID: String,
  revision: String,
  pdf: Data,
  pageCount: Int,
  byteCount: Int? = nil,
  sha256: String? = nil,
  extra: [String: Any] = [:]
) -> Data {
  var object: [String: Any] = [
    "sessionID": sessionID,
    "revision": revision,
    "sha256": sha256 ?? DocumentIdentity.contentHash(for: pdf),
    "byteCount": byteCount ?? pdf.count,
    "pageCount": pageCount,
    "pdf": pdf.base64EncodedString(),
  ]
  for (key, value) in extra { object[key] = value }
  return jsonData(object)
}

@Suite(.serialized)
struct CompanionDocumentClientTests {
  init() {
    documentMock.install(nil)
  }

  @Test
  func listNormalizesURLAndAuthenticates() async throws {
    documentMock.install { request in
      #expect(request.httpMethod == "GET")
      #expect(request.url?.path == "/companion/v1/documents")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ABCDEFGH")
      return DocumentMockResponse(
        body: jsonData([
          "documents": [
            ["id": "doc-1", "title": "A.pdf", "pageCount": 3, "lastOpened": "2026-10-16T01:02:03Z"],
            ["id": "doc-2", "title": "B.pdf", "pageCount": 1],
          ]
        ])
      )
    }
    let client = CompanionDocumentClient(session: documentSession())
    let documents = try await client.list(
      url: " mac.test ",
      pairingCode: "abcd-efgh"
    )
    #expect(documents == [
      CompanionRecentDocument(id: "doc-1", title: "A.pdf", pageCount: 3, lastOpened: "2026-10-16T01:02:03Z"),
      CompanionRecentDocument(id: "doc-2", title: "B.pdf", pageCount: 1),
    ])
  }

  @Test
  func acquireSaveHeartbeatAndReleaseUseExactSessionRoutes() async throws {
    let pdf = documentPDF(pageCount: 2)
    let sessionID = "device-session-1"
    documentMock.install { request in
      let path = request.url?.path ?? ""
      switch (request.httpMethod ?? "GET", path) {
      case ("POST", "/companion/v1/documents/doc-1/session"):
        let body = try! #require(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        #expect(body["deviceID"] as? String == "phone-1")
        #expect(body["deviceName"] as? String == "Rong's iPhone")
        #expect(body["sessionID"] as? String == sessionID)
        return DocumentMockResponse(body: acquiredBody(
          sessionID: sessionID,
          revision: "rev-1",
          pdf: pdf,
          pageCount: 2
        ))
      case ("PUT", "/companion/v1/documents/doc-1/session/\(sessionID)"):
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ABCDEFGH")
        let body = try! #require(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
        #expect(body["revision"] as? String == "rev-1")
        #expect(body["sha256"] as? String == DocumentIdentity.contentHash(for: pdf))
        #expect(body["byteCount"] as? Int == pdf.count)
        #expect(body["pageCount"] as? Int == 2)
        #expect(body["release"] as? Bool == true)
        #expect(Data(base64Encoded: body["pdf"] as? String ?? "") == pdf)
        return DocumentMockResponse(body: jsonData(["revision": "rev-2"]))
      case ("POST", "/companion/v1/documents/doc-1/session/\(sessionID)/heartbeat"):
        return DocumentMockResponse(statusCode: 204)
      case ("DELETE", "/companion/v1/documents/doc-1/session/\(sessionID)"):
        return DocumentMockResponse(statusCode: 204)
      default:
        return DocumentMockResponse(statusCode: 404)
      }
    }

    let client = CompanionDocumentClient(session: documentSession())
    let snapshot = try await client.acquire(
      url: "http://mac.test:8891/",
      pairingCode: "abcd-efgh",
      documentID: "doc-1",
      deviceID: "phone-1",
      deviceName: "Rong's iPhone",
      sessionID: sessionID
    )
    #expect(snapshot == CompanionDocumentSnapshot(sessionID: sessionID, revision: "rev-1", pdf: pdf, pageCount: 2))
    let revision = try await client.save(
      url: "http://mac.test:8891",
      pairingCode: "ABCDEFGH",
      documentID: "doc-1",
      sessionID: sessionID,
      revision: snapshot.revision,
      pdf: snapshot.pdf,
      pageCount: snapshot.pageCount,
      release: true
    )
    #expect(revision == "rev-2")
    try await client.heartbeat(
      url: "mac.test",
      pairingCode: "abcd-efgh",
      documentID: "doc-1",
      sessionID: sessionID
    )
    try await client.release(
      url: "mac.test",
      pairingCode: "abcd-efgh",
      documentID: "doc-1",
      sessionID: sessionID
    )

    let requests = documentMock.requestsSnapshot()
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ABCDEFGH" })
  }

  @Test
  func acquireDecodesOptionalStateWithISOAndReferenceDateTimestamps() async throws {
    let pdf = documentPDF(pageCount: 1)
    let annotation: [String: Any] = [
      "id": "annotation-1",
      "page": 1,
      "kind": "highlight",
      "origin": "source",
      "text": "selected",
      "comment": "",
      "color": "#ffff00",
      "rects": [["x": 1.0, "y": 1.0, "width": 20.0, "height": 10.0]],
      "createdAt": "2026-10-16T01:02:03Z",
      "nativeRef": "12 0 R",
    ]
    let quickLink: [String: Any] = [
      "id": "link-1",
      "origin": ["page": 1, "box": ["x": 1.0, "y": 1.0, "width": 10.0, "height": 10.0]],
      "result": ["page": 1, "box": ["x": 2.0, "y": 2.0, "width": 10.0, "height": 10.0]],
    ]
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let readingState: (Any, Date) = (
      "2026-10-16T01:02:03.123Z",
      isoFormatter.date(from: "2026-10-16T01:02:03.123Z")!
    )
    let states: [(Any, Date)] = [
      readingState,
      (1234.5, Date(timeIntervalSinceReferenceDate: 1234.5)),
    ]

    for (timestamp, expectedDate) in states {
      let body = acquiredBody(
        sessionID: "s",
        revision: "r",
        pdf: pdf,
        pageCount: 1,
        extra: [
          "annotations": [annotation],
          "nativeRefs": ["12 0 R"],
          "quickLinks": [quickLink],
          "readingState": [
            "page": 1,
            "zoom": 1.25,
            "scaleMode": "fitPage",
            "displayMode": "singlePage",
            "scrollDirection": "vertical",
            "sidebarVisible": true,
            "lastUpdated": timestamp,
          ],
        ]
      )
      documentMock.install { _ in DocumentMockResponse(body: body) }
      let client = CompanionDocumentClient(session: documentSession())
      let snapshot = try await client.acquire(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "doc-1",
        deviceID: "phone-1",
        deviceName: "Phone",
        sessionID: "s"
      )
      #expect(snapshot.annotations?.count == 1)
      #expect(snapshot.annotations?.first?.nativeRef == "12 0 R")
      #expect(snapshot.nativeRefs == ["12 0 R"])
      #expect(snapshot.quickLinks?.count == 1)
      #expect(snapshot.readingState?.page == 1)
      #expect(snapshot.readingState?.lastUpdated == expectedDate)
    }
  }

  @Test
  func acquireRejectsHashTruncationAndPageCountPayloads() async throws {
    let pdf = documentPDF(pageCount: 1)
    let cases: [(String, Data)] = [
      ("hash", acquiredBody(sessionID: "s", revision: "r", pdf: pdf, pageCount: 1, sha256: String(repeating: "0", count: 64))),
      ("byte-count", acquiredBody(sessionID: "s", revision: "r", pdf: pdf, pageCount: 1, byteCount: pdf.count + 1)),
      ("page-count", acquiredBody(sessionID: "s", revision: "r", pdf: pdf, pageCount: 2)),
      ("truncated", acquiredBody(sessionID: "s", revision: "r", pdf: Data(pdf.dropLast(10)), pageCount: 1)),
    ]

    for (name, body) in cases {
      documentMock.install { _ in DocumentMockResponse(body: body) }
      let client = CompanionDocumentClient(session: documentSession())
      await #expect(throws: CompanionDocumentError.invalidDocument) {
        try await client.acquire(
          url: "mac.test",
          pairingCode: "ABCD",
          documentID: "doc-1",
          deviceID: "phone-1",
          deviceName: name,
          sessionID: "s"
        )
      }
    }

  }

  @Test
  func unsafeIdentifiersCannotCollideOrReachTheNetwork() async throws {
    documentMock.install { _ in DocumentMockResponse(statusCode: 500) }
    let client = CompanionDocumentClient(session: documentSession())

    await #expect(throws: CompanionDocumentError.invalidIdentifier) {
      try await client.acquire(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "doc/one",
        deviceID: "phone-1",
        deviceName: "Phone",
        sessionID: "s"
      )
    }
    await #expect(throws: CompanionDocumentError.invalidIdentifier) {
      try await client.heartbeat(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "doc-1",
        sessionID: "s?collision"
      )
    }
    await #expect(throws: CompanionDocumentError.invalidIdentifier) {
      try await client.acquire(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "..",
        deviceID: "phone-1",
        deviceName: "Phone",
        sessionID: "s"
      )
    }
    #expect(documentMock.requestsSnapshot().isEmpty)
  }

  @Test
  func busyAndOldDesktopErrorsAreToastReady() async throws {
    documentMock.install { request in
      if request.url?.path.contains("busy") == true {
        return DocumentMockResponse(statusCode: 409)
      }
      return DocumentMockResponse(statusCode: 404)
    }
    let client = CompanionDocumentClient(session: documentSession())
    await #expect(throws: CompanionDocumentError.documentBusy) {
      try await client.acquire(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "busy",
        deviceID: "phone-1",
        deviceName: "Phone",
        sessionID: "s"
      )
    }
    await #expect(throws: CompanionDocumentError.desktopUpdateRequired) {
      try await client.list(url: "mac.test", pairingCode: "ABCD")
    }
    #expect(CompanionDocumentError.documentBusy.localizedDescription.contains("busy"))
    #expect(CompanionDocumentError.desktopUpdateRequired.localizedDescription.contains("Update PDFMathReader"))
  }

  @Test
  func saveValidatesBeforeSendingAndNeverAbandonsAutomatically() async throws {
    documentMock.install { _ in DocumentMockResponse(statusCode: 500) }
    let client = CompanionDocumentClient(session: documentSession())
    await #expect(throws: CompanionDocumentError.invalidDocument) {
      try await client.save(
        url: "mac.test",
        pairingCode: "ABCD",
        documentID: "doc-1",
        sessionID: "s",
        revision: "rev-1",
        pdf: Data("not a PDF".utf8),
        pageCount: 1,
        release: false
      )
    }
    #expect(documentMock.requestsSnapshot().isEmpty)
  }

  @Test
  func responsesAreBoundedBeforeJSONDecode() async throws {
    documentMock.install { _ in
      DocumentMockResponse(body: Data(repeating: 0x78, count: 129))
    }
    let client = CompanionDocumentClient(
      session: documentSession(),
      configuration: CompanionDocumentClientConfiguration(
        maxResponseBytes: 256,
        maxMetadataResponseBytes: 128
      )
    )
    await #expect(throws: CompanionDocumentError.responseTooLarge) {
      try await client.list(url: "mac.test", pairingCode: "ABCD")
    }
  }
}
