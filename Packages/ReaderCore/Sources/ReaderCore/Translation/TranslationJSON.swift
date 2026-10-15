import CryptoKit
import Foundation

/// A small JSON value used where translation settings must be copied without
/// exposing secrets or relying on `Any` across concurrency boundaries.
public enum TranslationJSON: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([TranslationJSON])
  case object([String: TranslationJSON])

  public init(_ value: Any) {
    switch value {
    case is NSNull:
      self = .null
    case let value as Bool:
      self = .bool(value)
    case let value as Int:
      self = .number(Double(value))
    case let value as UInt:
      self = .number(Double(value))
    case let value as Double where value.isFinite:
      self = .number(value)
    case let value as Float where value.isFinite:
      self = .number(Double(value))
    case let value as String:
      self = .string(value)
    case let value as [Any]:
      self = .array(value.map(TranslationJSON.init))
    case let value as [String: Any]:
      self = .object(value.mapValues(TranslationJSON.init))
    default:
      self = .null
    }
  }

  public var anyValue: Any {
    switch self {
    case .null:
      return NSNull()
    case let .bool(value):
      return value
    case let .number(value):
      return value
    case let .string(value):
      return value
    case let .array(value):
      return value.map(\.anyValue)
    case let .object(value):
      return value.mapValues(\.anyValue)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([TranslationJSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: TranslationJSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}

public enum TranslationJSONError: Error, LocalizedError, Sendable {
  case invalidValue

  public var errorDescription: String? {
    "The value is not valid JSON."
  }
}

/// Encodes JSON with recursively sorted object keys, matching the desktop
/// cache's `stable()` plus `JSON.stringify()` representation for its inputs.
public func stableJSONData(_ value: Any) throws -> Data {
  Data(try stableJSONString(value).utf8)
}

public func stableJSONString(_ value: Any) throws -> String {
  try encodeStableJSON(value)
}

public func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func stableSHA256Hex(_ value: Any) throws -> String {
  sha256Hex(try stableJSONData(value))
}

func jsonObjectData(_ value: Any) throws -> Data {
  guard JSONSerialization.isValidJSONObject(value) else {
    throw TranslationJSONError.invalidValue
  }
  return try JSONSerialization.data(withJSONObject: value)
}

private func encodeStableJSON(_ value: Any) throws -> String {
  if value is NSNull { return "null" }
  if let value = value as? Bool { return value ? "true" : "false" }
  if let value = value as? String { return encodeJSONString(value) }
  if let value = value as? [Any] {
    let members = try value.map(encodeStableJSON)
    return "[" + members.joined(separator: ",") + "]"
  }
  if let value = value as? [String: Any] {
    let members = try value.keys.sorted().map { key in
      "\(encodeJSONString(key)):\(try encodeStableJSON(value[key] as Any))"
    }
    return "{" + members.joined(separator: ",") + "}"
  }
  if let value = value as? NSNumber {
    guard value.doubleValue.isFinite else { return "null" }
    let data = try JSONSerialization.data(withJSONObject: [value])
    let encoded = String(decoding: data, as: UTF8.self)
    return String(encoded.dropFirst().dropLast())
  }
  if let value = value as? Double {
    guard value.isFinite else { return "null" }
    return try encodeStableJSON(NSNumber(value: value))
  }
  if let value = value as? Float {
    guard value.isFinite else { return "null" }
    return try encodeStableJSON(NSNumber(value: value))
  }
  if let value = value as? Int { return try encodeStableJSON(NSNumber(value: value)) }
  if let value = value as? UInt { return try encodeStableJSON(NSNumber(value: value)) }
  throw TranslationJSONError.invalidValue
}

private func encodeJSONString(_ value: String) -> String {
  let hex = Array("0123456789abcdef")
  var result = "\""
  for scalar in value.unicodeScalars {
    switch scalar.value {
    case 0x08: result += "\\b"
    case 0x09: result += "\\t"
    case 0x0A: result += "\\n"
    case 0x0C: result += "\\f"
    case 0x0D: result += "\\r"
    case 0x22: result += "\\\""
    case 0x5C: result += "\\\\"
    case 0...0x1F:
      let value = scalar.value
      result += "\\u00\(hex[Int((value >> 4) & 0xF)])\(hex[Int(value & 0xF)])"
    default:
      result.unicodeScalars.append(scalar)
    }
  }
  result += "\""
  return result
}
