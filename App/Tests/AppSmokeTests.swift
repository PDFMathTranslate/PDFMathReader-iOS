import XCTest

@testable import PDFMathReader

final class AppSmokeTests: XCTestCase {
  func testLaunchTypeExists() {
    XCTAssertNotNil(PDFMathReaderApp.self)
  }
}
