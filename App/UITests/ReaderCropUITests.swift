import XCTest

final class ReaderCropUITests: XCTestCase {
  @MainActor
  func testCropMenuPersistsAndResets() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-AppleLanguages", "(en)"]
    app.launch()
    openCropMenu(app)
    let reset = app.buttons["reader.resetCrop"]
    if reset.isEnabled {
      reset.tap()
      openCropMenu(app)
    }
    XCTAssertFalse(app.buttons["reader.cropLessHorizontally"].isEnabled)
    app.buttons["reader.cropMoreHorizontally"].tap()
    openCropMenu(app)
    XCTAssertTrue(app.buttons["reader.cropLessHorizontally"].isEnabled)
    app.buttons["reader.cropMoreVertically"].tap()
    app.terminate()
    app.launch()
    openCropMenu(app)
    XCTAssertTrue(app.buttons["reader.cropLessHorizontally"].isEnabled)
    XCTAssertTrue(app.buttons["reader.cropLessVertically"].isEnabled)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Reader crop menu"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["reader.resetCrop"].tap()
    openCropMenu(app)
    XCTAssertFalse(app.buttons["reader.cropLessHorizontally"].isEnabled)
    XCTAssertFalse(app.buttons["reader.cropLessVertically"].isEnabled)
    XCTAssertFalse(app.buttons["reader.resetCrop"].isEnabled)
  }

  @MainActor
  private func openCropMenu(_ app: XCUIApplication) {
    if app.buttons["reader.cropMoreHorizontally"].exists { return }
    let more = app.buttons["reader.moreMenu"].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 30))
    more.tap()
    let crop = app.buttons["reader.pageCrop"].firstMatch
    XCTAssertTrue(crop.waitForExistence(timeout: 5))
    crop.tap()
    XCTAssertTrue(app.buttons["reader.cropMoreHorizontally"].waitForExistence(timeout: 5))
  }
}
