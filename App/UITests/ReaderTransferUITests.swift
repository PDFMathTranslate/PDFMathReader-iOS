import XCTest

final class ReaderTransferUITests: XCTestCase {
  @MainActor
  func testAirDropMenuPresentsNativeShareSheet() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "transfer-smoke.pdf"]
    app.launch()
    let menu = app.buttons["reader.moreMenu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 20))
    menu.tap()
    let airDrop = app.buttons["reader.airDropToComputer"].firstMatch
    XCTAssertTrue(airDrop.waitForExistence(timeout: 5))
    airDrop.tap()
    let shareSheet = app.otherElements["ActivityListView"].firstMatch
    if !shareSheet.waitForExistence(timeout: 10) {
      print("TRANSFER_UI_HIERARCHY: \(app.debugDescription)")
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertTrue(shareSheet.exists,
                  "AirDrop should serialize the PDF and present the system share sheet")
  }
}
