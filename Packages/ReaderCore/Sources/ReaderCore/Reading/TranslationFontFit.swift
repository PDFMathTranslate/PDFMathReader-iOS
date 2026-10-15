import Foundation

public let maxTranslationFontLength = 100

private let cjkSerif: [String: [String]] = [
  "Japanese": ["Hiragino Mincho ProN", "Yu Mincho", "Noto Serif CJK JP"],
  "Korean": ["AppleMyungjo", "Batang", "Noto Serif CJK KR"],
  "Traditional Chinese": ["Songti TC", "PMingLiU", "Noto Serif CJK TC"],
]
private let serifFamilies = ["Iowan Old Style", "Georgia", "Times New Roman"]
private let sansFamilies = ["-apple-system", "BlinkMacSystemFont", "Segoe UI", "PingFang SC", "Microsoft YaHei"]
private let genericFamilies: Set<String> = ["serif", "sans-serif", "-apple-system", "BlinkMacSystemFont"]

public func stripTranslationFont(_ value: String?) -> String {
  guard let value else { return "" }
  let filtered = value.unicodeScalars.filter { scalar in
    scalar.properties.generalCategory != .control && !["\"", "\\", ";", "{", "}"].contains(Character(String(scalar)))
  }
  return String(String.UnicodeScalarView(filtered)).prefix(maxTranslationFontLength).description
}

public func isValidTranslationFont(_ value: String?) -> Bool {
  guard let value else { return false }
  return stripTranslationFont(value) == value
}

public func translationFontFamily(serif: Bool = false, font: String = "", language: String = "") -> String {
  let name = stripTranslationFont(font).trimmingCharacters(in: .whitespacesAndNewlines)
  guard serif || !name.isEmpty else { return "" }
  let families = serif ? serifFamilies + (cjkSerif[language] ?? ["Songti SC", "SimSun", "Noto Serif CJK SC"]) + ["serif"] : sansFamilies + ["sans-serif"]
  return ([name].filter { !$0.isEmpty } + families).map { genericFamilies.contains($0) ? $0 : "\"\($0)\"" }.joined(separator: ", ")
}
