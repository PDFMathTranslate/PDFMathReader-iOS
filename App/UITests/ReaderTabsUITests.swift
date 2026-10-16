import XCTest

final class ReaderTabsUITests: XCTestCase {
  @MainActor
  func testSingleSidebarButtonInBothOrientations() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split sidebar")
    continueAfterFailure = false
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()
    let toggle = app.buttons.matching(identifier: "reader.toggleSidebar")
    XCTAssertTrue(toggle.firstMatch.waitForExistence(timeout: 30))
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      // Allow the split view's orientation visibility task to settle.
      Thread.sleep(forTimeInterval: 1)
      XCTAssertEqual(toggle.allElementsBoundByIndex.filter(\.isHittable).count, 1)
      XCTAssertTrue(app.buttons.matching(identifier: "ToggleSidebar")
        .allElementsBoundByIndex.filter(\.isHittable).isEmpty,
        "The system toggle duplicates the custom sidebar button")
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = orientation == .portrait ? "sidebar-portrait" : "sidebar-landscape"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  @MainActor
  func testSidebarHoldClosesOnlyAfterFullDuration() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar interaction")
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()
    let sidebar = app.buttons["reader.toggleSidebar"].firstMatch
    XCTAssertTrue(sidebar.waitForExistence(timeout: 30))

    // Releasing before the threshold must keep the document open.
    sidebar.press(forDuration: 0.65)
    XCTAssertTrue(sidebar.exists)
    let close = app.buttons["reader.closeDocument"].firstMatch
    // A short press can also be recognized as a tap. Normalize to closed
    // before checking a full open/close cycle.
    if close.exists && close.isHittable { sidebar.tap() }
    sidebar.tap()
    let visible = NSPredicate(format: "exists == true AND isHittable == true")
    XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: visible, object: close)], timeout: 5), .completed)
    sidebar.tap()
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: close)], timeout: 5), .completed)

    sidebar.press(forDuration: 1.4)
    XCTAssertTrue(app.buttons["library.settings"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(sidebar.exists)
  }

  @MainActor
  func testSwitchAndCloseDocumentTabs() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMRTabPDFs", "sample.pdf", "precise-compaction.pdf"]
    app.launch()
    let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "reader.tab.")
    let tabs = app.buttons.matching(tabPredicate)
    XCTAssertTrue(tabs.element(boundBy: 1).waitForExistence(timeout: 25))
    XCTAssertEqual(tabs.count, 2)
    let first = tabs.element(boundBy: 0)
    let second = tabs.element(boundBy: 1)
    XCTAssertTrue(second.isSelected)
    let headerButton = app.buttons["reader.drawingTools"].firstMatch
    XCTAssertTrue(headerButton.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(second.frame.minY, headerButton.frame.maxY,
                                "Document tabs should sit below the reader header")
    first.tap()
    XCTAssertTrue(first.isSelected)
    XCTAssertFalse(second.isSelected)
    let add = app.buttons["reader.addTab"]
    add.tap()
    let cancel = app.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.tap()
    let closeButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader.closeTab."))
    closeButtons.element(boundBy: 0).tap()
    XCTAssertTrue(add.waitForNonExistence(timeout: 5))
    XCTAssertEqual(tabs.count, 0)
    XCTAssertEqual(closeButtons.count, 0)
    XCTAssertTrue(headerButton.exists, "The remaining document should stay open when the tab bar hides")
  }
}
