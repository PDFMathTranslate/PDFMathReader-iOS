import XCTest

final class ReaderDrawingUITests: XCTestCase {
  @MainActor
  func testDrawingToolsCanBeOpenedAndClosed() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"]
    app.launch()
    let tools = app.buttons["reader.drawingTools"].firstMatch
    XCTAssertTrue(tools.waitForExistence(timeout: 30))
    tools.tap()
    XCTAssertEqual(tools.value as? String, "Drawing On")
    let active = XCTAttachment(screenshot: app.screenshot())
    active.name = "PencilKit tools open"
    active.lifetime = .keepAlways
    add(active)
    // PencilKit exposes its native palette through accessibility.
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'eraser'")).firstMatch.waitForExistence(timeout: 5))
    tools.tap()
    XCTAssertEqual(tools.value as? String, "Drawing Off")
  }
}
