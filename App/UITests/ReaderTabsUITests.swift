import XCTest

final class ReaderTabsUITests: XCTestCase {
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
    XCTAssertEqual(tabs.count, 1)
    XCTAssertTrue(tabs.element(boundBy: 0).isSelected)
    closeButtons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 10))
    XCTAssertEqual(tabs.count, 0)
  }
}
