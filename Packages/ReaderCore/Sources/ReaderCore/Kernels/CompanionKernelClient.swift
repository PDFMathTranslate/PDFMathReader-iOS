import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The desktop kernel ids the companion API serves.
public enum CompanionKernel {
  public static let fast = "pdf_math_fast"
  public static let precise = "pdf_math_precise"

  /// Translation services the computer may use for a page. `auto` lets the
  /// computer choose; credentials never leave this device.
  public static let services: Set<String> = ["auto", "siliconflow-free", "apple-local"]
}

/// Strips the separators people type between pairing-code groups, matching the
/// desktop's normalization.
public func normalizeCompanionPairingCode(_ value: String) -> String {
  String(value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
}

/// Accepts what people usually type for the computer: a full URL, or just a
/// host name or address. A bare host gets the desktop's default port.
public func normalizeCompanionURL(_ value: String?) -> String {
  let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "" }
  if trimmed.contains("://") { return normalizeRemoteKernelUrl(trimmed) }
  let candidate = "http://" + trimmed
  guard var components = URLComponents(string: candidate), components.host != nil else { return "" }
  if components.port == nil && (components.path.isEmpty || components.path == "/") {
    components.port = CompanionKernelClient.defaultPort
    guard let withDefaultPort = components.string else { return "" }
    return normalizeRemoteKernelUrl(withDefaultPort)
  }
  return normalizeRemoteKernelUrl(candidate)
}

public struct CompanionKernelStatus: Codable, Sendable, Equatable {
  public let id: String
  public let available: Bool
  public let version: String
  public let reason: String

  public init(id: String, available: Bool, version: String = "", reason: String = "") {
    self.id = id
    self.available = available
    self.version = version
    self.reason = reason
  }
}

public struct CompanionComputer: Codable, Sendable, Equatable {
  public let name: String
  public let addresses: [String]

  public init(name: String, addresses: [String]) {
    self.name = name
    self.addresses = addresses
  }
}

public struct CompanionHealth: Codable, Sendable, Equatable {
  /// The computer answered with a compatible protocol and accepted the code.
  public let ok: Bool
  public let version: String
  public let reason: String
  public let kernels: [CompanionKernelStatus]
  public let computer: CompanionComputer?

  public init(
    ok: Bool,
    version: String = "",
    reason: String = "",
    kernels: [CompanionKernelStatus] = [],
    computer: CompanionComputer? = nil
  ) {
    self.ok = ok
    self.version = version
    self.reason = reason
    self.kernels = kernels
    self.computer = computer
  }

  public func isAvailable(_ engine: String) -> Bool {
    ok && kernels.contains { $0.id == engine && $0.available }
  }
}

public enum CompanionKernelError: Error, LocalizedError, Sendable, Equatable {
  case invalidServerURL
  case missingPairingCode
  case wrongPairingCode
  case tooManyAttempts
  case busy
  case incompatibleVersion
  case timeout(String)
  case httpStatus(Int)
  case invalidResponse
  case translationFailed(String)
  case jobLost
  case resultTooLarge
  case resultNotPDF

  public var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      return ReaderLocalization.resolve("Invalid computer address")
    case .missingPairingCode:
      return ReaderLocalization.resolve("Enter the pairing code shown on your computer")
    case .wrongPairingCode:
      return ReaderLocalization.resolve("Wrong pairing code")
    case .tooManyAttempts:
      return ReaderLocalization.resolve("Too many attempts. Try again in a minute.")
    case .busy:
      return ReaderLocalization.resolve("Your computer is busy. Try again soon.")
    case .incompatibleVersion:
      return ReaderLocalization.resolve("Update PDFMathReader on your computer")
    case let .timeout(operation):
      return ReaderLocalization.string("Your computer did not respond ({0})", operation)
    case let .httpStatus(status):
      return ReaderLocalization.string("HTTP {0}", String(status))
    case .invalidResponse:
      return ReaderLocalization.resolve("Your computer sent an invalid response")
    case let .translationFailed(message):
      return message
    case .jobLost:
      return ReaderLocalization.resolve("Your computer lost the page. Try again.")
    case .resultTooLarge:
      return ReaderLocalization.resolve("The translated page is too large")
    case .resultNotPDF:
      return ReaderLocalization.resolve("The translated page is not a PDF")
    }
  }
}

public struct CompanionKernelConfiguration: Sendable {
  public var healthTimeout: TimeInterval
  public var healthTTL: TimeInterval
  public var pollInterval: TimeInterval
  public var submitTimeout: TimeInterval
  public var pollTimeout: TimeInterval
  public var downloadTimeout: TimeInterval
  public var jobTimeout: TimeInterval
  public var maxPollFailures: Int
  public var maxResponseBytes: Int

  public init(
    healthTimeout: TimeInterval = 4,
    healthTTL: TimeInterval = 15,
    pollInterval: TimeInterval = 0.75,
    submitTimeout: TimeInterval = 60,
    pollTimeout: TimeInterval = 10,
    downloadTimeout: TimeInterval = 120,
    jobTimeout: TimeInterval = 15 * 60,
    maxPollFailures: Int = 5,
    maxResponseBytes: Int = 200 * 1024 * 1024
  ) {
    self.healthTimeout = healthTimeout
    self.healthTTL = healthTTL
    self.pollInterval = pollInterval
    self.submitTimeout = submitTimeout
    self.pollTimeout = pollTimeout
    self.downloadTimeout = downloadTimeout
    self.jobTimeout = jobTimeout
    self.maxPollFailures = max(1, maxPollFailures)
    self.maxResponseBytes = max(1, maxResponseBytes)
  }
}

/// Client for the PDFMathReader desktop companion API (protocol 1): the desktop
/// app runs its local Fast and Precise kernels for one-page PDFs sent from here.
public actor CompanionKernelClient {
  public static let protocolVersion = 1
  public static let defaultPort = 8891

  private struct HealthEntry {
    var at: Date
    var value: CompanionHealth
  }

  private struct HealthBody: Decodable {
    var status: String?
    var app: String?
    var `protocol`: Int?
    var version: String?
    var kernels: [CompanionKernelStatus]?
    var computer: CompanionComputer?
  }

  private struct JobBody: Decodable {
    var id: String?
    var state: String?
    var stage: String?
    var percent: Double?
    var error: String?
  }

  private struct JobRequest: Encodable {
    var engine: String
    var language: String
    var sourceLanguage: String?
    var service: String
    var glossary: [GlossaryEntry]
    var pdf: String
  }

  private let session: URLSession
  private let configuration: CompanionKernelConfiguration
  private let now: @Sendable () -> Date
  private var healthCache: [String: HealthEntry] = [:]

  public init(
    session: URLSession = .shared,
    configuration: CompanionKernelConfiguration = .init(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.session = session
    self.configuration = configuration
    self.now = now
  }

  /// Checks the computer and which kernels it has installed. Results are
  /// cached briefly so a burst of visible pages makes one probe.
  public func health(_ url: String?, pairingCode: String, force: Bool = false) async -> CompanionHealth {
    let base = normalizeCompanionURL(url)
    guard !base.isEmpty else {
      return CompanionHealth(ok: false, reason: CompanionKernelError.invalidServerURL.localizedDescription)
    }
    let code = normalizeCompanionPairingCode(pairingCode)
    guard !code.isEmpty else {
      return CompanionHealth(ok: false, reason: CompanionKernelError.missingPairingCode.localizedDescription)
    }
    let key = Self.cacheKey(base, code)
    if !force, let cached = healthCache[key], now().timeIntervalSince(cached.at) < configuration.healthTTL {
      return cached.value
    }
    let value: CompanionHealth
    do {
      let (data, response) = try await send(
        request(base, "/companion/v1/health", code: code),
        timeout: configuration.healthTimeout,
        operation: "health"
      )
      try Self.check(response)
      let body = try JSONDecoder().decode(HealthBody.self, from: data)
      if body.status != "ok" || body.app != "PDFMathReader" {
        value = CompanionHealth(ok: false, reason: CompanionKernelError.invalidResponse.localizedDescription)
      } else if body.protocol != Self.protocolVersion {
        value = CompanionHealth(
          ok: false,
          version: body.version ?? "",
          reason: CompanionKernelError.incompatibleVersion.localizedDescription,
          computer: body.computer
        )
      } else {
        value = CompanionHealth(
          ok: true,
          version: body.version ?? "",
          kernels: body.kernels ?? [],
          computer: body.computer
        )
      }
    } catch is CancellationError {
      return CompanionHealth(ok: false, reason: "Cancelled")
    } catch {
      value = CompanionHealth(ok: false, reason: Self.describe(error))
    }
    healthCache[key] = HealthEntry(at: now(), value: value)
    return value
  }

  public func markUnhealthy(_ url: String?, pairingCode: String, reason: String) {
    let base = normalizeCompanionURL(url)
    guard !base.isEmpty else { return }
    healthCache[Self.cacheKey(base, normalizeCompanionPairingCode(pairingCode))] = HealthEntry(
      at: now(),
      value: CompanionHealth(ok: false, reason: reason)
    )
  }

  /// Translates a one-page PDF on the computer and returns the translated page.
  public func translatePage(
    url: String,
    pairingCode: String,
    bytes: Data,
    engine: String,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "auto",
    glossary: [GlossaryEntry] = [],
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    let base = normalizeCompanionURL(url)
    guard !base.isEmpty else { throw CompanionKernelError.invalidServerURL }
    let code = normalizeCompanionPairingCode(pairingCode)
    guard !code.isEmpty else { throw CompanionKernelError.missingPairingCode }
    try Task.checkCancellation()

    // The desktop accepts at most 5000 entries of up to 500 characters each.
    let terms = glossary.filter {
      !$0.source.isEmpty && !$0.target.isEmpty && $0.source.count <= 500 && $0.target.count <= 500
    }
    let source = sourceLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
    var submit = request(base, "/companion/v1/jobs", code: code, method: "POST")
    submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
    submit.httpBody = try JSONEncoder().encode(
      JobRequest(
        engine: engine,
        language: language,
        sourceLanguage: source?.isEmpty == false ? source : nil,
        service: CompanionKernel.services.contains(service) ? service : "auto",
        glossary: Array(terms.prefix(5000)),
        pdf: bytes.base64EncodedString()
      )
    )
    let (created, submitResponse) = try await send(
      submit,
      timeout: configuration.submitTimeout,
      operation: "upload"
    )
    try Self.check(submitResponse, body: created)
    guard let id = try? JSONDecoder().decode(JobBody.self, from: created).id, !id.isEmpty,
      id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
    else {
      throw CompanionKernelError.invalidResponse
    }

    do {
      try await waitForJob(base: base, code: code, id: id, onProgress: onProgress)
      let data = try await download(base: base, code: code, id: id)
      onProgress?(RemoteKernelProgress(stage: "Done", completed: 100, percent: 100))
      cancelRemoteJob(base: base, code: code, id: id)
      return data
    } catch {
      // Free the computer's kernel worker when the page is no longer wanted.
      cancelRemoteJob(base: base, code: code, id: id)
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  private func waitForJob(
    base: String,
    code: String,
    id: String,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)?
  ) async throws {
    let started = now()
    var failures = 0
    var percent = 0.0
    while true {
      try Task.checkCancellation()
      if now().timeIntervalSince(started) > configuration.jobTimeout {
        throw CompanionKernelError.timeout("translation")
      }
      do {
        let (data, response) = try await send(
          request(base, "/companion/v1/jobs/\(id)", code: code),
          timeout: configuration.pollTimeout,
          operation: "status"
        )
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw CompanionKernelError.jobLost }
        try Self.check(response, body: data)
        let job = try JSONDecoder().decode(JobBody.self, from: data)
        failures = 0
        switch job.state {
        case "done":
          return
        case "failed", "cancelled":
          throw CompanionKernelError.translationFailed(job.error ?? "Translation failed")
        default:
          percent = max(percent, min(99, job.percent ?? 0))
          onProgress?(RemoteKernelProgress(stage: job.stage ?? "", completed: percent, percent: percent))
        }
      } catch let error as CompanionKernelError {
        switch error {
        case .timeout, .httpStatus, .invalidResponse:
          failures += 1
          if failures >= configuration.maxPollFailures { throw error }
        default:
          throw error
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures += 1
        if failures >= configuration.maxPollFailures { throw error }
      }
      try await Self.sleep(seconds: configuration.pollInterval)
    }
  }

  private func download(base: String, code: String, id: String) async throws -> Data {
    let (data, response) = try await send(
      request(base, "/companion/v1/jobs/\(id)/result", code: code),
      timeout: configuration.downloadTimeout,
      operation: "download"
    )
    try Self.check(response, body: data)
    guard data.count <= configuration.maxResponseBytes else { throw CompanionKernelError.resultTooLarge }
    guard data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else {
      throw CompanionKernelError.resultNotPDF
    }
    return data
  }

  private nonisolated func cancelRemoteJob(base: String, code: String, id: String) {
    let request = request(base, "/companion/v1/jobs/\(id)", code: code, method: "DELETE")
    let session = session
    Task.detached {
      _ = try? await session.data(for: request)
    }
  }

  private nonisolated func request(
    _ base: String,
    _ path: String,
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
    timeout: TimeInterval,
    operation: String
  ) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    let session = session
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
        throw CompanionKernelError.timeout(operation)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw CompanionKernelError.timeout(operation)
      }
      return result
    }
  }

  private static func check(_ response: URLResponse, body: Data = Data()) throws {
    guard let http = response as? HTTPURLResponse else { throw CompanionKernelError.invalidResponse }
    switch http.statusCode {
    case 200..<300:
      return
    case 401:
      throw CompanionKernelError.wrongPairingCode
    case 429:
      let message = (try? JSONDecoder().decode(JobBody.self, from: body))?.error ?? ""
      throw message.lowercased().contains("attempts") ? CompanionKernelError.tooManyAttempts : .busy
    case 400, 422:
      if let message = (try? JSONDecoder().decode(JobBody.self, from: body))?.error, !message.isEmpty {
        throw CompanionKernelError.translationFailed(message)
      }
      throw CompanionKernelError.httpStatus(http.statusCode)
    default:
      throw CompanionKernelError.httpStatus(http.statusCode)
    }
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? CompanionKernelError { return error.localizedDescription }
    if error is DecodingError { return CompanionKernelError.invalidResponse.localizedDescription }
    if let error = error as? URLError {
      switch error.code {
      case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost,
        .timedOut, .dnsLookupFailed:
        return ReaderLocalization.resolve("Can’t reach your computer. Check that PDFMathReader is open and kernel sharing is on.")
      default:
        break
      }
    }
    return error.localizedDescription
  }

  private static func cacheKey(_ base: String, _ code: String) -> String {
    // Kept in memory only; the code distinguishes a stale pairing from a new one.
    base + "\n" + code
  }

  private static func sleep(seconds: TimeInterval) async throws {
    if seconds <= 0 { return }
    try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
  }
}
