import XCTest

final class SettingsLayoutInspection: XCTestCase {
  @MainActor func testInspectSettingsLayout() {
    let app = XCUIApplication()
    app.launch()
    let close = app.buttons["reader.closeDocument"].firstMatch
    if !app.buttons["library.settings"].firstMatch.waitForExistence(timeout: 2) {
      if !(close.exists && close.isHittable) {
        let sidebar = app.buttons.matching(NSPredicate(
          format: "identifier == %@ OR label CONTAINS[c] %@", "ToggleSidebar", "Sidebar")).firstMatch
        if sidebar.exists { sidebar.tap() }
      }
      if close.waitForExistence(timeout: 5) { close.tap() }
    }
    let settings = app.buttons["library.settings"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    XCTAssertTrue(app.buttons["settings.appIcon"].waitForExistence(timeout: 5))
    for index in 0..<4 {
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "settings-section-\(index)"
      capture.lifetime = .keepAlways
      add(capture)
      app.swipeUp()
    }
  }
}
