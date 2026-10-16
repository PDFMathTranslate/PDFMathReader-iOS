import Foundation
import Observation

public enum L10n {
  /// A language displayed in the interface-language picker.
  ///
  /// `name` is the language's native label. The list is sorted using stable
  /// English names in the same order as the desktop application.
  public struct SupportedLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String

    public var id: String { code }

    public init(code: String, name: String) {
      self.code = code
      self.name = name
    }
  }

  /// The desktop interface-language set, excluding the separately displayed
  /// `system` choice.
  public static let supportedLanguages: [SupportedLanguage] = [
    SupportedLanguage(code: "ar", name: "العربية"),
    SupportedLanguage(code: "bn", name: "বাংলা"),
    SupportedLanguage(code: "zh-CN", name: "简体中文"),
    SupportedLanguage(code: "zh-TW", name: "繁體中文"),
    SupportedLanguage(code: "arz", name: "العربية المصرية"),
    SupportedLanguage(code: "en", name: "English"),
    SupportedLanguage(code: "fr", name: "Français"),
    SupportedLanguage(code: "de", name: "Deutsch"),
    SupportedLanguage(code: "hi", name: "हिन्दी"),
    SupportedLanguage(code: "ja", name: "日本語"),
    SupportedLanguage(code: "ko", name: "한국어"),
    SupportedLanguage(code: "pcm", name: "Naijá"),
    SupportedLanguage(code: "pt", name: "Português"),
    SupportedLanguage(code: "ru", name: "Русский"),
    SupportedLanguage(code: "es", name: "Español"),
    SupportedLanguage(code: "ur", name: "اردو"),
  ]

  /// The persisted preference. `system` resolves through the preferred
  /// language list at the time a localized value is requested.
  ///
  /// The value is intentionally kept as the caller supplied it. This lets
  /// older preferences such as `zh-Hans` be round-tripped while resolution
  /// still maps them to the current canonical code.
  public static var languageChoice: String {
    get { storage.getChoice() }
    set { storage.setChoice(newValue) }
  }

  /// The locale used for both SwiftUI's environment and formatted strings.
  public static var locale: Locale {
    Locale(identifier: resolvedLanguage())
  }

  /// Whether the selected interface language uses right-to-left layout.
  public static var isRightToLeft: Bool {
    ["ar", "arz", "ur"].contains(resolvedLanguage())
  }

  /// Resolves a persisted language choice using the desktop policy.
  ///
  /// The preferred-language list is ordered from most to least preferred, as
  /// returned by `Locale.preferredLanguages`. Unsupported entries are skipped
  /// before falling back to English.
  public static func resolveLanguage(
    choice: String,
    preferredLanguages: [String]
  ) -> String {
    let normalizedChoice = normalize(choice)
    guard normalizedChoice == "system" else {
      return canonicalLanguage(for: normalizedChoice) ?? "en"
    }

    for preferredLanguage in preferredLanguages {
      if let language = canonicalLanguage(for: normalize(preferredLanguage)) {
        return language
      }
    }
    return "en"
  }

  /// Returns the localized catalog value for `key`, with positional printf
  /// arguments formatted using the selected locale.
  public static func string(_ key: String, _ args: CVarArg...) -> String {
    let language = resolvedLanguage()
    let localized = localizedValue(forKey: key, language: language)
    guard !args.isEmpty else { return localized }
    return String(
      format: localized,
      locale: Locale(identifier: language),
      arguments: args
    )
  }

  // MARK: - Resolution

  private static let storage = LanguageChoiceStorage()

  private static func resolvedLanguage() -> String {
    resolveLanguage(
      choice: storage.getChoice(),
      preferredLanguages: Locale.preferredLanguages
    )
  }

  private static let supportedCodes: Set<String> = Set(
    supportedLanguages.map(\.code)
  )

  private static func normalize(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
  }

  private static func canonicalLanguage(for normalized: String) -> String? {
    guard !normalized.isEmpty else { return nil }
    let components = normalized.split(separator: "-").map(String.init)
    guard let base = components.first else { return nil }

    if base == "zh" {
      let traditional = components.dropFirst().contains {
        ["hant", "tw", "hk", "mo"].contains($0)
      }
      return traditional ? "zh-TW" : "zh-CN"
    }
    if base == "ar",
       components.dropFirst().first == "eg" {
      return "arz"
    }
    if supportedCodes.contains(base) {
      return base
    }
    return nil
  }

  // MARK: - Bundle lookup

  // The application target hosts the unit tests, so `.main` is the app bundle
  // in both cases. Keeping one bundle reference avoids filesystem work for
  // every localized string read.
  private static let resourceBundle = Bundle.main

  private static let localizationBundleCache = LocalizationBundleCache()

  private static func localizedValue(forKey key: String, language: String) -> String {
    let bundle = resourceBundle
    let selectedBundle = localizationBundle(for: language, in: bundle)
    if let value = selectedBundle?.localizedString(
      forKey: key,
      value: nil,
      table: "Localizable"
    ), value != key {
      return value
    }

    // Catalogs can be incomplete while a translation is being updated. Keep
    // the selected language for complete entries, but use the explicit
    // English .lproj before returning the key itself for an unknown key.
    if language != "en",
       let value = localizationBundle(for: "en", in: bundle)?.localizedString(
         forKey: key,
         value: nil,
         table: "Localizable"
       ), value != key {
      return value
    }
    return key
  }

  private static func localizationBundle(for language: String, in bundle: Bundle) -> Bundle? {
    localizationBundleCache.bundle(for: language) {
      uncachedLocalizationBundle(for: language, in: bundle)
    }
  }

  private static func uncachedLocalizationBundle(for language: String, in bundle: Bundle) -> Bundle? {
    let names: [String]
    switch language {
    case "zh-CN": names = ["zh-CN", "zh-Hans"]
    case "zh-TW": names = ["zh-TW", "zh-Hant"]
    default: names = [language]
    }

    // Construct the path ourselves first. Bundle's resource lookup may
    // canonicalize zh-CN/zh-TW to zh-Hans/zh-Hant on iOS.
    for name in names {
      let url = bundle.bundleURL.appendingPathComponent("\(name).lproj", isDirectory: true)
      if isDirectory(url), let localizedBundle = Bundle(url: url) {
        return localizedBundle
      }
    }

    // A packaged app can use a canonical directory name even when the source
    // catalog used a regional code. Enumerate the actual directories and
    // match them explicitly as a final step.
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: bundle.bundleURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }
    let normalizedNames = Set(names.map(normalize))
    for url in entries where url.pathExtension == "lproj" {
      let directoryName = url.deletingPathExtension().lastPathComponent
      if normalizedNames.contains(normalize(directoryName)),
         let localizedBundle = Bundle(url: url) {
        return localizedBundle
      }
    }
    return nil
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

/// A small lock-backed reference type keeps the public static API usable from
/// UIKit, SwiftUI, and nonisolated async translation code under Swift 6.
private final class LanguageChoiceStorage: Observable, @unchecked Sendable {
  private let lock = NSLock()
  private let registrar = ObservationRegistrar()
  private var choice = "system"

  /// The registrar is kept separate from the lock-backed value so a read of
  /// `L10n.languageChoice` becomes an Observation dependency. The mutation
  /// closure only holds the lock while changing the value; the registrar can
  /// then notify its observers without re-entering the lock.
  private var observedChoice: String {
    get {
      registrar.access(self, keyPath: \.observedChoice)
      lock.lock()
      defer { lock.unlock() }
      return choice
    }
    set {
      registrar.withMutation(of: self, keyPath: \.observedChoice) {
        lock.lock()
        choice = newValue
        lock.unlock()
      }
    }
  }

  func getChoice() -> String {
    observedChoice
  }

  func setChoice(_ value: String) {
    lock.lock()
    let changed = choice != value
    lock.unlock()
    guard changed else { return }
    observedChoice = value
  }
}

private final class LocalizationBundleCache: @unchecked Sendable {
  private let lock = NSLock()
  private var bundles: [String: Bundle] = [:]

  func bundle(for language: String, load: () -> Bundle?) -> Bundle? {
    lock.lock()
    if let cached = bundles[language] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    guard let loaded = load() else { return nil }
    lock.lock()
    bundles[language] = loaded
    lock.unlock()
    return loaded
  }
}
