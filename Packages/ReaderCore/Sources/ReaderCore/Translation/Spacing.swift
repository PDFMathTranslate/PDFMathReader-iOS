import Foundation

private enum TranslationScript: Equatable {
  case cjk
  case western
  case other
}

private func isLetter(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
    return true
  default:
    return false
  }
}

private func isCJK(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (0x1100...0x11FF).contains(value) ||
    (0x2E80...0x2FFF).contains(value) ||
    (0x3000...0x30FF).contains(value) ||
    (0x3130...0x318F).contains(value) ||
    (0x3400...0x4DBF).contains(value) ||
    (0x4E00...0x9FFF).contains(value) ||
    (0xAC00...0xD7AF).contains(value) ||
    (0xF900...0xFAFF).contains(value) ||
    (0x20000...0x2FA1F).contains(value) ||
    (0x30000...0x3134F).contains(value)
}

private func isLatin(_ scalar: UnicodeScalar) -> Bool {
  (0x0041...0x024F).contains(scalar.value) ||
    (0x0250...0x02AF).contains(scalar.value) ||
    (0x1E00...0x1EFF).contains(scalar.value) ||
    (0x2C60...0x2C7F).contains(scalar.value) ||
    (0xA720...0xA7FF).contains(scalar.value) ||
    (0xAB30...0xAB6F).contains(scalar.value) ||
    (0x10780...0x107BF).contains(scalar.value)
}

private func isDecimalNumber(_ scalar: UnicodeScalar) -> Bool {
  scalar.properties.generalCategory == .decimalNumber
}

private func isMark(_ scalar: UnicodeScalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .nonspacingMark, .spacingMark, .enclosingMark:
    return true
  default:
    return false
  }
}

private func script(_ scalar: UnicodeScalar) -> TranslationScript {
  if isLetter(scalar) && isCJK(scalar) { return .cjk }
  if (isLetter(scalar) && isLatin(scalar)) || isDecimalNumber(scalar) { return .western }
  return .other
}

public func translationSpacing(_ text: String = "") -> String {
  var result = ""
  var previous: TranslationScript?
  for scalar in text.unicodeScalars {
    if isMark(scalar) {
      result.unicodeScalars.append(scalar)
      continue
    }
    let current = script(scalar)
    if let previous, previous != .other, current != .other, previous != current {
      result.append(" ")
    }
    result.unicodeScalars.append(scalar)
    if scalar == "%" || scalar == "％" || scalar == "‰" || scalar == "‱" {
      if previous == .western { previous = .western }
      else { previous = current == .other ? nil : current }
    } else {
      previous = current == .other ? nil : current
    }
  }
  return result
}

public func kernelTranslationSpacing(_ text: String) -> String {
  do {
    var parser = OrderedJSONParser(text)
    return serializeOrderedJSON(spaceOrderedJSON(try parser.parse()))
  } catch {
    return translationSpacing(text)
  }
}

private indirect enum OrderedJSONValue {
  case object([(String, OrderedJSONValue)])
  case array([OrderedJSONValue])
  case string(String)
  case number(String)
  case boolean(Bool)
  case null
}

private enum OrderedJSONError: Error {
  case invalid
}

private struct OrderedJSONParser {
  private let bytes: [UInt8]
  private var index = 0

  init(_ text: String) {
    bytes = Array(text.utf8)
  }

  mutating func parse() throws -> OrderedJSONValue {
    skipWhitespace()
    let value = try parseValue()
    skipWhitespace()
    guard index == bytes.count else { throw OrderedJSONError.invalid }
    return value
  }

  private mutating func parseValue() throws -> OrderedJSONValue {
    skipWhitespace()
    guard index < bytes.count else { throw OrderedJSONError.invalid }
    switch bytes[index] {
    case 0x7B: return try parseObject()
    case 0x5B: return try parseArray()
    case 0x22: return .string(try parseString())
    case 0x74:
      try expectLiteral("true")
      return .boolean(true)
    case 0x66:
      try expectLiteral("false")
      return .boolean(false)
    case 0x6E:
      try expectLiteral("null")
      return .null
    default:
      return .number(try parseNumber())
    }
  }

  private mutating func parseObject() throws -> OrderedJSONValue {
    try expect(0x7B)
    skipWhitespace()
    var members: [(String, OrderedJSONValue)] = []
    if consume(0x7D) { return .object(members) }
    while true {
      skipWhitespace()
      let key = try parseString()
      skipWhitespace()
      try expect(0x3A)
      let value = try parseValue()
      members.append((key, value))
      skipWhitespace()
      if consume(0x7D) { return .object(members) }
      try expect(0x2C)
    }
  }

  private mutating func parseArray() throws -> OrderedJSONValue {
    try expect(0x5B)
    skipWhitespace()
    var values: [OrderedJSONValue] = []
    if consume(0x5D) { return .array(values) }
    while true {
      values.append(try parseValue())
      skipWhitespace()
      if consume(0x5D) { return .array(values) }
      try expect(0x2C)
    }
  }

  private mutating func parseString() throws -> String {
    try expect(0x22)
    var value: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == 0x22 { return String(decoding: value, as: UTF8.self) }
      if byte == 0x5C {
        guard index < bytes.count else { throw OrderedJSONError.invalid }
        let escape = bytes[index]
        index += 1
        switch escape {
        case 0x22, 0x5C, 0x2F: value.append(escape)
        case 0x62: value.append(0x08)
        case 0x66: value.append(0x0C)
        case 0x6E: value.append(0x0A)
        case 0x72: value.append(0x0D)
        case 0x74: value.append(0x09)
        case 0x75:
          let scalar = try parseUnicodeEscape()
          if let scalar = UnicodeScalar(scalar) {
            value.append(contentsOf: String(scalar).utf8)
          } else {
            value.append(contentsOf: "\u{FFFD}".utf8)
          }
        default: throw OrderedJSONError.invalid
        }
      } else {
        guard byte >= 0x20 else { throw OrderedJSONError.invalid }
        value.append(byte)
      }
    }
    throw OrderedJSONError.invalid
  }

  private mutating func parseUnicodeEscape() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw OrderedJSONError.invalid }
    var value: UInt32 = 0
    for _ in 0..<4 {
      guard let digit = hexValue(bytes[index]) else { throw OrderedJSONError.invalid }
      value = value * 16 + UInt32(digit)
      index += 1
    }
    if (0xD800...0xDBFF).contains(value), index + 6 <= bytes.count,
       bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
      let saved = index
      index += 2
      if let low = try? parseUnicodeEscape(), (0xDC00...0xDFFF).contains(low) {
        return 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
      }
      index = saved
    }
    return value
  }

  private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x41...0x46: return byte - 0x41 + 10
    case 0x61...0x66: return byte - 0x61 + 10
    default: return nil
    }
  }

  private mutating func parseNumber() throws -> String {
    let start = index
    if consume(0x2D) {}
    if consume(0x30) {
      if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { throw OrderedJSONError.invalid }
    } else {
      guard consumeDigits() else { throw OrderedJSONError.invalid }
    }
    if consume(0x2E) {
      guard consumeDigits() else { throw OrderedJSONError.invalid }
    }
    if index < bytes.count, bytes[index] == 0x65 || (index < bytes.count && bytes[index] == 0x45) {
      index += 1
      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      guard consumeDigits() else { throw OrderedJSONError.invalid }
    }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  private mutating func consumeDigits() -> Bool {
    let start = index
    while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    return index > start
  }

  private mutating func expectLiteral(_ literal: String) throws {
    for byte in literal.utf8 { try expect(byte) }
  }

  private mutating func expect(_ byte: UInt8) throws {
    guard consume(byte) else { throw OrderedJSONError.invalid }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }
}

private func spaceOrderedJSON(_ value: OrderedJSONValue) -> OrderedJSONValue {
  switch value {
  case let .object(members):
    return .object(members.map { ($0.0, spaceOrderedJSON($0.1)) })
  case let .array(values):
    return .array(values.map(spaceOrderedJSON))
  case let .string(value):
    return .string(translationSpacing(value))
  default:
    return value
  }
}

private func serializeOrderedJSON(_ value: OrderedJSONValue) -> String {
  switch value {
  case let .object(members):
    return "{" + members.map { "\(serializeJSONString($0.0)):\(serializeOrderedJSON($0.1))" }.joined(separator: ",") + "}"
  case let .array(values):
    return "[" + values.map(serializeOrderedJSON).joined(separator: ",") + "]"
  case let .string(value):
    return serializeJSONString(value)
  case let .number(value):
    if let data = try? JSONSerialization.data(withJSONObject: valueNumber(value), options: [.fragmentsAllowed]),
       let result = String(data: data, encoding: .utf8) {
      return result
    }
    return value
  case let .boolean(value):
    return value ? "true" : "false"
  case .null:
    return "null"
  }
}

private func valueNumber(_ value: String) -> Any {
  (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) ?? 0
}

private func serializeJSONString(_ value: String) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
    return "\"\(value)\""
  }
  return String(decoding: data, as: UTF8.self)
}

public func paragraphDisplayText(_ text: String = "") -> String {
  let spaced = translationSpacing(text)
  var lines: [String] = []
  var start = spaced.startIndex
  for index in spaced.indices where spaced[index] == "\n" {
    lines.append(displayLine(String(spaced[start..<index])))
    lines.append("\n")
    start = spaced.index(after: index)
  }
  lines.append(displayLine(String(spaced[start...])))
  return lines.joined()
}

private func displayLine(_ line: String) -> String {
  guard line.hasPrefix("  "), !line.hasPrefix("   "),
        line.dropFirst(2).unicodeScalars.contains(where: { isLetter($0) && isHan($0) }) else { return line }
  return "\u{3000}\u{3000}" + String(line.dropFirst(2))
}

private func isHan(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (0x2E80...0x2FFF).contains(value) ||
    (0x3400...0x4DBF).contains(value) ||
    (0x4E00...0x9FFF).contains(value) ||
    (0xF900...0xFAFF).contains(value) ||
    (0x20000...0x2FA1F).contains(value) ||
    (0x30000...0x3134F).contains(value)
}
