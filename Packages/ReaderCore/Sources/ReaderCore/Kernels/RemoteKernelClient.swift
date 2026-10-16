import Foundation

@preconcurrency import PDFKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Normalizes the user-entered base URL used by a zotero-pdf2zh server.
///
/// This intentionally mirrors the desktop client: query strings and fragments
/// are not part of the server identity, credentials are rejected, and a base
/// path is preserved.
public func normalizeRemoteKernelUrl(_ value: String?) -> String {
  guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return ""
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard var components = URLComponents(string: trimmed),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    let host = components.host,
    !host.isEmpty,
    components.user == nil,
    components.password == nil
  else {
    return ""
  }

  components.scheme = scheme
  components.query = nil
  components.fragment = nil
  components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
  guard let normalized = components.string, URL(string: normalized) != nil else {
    return ""
  }
  return normalized
}

/// URL form of ``normalizeRemoteKernelUrl(_:)`` for callers that need to build
/// URL requests without repeating validation.
public func normalizedRemoteKernelURL(_ value: String?) -> URL? {
  let normalized = normalizeRemoteKernelUrl(value)
  return normalized.isEmpty ? nil : URL(string: normalized)
}

public struct RemoteKernelHealth: Sendable, Equatable {
  public let ok: Bool
  public let version: String
  public let reason: String

  public init(ok: Bool, version: String = "", reason: String = "") {
    self.ok = ok
    self.version = version
    self.reason = reason
  }
}

public struct RemoteKernelProgress: Sendable, Equatable {
  public let stage: String
  public let completed: Double
  public let total: Double
  public let percent: Double

  public init(stage: String, completed: Double, total: Double = 100, percent: Double) {
    self.stage = String(stage.prefix(200))
    self.completed = completed
    self.total = total
    self.percent = percent
  }
}

public struct RemoteKernelConfiguration: Sendable {
  public var healthTimeout: TimeInterval
  public var healthTTL: TimeInterval
  public var pollInterval: TimeInterval
  public var submitTimeout: TimeInterval
  public var downloadTimeout: TimeInterval
  public var pollTimeout: TimeInterval
  public var jobTimeout: TimeInterval
  public var maxPollFailures: Int
  public var maxResponseBytes: Int

  public init(
    healthTimeout: TimeInterval = 3,
    healthTTL: TimeInterval = 15,
    pollInterval: TimeInterval = 1,
    submitTimeout: TimeInterval = 60,
    downloadTimeout: TimeInterval = 120,
    pollTimeout: TimeInterval = 10,
    jobTimeout: TimeInterval = 15 * 60,
    maxPollFailures: Int = 5,
    maxResponseBytes: Int = 200 * 1024 * 1024
  ) {
    self.healthTimeout = healthTimeout
    self.healthTTL = healthTTL
    self.pollInterval = pollInterval
    self.submitTimeout = submitTimeout
    self.downloadTimeout = downloadTimeout
    self.pollTimeout = pollTimeout
    self.jobTimeout = jobTimeout
    self.maxPollFailures = max(1, maxPollFailures)
    self.maxResponseBytes = max(1, maxResponseBytes)
  }
}

public enum RemoteKernelError: Error, LocalizedError, Sendable, Equatable {
  case invalidServerURL
  case invalidPDF
  case pageOutOfRange
  case timeout(String)
  case httpStatus(Int)
  case invalidResponse(String)
  case remoteFailure(String)
  case noTaskID
  case stoppedResponding
  case resultTooLarge
  case resultNotPDF

  public var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      return ReaderLocalization.resolve("Invalid server URL")
    case .invalidPDF:
      return ReaderLocalization.resolve("The PDF data is invalid")
    case .pageOutOfRange:
      return ReaderLocalization.resolve("Page is out of range")
    case let .timeout(operation):
      return ReaderLocalization.string("Remote {0} timed out", operation)
    case let .httpStatus(status):
      return ReaderLocalization.string("HTTP {0}", String(status))
    case let .invalidResponse(message):
      return message
    case let .remoteFailure(message):
      return ReaderLocalization.string("Remote translation failed: {0}", message)
    case .noTaskID:
      return ReaderLocalization.resolve("Remote server sent no task id")
    case .stoppedResponding:
      return ReaderLocalization.resolve("Remote server stopped responding")
    case .resultTooLarge:
      return ReaderLocalization.resolve("Remote result is too large")
    case .resultNotPDF:
      return ReaderLocalization.resolve("Remote result is not a PDF")
    }
  }
}

/// The accepted zotero-pdf2zh upload protocol for one page.
public struct RemoteKernelPageRequest: Sendable {
  public var url: String
  public var bytes: Data
  /// One-based page number, matching the desktop server API.
  public var page: Int
  public var language: String
  public var sourceLanguage: String?
  public var service: String
  public var threads: Int

  public init(
    url: String,
    bytes: Data,
    page: Int,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "",
    threads: Int = 2
  ) {
    self.url = url
    self.bytes = bytes
    self.page = page
    self.language = language
    self.sourceLanguage = sourceLanguage
    self.service = service
    self.threads = threads
  }
}

/// A small client for the asynchronous zotero-pdf2zh server protocol.
public actor RemoteKernelClient {
  private struct HealthEntry {
    var at: Date
    var value: RemoteKernelHealth
  }

  private struct PollResult {
    var record: [String: Any]?
    var reached: Bool
  }

  private struct ProgressEstimator {
    var percent = 0.0

    mutating func update(message: String, reported: Double) -> Double {
      let lower = message.lowercased()
      var floor = 0.0
      if let match = message.range(of: #"\btranslate\s+(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
        let counter = String(message[match])
        let numbers = counter
          .split(whereSeparator: { $0 == " " || $0 == "/" })
          .compactMap { Double($0) }
        if numbers.count == 2, numbers[0] > 0, numbers[1] > 0 {
          floor = 15 + (75 * min(numbers[0], numbers[1]) / numbers[1])
        }
      }
      if floor == 0 {
        let stageFloors: [(String, Double)] = [
          ("初始化", 3),
          ("initializ", 3),
          ("parse pdf", 8),
          ("intermediate representation", 8),
          ("scanned", 12),
          ("layout", 18),
          ("parse paragraphs", 25),
          ("formulas", 30),
          ("styles", 30),
          ("term", 35),
          ("translate paragraphs", 40),
          ("typeset", 80),
          ("font", 88),
          ("drawing", 92),
          ("save", 95),
        ]
        floor = stageFloors.first(where: { lower.contains($0.0.lowercased()) })?.1 ?? 0
      }
      let server = min(99, max(0, reported.isFinite ? reported : 0))
      percent = max(percent, floor, server, percent + (90 - percent) * 0.03)
      return min(99, percent)
    }
  }

  private let session: URLSession
  private let configuration: RemoteKernelConfiguration
  private let now: @Sendable () -> Date
  private var healthCache: [String: HealthEntry] = [:]
  private var pendingHealth: [String: Task<RemoteKernelHealth, Never>] = [:]

  public init(
    session: URLSession = .shared,
    configuration: RemoteKernelConfiguration = .init(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.session = session
    self.configuration = configuration
    self.now = now
  }

  /// Checks `/health`, caching both successful and unsuccessful results for a
  /// short period so a visible-page burst performs one probe.
  public func health(_ url: String?, force: Bool = false) async -> RemoteKernelHealth {
    let base = normalizeRemoteKernelUrl(url)
    guard !base.isEmpty else {
      return RemoteKernelHealth(ok: false, reason: RemoteKernelError.invalidServerURL.localizedDescription)
    }
    if Task.isCancelled {
      return RemoteKernelHealth(ok: false, reason: "Cancelled")
    }
    if !force, let cached = healthCache[base], now().timeIntervalSince(cached.at) < configuration.healthTTL {
      return cached.value
    }
    if !force, let pending = pendingHealth[base] {
      let value = await pending.value
      return Task.isCancelled ? RemoteKernelHealth(ok: false, reason: "Cancelled") : value
    }

    let clientSession = session
    let timeout = configuration.healthTimeout
    let task = Task<RemoteKernelHealth, Never> {
      do {
        let requestURL = URL(string: base + "/health")!
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await Self.requestData(
          session: clientSession,
          request: request,
          timeout: timeout,
          operation: "health"
        )
        guard let http = response as? HTTPURLResponse else {
          return RemoteKernelHealth(ok: false, reason: "Invalid health response")
        }
        guard (200..<300).contains(http.statusCode) else {
          return RemoteKernelHealth(ok: false, reason: "HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return RemoteKernelHealth(ok: false, reason: "Unexpected health response")
        }
        guard (object["status"] as? String) == "ok" else {
          return RemoteKernelHealth(ok: false, reason: "Unexpected health response")
        }
        return RemoteKernelHealth(ok: true, version: object["version"] as? String ?? "")
      } catch {
        return RemoteKernelHealth(ok: false, reason: error.localizedDescription)
      }
    }
    pendingHealth[base] = task
    let value = await task.value
    pendingHealth.removeValue(forKey: base)
    healthCache[base] = HealthEntry(at: now(), value: value)
    return Task.isCancelled ? RemoteKernelHealth(ok: false, reason: "Cancelled") : value
  }

  public func markUnhealthy(_ url: String?, reason: String = "Remote job failed") {
    let base = normalizeRemoteKernelUrl(url)
    guard !base.isEmpty else { return }
    healthCache[base] = HealthEntry(at: now(), value: RemoteKernelHealth(ok: false, reason: reason))
  }

  public func translatePage(
    _ request: RemoteKernelPageRequest,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    try Task.checkCancellation()
    let base = normalizeRemoteKernelUrl(request.url)
    guard !base.isEmpty else { throw RemoteKernelError.invalidServerURL }

    let upload = try Self.singlePage(bytes: request.bytes, page: request.page)
    try Task.checkCancellation()
    let uploadName = "pdfmathreader-\(UUID().uuidString).pdf"
    var body: [String: Any] = [
      "fileName": uploadName,
      "fileContent": upload.base64EncodedString(),
      "engine": "pdf2zh_next",
      "sourceLang": request.sourceLanguage ?? "en",
      "targetLang": request.language,
      "qps": max(1, request.threads),
      "mono": true,
      "dual": false,
      "noMono": false,
      "noDual": true,
      "asyncJob": true,
    ]
    let service = request.service.trimmingCharacters(in: .whitespacesAndNewlines)
    if !service.isEmpty {
      body["service"] = service
      body["next_service"] = service
    }

    let deadline = now().addingTimeInterval(configuration.jobTimeout)
    var estimator = ProgressEstimator()
    let initial = estimator.update(message: "", reported: 0)
    onProgress?(RemoteKernelProgress(stage: "Remote translation", completed: initial, percent: initial))

    let requestData = try JSONSerialization.data(withJSONObject: body, options: [])
    var submit = URLRequest(url: URL(string: base + "/translate")!)
    submit.httpMethod = "POST"
    submit.httpBody = requestData
    submit.cachePolicy = .reloadIgnoringLocalCacheData
    submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
    submit.setValue("accepted", forHTTPHeaderField: "X-PDF2zh-Protocol")
    let (submitData, submitResponse) = try await Self.requestData(
      session: session,
      request: submit,
      timeout: configuration.submitTimeout,
      operation: "submission"
    )
    try Task.checkCancellation()
    guard let submitHTTP = submitResponse as? HTTPURLResponse else {
      throw RemoteKernelError.invalidResponse(
        ReaderLocalization.resolve("Remote server returned an invalid response")
      )
    }
    guard let payload = try JSONSerialization.jsonObject(with: submitData) as? [String: Any] else {
      throw RemoteKernelError.invalidResponse(
        ReaderLocalization.string("Remote server returned HTTP {0}", String(submitHTTP.statusCode))
      )
    }
    let payloadStatus = payload["status"] as? String
    if !(200..<300).contains(submitHTTP.statusCode) || payloadStatus == "error" {
      let message = (payload["message"] as? String) ?? "HTTP \(submitHTTP.statusCode)"
      throw RemoteKernelError.remoteFailure(message)
    }

    var files: [String]?
    if let listed = payload["fileList"] as? [Any] {
      files = listed.compactMap { $0 as? String }
    } else {
      files = nil
    }
    if files == nil {
      let id = Self.taskID(from: payload)
      guard payloadStatus == "accepted", !id.isEmpty else { throw RemoteKernelError.noTaskID }
      var failures = 0
      while files == nil {
        try Task.checkCancellation()
        if now() > deadline { throw RemoteKernelError.timeout("translation") }
        let polled = try await findRecord(base: base, id: id)
        failures = polled.reached ? 0 : failures + 1
        if failures >= configuration.maxPollFailures { throw RemoteKernelError.stoppedResponding }
        if let record = polled.record {
          let status = (record["status"] as? String ?? "").lowercased()
          if status == "failed" || status == "失败" {
            let message = (record["error"] as? String)
              ?? (record["message"] as? String)
              ?? (record["status"] as? String)
              ?? "failed"
            throw RemoteKernelError.remoteFailure(message)
          }
          let result = record["result"] as? [String: Any]
          let listed = (result?["fileList"] as? [Any]) ?? (record["fileList"] as? [Any])
          let finished = (record["finished"] as? Bool) == true
          if let listed, !listed.isEmpty, finished {
            files = listed.compactMap { $0 as? String }
          } else if !finished {
            let message = record["message"] as? String ?? ""
            let reported = Self.doubleValue(record["progress"])
            let percent = estimator.update(message: message, reported: reported)
            onProgress?(RemoteKernelProgress(stage: message, completed: percent, percent: percent))
          }
        }
        if files == nil {
          try await Self.sleep(seconds: configuration.pollInterval)
        }
      }
    }

    guard let names = files else {
      throw RemoteKernelError.invalidResponse(ReaderLocalization.resolve("No translated files"))
    }
    guard let name = Self.pickTranslatedFile(names) else {
      throw RemoteKernelError.invalidResponse(
        ReaderLocalization.resolve("Remote server returned no translated PDF")
      )
    }
    let translated = try await download(base: base, name: name)
    try Task.checkCancellation()
    return try Self.singlePage(bytes: translated, page: 1)
  }

  public func translatePage(
    url: String,
    bytes: Data,
    page: Int,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "",
    threads: Int = 2,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    try await translatePage(
      RemoteKernelPageRequest(
        url: url,
        bytes: bytes,
        page: page,
        language: language,
        sourceLanguage: sourceLanguage,
        service: service,
        threads: threads
      ),
      onProgress: onProgress
    )
  }

  private func findRecord(base: String, id: String) async throws -> PollResult {
    var reached = false
    for (path, key) in [("/api/tasks", "tasks"), ("/api/history", "history")] {
      do {
        let object = try await getJSON(URL(string: base + path)!, timeout: configuration.pollTimeout)
        reached = true
        let list = object[key] as? [[String: Any]]
        if let record = list?.first(where: { Self.taskID(from: $0) == id }) {
          return PollResult(record: record, reached: reached)
        }
      } catch {
        if Task.isCancelled { throw CancellationError() }
      }
    }
    return PollResult(record: nil, reached: reached)
  }

  private func getJSON(_ url: URL, timeout: TimeInterval) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await Self.requestData(
      session: session,
      request: request,
      timeout: timeout,
      operation: "poll"
    )
    guard let http = response as? HTTPURLResponse else {
      throw RemoteKernelError.invalidResponse(ReaderLocalization.resolve("Invalid polling response"))
    }
    guard (200..<300).contains(http.statusCode) else { throw RemoteKernelError.httpStatus(http.statusCode) }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RemoteKernelError.invalidResponse(ReaderLocalization.resolve("Invalid polling response"))
    }
    return object
  }

  private func download(base: String, name: String) async throws -> Data {
    try Task.checkCancellation()
    var request = URLRequest(url: URL(string: base + "/translatedFile/" + Self.percentEncode(name))!)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await Self.requestData(
      session: session,
      request: request,
      timeout: configuration.downloadTimeout,
      operation: "download"
    )
    if let http = response as? HTTPURLResponse {
      guard (200..<300).contains(http.statusCode) else { throw RemoteKernelError.httpStatus(http.statusCode) }
      if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
        length > configuration.maxResponseBytes
      {
        throw RemoteKernelError.resultTooLarge
      }
    }
    guard data.count <= configuration.maxResponseBytes else { throw RemoteKernelError.resultTooLarge }
    guard data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else {
      throw RemoteKernelError.resultNotPDF
    }
    return data
  }

  private static func singlePage(bytes: Data, page: Int) throws -> Data {
    guard let source = PDFDocument(data: bytes) else { throw RemoteKernelError.invalidPDF }
    guard page >= 1, page <= source.pageCount, let sourcePage = source.page(at: page - 1) else {
      throw RemoteKernelError.pageOutOfRange
    }
    let output = PDFDocument()
    let pageToInsert = (sourcePage.copy() as? PDFPage) ?? sourcePage
    output.insert(pageToInsert, at: 0)
    guard let result = output.dataRepresentation() else { throw RemoteKernelError.invalidPDF }
    return result
  }

  private static func requestData(
    session: URLSession,
    request: URLRequest,
    timeout: TimeInterval,
    operation: String
  ) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
      group.addTask {
        do {
          return try await session.data(for: request)
        } catch {
          if Task.isCancelled { throw CancellationError() }
          throw error
        }
      }
      group.addTask {
        try await Self.sleep(seconds: timeout)
        throw RemoteKernelError.timeout(operation)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw RemoteKernelError.timeout(operation)
      }
      return result
    }
  }

  private static func sleep(seconds: TimeInterval) async throws {
    if seconds <= 0 { return }
    let nanoseconds = UInt64(min(seconds, 86_400) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private static func taskID(from record: [String: Any]) -> String {
    if let taskID = record["taskId"] as? String { return taskID }
    if let taskID = record["task_id"] as? String { return taskID }
    if let taskID = record["taskId"] as? NSNumber { return taskID.stringValue }
    if let taskID = record["task_id"] as? NSNumber { return taskID.stringValue }
    return ""
  }

  private static func doubleValue(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String, let number = Double(value) { return number }
    return 0
  }

  private static func pickTranslatedFile(_ names: [String]) -> String? {
    let pdfs = names.filter { $0.lowercased().hasSuffix(".pdf") }
    if let mono = pdfs.first(where: { $0.lowercased().hasSuffix(".mono.pdf") }) { return mono }
    return pdfs.first(where: {
      let lower = $0.lowercased()
      return lower.contains("mono") && !lower.contains("dual") && !lower.contains("compare") && !lower.contains("cut")
    })
  }

  private static func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }
}
