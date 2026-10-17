import XCTest

final class ReaderCropUITests: XCTestCase {
  @MainActor
  func testCropMenuPersistsAndResets() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-AppleLanguages", "(en)", "-PMRUILanguage", "en"]
    app.launch()
    openCropMenu(app)
    let reset = button("reader.resetCrop", label: "Reset Crop", in: app)
    if reset.isEnabled {
      reset.tap()
      openCropMenu(app)
    }
    XCTAssertFalse(button("reader.cropLessHorizontally", label: "Crop Less Horizontally", in: app).isEnabled)
    button("reader.cropMoreHorizontally", label: "Crop More Horizontally", in: app).tap()
    openCropMenu(app)
    XCTAssertTrue(button("reader.cropLessHorizontally", label: "Crop Less Horizontally", in: app).isEnabled)
    button("reader.cropMoreVertically", label: "Crop More Vertically", in: app).tap()
    app.terminate()
    app.launch()
    openCropMenu(app)
    XCTAssertTrue(button("reader.cropLessHorizontally", label: "Crop Less Horizontally", in: app).isEnabled)
    XCTAssertTrue(button("reader.cropLessVertically", label: "Crop Less Vertically", in: app).isEnabled)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Reader crop menu"
    attachment.lifetime = .keepAlways
    add(attachment)
    button("reader.resetCrop", label: "Reset Crop", in: app).tap()
    openCropMenu(app)
    XCTAssertFalse(button("reader.cropLessHorizontally", label: "Crop Less Horizontally", in: app).isEnabled)
    XCTAssertFalse(button("reader.cropLessVertically", label: "Crop Less Vertically", in: app).isEnabled)
    XCTAssertFalse(button("reader.resetCrop", label: "Reset Crop", in: app).isEnabled)
  }

  @MainActor
  private func openCropMenu(_ app: XCUIApplication) {
    if button("reader.cropMoreHorizontally", label: "Crop More Horizontally", in: app).exists { return }
    let more = app.buttons["reader.moreMenu"].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 30))
    more.tap()
    let crop = button("reader.pageCrop", label: "Page Crop", in: app)
    XCTAssertTrue(crop.waitForExistence(timeout: 5))
    crop.tap()
    XCTAssertTrue(button("reader.cropMoreHorizontally", label: "Crop More Horizontally", in: app).waitForExistence(timeout: 5))
  }

  /// iPadOS 27 drops identifiers from nested SwiftUI menus; fall back to the
  /// English title pinned by `-PMRUILanguage en`.
  @MainActor
  private func button(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
  }
}
