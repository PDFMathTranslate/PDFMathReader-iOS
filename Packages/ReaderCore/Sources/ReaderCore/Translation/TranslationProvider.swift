import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TranslationMessage: Codable, Hashable, Sendable {
  public var role: String
  public var content: String

  public init(role: String = "user", content: String) {
    self.role = role
    self.content = content
  }
}

public struct TranslationProviderRequest: Sendable {
  public var model: String?
  public var messages: [TranslationMessage]
  public var extra: [String: TranslationJSON]

  public init(
    model: String? = nil,
    messages: [TranslationMessage],
    extra: [String: TranslationJSON] = [:]
  ) {
    self.model = model
    self.messages = messages
    self.extra = extra
  }
}

public struct TranslationProviderResponse: Sendable {
  public let statusCode: Int
  public let data: Data
  public let headers: [String: String]

  public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.data = data
    self.headers = headers
  }

  public var isOK: Bool { (200..<300).contains(statusCode) }

  public func jsonObject() throws -> Any {
    try JSONSerialization.jsonObject(with: data)
  }

  public func translationContent() -> String? {
    guard let object = try? jsonObject() as? [String: Any],
          let choices = object["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String,
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return content
  }
}

public protocol TranslationProvider: Sendable {
  var id: String { get }
  var model: String { get }
  var cacheIdentity: [String: String]? { get }
  func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse
}

public enum TranslationProviderError: Error, LocalizedError, Sendable, Equatable {
  case invalidBaseURL
  case cancelled
  case timeout
  case network(String)
  case http(provider: String, status: Int)
  case invalidResponse
  case emptyTranslation
  case emptyFreeTranslation

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return ReaderLocalization.resolve("Invalid translation base URL")
    case .cancelled:
      return ReaderLocalization.resolve("The translation request was cancelled.")
    case .timeout:
      return ReaderLocalization.resolve("The translation request timed out.")
    case let .network(message):
      return message
    case let .http(provider, status):
      if provider == "siliconflow-free" {
        return ReaderLocalization.string("SiliconFlow free service request failed ({0}). Please retry later.", String(status))
      }
      if status == 401 {
        return ReaderLocalization.resolve("OpenAI rejected the configured API key. Update it in Settings or your launch environment.")
      }
      if status == 429 {
        return ReaderLocalization.resolve("OpenAI rate limit reached. Reduce parallel requests and retry.")
      }
      return ReaderLocalization.string("OpenAI request failed ({0}).", String(status))
    case .invalidResponse:
      return ReaderLocalization.resolve("The translation service returned an invalid response.")
    case .emptyTranslation:
      return ReaderLocalization.resolve("Empty translation")
    case .emptyFreeTranslation:
      return ReaderLocalization.resolve("SiliconFlow free service returned an empty translation.")
    }
  }
}

public func validTranslation(_ response: TranslationProviderResponse) -> Bool {
  response.translationContent() != nil
}

public let FREE_ENDPOINTS: [URL] = [
  URL(string: "https://api1.pdf2zh-next.com/chatproxy")!,
  URL(string: "https://api2.pdf2zh-next.com/chatproxy")!,
]
public let FREE_SERVICE_TIMEOUT_MS = 5 * 60 * 1000

public func freeTranslationPrompt(_ text: String, _ language: String) -> String {
  "You are a professional,authentic machine translation engine.\n\n;; Treat next line as plain text input and translate it into \(language), output translation ONLY. If translation is unnecessary (e.g. proper nouns, codes, {{1}}, etc. ), return the original text. NO explanations. NO notes. Input:\n\n\(text)"
}

public func selectTranslationProvider(_ key: String?, model: String? = nil) -> (id: String, model: String, key: String?) {
  let selectedModel = model?.isEmpty == false
    ? model!
    : (ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4.1-mini")
  if let key, !key.isEmpty { return ("openai", selectedModel, key) }
  return ("siliconflow-free", "siliconflow-free", nil)
}

public final class OpenAICompatibleProvider: TranslationProvider, @unchecked Sendable {
  public let id = "openai"
  public let model: String
  public let cacheIdentity: [String: String]?
  public let baseURL: URL
  public let apiKey: String
  private let session: URLSession

  public init(
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    apiKey: String,
    model: String = "gpt-4.1-mini",
    session: URLSession = .shared
  ) throws {
    guard ["http", "https"].contains(baseURL.scheme?.lowercased()),
          baseURL.user == nil, baseURL.password == nil else {
      throw TranslationProviderError.invalidBaseURL
    }
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
    self.cacheIdentity = ["service": "openai", "baseUrl": baseURL.absoluteString, "model": model]
    self.session = session
  }

  public func requestBody(for request: TranslationProviderRequest) -> [String: Any] {
    var body = request.extra.reduce(into: [String: Any]()) { result, pair in
      result[pair.key] = pair.value.anyValue
    }
    body["messages"] = request.messages.map { message in
      var value: [String: Any] = ["role": message.role, "content": message.content]
      if let replacement = formulaInstructionReplacement(in: message.content) {
        value["content"] = replacement
      }
      return value
    }
    body["stream"] = false
    body["model"] = model
    return body
  }

  public func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    try await withTranslationTimeout(nanoseconds: 60 * 1_000_000_000) {
      try await self.send(request)
    }
  }

  private func send(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    try Task.checkCancellation()
    var url = baseURL
    url.appendPathComponent("chat/completions")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try jsonObjectData(requestBody(for: request))
    do {
      let (data, response) = try await session.data(for: urlRequest)
      let http = response as? HTTPURLResponse
      return TranslationProviderResponse(
        statusCode: http?.statusCode ?? 0,
        data: data,
        headers: http?.allHeaderFields.reduce(into: [:]) { result, item in
          if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        } ?? [:]
      )
    } catch is CancellationError {
      throw TranslationProviderError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw TranslationProviderError.cancelled
    } catch {
      throw TranslationProviderError.network(error.localizedDescription)
    }
  }

  private func formulaInstructionReplacement(in content: String) -> String? {
    let old = "Keep the formula notation {v*} unchanged."
    let replacement = "Preserve every numbered formula placeholder exactly as it appears in Source Text (for example {{v0}} or {v0}). Never output the generic wildcard {v*} or invent a placeholder."
    guard let range = content.range(of: old) else { return nil }
    var result = content
    result.replaceSubrange(range, with: replacement)
    return result
  }
}

public final class SiliconFlowFreeProvider: TranslationProvider, @unchecked Sendable {
  public let id = "siliconflow-free"
  public let model = "siliconflow-free"
  public let cacheIdentity: [String: String]? = nil
  public let language: String
  public let kernel: String?
  public let endpoints: [URL]
  private let session: URLSession
  private let retryDelay: @Sendable (Int) -> UInt64
  private let state = SiliconFlowState()

  public init(
    language: String,
    kernel: String? = nil,
    session: URLSession = .shared,
    endpoints: [URL] = FREE_ENDPOINTS,
    retryDelay: @escaping @Sendable (Int) -> UInt64 = SiliconFlowFreeProvider.defaultRetryDelay
  ) {
    self.language = language
    self.kernel = kernel
    self.session = session
    self.endpoints = endpoints
    self.retryDelay = retryDelay
  }

  public static func defaultRetryDelay(_ attempt: Int) -> UInt64 {
    let base = min(4_000.0 * pow(2.0, Double(attempt)), 60_000.0)
    let jitter = 0.75 + Double.random(in: 0...0.5)
    return UInt64(base * jitter * 1_000_000.0)
  }

  public func requestBody(for request: TranslationProviderRequest) -> [String: Any] {
    var text = request.messages.map(\.content).joined(separator: "\n\n")
    if kernel == "pdf_math_fast",
       text.hasPrefix("You are a professional, authentic machine translation engine.") {
      let marker = "\n\nSource Text: "
      let ending = "\n\nTranslated Text:"
      if let start = text.range(of: marker), let end = text.range(of: ending, range: start.upperBound..<text.endIndex),
         start.upperBound <= end.lowerBound, end.upperBound == text.endIndex {
        let source = String(text[start.upperBound..<end.lowerBound])
        text = freeTranslationPrompt(source, language) +
          "\nPreserve every numbered formula placeholder from the input exactly (for example {{v0}} or {v0}); never output {v*} or invent a placeholder."
      }
    }
    if !text.contains(";; Treat next line as plain text input and translate it into") {
      let note = "The input below is a complete task with its own rules and output format. Follow those rules exactly and return only the output they request; never translate or repeat the rules themselves.\n\n"
      text = freeTranslationPrompt(note + text, language.isEmpty ? "the language the task requests" : language)
    }
    return ["text": text]
  }

  public func complete(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    try Task.checkCancellation()
    return try await withTranslationTimeout(nanoseconds: UInt64(FREE_SERVICE_TIMEOUT_MS) * 1_000_000) {
      try await self.request(request)
    }
  }

  private func endpoint() async -> URL {
    if let selected = await state.selected { return selected }
    let found = await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
      for endpoint in endpoints {
        group.addTask { [session] in
          var request = URLRequest(url: endpoint.appendingPathComponent("check"))
          request.httpMethod = "POST"
          request.timeoutInterval = 5
          do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["status"] as? String == "ok" else { return nil }
            return endpoint
          } catch { return nil }
        }
      }
      for await value in group where value != nil {
        group.cancelAll()
        return value
      }
      return nil
    } ?? endpoints.first ?? FREE_ENDPOINTS[0]
    await state.setSelected(found)
    return found
  }

  private func throttle(_ endpoint: URL) async throws {
    let qps = await state.qps(for: endpoint, session: session)
    let start = await state.reserveStart(qps: qps)
    let now = DispatchTime.now().uptimeNanoseconds
    if start > now { try await Task.sleep(nanoseconds: start - now) }
  }

  private func request(_ request: TranslationProviderRequest) async throws -> TranslationProviderResponse {
    let payload = try jsonObjectData(requestBody(for: request))
    var attempt = 0
    var failures = 0
    while true {
      let response: TranslationProviderResponse
      do {
        response = try await freeRequest(payload: payload)
      } catch let error as TranslationProviderError {
        if case .cancelled = error { throw error }
        if case .emptyFreeTranslation = error { throw error }
        failures += 1
        if failures >= 3 { throw error }
        try await Task.sleep(nanoseconds: retryDelay(attempt))
        attempt += 1
        continue
      }
      if response.statusCode != 429 {
        if response.statusCode < 500 { return response }
        failures += 1
        if failures >= 3 { return response }
      }
      try await Task.sleep(nanoseconds: retryDelay(attempt))
      attempt += 1
    }
  }

  private func freeRequest(payload: Data) async throws -> TranslationProviderResponse {
    let first = await endpoint()
    try await throttle(first)
    for endpoint in [first] + endpoints.filter({ $0 != first }) {
      try Task.checkCancellation()
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = payload
      do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 500 && endpoint == first { continue }
        if !(200..<300).contains(status) {
          return TranslationProviderResponse(statusCode: status, data: data)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["content"] as? String else {
          throw TranslationProviderError.emptyFreeTranslation
        }
        let content = raw.replacingOccurrences(
          of: #"<think>[\s\S]*?</think>"#,
          with: "",
          options: [.regularExpression]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw TranslationProviderError.emptyFreeTranslation }
        await state.setSelected(endpoint)
        let responseObject: [String: Any] = [
          "model": model,
          "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        return TranslationProviderResponse(statusCode: 200, data: try jsonObjectData(responseObject))
      } catch let error as TranslationProviderError {
        throw error
      } catch is CancellationError {
        throw TranslationProviderError.cancelled
      } catch let error as URLError where error.code == .cancelled {
        throw TranslationProviderError.cancelled
      } catch {
        if endpoint != first { throw TranslationProviderError.network(error.localizedDescription) }
        continue
      }
    }
    throw TranslationProviderError.network(
      ReaderLocalization.resolve("SiliconFlow free service endpoints are unavailable.")
    )
  }
}

private func withTranslationTimeout<T: Sendable>(
  nanoseconds: UInt64,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask(operation: operation)
    group.addTask {
      try await Task.sleep(nanoseconds: nanoseconds)
      throw TranslationProviderError.timeout
    }
    guard let result = try await group.next() else { throw TranslationProviderError.timeout }
    group.cancelAll()
    return result
  }
}

private actor SiliconFlowState {
  private(set) var selected: URL?
  private var qpsTasks: [URL: Task<Int, Never>] = [:]
  private var nextStart: UInt64 = 0

  func setSelected(_ endpoint: URL) {
    selected = endpoint
  }

  func qps(for endpoint: URL, session: URLSession) async -> Int {
    if let task = qpsTasks[endpoint] { return await task.value }
    let task = Task<Int, Never> {
      var request = URLRequest(url: endpoint.appendingPathComponent("config"))
      request.timeoutInterval = 5
      do {
        let (data, response) = try await session.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if (response as? HTTPURLResponse)?.statusCode == 200,
           object?["status"] as? String == "ok",
           let value = object?["qps"] as? Int, value > 0 {
          return value
        }
      } catch {}
      return 10
    }
    qpsTasks[endpoint] = task
    return await task.value
  }

  func reserveStart(qps: Int) -> UInt64 {
    let interval = UInt64(1_000_000_000 / UInt64(max(qps, 1)))
    let now = DispatchTime.now().uptimeNanoseconds
    let start = max(now, nextStart)
    nextStart = start + interval
    return start
  }
}
