import Foundation
import Observation
import ReaderCore
import XCTest

@testable import PDFMathReader

final class LocalizationTests: XCTestCase {
  private var previousLanguageChoice = "system"

  override func setUp() {
    super.setUp()
    previousLanguageChoice = L10n.languageChoice
  }

  override func tearDown() {
    L10n.languageChoice = previousLanguageChoice
    super.tearDown()
  }

  func testSupportedLanguagesMatchDesktopCodesAndOrder() {
    XCTAssertEqual(
      L10n.supportedLanguages.map(\.code),
      ["ar", "bn", "zh-CN", "zh-TW", "arz", "en", "fr", "de",
       "hi", "ja", "ko", "pcm", "pt", "ru", "es", "ur"]
    )
    XCTAssertEqual(L10n.supportedLanguages.count, 16)
    XCTAssertEqual(
      Set(L10n.supportedLanguages.map(\.code)),
      Set(["en", "ar", "arz", "bn", "de", "es", "fr", "hi", "ja",
           "ko", "pcm", "pt", "ru", "ur", "zh-CN", "zh-TW"])
    )
    XCTAssertEqual(L10n.supportedLanguages.map(\.id), L10n.supportedLanguages.map(\.code))
  }

  func testResolveLanguageHandlesLegacyAndRegionalAliases() {
    let directCases: [(String, String)] = [
      ("en-US", "en"),
      ("pt-BR", "pt"),
      ("ar_EG", "arz"),
      ("ar-SA", "ar"),
      ("zh-Hans", "zh-CN"),
      ("zh-CN", "zh-CN"),
      ("zh-Hant", "zh-TW"),
      ("zh-TW", "zh-TW"),
      ("zh-Hant-HK", "zh-TW"),
      ("zh-HK", "zh-TW"),
      ("zh-MO", "zh-TW"),
      ("zh-SG", "zh-CN"),
      ("unsupported", "en"),
    ]

    for (choice, expected) in directCases {
      XCTAssertEqual(
        L10n.resolveLanguage(choice: choice, preferredLanguages: []),
        expected,
        choice
      )
    }
  }

  func testSystemResolutionUsesPreferredOrderAndEnglishFallback() {
    XCTAssertEqual(
      L10n.resolveLanguage(choice: "system", preferredLanguages: ["xx-ZZ", "fr-CA"]),
      "fr"
    )
    XCTAssertEqual(
      L10n.resolveLanguage(choice: "system", preferredLanguages: ["ar-EG"]),
      "arz"
    )
    XCTAssertEqual(
      L10n.resolveLanguage(choice: "system", preferredLanguages: ["zh-Hant-HK"]),
      "zh-TW"
    )
    XCTAssertEqual(
      L10n.resolveLanguage(choice: "system", preferredLanguages: ["xx-ZZ"]),
      "en"
    )
    XCTAssertEqual(
      L10n.resolveLanguage(choice: "SYSTEM", preferredLanguages: ["de"]),
      "de"
    )
  }

  func testLocaleAndDirectionFollowTheResolvedChoice() {
    L10n.languageChoice = "ur"
    XCTAssertTrue(L10n.isRightToLeft)
    XCTAssertTrue(L10n.locale.identifier.lowercased().hasPrefix("ur"))

    L10n.languageChoice = "arz"
    XCTAssertTrue(L10n.isRightToLeft)
    XCTAssertTrue(L10n.locale.identifier.lowercased().hasPrefix("arz"))

    L10n.languageChoice = "de"
    XCTAssertFalse(L10n.isRightToLeft)
    XCTAssertEqual(L10n.locale.identifier.lowercased(), "de")
  }

  func testRealCatalogStringChangesWithSelectedLanguage() {
    L10n.languageChoice = "de"
    let german = L10n.string("settings.title")
    XCTAssertFalse(german.isEmpty)
    XCTAssertNotEqual(german, "Settings")

    L10n.languageChoice = "ja"
    let japanese = L10n.string("settings.title")
    XCTAssertFalse(japanese.isEmpty)
    XCTAssertNotEqual(japanese, "Settings")
    XCTAssertNotEqual(japanese, german)
  }

  func testInterpolationUsesTheSelectedCatalogAndLocale() {
    L10n.languageChoice = "fr"
    XCTAssertEqual(L10n.string("sidebar.page", "7"), "Page 7")

    L10n.languageChoice = "de"
    let value = L10n.string("sidebar.page", "7")
    XCTAssertTrue(value.contains("7"))
    XCTAssertNotEqual(value, "Page 7")

    L10n.languageChoice = "ar"
    let rightToLeftValue = L10n.string("toolbar.pageOf", "2", "9")
    XCTAssertTrue(rightToLeftValue.contains("2"))
    XCTAssertTrue(rightToLeftValue.contains("9"))
    XCTAssertNotEqual(rightToLeftValue, "Page 2 of 9")
  }

  func testCoreErrorsFollowInterfaceLanguageAndKeepArguments() {
    ReaderErrorLocalization.configure()
    L10n.languageChoice = "en"
    let english = TranslatedPDFExporterError.invalidDocument.localizedDescription
    XCTAssertEqual(english, "The source PDF could not be opened.")
    L10n.languageChoice = "de"
    let german = TranslatedPDFExporterError.invalidDocument.localizedDescription
    XCTAssertNotEqual(german, english)
    XCTAssertFalse(german.contains("core.error."))
    let formatted = TranslatedPDFExporterError.unableToRenderPage(index: 41).localizedDescription
    XCTAssertTrue(formatted.contains("42"))
    XCTAssertFalse(formatted.contains("{0}"))
  }

  func testUnknownKeyFallsBackToItsKey() {
    L10n.languageChoice = "fr"
    XCTAssertEqual(L10n.string("localization.unknown.test.key"), "localization.unknown.test.key")
  }

  func testEveryDesktopLanguageResolvesItsCatalog() {
    let expectedTitles = [
      "ar": "الإعدادات",
      "arz": "الإعدادات",
      "bn": "সেটিংস",
      "de": "Einstellungen",
      "en": "Settings",
      "es": "Configuración",
      "fr": "Paramètres",
      "hi": "सेटिंग्स",
      "ja": "設定",
      "ko": "설정",
      "pcm": "Setings",
      "pt": "Definições",
      "ru": "Настройки",
      "ur": "ترتیبات",
      "zh-CN": "设置",
      "zh-TW": "設定",
    ]

    for language in L10n.supportedLanguages {
      L10n.languageChoice = language.code
      XCTAssertEqual(
        L10n.string("settings.title"),
        expectedTitles[language.code],
        language.code
      )
    }
  }

  func testUnsupportedChoiceUsesEnglishCatalog() {
    L10n.languageChoice = "xx-YY"
    XCTAssertEqual(L10n.locale.identifier.lowercased(), "en")
    XCTAssertEqual(L10n.string("settings.title"), "Settings")
  }

  func testLocalizedReadsTrackLanguageChoiceChanges() {
    L10n.languageChoice = "en"
    let probe = ObservationProbe()

    withObservationTracking {
      _ = L10n.string("settings.title")
    } onChange: {
      probe.markChanged()
    }

    L10n.languageChoice = "de"
    XCTAssertTrue(probe.didChange)
  }
}

private final class ObservationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  func markChanged() {
    lock.lock()
    changed = true
    lock.unlock()
  }

  var didChange: Bool {
    lock.lock()
    defer { lock.unlock() }
    return changed
  }
}
