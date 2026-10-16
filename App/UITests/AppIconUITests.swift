import XCTest

final class AppIconUITests: XCTestCase {
  @MainActor
  func testAlternateIconPersistsAndRestoresDefault() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    dismissIconConfirmation()
    app.launch()
    openIconPicker(in: app)

    // Start from a known icon even when a previous run selected Warm.
    select("base", in: app)
    select("warm", in: app)
    app.terminate()
    app.launch()
    openIconPicker(in: app)
    XCTAssertTrue(app.buttons["settings.appIcon.warm"].isSelected)

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "app-icon-picker"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    select("base", in: app)
  }

  @MainActor
  private func openIconPicker(in app: XCUIApplication) {
    let close = app.buttons["reader.closeDocument"].firstMatch
    if close.waitForExistence(timeout: 2) { close.tap() }
    let settings = app.buttons["library.settings"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()
    let iconRow = app.buttons["settings.appIcon"].firstMatch
    XCTAssertTrue(iconRow.waitForExistence(timeout: 5))
    iconRow.tap()
    XCTAssertTrue(app.buttons["settings.appIcon.base"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func select(_ id: String, in app: XCUIApplication) {
    let button = app.buttons["settings.appIcon.\(id)"]
    if !button.isSelected {
      button.tap()
      dismissIconConfirmation()
      let selected = NSPredicate(format: "selected == true AND enabled == true")
      XCTAssertTrue(XCTNSPredicateExpectation(predicate: selected, object: button)
        .waitForFulfillment(timeout: 10))
    }
    XCTAssertTrue(button.isSelected)
  }

  @MainActor
  private func dismissIconConfirmation() {
    let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    if alert.waitForExistence(timeout: 5) { alert.buttons.firstMatch.tap() }
  }
}

private extension XCTNSPredicateExpectation {
  func waitForFulfillment(timeout: TimeInterval) -> Bool {
    XCTWaiter.wait(for: [self], timeout: timeout) == .completed
  }
}
