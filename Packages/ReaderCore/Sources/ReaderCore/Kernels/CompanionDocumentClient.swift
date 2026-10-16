import Foundation

@preconcurrency import PDFKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A document listed by the paired desktop's recent-document service.
public struct CompanionRecentDocument: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let pageCount: Int
  public let lastOpened: String?

  public init(id: String, title: String, pageCount: Int, lastOpened: String? = nil) {
    self.id = id
    self.title = title
    self.pageCount = pageCount
    self.lastOpened = lastOpened
  }
}

/// The document bytes and revision acquired from the paired desktop.
public struct CompanionDocumentSnapshot: Codable, Sendable, Equatable {
  public let sessionID: String
  public let revision: String
  public let pdf: Data
  public let pageCount: Int
  /// Optional state returned by newer desktops. Older desktops omit these
  /// fields and the manager falls back to state embedded in the PDF.
  public let annotations: [ReaderAnnotation]?
  public let nativeRefs: [String]?
  public let quickLinks: [ReaderQuickLink]?
  public let readingState: ReadingState?

  public init(
    sessionID: String,
    revision: String,
    pdf: Data,
    pageCount: Int,
    annotations: [ReaderAnnotation]? = nil,
    nativeRefs: [String]? = nil,
    quickLinks: [ReaderQuickLink]? = nil,
    readingState: ReadingState? = nil
  ) {
    self.sessionID = sessionID
    self.revision = revision
    self.pdf = pdf
    self.pageCount = pageCount
    self.annotations = annotations
    self.nativeRefs = nativeRefs
    self.quickLinks = quickLinks
    self.readingState = readingState
  }
}

public struct CompanionDocumentClientConfiguration: Sendable {
  /// Per-request wall-clock timeout. The URLSession request is cancelled when
  /// this interval elapses.
  public var requestTimeout: TimeInterval
  /// Upper bound for a JSON response carrying a base64-encoded PDF. A 200 MiB
  /// PDF needs more than 200 MiB on the wire because base64 expands it.
  public var maxResponseBytes: Int
  /// Upper bound for metadata and small acknowledgement responses.
  public var maxMetadataResponseBytes: Int
  /// Upper bound for the decoded PDF payload.
  public var maxDocumentBytes: Int
  /// Upper bound on the number of records accepted from the list endpoint.
  public var maxDocuments: Int

  public init(
    requestTimeout: TimeInterval = 30,
    maxResponseBytes: Int = 280 * 1024 * 1024,
    maxMetadataResponseBytes: Int = 4 * 1024 * 1024,
    maxDocumentBytes: Int = 200 * 1024 * 1024,
    maxDocuments: Int = 10_000
  ) {
    self.requestTimeout = max(0.001, requestTimeout)
    self.maxResponseBytes = max(1, maxResponseBytes)
    self.maxMetadataResponseBytes = max(1, maxMetadataResponseBytes)
    self.maxDocumentBytes = max(1, min(maxDocumentBytes, 200 * 1024 * 1024))
    self.maxDocuments = max(1, maxDocuments)
  }
}

public enum CompanionDocumentError: Error, LocalizedError, Sendable, Equatable {
  case invalidServerURL
  case missingPairingCode
  case wrongPairingCode
  case documentBusy
  case desktopUpdateRequired
  case invalidIdentifier
  case invalidRequest
  case invalidResponse
  case invalidDocument
  case documentTooLarge
  case responseTooLarge
  case timeout(String)
  case httpStatus(Int)
  case rateLimited
  case networkFailure

  /// Compatibility spelling for callers that use the kernel client's name.
  public static let incompatibleVersion = CompanionDocumentError.desktopUpdateRequired
  /// Compatibility spelling for callers that use the kernel client's name.
  public static let busy = CompanionDocumentError.documentBusy

  public var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      return ReaderLocalization.resolve("Invalid computer address")
    case .missingPairingCode:
      return ReaderLocalization.resolve("Enter the pairing code shown on your computer")
    case .wrongPairingCode:
      return ReaderLocalization.resolve("Wrong pairing code")
    case .documentBusy:
      return ReaderLocalization.resolve("That document is busy on your computer. Try again shortly.")
    case .desktopUpdateRequired:
      return ReaderLocalization.resolve("Update PDFMathReader on your computer")
    case .invalidIdentifier:
      return ReaderLocalization.resolve("The computer sent an invalid document identifier")
    case .invalidRequest:
      return ReaderLocalization.resolve("The computer rejected the document handoff request")
    case .invalidResponse:
      return ReaderLocalization.resolve("Your computer sent an invalid document response")
    case .invalidDocument:
      return ReaderLocalization.resolve("The computer sent an invalid PDF")
    case .documentTooLarge:
      return ReaderLocalization.resolve("That PDF is too large to open on this device")
    case .responseTooLarge:
      return ReaderLocalization.resolve("The computer sent too much data")
    case let .timeout(operation):
      return ReaderLocalization.string("Your computer did not respond ({0})", operation)
    case let .httpStatus(status):
      return ReaderLocalization.string("HTTP {0}", String(status))
    case .rateLimited:
      return ReaderLocalization.resolve("Too many requests. Try again shortly.")
    case .networkFailure:
      return ReaderLocalization.resolve("Can’t reach your computer. Check that PDFMathReader is open and document sharing is on.")
    }
  }
}

/// The document handoff surface used by the reader and by test doubles.
public protocol CompanionDocumentServing: Sendable {
  func list(url: String?, pairingCode: String) async throws -> [CompanionRecentDocument]

  func acquire(
    url: String?,
    pairingCode: String,
    documentID: String,
    deviceID: String,
    deviceName: String,
    sessionID: String
  ) async throws -> CompanionDocumentSnapshot

  func save(
    url: String?,
    pairingCode: String,
    documentID: String,
    sessionID: String,
    revision: String,
    pdf: Data,
    pageCount: Int,
    release: Bool
  ) async throws -> String
}

/// Collects a response while enforcing its byte bound as URLSession delivers
/// chunks. URLSession's convenience `data(for:)` API only exposes the body
/// after it has already collected it, which is too late for a large PDF.
private final class BoundedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var body = Data()
  private var response: URLResponse?
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  private var terminalResult: Result<(Data, URLResponse), Error>?

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func perform(_ task: URLSessionDataTask) async throws -> (Data, URLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        lock.lock()
        if let terminalResult {
          lock.unlock()
          continuation.resume(with: terminalResult)
          return
        }
        self.continuation = continuation
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if response.expectedContentLength > Int64(limit) {
      completionHandler(.cancel)
      finish(.failure(CompanionDocumentError.responseTooLarge))
      return
    }
    lock.lock()
    self.response = response
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let exceedsLimit = body.count > limit || data.count > limit - body.count
    if !exceedsLimit {
      body.append(data)
    }
    lock.unlock()
    if exceedsLimit {
      dataTask.cancel()
      finish(.failure(CompanionDocumentError.responseTooLarge))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      finish(.failure(CompanionDocumentClient.mapTransportError(error)))
      return
    }
    lock.lock()
    let response = self.response
    let body = self.body
    lock.unlock()
    guard let response else {
      finish(.failure(CompanionDocumentError.invalidResponse))
      return
    }
    finish(.success((body, response)))
  }

  private func finish(_ result: Result<(Data, URLResponse), Error>) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

/// Client for the paired desktop's recent-document and exclusive-session API.
public actor CompanionDocumentClient: CompanionDocumentServing {
  public static let protocolVersion = 1

  private struct DocumentListResponse: Decodable {
    let documents: [CompanionRecentDocument]
  }

  private struct AcquireRequest: Encodable {
    let deviceID: String
    let deviceName: String
    let sessionID: String
  }

  private struct AcquireResponse: Decodable {
    let sessionID: String
    let revision: String
    let sha256: String
    let byteCount: Int
    let pageCount: Int
    let pdf: Data
    let annotations: [ReaderAnnotation]?
    let nativeRefs: [String]?
    let quickLinks: [ReaderQuickLink]?
    let readingState: ReadingState?
  }

  private struct SaveRequest: Encodable {
    let revision: String
    let pdf: Data
    let sha256: String
    let byteCount: Int
    let pageCount: Int
    let release: Bool
  }

  private struct RevisionResponse: Decodable {
    let revision: String
  }

  private let session: URLSession
  private let configuration: CompanionDocumentClientConfiguration

  public init(
    session: URLSession = .shared,
    configuration: CompanionDocumentClientConfiguration = .init()
  ) {
    self.session = session
    self.configuration = configuration
  }

  /// Lists the desktop's recent documents.
  public func list(url: String?, pairingCode: String) async throws -> [CompanionRecentDocument] {
    let context = try Self.context(url: url, pairingCode: pairingCode)
    let (data, response) = try await send(
      Self.request(base: context.base, path: "/companion/v1/documents", code: context.code),
      operation: "documents",
      responseLimit: configuration.maxMetadataResponseBytes
    )
    try Self.check(response, body: data)
    try Self.checkResponseSize(data, limit: configuration.maxMetadataResponseBytes)
    let body = try Self.decode(DocumentListResponse.self, from: data)
    guard body.documents.count <= configuration.maxDocuments else {
      throw CompanionDocumentError.responseTooLarge
    }
    return body.documents
  }

  /// Acquires one document for this device. `sessionID` is supplied by the
  /// caller and is also sent to the desktop so retries remain idempotent.
  public func acquire(
    url: String?,
    pairingCode: String,
    documentID: String,
    deviceID: String,
    deviceName: String,
    sessionID: String
  ) async throws -> CompanionDocumentSnapshot {
    let context = try Self.context(url: url, pairingCode: pairingCode)
    try Self.validateIdentifier(documentID)
    try Self.validateIdentifier(sessionID)
    try Self.validateDeviceField(deviceID)
    try Self.validateDeviceField(deviceName)

    var request = Self.request(
      base: context.base,
      path: "/companion/v1/documents/\(documentID)/session",
      code: context.code,
      method: "POST"
    )
    request.httpBody = try JSONEncoder().encode(
      AcquireRequest(deviceID: deviceID, deviceName: deviceName, sessionID: sessionID)
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await send(
      request,
      operation: "acquire",
      responseLimit: configuration.maxResponseBytes
    )
    try Self.check(response, body: data)
    try Self.checkResponseSize(data, limit: configuration.maxResponseBytes)
    let body = try Self.decodeAcquireResponse(from: data)
    try Self.validateIdentifier(body.sessionID)
    guard body.sessionID == sessionID else { throw CompanionDocumentError.invalidResponse }
    guard !body.revision.isEmpty, body.revision.utf8.count <= 256 else {
      throw CompanionDocumentError.invalidResponse
    }
    try Self.validatePDF(
      body.pdf,
      expectedByteCount: body.byteCount,
      expectedHash: body.sha256,
      expectedPageCount: body.pageCount,
      maxBytes: configuration.maxDocumentBytes
    )
    try Self.validateCompanionMetadata(
      annotations: body.annotations,
      nativeRefs: body.nativeRefs,
      quickLinks: body.quickLinks,
      readingState: body.readingState,
      pageCount: body.pageCount
    )
    return CompanionDocumentSnapshot(
      sessionID: body.sessionID,
      revision: body.revision,
      pdf: body.pdf,
      pageCount: body.pageCount,
      annotations: body.annotations,
      nativeRefs: body.nativeRefs,
      quickLinks: body.quickLinks,
      readingState: body.readingState
    )
  }

  /// Saves the current PDF revision and optionally releases the exclusive
  /// session. The method validates the complete PDF before making the request.
  @discardableResult
  public func save(
    url: String?,
    pairingCode: String,
    documentID: String,
    sessionID: String,
    revision: String,
    pdf: Data,
    pageCount: Int,
    release: Bool = false
  ) async throws -> String {
    let context = try Self.context(url: url, pairingCode: pairingCode)
    try Self.validateIdentifier(documentID)
    try Self.validateIdentifier(sessionID)
    guard !revision.isEmpty, revision.utf8.count <= 256 else {
      throw CompanionDocumentError.invalidRequest
    }
    try Self.validatePDF(
      pdf,
      expectedByteCount: pdf.count,
      expectedHash: DocumentIdentity.contentHash(for: pdf),
      expectedPageCount: pageCount,
      maxBytes: configuration.maxDocumentBytes
    )

    var request = Self.request(
      base: context.base,
      path: "/companion/v1/documents/\(documentID)/session/\(sessionID)",
      code: context.code,
      method: "PUT"
    )
    request.httpBody = try JSONEncoder().encode(
      SaveRequest(
        revision: revision,
        pdf: pdf,
        sha256: DocumentIdentity.contentHash(for: pdf),
        byteCount: pdf.count,
        pageCount: pageCount,
        release: release
      )
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await send(
      request,
      operation: "save",
      responseLimit: configuration.maxMetadataResponseBytes
    )
    try Self.check(response, body: data)
    try Self.checkResponseSize(data, limit: configuration.maxMetadataResponseBytes)
    let body = try Self.decode(RevisionResponse.self, from: data)
    guard !body.revision.isEmpty, body.revision.utf8.count <= 256 else {
      throw CompanionDocumentError.invalidResponse
    }
    return body.revision
  }

  /// Sends a keep-alive for an acquired session. It does not release the
  /// session and accepts either a JSON or an empty success response.
  public func heartbeat(
    url: String?,
    pairingCode: String,
    documentID: String,
    sessionID: String
  ) async throws {
    let context = try Self.context(url: url, pairingCode: pairingCode)
    try Self.validateIdentifier(documentID)
    try Self.validateIdentifier(sessionID)
    let request = Self.request(
      base: context.base,
      path: "/companion/v1/documents/\(documentID)/session/\(sessionID)/heartbeat",
      code: context.code,
      method: "POST"
    )
    let (data, response) = try await send(
      request,
      operation: "heartbeat",
      responseLimit: configuration.maxMetadataResponseBytes
    )
    try Self.check(response, body: data)
    try Self.checkResponseSize(data, limit: configuration.maxMetadataResponseBytes)
  }

  /// Explicitly abandons an acquired session. Callers decide when this is
  /// appropriate; failed local validation never invokes it automatically.
  public func release(
    url: String?,
    pairingCode: String,
    documentID: String,
    sessionID: String
  ) async throws {
    let context = try Self.context(url: url, pairingCode: pairingCode)
    try Self.validateIdentifier(documentID)
    try Self.validateIdentifier(sessionID)
    let request = Self.request(
      base: context.base,
      path: "/companion/v1/documents/\(documentID)/session/\(sessionID)",
      code: context.code,
      method: "DELETE"
    )
    let (data, response) = try await send(
      request,
      operation: "release",
      responseLimit: configuration.maxMetadataResponseBytes
    )
    try Self.check(response, body: data)
    try Self.checkResponseSize(data, limit: configuration.maxMetadataResponseBytes)
  }

  private struct Context: Sendable {
    let base: String
    let code: String
  }

  private static func context(url: String?, pairingCode: String) throws -> Context {
    let base = normalizeCompanionURL(url)
    guard !base.isEmpty else { throw CompanionDocumentError.invalidServerURL }
    let code = normalizeCompanionPairingCode(pairingCode)
    guard !code.isEmpty else { throw CompanionDocumentError.missingPairingCode }
    return Context(base: base, code: code)
  }

  private nonisolated static func request(
    base: String,
    path: String,
    code: String,
    method: String = "GET"
  ) -> URLRequest {
    var request = URLRequest(url: URL(string: base + path)!)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func send(
    _ request: URLRequest,
    operation: String,
    responseLimit: Int
  ) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    let urlSessionConfiguration = session.configuration
    let delegate = BoundedResponseDelegate(limit: responseLimit)
    let boundedSession = URLSession(
      configuration: urlSessionConfiguration,
      delegate: delegate,
      delegateQueue: nil
    )
    let task = boundedSession.dataTask(with: request)
    let timeout = self.configuration.requestTimeout
    defer {
      task.cancel()
      boundedSession.invalidateAndCancel()
    }
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
      group.addTask { try await delegate.perform(task) }
      group.addTask {
        try await Self.sleep(seconds: timeout)
        throw CompanionDocumentError.timeout(operation)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw CompanionDocumentError.timeout(operation)
      }
      return result
    }
  }

  private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw CompanionDocumentError.invalidResponse
    }
  }

  private nonisolated static func decodeAcquireResponse(from data: Data) throws -> AcquireResponse {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self), seconds.isFinite {
          return Date(timeIntervalSinceReferenceDate: seconds)
        }
        if let string = try? container.decode(String.self) {
          let fractional = ISO8601DateFormatter()
          fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          if let date = fractional.date(from: string) { return date }
          let standard = ISO8601DateFormatter()
          standard.formatOptions = [.withInternetDateTime]
          if let date = standard.date(from: string) { return date }
        }
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected a reference-date number or ISO 8601 timestamp"
        )
      }
      return try decoder.decode(AcquireResponse.self, from: data)
    } catch {
      throw CompanionDocumentError.invalidResponse
    }
  }

  private nonisolated static func checkResponseSize(_ data: Data, limit: Int) throws {
    guard data.count <= limit else { throw CompanionDocumentError.responseTooLarge }
  }

  private nonisolated static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 256 else {
      throw CompanionDocumentError.invalidIdentifier
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw CompanionDocumentError.invalidIdentifier
    }
  }

  private nonisolated static func validateDeviceField(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CompanionDocumentError.invalidRequest
    }
  }

  private nonisolated static func validatePDF(
    _ data: Data,
    expectedByteCount: Int,
    expectedHash: String,
    expectedPageCount: Int,
    maxBytes: Int
  ) throws {
    guard data.count <= maxBytes else { throw CompanionDocumentError.documentTooLarge }
    guard expectedByteCount == data.count, expectedPageCount > 0 else {
      throw CompanionDocumentError.invalidDocument
    }
    // PDFKit can recover a few missing trailer bytes. Require the basic file
    // markers as well so a truncated payload is never handed to the reader.
    guard data.prefix(5) == Data("%PDF-".utf8),
      data.suffix(min(data.count, 1_024)).range(of: Data("%EOF".utf8)) != nil
    else {
      throw CompanionDocumentError.invalidDocument
    }
    let actualHash = DocumentIdentity.contentHash(for: data)
    guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
      throw CompanionDocumentError.invalidDocument
    }
    guard let document = PDFDocument(data: data), !document.isLocked,
      document.pageCount > 0, document.pageCount == expectedPageCount
    else {
      throw CompanionDocumentError.invalidDocument
    }
    for pageIndex in 0..<document.pageCount {
      guard document.page(at: pageIndex) != nil else {
        throw CompanionDocumentError.invalidDocument
      }
    }
  }

  private nonisolated static func validateCompanionMetadata(
    annotations: [ReaderAnnotation]?,
    nativeRefs: [String]?,
    quickLinks: [ReaderQuickLink]?,
    readingState: ReadingState?,
    pageCount: Int
  ) throws {
    if let annotations {
      guard (try? ReaderAnnotationValidator.validate(annotations)) != nil,
        annotations.allSatisfy({ (1...pageCount).contains($0.page) })
      else { throw CompanionDocumentError.invalidDocument }
    }
    if let nativeRefs {
      guard (try? ReaderAnnotationValidator.validateNativeReferences(nativeRefs)) != nil else {
        throw CompanionDocumentError.invalidDocument
      }
    }
    if let quickLinks {
      guard (try? ReaderQuickLinkValidator.validate(quickLinks)) != nil,
        quickLinks.allSatisfy({
          (1...pageCount).contains($0.origin.page) && (1...pageCount).contains($0.result.page)
        })
      else { throw CompanionDocumentError.invalidDocument }
    }
    if let readingState {
      guard (1...pageCount).contains(readingState.page),
        readingState.zoom.isFinite, readingState.zoom >= 0.1
      else { throw CompanionDocumentError.invalidDocument }
    }
  }

  private nonisolated static func check(_ response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw CompanionDocumentError.invalidResponse
    }
    switch http.statusCode {
    case 200..<300:
      return
    case 401:
      throw CompanionDocumentError.wrongPairingCode
    case 404:
      throw CompanionDocumentError.desktopUpdateRequired
    case 409:
      throw CompanionDocumentError.documentBusy
    case 429:
      throw CompanionDocumentError.rateLimited
    case 400, 422:
      throw CompanionDocumentError.invalidRequest
    default:
      throw CompanionDocumentError.httpStatus(http.statusCode)
    }
  }

  fileprivate nonisolated static func mapTransportError(_ error: Error) -> Error {
    if error is CompanionDocumentError { return error }
    if error is CancellationError { return error }
    if error is URLError { return CompanionDocumentError.networkFailure }
    return CompanionDocumentError.networkFailure
  }

  private nonisolated static func sleep(seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0.001), 86_400) * 1_000_000_000))
  }
}
