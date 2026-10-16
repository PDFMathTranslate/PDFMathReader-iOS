import XCTest

/// End-to-end smoke test: open a PDF, wait for a translated paragraph, then
/// highlight a word in the original text. Expects `sample.pdf` in the app's
/// Documents directory (copy it there with `simctl get_app_container`).
final class ReaderSmokeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testOpenTranslateAndHighlight() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"]
    app.launch()

    XCTAssertTrue(translationProbes(in: app).firstMatch.waitForExistence(timeout: 30), "Reader did not open")
    // The probe lists every translated paragraph; wait until one is Chinese.
    let probe = translatedProbe(in: app)
    if !probe.waitForExistence(timeout: 120) {
      attachScreenshot(app, name: "translation-missing")
      XCTFail("No translated paragraph appeared")
      return
    }
    // The toggle state persists across launches, so pin it before each screenshot.
    setTranslationsVisible(true, in: app)
    sleep(1)
    let text = probe.value as? String ?? ""
    XCTContext.runActivity(named: "Translated text: \(text)") { _ in }
    XCTAssertNotNil(text.range(of: "\\p{Han}", options: .regularExpression), "Translation is not Chinese: \(text)")
    attachScreenshot(app, name: "1-translated")

    setTranslationsVisible(false, in: app)
    sleep(1)
    attachScreenshot(app, name: "2-original")

    // "worthy" sits 37% along the first line; PDFKit exposes that line as
    // static text, which keeps the press independent of device and layout.
    let line = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "The grass-blade is worthy")
    ).firstMatch
    let hasLine = line.waitForExistence(timeout: 5)
    let word = hasLine
      ? line.coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5))
      : app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5625))
    let wordEnd = hasLine
      ? line.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5))
      : app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.5625))

    // Selection gestures differ by device: iPhone selects on long press, while
    // iPad can start a text drag instead. Try each until the edit menu shows;
    // double-tap goes last because PDFKit may zoom instead of selecting.
    let highlight = menuEntry("Highlight Yellow", in: app)
    let gestures: [(String, () -> Void)] = [
      ("long-press", { word.press(forDuration: 1.2) }),
      ("press-drag", { word.press(forDuration: 0.8, thenDragTo: wordEnd) }),
      ("double-tap", { word.doubleTap() }),
    ]
    var found = false
    for (name, gesture) in gestures {
      gesture()
      if !highlight.waitForExistence(timeout: 3) {
        // The inline Annotate section can land on a later page of the edit menu.
        let forward = menuEntry("Forward", in: app)
        if forward.exists { forward.tap() }
      }
      if highlight.waitForExistence(timeout: 2) {
        XCTContext.runActivity(named: "Selection gesture: \(name)") { _ in }
        found = true
        break
      }
      attachScreenshot(app, name: "after-\(name)")
      // Clear any partial selection before the next attempt.
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
    }
    if !found {
      attachScreenshot(app, name: "edit-menu-missing")
      add(XCTAttachment(string: app.debugDescription))
      XCTFail("Highlight Yellow is not in the selection menu")
      return
    }
    attachScreenshot(app, name: "3-menu")
    highlight.tap()
    sleep(1)
    attachScreenshot(app, name: "4-highlighted")
  }

  @MainActor
  /// Opens a PDF that lives outside the app sandbox (Files "On My iPad" or
  /// iCloud Drive) through the import picker. Place `PMR-Files-Test.pdf` in
  /// that location first.
  func testOpenFromFilesPicker() {
    let fileName = "PMR-Files-Test"
    let app = XCUIApplication()
    app.launchArguments = ["-PMRUITestProbe"]
    app.launch()

    let importButton = app.buttons["Import PDF"].firstMatch
    XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Import button not found")
    importButton.tap()

    // iPad shows a sidebar of locations; iPhone shows a search field.
    let iCloud = app.cells["DOC.sidebar.item.iCloud Drive"].firstMatch
    let search = app.searchFields.firstMatch
    let deadline = Date().addingTimeInterval(15)
    while !iCloud.exists && !search.exists && Date() < deadline { usleep(250_000) }
    if iCloud.exists {
      iCloud.tap()
      // The file may sit below the fold of a large folder; search instead.
      let searchButton = app.buttons["Search"].firstMatch
      if searchButton.waitForExistence(timeout: 5) { searchButton.tap() }
    }
    if search.waitForExistence(timeout: 5) {
      search.tap()
      search.typeText(fileName)
    } else if !iCloud.exists {
      attachScreenshot(app, name: "picker-missing")
      add(XCTAttachment(string: app.debugDescription))
      XCTFail("Files picker did not appear")
      return
    }
    let result = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", fileName)).firstMatch
    if !result.waitForExistence(timeout: 20) {
      attachScreenshot(app, name: "picker-no-result")
      add(XCTAttachment(string: app.debugDescription))
      XCTFail("\(fileName) not found in the Files picker")
      return
    }
    attachScreenshot(app, name: "picker-result")
    // The iPhone picker can report the result before its search transition
    // ends; give it a moment, then tap by coordinate if it is still covered.
    let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: result)
    if XCTWaiter().wait(for: [hittable], timeout: 5) == .completed {
      result.tap()
    } else {
      result.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    // Some picker layouts select first and need an explicit Open.
    let open = app.buttons["Open"].firstMatch
    if open.waitForExistence(timeout: 2), open.isHittable { open.tap() }

    // iPad may already show a restored reader, so match the new title.
    let opened = app.navigationBars["\(fileName).pdf"].firstMatch.waitForExistence(timeout: 30)
    attachScreenshot(app, name: opened ? "files-opened" : "files-open-failed")
    XCTAssertFalse(app.staticTexts["This PDF could not be read."].exists, "Read failed alert shown")
    XCTAssertFalse(app.staticTexts["PDF unavailable"].exists, "Reader shows PDF unavailable")
    XCTAssertTrue(opened, "Reader did not open the picked PDF")

    // A file opened from Files must translate like one in the app's Documents.
    if !translatedProbe(in: app).waitForExistence(timeout: 120) {
      attachScreenshot(app, name: "files-translation-missing")
      XCTFail("No translated paragraph appeared for the picked PDF")
      return
    }
    setTranslationsVisible(true, in: app)
    sleep(1)
    attachScreenshot(app, name: "files-translated")
  }

  /// iPad restores earlier reader windows, so several probes can exist; a
  /// bare identifier query then has no single value to read.
  @MainActor
  private func translationProbes(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "debug.translationStatus")
  }

  @MainActor
  private func translatedProbe(in app: XCUIApplication) -> XCUIElement {
    translationProbes(in: app)
      .matching(NSPredicate(format: "value MATCHES %@", "(?s).*\\p{Han}.*"))
      .firstMatch
  }

  @MainActor
  /// The edit menu exposes entries as buttons on iPhone and menu items on iPad.
  private func menuEntry(_ label: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label == %@ AND (elementType == %d OR elementType == %d)",
        label,
        XCUIElement.ElementType.button.rawValue,
        XCUIElement.ElementType.menuItem.rawValue
      )
    ).firstMatch
  }

  @MainActor
  private func setTranslationsVisible(_ visible: Bool, in app: XCUIApplication) {
    let wanted = visible ? "Show translated text" : "Show original text"
    let toggle = app.buttons["reader.toggleTranslations"].firstMatch
    if toggle.waitForExistence(timeout: 3), toggle.isHittable {
      if toggle.label == wanted { toggle.tap() }
      return
    }
    // Compact width moves secondary toolbar items into the overflow menu.
    let more = app.navigationBars.buttons["More"].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 5), "Toolbar overflow button not found")
    more.tap()
    let item = app.buttons[wanted].firstMatch
    if item.waitForExistence(timeout: 3) {
      item.tap()
      return
    }
    let other = visible ? "Show original text" : "Show translated text"
    XCTAssertTrue(app.buttons[other].firstMatch.exists, "Translation toggle not in overflow menu")
    // Already in the wanted state; dismiss the menu.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
