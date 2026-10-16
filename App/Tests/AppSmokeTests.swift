import XCTest
import ReaderCore

@testable import PDFMathReader

final class AppSmokeTests: XCTestCase {
  func testLaunchTypeExists() {
    XCTAssertNotNil(PDFMathReaderApp.self)
  }

  func testAppleLanguageNamesAndCodesResolveToTheSameModels() {
    XCTAssertEqual(
      AppleTranslationLanguages(source: "English", target: "Simplified Chinese"),
      AppleTranslationLanguages(source: "en", target: "zh-Hans")
    )
    XCTAssertEqual(
      AppleTranslationLanguages(source: "", target: "zh-TW"),
      AppleTranslationLanguages(source: nil, target: "zh-Hant")
    )
    XCTAssertNotEqual(
      AppleTranslationLanguages(source: "en", target: "zh"),
      AppleTranslationLanguages(source: "en", target: "zh-TW")
    )
  }

  func testAppleSameLanguageDoesNotRequireDownloadedModels() async throws {
    guard #available(iOS 26.0, *) else { return }
    let provider = AppleTranslationProvider(sourceLanguage: "English", targetLanguage: "en")
    let response = try await provider.complete(
      TranslationProviderRequest(messages: [TranslationMessage(role: "user", content: "A scientific paragraph.")])
    )
    XCTAssertEqual(response.translationContent(), "A scientific paragraph.")
  }
}
