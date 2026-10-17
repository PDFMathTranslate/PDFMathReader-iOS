import XCTest

final class TranslationFontUITests: XCTestCase {
  @MainActor
  func testSelectedTranslationFontPersistsAfterRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-PMRUILanguage", "en", "-AppleLocale", "en_US"]
    app.launch()

    func openFontSettings() {
      let settings = app.buttons["library.settings"].firstMatch
      if !settings.waitForExistence(timeout: 3) {
        let close = app.buttons["reader.closeDocument"].firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
      }
      XCTAssertTrue(settings.waitForExistence(timeout: 10))
      settings.tap()
      let font = app.buttons["settings.translationFont"].firstMatch
      for _ in 0..<10 {
        if font.exists && font.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(font.waitForExistence(timeout: 5))
    }

    openFontSettings()
    app.buttons["settings.translationFont"].firstMatch.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Georgia")
    let georgia = app.buttons["Georgia"].firstMatch
    XCTAssertTrue(georgia.waitForExistence(timeout: 5))
    georgia.tap()
    let selectedFont = app.buttons["settings.translationFont"].firstMatch
    XCTAssertTrue(selectedFont.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedFont.label.contains("Georgia"))
    app.buttons["settings.done"].tap()

    app.terminate()
    app.launch()
    openFontSettings()
    XCTAssertTrue(selectedFont.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedFont.label.contains("Georgia"))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "translation-font-georgia-persisted"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
