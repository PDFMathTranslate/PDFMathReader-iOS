import XCTest

final class LocalizationUITests: XCTestCase {
  @MainActor
  func testLanguageSwitchUpdatesOpenSettingsAndPersists() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let settings = app.buttons["library.settings"].firstMatch
    if !settings.waitForExistence(timeout: 5) {
      let close = app.buttons["reader.closeDocument"].firstMatch
      if close.waitForExistence(timeout: 5) { close.tap() }
    }
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()

    func selectLanguage(_ name: String) {
      let picker = app.buttons["settings.uiLanguage"].firstMatch
      XCTAssertTrue(picker.waitForExistence(timeout: 5))
      picker.tap()
      let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 5))
      choice.tap()
    }

    selectLanguage("Deutsch")
    XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 5))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "settings-german"
    attachment.lifetime = .keepAlways
    add(attachment)

    app.terminate()
    app.launch()
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 5))
    selectLanguage("العربية")
    XCTAssertTrue(app.navigationBars["الإعدادات"].waitForExistence(timeout: 5))
    let done = app.buttons["settings.done"].firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    XCTAssertLessThan(done.frame.midX, app.windows.firstMatch.frame.midX,
                      "Confirmation action should move to the left edge in Arabic")
    let rtl = XCTAttachment(screenshot: app.screenshot())
    rtl.name = "settings-arabic"
    rtl.lifetime = .keepAlways
    add(rtl)
    selectLanguage("English")
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
  }
}
