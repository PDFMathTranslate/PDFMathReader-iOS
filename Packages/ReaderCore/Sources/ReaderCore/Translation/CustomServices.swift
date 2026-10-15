import Foundation

public let CUSTOM_SERVICE_PREFIX = "custom-"
public let CUSTOM_CREDENTIAL_BUCKET = "custom"
public let MAX_CUSTOM_SERVICES = 32
public let MAX_CUSTOM_SERVICE_NAME = 80

public struct CustomTranslationService: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var baseURL: String
  public var model: String

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case baseURL = "base_url"
    case model
  }

  public init(id: String, name: String, baseURL: String = "", model: String = "") {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.model = model
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
  }
}

public struct CustomServiceBackend: Hashable, Sendable {
  public let service: String
  public let key: String
  public let baseURL: String
  public let model: String

  public init(service: String, key: String, baseURL: String, model: String) {
    self.service = service
    self.key = key
    self.baseURL = baseURL
    self.model = model
  }
}

private let customIDRegex = try! NSRegularExpression(pattern: #"^custom-[a-z0-9]{8,32}$"#)

public func isCustomServiceId(_ value: String) -> Bool {
  customIDRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

public func createCustomServiceId(bytes: [UInt8]? = nil) -> String {
  let values: [UInt8]
  if let bytes {
    values = Array(bytes.prefix(6)) + Array(repeating: 0, count: max(0, 6 - bytes.count))
  } else {
    values = (0..<6).map { _ in UInt8.random(in: 0...255) }
  }
  return CUSTOM_SERVICE_PREFIX + values.map { String(format: "%02x", $0) }.joined()
}

private func singleLine(_ value: String, limit: Int) -> Bool {
  value.utf16.count <= limit && !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
}

public func validCustomService(_ value: CustomTranslationService) -> Bool {
  isCustomServiceId(value.id) &&
    singleLine(value.name, limit: MAX_CUSTOM_SERVICE_NAME) &&
    singleLine(value.baseURL, limit: 2048) &&
    singleLine(value.model, limit: 2048)
}

public func isValidCustomServices(_ value: [CustomTranslationService]) -> Bool {
  guard value.count <= MAX_CUSTOM_SERVICES else { return false }
  var ids = Set<String>()
  for entry in value {
    guard validCustomService(entry), ids.insert(entry.id).inserted else { return false }
  }
  return true
}

public func cloneCustomServices(_ value: [CustomTranslationService]) -> [CustomTranslationService] {
  var result: [CustomTranslationService] = []
  var ids = Set<String>()
  for entry in value where validCustomService(entry) && ids.insert(entry.id).inserted {
    result.append(CustomTranslationService(id: entry.id, name: entry.name, baseURL: entry.baseURL, model: entry.model))
    if result.count == MAX_CUSTOM_SERVICES { break }
  }
  return result
}

public func customBackendFor(
  kernel: String,
  services: [TranslationServiceDescriptor]
) -> CustomServiceBackend? {
  let backend: CustomServiceBackend?
  switch kernel {
  case "pdf_inspector":
    backend = CustomServiceBackend(service: "openai", key: "key", baseURL: "base_url", model: "model")
  case "pdf_math_fast":
    backend = CustomServiceBackend(service: "openailiked", key: "api_key", baseURL: "base_url", model: "model")
  case "pdf_math_precise":
    backend = CustomServiceBackend(
      service: "openaicompatible",
      key: "openai_compatible_api_key",
      baseURL: "openai_compatible_base_url",
      model: "openai_compatible_model"
    )
  default:
    backend = nil
  }
  guard let backend, services.contains(where: { $0.id == backend.service }) else { return nil }
  return backend
}

public func customServiceDescriptors(
  kernel: String,
  services: [TranslationServiceDescriptor],
  customServices: [CustomTranslationService]
) -> [TranslationServiceDescriptor] {
  guard customBackendFor(kernel: kernel, services: services) != nil else { return [] }
  return cloneCustomServices(customServices).map {
    TranslationServiceDescriptor(
      id: $0.id,
      label: $0.name.isEmpty ? $0.id : $0.name,
      fields: [
        TranslationServiceField(id: "key", label: "API key", type: .string, secret: true, required: true),
        TranslationServiceField(id: "base_url", label: "Base URL", type: .url, required: true),
        TranslationServiceField(id: "model", label: "Model", type: .string, required: true),
      ],
      custom: true
    )
  }
}

public func withCustomProfiles(
  config: [String: Any],
  customServices: [CustomTranslationService]
) -> [String: Any] {
  var result = config
  var profiles = (config["profiles"] as? [String: Any]) ?? [:]
  var values = config["values"]
  for entry in cloneCustomServices(customServices) {
    var entryValues: [String: Any] = [:]
    if !entry.baseURL.isEmpty { entryValues["base_url"] = entry.baseURL }
    if !entry.model.isEmpty { entryValues["model"] = entry.model }
    profiles[entry.id] = ["values": entryValues]
    if config["id"] as? String == entry.id { values = entryValues }
  }
  if let values {
    result["values"] = values
  } else {
    result.removeValue(forKey: "values")
  }
  result["profiles"] = profiles
  return result
}

public func withCustomCredentials(
  credentials: [String: Any],
  kernel: String
) -> [String: Any] {
  guard !kernel.isEmpty,
        let custom = credentials[CUSTOM_CREDENTIAL_BUCKET] as? [String: Any], !custom.isEmpty else {
    return credentials
  }
  var result = credentials
  var kernelValues = (credentials[kernel] as? [String: Any]) ?? [:]
  for (id, value) in custom { kernelValues[id] = value }
  result[kernel] = kernelValues
  return result
}

public func customSelectionValues(
  id: String,
  customServices: [CustomTranslationService],
  credentials: [String: Any]
) -> [String: String]? {
  guard let entry = cloneCustomServices(customServices).first(where: { $0.id == id }) else { return nil }
  var result: [String: String] = [:]
  if !entry.baseURL.isEmpty { result["base_url"] = entry.baseURL }
  if !entry.model.isEmpty { result["model"] = entry.model }
  if let key = ((credentials[CUSTOM_CREDENTIAL_BUCKET] as? [String: Any])?[id] as? [String: Any])?["key"] as? String,
     !key.isEmpty {
    result["key"] = key
  }
  return result
}

public enum CustomServiceError: Error, LocalizedError, Sendable {
  case unsupportedKernel
  case incompleteSettings

  public var errorDescription: String? {
    switch self {
    case .unsupportedKernel: return "Unsupported translation service for this kernel"
    case .incompleteSettings: return "API key, Base URL and Model are required for this OpenAI-compatible service"
    }
  }
}

public func resolveCustomSelection(
  kernel: String,
  selection: (id: String, values: [String: String])
) throws -> (id: String, values: [String: String]) {
  guard isCustomServiceId(selection.id) else { return selection }
  let backend: CustomServiceBackend
  switch kernel {
  case "pdf_inspector": backend = CustomServiceBackend(service: "openai", key: "key", baseURL: "base_url", model: "model")
  case "pdf_math_fast": backend = CustomServiceBackend(service: "openailiked", key: "api_key", baseURL: "base_url", model: "model")
  case "pdf_math_precise": backend = CustomServiceBackend(service: "openaicompatible", key: "openai_compatible_api_key", baseURL: "openai_compatible_base_url", model: "openai_compatible_model")
  default: throw CustomServiceError.unsupportedKernel
  }
  let key = selection.values["key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let baseURL = selection.values["base_url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let model = selection.values["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !key.isEmpty, !baseURL.isEmpty, !model.isEmpty else { throw CustomServiceError.incompleteSettings }
  return (backend.service, [backend.key: key, backend.baseURL: baseURL, backend.model: model])
}
