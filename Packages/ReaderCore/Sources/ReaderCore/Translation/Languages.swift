import Foundation

public struct TranslationLanguageOption: Codable, Hashable, Sendable, Identifiable {
  public let name: String
  public let code: String

  public var id: String { code }

  public init(name: String, code: String) {
    self.name = name
    self.code = code
  }
}

private let translationLanguageEntries: [(name: String, code: String)] = [
  ("Simplified Chinese", "zh"),
  ("Traditional Chinese", "zh-TW"),
  ("English", "en"),
  ("Japanese", "ja"),
  ("Korean", "ko"),
  ("French", "fr"),
  ("German", "de"),
  ("Spanish", "es"),
  ("Russian", "ru"),
  ("Italian", "it"),
  ("Portuguese", "pt"),
  ("Brazilian Portuguese", "pt-BR"),
  ("Traditional Chinese (Hong Kong)", "zh-HK"),
  ("Polish", "pl"),
  ("Dutch", "nl"),
  ("Ukrainian", "uk"),
  ("Czech", "cs"),
  ("Romanian", "ro"),
  ("Hungarian", "hu"),
  ("Slovak", "sk"),
  ("Croatian", "hr"),
  ("Slovenian", "sl"),
  ("Bulgarian", "bg"),
  ("Serbian", "sr"),
  ("Greek", "el"),
  ("Swedish", "sv"),
  ("Danish", "da"),
  ("Norwegian", "no"),
  ("Finnish", "fi"),
  ("Icelandic", "is"),
  ("Estonian", "et"),
  ("Latvian", "lv"),
  ("Lithuanian", "lt"),
  ("Turkish", "tr"),
  ("Vietnamese", "vi"),
  ("Indonesian", "id"),
  ("Malay", "ms"),
  ("Filipino", "tl"),
  ("Thai", "th"),
  ("Catalan", "ca"),
  ("Irish", "ga"),
  ("Albanian", "sq"),
  ("Afrikaans", "af"),
  ("Swahili", "sw"),
  ("Armenian", "hy"),
  ("Georgian", "ka"),
  ("Mongolian", "mn"),
  ("Arabic", "ar"),
  ("Hebrew", "he"),
  ("Hindi", "hi"),
  ("Persian", "fa"),
]

public let translationLanguageOptions: [TranslationLanguageOption] =
  translationLanguageEntries.map { TranslationLanguageOption(name: $0.name, code: $0.code) }

public let LANGUAGE_CODES: [String: String] = Dictionary(
  uniqueKeysWithValues: translationLanguageEntries.map { ($0.name, $0.code) }
)

private let allTranslationLanguages = translationLanguageEntries.map(\.name)
private let fastTranslationLanguages = Array(allTranslationLanguages.prefix(10))
private let preciseTranslationLanguages = allTranslationLanguages.filter {
  !["Arabic", "Hebrew", "Hindi", "Persian"].contains($0)
}

public func isCustomLanguageCode(_ value: String) -> Bool {
  guard value.utf16.count <= 63 else { return false }
  guard value.range(of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil else {
    return false
  }
  return !LANGUAGE_CODES.keys.contains(value)
}

public func translationLanguageCode(_ value: String) -> String? {
  LANGUAGE_CODES[value] ?? (isCustomLanguageCode(value) ? value : nil)
}

public func translationLanguagesForKernel(_ engine: String, direction: String = "target") -> [String] {
  switch engine {
  case "pdf_inspector":
    return allTranslationLanguages
  case "pdf_math_fast":
    return direction == "source" ? allTranslationLanguages : fastTranslationLanguages
  case "pdf_math_precise":
    return direction == "source" ? allTranslationLanguages : preciseTranslationLanguages
  default:
    return []
  }
}

public func isTranslationLanguageSupported(
  _ engine: String,
  _ name: String,
  _ direction: String = "target"
) -> Bool {
  let languages = translationLanguagesForKernel(engine, direction: direction)
  guard !languages.isEmpty else { return false }
  return languages.contains(name) || isCustomLanguageCode(name)
}

public func normalizeTranslationLanguage(
  _ engine: String,
  _ name: String,
  _ fallback: String,
  _ direction: String = "target"
) -> String {
  let languages = translationLanguagesForKernel(engine, direction: direction)
  if isTranslationLanguageSupported(engine, name, direction) { return name }
  return languages.contains(fallback) ? fallback : (languages.first ?? "")
}

public func translationLanguageLabel(_ name: String, locale: String = "en") -> String {
  guard let code = LANGUAGE_CODES[name] else { return name }
  let displayCode: String
  switch code {
  case "zh": displayCode = "zh-Hans"
  case "zh-TW": displayCode = "zh-Hant"
  case "zh-HK": displayCode = "zh-Hant-HK"
  default: displayCode = code
  }
  let displayLocale = Locale(identifier: locale)
  if code == "zh" || code == "zh-TW" || code == "zh-HK" {
    // Language-only localization discards the script and labels every variant "Chinese".
    return displayLocale.localizedString(forIdentifier: displayCode) ?? name
  }
  return displayLocale.localizedString(forLanguageCode: displayCode) ?? name
}
