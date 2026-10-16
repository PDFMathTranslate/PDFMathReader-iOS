import XCTest

final class ReaderTabsUITests: XCTestCase {
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
