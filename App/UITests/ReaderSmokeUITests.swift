import XCTest

/// End-to-end smoke test: open a PDF, wait for a translated paragraph, then
/// highlight a word in the original text. Expects `sample.pdf` in the app's
/// Documents directory (copy it there with `simctl get_app_container`).
final class ReaderSmokeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testOpenTranslateAndHighlight() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"]
    app.launch()

    let probe = app.descendants(matching: .any)["debug.translationStatus"]
    XCTAssertTrue(probe.waitForExistence(timeout: 30), "Reader did not open")
    let translated = NSPredicate(format: "value != nil AND value != ''")
    let expectation = XCTNSPredicateExpectation(predicate: translated, object: probe)
    if XCTWaiter().wait(for: [expectation], timeout: 120) != .completed {
      attachScreenshot(app, name: "translation-missing")
      XCTFail("No translated paragraph appeared")
      return
    }
    // The toggle state persists across launches, so pin it before each screenshot.
    setTranslationsVisible(true, in: app)
    sleep(1)
    let text = probe.value as? String ?? ""
    XCTContext.runActivity(named: "Translated text: \(text)") { _ in }
    XCTAssertNotNil(text.range(of: "\\p{Han}", options: .regularExpression), "Translation is not Chinese: \(text)")
    attachScreenshot(app, name: "1-translated")

    setTranslationsVisible(false, in: app)
    sleep(1)
    attachScreenshot(app, name: "2-original")

    // "worthy" in the first sentence of the sample page.
    let word = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5625))
    word.press(forDuration: 1.2)

    let highlight = app.buttons["Highlight Yellow"].firstMatch
    if !highlight.waitForExistence(timeout: 5) {
      // The inline Annotate section can land on a later page of the edit menu.
      let forward = app.buttons["Forward"].firstMatch
      if forward.exists { forward.tap() }
    }
    if !highlight.waitForExistence(timeout: 5) {
      attachScreenshot(app, name: "edit-menu-missing")
      add(XCTAttachment(string: app.debugDescription))
      XCTFail("Highlight Yellow is not in the selection menu")
      return
    }
    attachScreenshot(app, name: "3-menu")
    highlight.tap()
    sleep(1)
    attachScreenshot(app, name: "4-highlighted")
  }

  @MainActor
  private func setTranslationsVisible(_ visible: Bool, in app: XCUIApplication) {
    let wanted = visible ? "Show translated text" : "Show original text"
    let toggle = app.buttons["reader.toggleTranslations"].firstMatch
    if toggle.waitForExistence(timeout: 3), toggle.isHittable {
      if toggle.label == wanted { toggle.tap() }
      return
    }
    // Compact width moves secondary toolbar items into the overflow menu.
    let more = app.navigationBars.buttons["More"].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 5), "Toolbar overflow button not found")
    more.tap()
    let item = app.buttons[wanted].firstMatch
    if item.waitForExistence(timeout: 3) {
      item.tap()
      return
    }
    let other = visible ? "Show original text" : "Show translated text"
    XCTAssertTrue(app.buttons[other].firstMatch.exists, "Translation toggle not in overflow menu")
    // Already in the wanted state; dismiss the menu.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
