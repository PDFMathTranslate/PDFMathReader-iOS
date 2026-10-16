import XCTest
import UIKit

private struct PDFViewportProbeValue: Equatable {
  let frameX: Double
  let frameY: Double
  let width: Double
  let height: Double
  let scale: Double
  let offsetX: Double
  let offsetY: Double

  init?(csv: String) {
    let values = csv.split(separator: ",", omittingEmptySubsequences: false).compactMap {
      Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard values.count == 7, values.allSatisfy({ $0.isFinite }) else { return nil }
    frameX = values[0]
    frameY = values[1]
    width = values[2]
    height = values[3]
    scale = values[4]
    offsetX = values[5]
    offsetY = values[6]
  }
}

final class ReaderInteractionSettingsUITests: XCTestCase {
  @MainActor
  private func stableViewportValue(
    from probe: XCUIElement,
    timeout: TimeInterval = 8
  ) -> PDFViewportProbeValue? {
    let deadline = Date().addingTimeInterval(timeout)
    var previous: PDFViewportProbeValue?
    while Date() < deadline {
      if let rawValue = probe.value as? String,
         let current = PDFViewportProbeValue(csv: rawValue) {
        if current == previous { return current }
        previous = current
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
  }

  @MainActor
  private func attachAccessibilityDiagnostics(
    for app: XCUIApplication,
    name: String
  ) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "\(name)-screenshot"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name)-accessibility"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  @MainActor
  private func makeScrollingPDF() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrolling-\(UUID().uuidString).pdf")
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    try renderer.writePDF(to: url) { context in
      for page in 1...4 {
        context.beginPage()
        ("Scrolling test — page \(page)" as NSString).draw(
          at: CGPoint(x: 48, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
      }
    }
    return url
  }

  @MainActor
  func testHorizontalScrollingHidesAndRestoresHeaderAndTabs() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let pdf = try makeScrollingPDF()
    defer { try? FileManager.default.removeItem(at: pdf) }
    app.launchArguments = ["-PMRTabPDFs", "sample.pdf", pdf.path]
    app.launch()
    let more = app.buttons["reader.moreMenu"].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 30))
    more.tap()
    app.buttons["reader.layoutMenu"].tap()
    app.descendants(matching: .any).matching(identifier: "reader.scrollDirection.horizontal").firstMatch.tap()
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: end)
    let reveal = app.buttons["reader.showTitleBar"].firstMatch
    XCTAssertFalse(reveal.exists)
    let addTab = app.buttons["reader.addTab"].firstMatch
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: addTab)], timeout: 5),
      .completed,
      "Tabs should be inaccessible while the title bar is hidden"
    )
    end.press(forDuration: 0.05, thenDragTo: start)
    let visible = NSPredicate(format: "exists == true AND isHittable == true")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: visible, object: addTab)], timeout: 5),
      .completed,
      "Reverse scrolling must restore the tabs"
    )
    XCTAssertTrue(more.isHittable)
    XCTAssertFalse(reveal.exists)
  }

  @MainActor
  func testScrollingHidesTitleBarAndReverseScrollRestoresControls() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let pdf = try makeScrollingPDF()
    defer { try? FileManager.default.removeItem(at: pdf) }
    app.launchArguments = ["-PMRTabPDFs", "sample.pdf", pdf.path]
    app.launch()
    let translation = app.buttons["reader.toggleTranslations"].firstMatch
    XCTAssertTrue(translation.waitForExistence(timeout: 30))
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
    start.press(forDuration: 0.05, thenDragTo: end)
    let reveal = app.buttons["reader.showTitleBar"].firstMatch
    XCTAssertFalse(reveal.exists)
    let addTab = app.buttons["reader.addTab"].firstMatch
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: addTab)], timeout: 5),
      .completed,
      "Tabs must hide together with the header"
    )
    end.press(forDuration: 0.05, thenDragTo: start)
    let visible = NSPredicate(format: "exists == true AND isHittable == true")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: visible, object: addTab)], timeout: 5),
      .completed,
      "Reverse scrolling must restore the tabs"
    )
    XCTAssertTrue(translation.isHittable, "Reverse scrolling must restore the header")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "reader-title-bar-restored"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testReverseScrollTitleBarRevealPreservesPDFGeometry() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let pdf = try makeScrollingPDF()
    defer { try? FileManager.default.removeItem(at: pdf) }
    app.launchArguments = ["-PMRTabPDFs", "sample.pdf", pdf.path, "-PMRUITestProbe"]
    app.launch()

    let addTab = app.buttons["reader.addTab"].firstMatch
    XCTAssertTrue(addTab.waitForExistence(timeout: 30))
    let probe = app.descendants(matching: .any)
      .matching(identifier: "debug.pdfViewport").firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 10), "PDF viewport probe did not appear")

    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
    start.press(forDuration: 0.05, thenDragTo: end)

    let reveal = app.buttons["reader.showTitleBar"].firstMatch
    XCTAssertFalse(reveal.exists)
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: addTab)], timeout: 5),
      .completed,
      "Tabs should be hidden before reverse scrolling"
    )
    let hiddenViewport = try XCTUnwrap(
      stableViewportValue(from: probe),
      "PDF viewport probe did not settle after scrolling"
    )

    end.press(forDuration: 0.05, thenDragTo: start)
    let restoredHeader = app.buttons["reader.toggleTranslations"].firstMatch
    let headerVisible = NSPredicate(format: "exists == true AND isHittable == true")
    let headerRestored = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: headerVisible, object: restoredHeader)],
      timeout: 5
    ) == .completed
    if !headerRestored {
      attachAccessibilityDiagnostics(for: app, name: "reader-title-bar-reveal-failed")
      XCTFail("Reverse scrolling must restore the reader header")
      return
    }

    let restoredViewport = try XCTUnwrap(
      stableViewportValue(from: probe),
      "PDF viewport probe did not settle after reverse scrolling"
    )

    XCTAssertEqual(restoredViewport.frameX, hiddenViewport.frameX, accuracy: 0.001)
    XCTAssertEqual(restoredViewport.frameY, hiddenViewport.frameY, accuracy: 0.001)
    XCTAssertEqual(restoredViewport.width, hiddenViewport.width, accuracy: 0.001)
    XCTAssertEqual(restoredViewport.height, hiddenViewport.height, accuracy: 0.001)
    XCTAssertEqual(restoredViewport.scale, hiddenViewport.scale, accuracy: 0.001)
  }
}
