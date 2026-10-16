import XCTest

final class ReaderWorkspaceRestorationUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testTabsAndSelectionRestoreAndClosedTabStaysClosed() {
    let firstLaunch = XCUIApplication()
    firstLaunch.launchArguments = ["-PMRTabPDFs", "sample.pdf", "precise-compaction.pdf"]
    firstLaunch.launch()

    let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "reader.tab.")
    let initialTabs = firstLaunch.buttons.matching(tabPredicate)
    XCTAssertTrue(initialTabs.element(boundBy: 1).waitForExistence(timeout: 25))
    XCTAssertEqual(initialTabs.count, 2)
    initialTabs.element(boundBy: 0).tap()
    XCTAssertTrue(initialTabs.element(boundBy: 0).isSelected)

    XCUIDevice.shared.press(.home)
    firstLaunch.terminate()

    let restored = XCUIApplication()
    restored.launchArguments = []
    restored.launch()
    let restoredTabs = restored.buttons.matching(tabPredicate)
    XCTAssertTrue(restoredTabs.element(boundBy: 1).waitForExistence(timeout: 25))
    XCTAssertEqual(restoredTabs.count, 2)
    XCTAssertTrue(restoredTabs.element(boundBy: 0).isSelected)

    let closeButtons = restored.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "reader.closeTab.")
    )
    XCTAssertEqual(closeButtons.count, 2)
    closeButtons.element(boundBy: 0).tap()
    XCTAssertTrue(closeButtons.element(boundBy: 0).waitForNonExistence(timeout: 5))
    XCTAssertEqual(restored.buttons.matching(tabPredicate).count, 0)
    XCTAssertEqual(restored.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "reader.closeTab.")
    ).count, 0)
    XCTAssertTrue(restored.buttons["reader.drawingTools"].waitForExistence(timeout: 5))

    XCUIDevice.shared.press(.home)
    restored.terminate()

    let afterClose = XCUIApplication()
    afterClose.launchArguments = []
    afterClose.launch()
    XCTAssertTrue(afterClose.buttons["reader.drawingTools"].waitForExistence(timeout: 25))
    XCTAssertEqual(afterClose.buttons.matching(tabPredicate).count, 0)
    XCTAssertEqual(afterClose.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "reader.closeTab.")
    ).count, 0)
  }
}
