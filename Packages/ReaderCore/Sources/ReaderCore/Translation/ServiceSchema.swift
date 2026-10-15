import Foundation

public enum TranslationServiceFieldType: String, Sendable, Codable {
  case text
  case string
  case url
  case number
  case integer
  case boolean
}

public struct TranslationServiceField: Sendable, Codable, Equatable {
  public var id: String
  public var label: String
  public var type: TranslationServiceFieldType
  public var secret: Bool
  public var defaultValue: TranslationJSON?
  public var required: Bool
  public var choices: [TranslationJSON]?
  public var minimum: Double?
  public var maximum: Double?
  public var integer: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case label
    case type
    case secret
    case defaultValue = "default"
    case required
    case choices
    case minimum = "min"
    case maximum = "max"
    case integer
  }

  public init(
    id: String,
    label: String? = nil,
    type: TranslationServiceFieldType = .text,
    secret: Bool = false,
    defaultValue: TranslationJSON? = nil,
    required: Bool = false,
    choices: [TranslationJSON]? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    integer: Bool = false
  ) {
    self.id = id
    self.label = label ?? id
    self.type = type
    self.secret = secret
    self.defaultValue = defaultValue
    self.required = required
    self.choices = choices
    self.minimum = minimum
    self.maximum = maximum
    self.integer = integer
  }
}

public struct TranslationServiceDescriptor: Sendable, Codable, Equatable {
  public var id: String
  public var label: String
  public var fields: [TranslationServiceField]
  public var available: Bool?
  public var supportsPrompt: Bool?
  public var custom: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case label
    case fields
    case available
    case supportsPrompt
    case custom
  }

  public init(
    id: String,
    label: String? = nil,
    fields: [TranslationServiceField] = [],
    available: Bool? = nil,
    supportsPrompt: Bool? = nil,
    custom: Bool? = nil
  ) {
    self.id = id
    self.label = label ?? id
    self.fields = fields
    self.available = available
    self.supportsPrompt = supportsPrompt
    self.custom = custom
  }
}

public struct TranslationServiceSchema: Sendable, Codable, Equatable {
  public var id: String
  public var version: String
  public var services: [TranslationServiceDescriptor]
  public var reason: String?

  public init(id: String, version: String = "", services: [TranslationServiceDescriptor] = [], reason: String? = nil) {
    self.id = id
    self.version = version
    self.services = services
    self.reason = reason
  }
}

private let serviceIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#)
private let fieldIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#)

public func validServiceId(_ value: String) -> Bool {
  serviceIDRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

private func validFieldId(_ value: String) -> Bool {
  fieldIDRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

private func isSecretFieldId(_ value: String) -> Bool {
  value.range(
    of: #"(?:api[_-]?key|auth[_-]?key|access[_-]?token)|(?:^|[_-])(token|secret|password|credential|key)(?:$|[_-])"#,
    options: [.regularExpression, .caseInsensitive]
  ) != nil
}

private func record(_ value: Any?) -> [String: Any]? {
  value as? [String: Any]
}

private func finiteNumber(_ value: Any?) -> Double? {
  if value is Bool { return nil }
  if let value = value as? Double, value.isFinite { return value }
  if let value = value as? Float, value.isFinite { return Double(value) }
  if let value = value as? Int { return Double(value) }
  if let value = value as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
  return nil
}

private func normalizedField(_ field: [String: Any]) -> [String: Any]? {
  guard let id = field["id"] as? String, validFieldId(id) else { return nil }
  let typeValue = field["type"] as? String ?? "text"
  let type = ["text", "string", "url", "number", "integer", "boolean"].contains(typeValue)
    ? typeValue : "text"
  var result: [String: Any] = [
    "id": id,
    "label": (field["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
    "type": type,
    "secret": (field["secret"] as? Bool) == true,
    "required": (field["required"] as? Bool) == true,
    "integer": (field["integer"] as? Bool) == true,
  ]
  if let value = field["default"] { result["default"] = value }
  if let choices = field["choices"] as? [Any] { result["choices"] = Array(choices.prefix(100)) }
  if let value = finiteNumber(field["min"]) { result["min"] = value }
  if let value = finiteNumber(field["max"]) { result["max"] = value }
  return result
}

private func normalizedService(_ service: [String: Any]) -> [String: Any]? {
  guard let id = service["id"] as? String, validServiceId(id) else { return nil }
  var seen = Set<String>()
  let fields = (service["fields"] as? [[String: Any] ] ?? []).compactMap { field -> [String: Any]? in
    guard let normalized = normalizedField(field), let id = normalized["id"] as? String, seen.insert(id).inserted else {
      return nil
    }
    return normalized
  }
  var result: [String: Any] = [
    "id": id,
    "label": (service["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
    "fields": fields,
  ]
  if let available = service["available"] as? Bool { result["available"] = available }
  if let supportsPrompt = service["supportsPrompt"] as? Bool { result["supportsPrompt"] = supportsPrompt }
  return result
}

public func normalizeTranslationServiceSchema(
  _ raw: [String: Any]?,
  engine: String,
  version: String = ""
) -> [String: Any] {
  let source = raw ?? [:]
  var seen = Set<String>()
  let services = (source["services"] as? [[String: Any]] ?? []).compactMap { service -> [String: Any]? in
    guard let normalized = normalizedService(service), let id = normalized["id"] as? String, seen.insert(id).inserted else {
      return nil
    }
    return normalized
  }
  var result: [String: Any] = [
    "id": (source["id"] as? String).flatMap { validServiceId($0) ? $0 : nil } ?? engine,
    "version": source["version"] as? String ?? version,
    "services": services,
  ]
  if let reason = source["reason"] as? String, !reason.isEmpty { result["reason"] = reason }
  return result
}

public func cloneTranslationServices(_ value: [String: Any]?) -> [String: Any] {
  guard let value else { return [:] }
  var result: [String: Any] = [:]
  for (engine, rawConfig) in value {
    guard validServiceId(engine), let config = record(rawConfig),
          let id = config["id"] as? String, validServiceId(id) else { continue }
    func safeValues(_ raw: Any?) -> [String: Any] {
      guard let raw = record(raw) else { return [:] }
      return raw.reduce(into: [:]) { output, pair in
        guard validFieldId(pair.key), !isSecretFieldId(pair.key) else { return }
        if let value = pair.value as? String { output[pair.key] = value }
        else if let value = pair.value as? Bool { output[pair.key] = value }
        else if let value = finiteNumber(pair.value) { output[pair.key] = value }
      }
    }
    var profiles: [String: Any] = [:]
    if let rawProfiles = record(config["profiles"]) {
      for (service, rawProfile) in rawProfiles where validServiceId(service) {
        let profile = record(rawProfile) ?? [:]
        profiles[service] = ["values": safeValues(profile["values"])]
      }
    }
    result[engine] = ["id": id, "values": safeValues(config["values"]), "profiles": profiles]
  }
  return result
}
