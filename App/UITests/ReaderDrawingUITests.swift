import XCTest

final class ReaderDrawingUITests: XCTestCase {
  @MainActor
  func testDrawingToolsCanBeOpenedAndClosed() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"]
    app.launch()
    if drawingMode(app) == "on" { app.buttons["reader.drawingTools"].firstMatch.tap() }
    let tools = app.buttons["reader.drawingTools"].firstMatch
    XCTAssertTrue(tools.waitForExistence(timeout: 30))
    tools.tap()
    XCTAssertEqual(drawingMode(app), "on")
    let active = XCTAttachment(screenshot: app.screenshot())
    active.name = "PencilKit tools open"
    active.lifetime = .keepAlways
    add(active)
    // PencilKit exposes its native palette through accessibility.
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'eraser'")).firstMatch.waitForExistence(timeout: 5))
    // The palette covers the toolbar toggle, so it carries its own Done.
    let done = app.buttons["reader.exitPencilMode"].firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 5), "Pencil palette has no way back to reading")
    done.tap()
    XCTAssertEqual(drawingMode(app), "off")
  }

  /// In Pencil mode, fingers still scroll the document instead of drawing.
  @MainActor
  func testFingerScrollsInPencilMode() {
    continueAfterFailure = false
    let app = launchReader()
    let tools = app.buttons["reader.drawingTools"].firstMatch
    tools.tap()
    XCTAssertEqual(drawingMode(app), "on")
    // The pager only appears while the document scrolls.
    let pager = app.descendants(matching: .any)["reader.pager"].firstMatch
    let line = pageLine(in: app)
    let before = line.frame.minY
    sleep(3)
    XCTAssertFalse(pager.exists, "Pager is showing before any scroll")
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
    // The sample is a single fitted page, so a scroll may only bounce;
    // the pager still reports that the scroll view moved. It hides after 1 s.
    let scrolled = pager.exists || line.frame.minY < before - 50
    attach(app, "pencil-mode-after-finger-swipe")
    XCTAssertTrue(scrolled, "A finger swipe did not scroll in Pencil mode")
    XCTAssertEqual(drawingMode(app), "on", "A finger swipe left Pencil mode")
  }

  /// Putting the Pencil away: a finger long-press in Pencil mode returns to
  /// reading mode and selects the pressed word with the annotation menu.
  @MainActor
  func testFingerLongPressLeavesPencilModeAndSelects() {
    continueAfterFailure = false
    let app = launchReader()
    let tools = app.buttons["reader.drawingTools"].firstMatch
    tools.tap()
    XCTAssertEqual(drawingMode(app), "on")
    attach(app, "1-pencil-mode")
    pageLine(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5)).press(forDuration: 1.0)
    XCTAssertEqual(drawingMode(app), "off", "Long-press did not leave Pencil mode")
    let highlight = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
                  "Highlight Yellow",
                  XCUIElement.ElementType.button.rawValue,
                  XCUIElement.ElementType.menuItem.rawValue)
    ).firstMatch
    let found = highlight.waitForExistence(timeout: 3)
    attach(app, "2-reading-menu")
    if !found { add(XCTAttachment(string: app.debugDescription)) }
    XCTAssertTrue(found, "Annotation menu did not appear after leaving Pencil mode")
    highlight.tap()
    sleep(1)
    attach(app, "3-highlighted")
  }

  @MainActor
  private func launchReader() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe", "-PMRTranslationService", "siliconFlowFree"]
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")
    XCTAssertTrue(app.buttons["reader.drawingTools"].firstMatch.waitForExistence(timeout: 10))
    if drawingMode(app) == "on" {
      app.buttons["reader.drawingTools"].firstMatch.tap()
    }
    return app
  }

  /// Toolbar buttons drop their accessibility value; the debug probe keeps it.
  @MainActor
  private func drawingMode(_ app: XCUIApplication) -> String? {
    let probe = app.descendants(matching: .any)["debug.drawingMode"].firstMatch
    _ = probe.waitForExistence(timeout: 5)
    return probe.value as? String
  }

  private func pageLine(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The grass-blade is worthy")).firstMatch
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
