import XCTest

/// End-to-end smoke test: open a PDF, wait for a translated paragraph, then
/// highlight a word in the original text. Expects `sample.pdf` in the app's
/// Documents directory (copy it there with `simctl get_app_container`).
final class ReaderSmokeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Pins the free proxy so translation tests do not depend on the service
  /// saved on the device; the app keeps the saved choice on disk.
  private let freeService = ["-PMRTranslationService", "siliconFlowFree"]

  @MainActor
  func testRecentLongPressPinRemoveAndReopen() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-AppleLanguages", "(en)"]
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30))
    closeReaderToLibrary(app)

    let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                               "library.recent.", "sample.pdf")).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    card.press(forDuration: 1)
    XCTAssertTrue(menuEntry("Open", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(menuEntry("Clear Translation Cache", in: app).exists)
    XCTAssertTrue(menuEntry("Copy File Location", in: app).exists)
    // The simulator may already have this fixture pinned from an earlier run.
    let unpin = menuEntry("Unpin", in: app)
    if unpin.exists {
      unpin.tap()
      card.press(forDuration: 1)
    }
    menuEntry("Pin", in: app).tap()
    card.press(forDuration: 1)
    XCTAssertTrue(menuEntry("Unpin", in: app).waitForExistence(timeout: 5))
    menuEntry("Remove from Recents", in: app).tap()
    XCTAssertTrue(card.waitForNonExistence(timeout: 5))

    // Removing the history entry must leave the original PDF usable.
    app.terminate()
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30))
    closeReaderToLibrary(app)
    XCTAssertTrue(card.waitForExistence(timeout: 10))
  }

  @MainActor
  func testSwipeToToggleSidebar() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad split sidebar")
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")

    let close = app.buttons["reader.closeDocument"].firstMatch
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    let visible = NSPredicate(format: "exists == true AND isHittable == true")
    func waitForSidebar(_ predicate: NSPredicate) {
      XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: close)], timeout: 5), .completed)
    }
    waitForSidebar(hidden)
    let sidebarButton = app.buttons.matching(
      NSPredicate(format: "identifier == %@ OR label CONTAINS[c] %@", "ToggleSidebar", "Sidebar")
    ).firstMatch
    XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5))
    sidebarButton.tap()
    waitForSidebar(visible)
    let thumbnail = app.buttons["reader.thumbnail.1"].firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    let buttonOpenedFrame = thumbnail.frame
    let initialSidebar = close.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 180, dy: 350))
    initialSidebar.press(forDuration: 0.05, thenDragTo: initialSidebar.withOffset(CGVector(dx: -140, dy: 0)))
    waitForSidebar(hidden)
    let window = app.windows.firstMatch
    // Start inside the reader's 32-point leading edge, below its toolbar.
    let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
      .withOffset(CGVector(dx: 16, dy: 0))
    edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 180, dy: 0)))
    waitForSidebar(visible)
    XCTAssertEqual(thumbnail.frame.minX, buttonOpenedFrame.minX, accuracy: 2)
    XCTAssertEqual(thumbnail.frame.width, buttonOpenedFrame.width, accuracy: 2)
    XCTAssertFalse(app.navigationBars["Reader tools"].exists, "Swipe opened a sheet instead of the system sidebar")

    // A vertical thumbnail scroll must leave the sidebar open.
    let sidebar = close.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 180, dy: 350))
    sidebar.press(forDuration: 0.05, thenDragTo: sidebar.withOffset(CGVector(dx: 0, dy: -150)))
    waitForSidebar(visible)
    sidebar.press(forDuration: 0.05, thenDragTo: sidebar.withOffset(CGVector(dx: -140, dy: 0)))
    waitForSidebar(hidden)
  }

  /// Apple on-device translation either translates or names the missing
  /// language download, never the framework's bare "Unable to Translate".
  @MainActor
  func testAppleTranslationReportsMissingLanguages() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe", "-PMRTranslationService", "appleOnDevice"]
    app.launch()
    XCTAssertTrue(translationProbes(in: app).firstMatch.waitForExistence(timeout: 30), "Reader did not open")

    let status = app.descendants(matching: .any).matching(identifier: "debug.pipelineStatus")
      .matching(NSPredicate(format: "value MATCHES %@", "(?s).*page [0-9]+: (error|ready).*")).firstMatch
    let translated = translatedProbe(in: app)
    let deadline = Date().addingTimeInterval(60)
    while !translated.exists && !status.exists && Date() < deadline { usleep(500_000) }
    attachPipelineStatus(app)
    attachScreenshot(app, name: "apple-reader")
    if translated.exists { return }
    let value = status.value as? String ?? ""
    XCTAssertTrue(value.contains("Download Languages") || value.contains("Apple on-device translation failed"),
                  "No actionable Apple Translation message: \(value)")

    // Settings shows the language status row with the download action.
    // Relaunching on iPad restores the reader window, so close it instead.
    closeReaderToLibrary(app)
    let settings = app.buttons["library.settings"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 15), "No Settings button in the library")
    settings.tap()
    let row = app.descendants(matching: .any)["settings.appleTranslationLanguages"].firstMatch
    if !row.waitForExistence(timeout: 5) {
      app.swipeUp()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10), "No Apple Translation language row in Settings")
    attachScreenshot(app, name: "apple-settings-row")
  }

  /// Dark appearance dims pages like the desktop's `invert(0.75)`: white
  /// paper renders as 25% gray (about 64 of 255), not white.
  @MainActor
  func testDarkModeInvertsPages() throws {
    XCUIDevice.shared.appearance = .dark
    defer { XCUIDevice.shared.appearance = .light }
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"] + freeService
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")
    // Translation covers must match the dimmed paper under them.
    XCTAssertTrue(translatedProbe(in: app).waitForExistence(timeout: 120), "No translated paragraph appeared")
    setTranslationsVisible(true, in: app)
    sleep(2)
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "dark-page"
    attachment.lifetime = .keepAlways
    add(attachment)

    let paper = try XCTUnwrap(dominantGray(in: screenshot.image), "Could not read the screenshot")
    XCTAssertTrue((52...76).contains(paper), "Dominant page gray is \(paper), expected about 64")
  }

  /// Switching appearance with a document open re-renders the pages in
  /// place, including the sidebar thumbnails and the library recents.
  @MainActor
  func testAppearanceSwitchWhileReading() throws {
    XCUIDevice.shared.appearance = .light
    XCUIDevice.shared.orientation = .landscapeLeft
    defer {
      XCUIDevice.shared.appearance = .light
      XCUIDevice.shared.orientation = .portrait
    }
    let app = XCUIApplication()
    // Use the repository fixture directly: test installation may replace the
    // simulator container, including a manually copied Documents/sample.pdf.
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/pdfs/sample.pdf")
    app.launchArguments = ["-PMROpenPDF", fixture.path, "-PMRUITestProbe"] + freeService
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")
    sleep(2)
    let light = app.screenshot()
    attachScreenshot(app, name: "1-light")
    XCTAssertGreaterThan(try XCTUnwrap(dominantGray(in: light.image)), 200, "Light page is not white")
    // The split view keeps two sidebar instances in one place; the element
    // screenshot shows whichever is on screen.
    let thumbnail = app.buttons.matching(identifier: "reader.thumbnail.1").firstMatch
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 10), "Sidebar thumbnail missing in landscape")
    let lightThumb = try XCTUnwrap(dominantGray(in: thumbnail.screenshot().image))
    XCTAssertGreaterThan(lightThumb, 200, "Light thumbnail is not white")

    XCUIDevice.shared.appearance = .dark
    sleep(3)
    XCTAssertTrue(pageLine(in: app).exists, "Page text vanished after switching to dark")
    let darkThumb = try XCTUnwrap(dominantGray(in: thumbnail.screenshot().image))
    XCTAssertTrue((52...76).contains(darkThumb), "Thumbnail gray is \(darkThumb) after a live switch")
    let dark = app.screenshot()
    attachScreenshot(app, name: "2-dark-live")
    let paper = try XCTUnwrap(dominantGray(in: dark.image))
    XCTAssertTrue((52...76).contains(paper), "Dominant page gray is \(paper) after a live switch")

    closeReaderToLibrary(app)
    sleep(2)
    attachScreenshot(app, name: "3-dark-library")

    app.terminate()
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not reopen")
    sleep(2)
    attachScreenshot(app, name: "4-dark-launch")
  }

  @MainActor
  func testOpenTranslateAndHighlight() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"] + freeService
    app.launch()

    XCTAssertTrue(translationProbes(in: app).firstMatch.waitForExistence(timeout: 30), "Reader did not open")
    // The probe lists every translated paragraph; wait until one is Chinese.
    let probe = translatedProbe(in: app)
    if !probe.waitForExistence(timeout: 120) {
      attachScreenshot(app, name: "translation-missing")
      attachPipelineStatus(app)
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

    guard let highlight = selectWordForAnnotation(in: app) else { return }
    attachScreenshot(app, name: "3-menu")
    highlight.tap()
    sleep(1)
    attachScreenshot(app, name: "4-highlighted")
  }

  /// Reading mode (the default): translations stay in place, a tap does not
  /// swap a paragraph back to the original, and a long press on translated
  /// text selects the source beneath it and offers the annotation menu.
  @MainActor
  func testReadingModeAnnotatesUnderTranslation() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-PMRUITestProbe"] + freeService
    app.launch()

    XCTAssertTrue(translationProbes(in: app).firstMatch.waitForExistence(timeout: 30), "Reader did not open")
    if !translatedProbe(in: app).waitForExistence(timeout: 120) {
      attachScreenshot(app, name: "translation-missing")
      attachPipelineStatus(app)
      XCTFail("No translated paragraph appeared")
      return
    }
    setTranslationsVisible(true, in: app)
    sleep(1)
    let before = displayedTranslations(in: app)
    XCTAssertGreaterThan(before, 0, "No translated text on screen")
    attachScreenshot(app, name: "1-reading-translated")

    pageLine(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.5)).tap()
    sleep(1)
    XCTAssertEqual(displayedTranslations(in: app), before, "A tap swapped a translation to the original")

    guard let highlight = selectWordForAnnotation(in: app) else { return }
    attachScreenshot(app, name: "2-reading-menu")
    highlight.tap()
    sleep(1)
    attachScreenshot(app, name: "3-reading-highlighted")
    // More paragraphs may finish translating meanwhile; none may disappear.
    XCTAssertGreaterThanOrEqual(displayedTranslations(in: app), before, "Translations disappeared after highlighting")
  }

  /// Paragraphs the overlays currently show in translation (Han text).
  @MainActor
  private func displayedTranslations(in app: XCUIApplication) -> Int {
    // iPad may restore several reader windows; sum over every probe.
    app.descendants(matching: .any).matching(identifier: "debug.overlayText").allElementsBoundByIndex
      .flatMap { ($0.value as? String ?? "").split(separator: "\n") }
      .filter { $0.range(of: "\\p{Han}", options: .regularExpression) != nil }
      .count
  }

  /// "The grass-blade is worthy" is the sample's first line. PDFKit exposes
  /// that line as static text, which keeps presses independent of layout.
  @MainActor
  private func pageLine(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "The grass-blade is worthy")
    ).firstMatch
  }

  /// Selects "worthy" (37% along the first line) and returns the visible
  /// Highlight Yellow menu entry, or records a failure and returns nil.
  @MainActor
  private func selectWordForAnnotation(in app: XCUIApplication) -> XCUIElement? {
    let line = pageLine(in: app)
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
      return nil
    }
    return highlight
  }

  /// iPad reader: sidebar hidden in portrait, shown in landscape.
  @MainActor
  func testSidebarFollowsOrientation() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()

    let thumbnails = app.buttons["reader.closeDocument"].firstMatch
    let shown = NSPredicate(format: "exists == true AND isHittable == true")
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    func expectSidebar(_ predicate: NSPredicate, _ name: String) {
      let result = XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: thumbnails)],
        timeout: 10
      )
      attachScreenshot(app, name: name)
      XCTAssertEqual(result, .completed, "Unexpected sidebar state: \(name)")
    }

    let pageText = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "The grass-blade is worthy")
    ).firstMatch
    XCTAssertTrue(pageText.waitForExistence(timeout: 30), "Reader did not open")
    expectSidebar(hidden, "portrait-sidebar-hidden")
    XCUIDevice.shared.orientation = .landscapeLeft
    expectSidebar(shown, "landscape-sidebar-shown")
    XCUIDevice.shared.orientation = .portrait
    expectSidebar(hidden, "portrait-again-sidebar-hidden")
  }

  /// Explicit sidebar choices survive leaving and returning to the app.
  @MainActor
  func testSidebarVisibilityPersistsAcrossBackgroundActivation() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    XCUIDevice.shared.orientation = .portrait

    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()

    let close = app.buttons["reader.closeDocument"].firstMatch
    let toggle = app.buttons["reader.toggleSidebar"].firstMatch
    let visible = NSPredicate(format: "exists == true AND isHittable == true")
    let hidden = NSPredicate(format: "exists == false OR isHittable == false")
    func waitForSidebar(_ predicate: NSPredicate, _ message: String) {
      XCTAssertEqual(
        XCTWaiter().wait(
          for: [XCTNSPredicateExpectation(predicate: predicate, object: close)],
          timeout: 10
        ),
        .completed,
        message
      )
    }
    func reactivate() {
      XCUIDevice.shared.press(.home)
      app.activate()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
      XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 10))
      // Let delayed layout work settle before checking the user's choice.
      sleep(1)
    }

    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Reader sidebar toggle missing")
    waitForSidebar(hidden, "Portrait sidebar did not start hidden")
    toggle.tap()
    waitForSidebar(visible, "Sidebar did not open")
    reactivate()
    waitForSidebar(visible, "Visible sidebar disappeared after activation")

    toggle.tap()
    waitForSidebar(hidden, "Sidebar did not hide")
    reactivate()
    waitForSidebar(hidden, "Hidden sidebar reappeared after activation")
  }

  /// Desktop parity: the pager sits in the bottom-right corner, appears when
  /// the document scrolls, and hides again about a second later.
  @MainActor
  func testPagerAutoShowsInBottomRightCorner() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()

    let pageText = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "The grass-blade is worthy")
    ).firstMatch
    XCTAssertTrue(pageText.waitForExistence(timeout: 30), "Reader did not open")
    let pager = app.descendants(matching: .any).matching(identifier: "reader.pager").firstMatch
    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: pager)], timeout: 5),
      .completed,
      "Pager stayed up without scrolling"
    )

    // Drag on blank page space; starting on text would select it instead.
    // Zoom in first: the one-page sample fits an iPhone screen and would not scroll.
    let window = app.windows.firstMatch
    window.pinch(withScale: 2, velocity: 2)
    // The pager hides 1 s after the last scroll, so query it right away.
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.72))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.42)))
    guard pager.exists else {
      attachScreenshot(app, name: "pager-missing")
      XCTFail("Pager did not appear on scroll")
      return
    }
    let shownFrame = pager.frame
    attachScreenshot(app, name: "pager-shown")
    XCTAssertGreaterThan(shownFrame.minX, window.frame.midX, "Pager is not on the right")
    XCTAssertGreaterThan(shownFrame.minY, window.frame.midY, "Pager is not at the bottom")

    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: pager)], timeout: 4),
      .completed,
      "Pager did not hide after scrolling stopped"
    )
    attachScreenshot(app, name: "pager-hidden")
  }

  /// Top-right toolbar keeps translation and search directly accessible,
  /// with annotation visibility in the menu. Expects
  /// `sample.pdf` to carry at least one highlight.
  @MainActor
  func testTrailingToolbarLayout() {
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")

    let bar = app.navigationBars.firstMatch
    let translation = bar.buttons["reader.toggleTranslations"]
    let search = bar.buttons["Search document"]
    let more = bar.buttons["reader.moreMenu"]
    for (button, name) in [(translation, "translation"), (search, "search"), (more, "menu")] {
      XCTAssertTrue(button.waitForExistence(timeout: 5), "No \(name) button in the toolbar")
      XCTAssertTrue(button.isHittable, "\(name) button is not directly in the toolbar")
    }
    XCTAssertFalse(bar.buttons["reader.toggleAnnotations"].exists, "Annotation visibility should live in the menu")
    XCTAssertLessThan(translation.frame.minX, search.frame.minX)
    XCTAssertLessThan(search.frame.minX, more.frame.minX)
    for moved in ["Zoom", "Layout", "Export PDF"] {
      XCTAssertFalse(bar.buttons[moved].exists, "\(moved) should live in the menu")
    }
    attachScreenshot(app, name: "1-toolbar")

    more.tap()
    let hideAnnotations = app.buttons["Hide highlights and comments"].firstMatch
    XCTAssertTrue(hideAnnotations.waitForExistence(timeout: 3))
    hideAnnotations.tap()
    more.tap()
    let showAnnotations = app.buttons["Show highlights and comments"].firstMatch
    XCTAssertTrue(showAnnotations.waitForExistence(timeout: 3))
    sleep(1)
    attachScreenshot(app, name: "2-annotations-hidden")
    showAnnotations.tap()

    more.tap()
    XCTAssertTrue(hideAnnotations.waitForExistence(timeout: 3))
    for item in ["Zoom", "Layout", "Export"] {
      XCTAssertTrue(app.buttons[item].firstMatch.waitForExistence(timeout: 3), "\(item) missing from the menu")
    }
    // iOS 27 devices drop the identifier on menu items, so accept the label too.
    let translateAll = app.buttons.matching(
      NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "reader.translateAllPages", "Translate all pages")
    ).firstMatch
    XCTAssertTrue(translateAll.waitForExistence(timeout: 3), "Translate all pages missing from the menu")
    attachScreenshot(app, name: "3-menu")
  }

  /// iPad reader: the sidebar's close button closes the document window and
  /// returns to the library.
  @MainActor
  func testCloseDocumentFromSidebar() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf"]
    app.launch()

    let close = app.buttons["reader.closeDocument"].firstMatch
    XCTAssertTrue(pageLine(in: app).waitForExistence(timeout: 30), "Reader did not open")
    if !close.waitForExistence(timeout: 5) {
      // Portrait starts with the sidebar hidden; open it with the split view's toggle.
      app.buttons.matching(
        NSPredicate(format: "identifier == %@ OR label CONTAINS[c] %@", "ToggleSidebar", "Sidebar")
      ).firstMatch.tap()
    }
    XCTAssertTrue(close.waitForExistence(timeout: 10), "No close button in the sidebar")
    attachScreenshot(app, name: "1-sidebar-close-button")
    close.tap()

    // Windows restored from earlier runs may linger in the background and stay
    // in the accessibility tree, so check what is in front rather than existence.
    let front = NSPredicate(format: "exists == true AND isHittable == true")
    let notFront = NSPredicate(format: "exists == false OR isHittable == false")
    let results = [
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: front, object: app.buttons["Import PDF"].firstMatch)], timeout: 10),
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: notFront, object: close)], timeout: 10),
    ]
    attachScreenshot(app, name: "2-library-after-close")
    XCTAssertEqual(results[0], .completed, "Library did not come back")
    XCTAssertEqual(results[1], .completed, "Reader window is still in front")
  }

  @MainActor
  /// Opens a PDF that lives outside the app sandbox (Files "On My iPad" or
  /// iCloud Drive) through the import picker. Place `PMR-Files-Test.pdf` in
  /// that location first.
  func testOpenFromFilesPicker() {
    let fileName = "PMR-Files-Test"
    let app = XCUIApplication()
    app.launchArguments = ["-PMRUITestProbe"] + freeService
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
    // The picker can report the result before its search transition ends and
    // then rebuild the cell, so re-query until a live cell can take the tap.
    let tapDeadline = Date().addingTimeInterval(10)
    var tapped = false
    while !tapped && Date() < tapDeadline {
      let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", fileName)).firstMatch
      if cell.exists && cell.isHittable {
        cell.tap()
        tapped = true
      } else if cell.exists && Date().addingTimeInterval(5) > tapDeadline {
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tapped = true
      } else {
        usleep(250_000)
      }
    }
    XCTAssertTrue(tapped, "\(fileName) result never became tappable")
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
      attachPipelineStatus(app)
      XCTFail("No translated paragraph appeared for the picked PDF")
      return
    }
    setTranslationsVisible(true, in: app)
    sleep(1)
    attachScreenshot(app, name: "files-translated")
  }

  /// Closes the front reader through the sidebar's close button so the
  /// library is in front.
  @MainActor
  private func closeReaderToLibrary(_ app: XCUIApplication) {
    guard UIDevice.current.userInterfaceIdiom == .pad else {
      // iPhone does not restore the reader, so a plain relaunch shows the library.
      let arguments = app.launchArguments.filter { $0 != "-PMROpenPDF" && $0 != "sample.pdf" }
      app.terminate()
      app.launchArguments = arguments
      app.launch()
      return
    }
    let close = app.buttons["reader.closeDocument"].firstMatch
    if !(close.exists && close.isHittable) {
      app.buttons.matching(
        NSPredicate(format: "identifier == %@ OR identifier == %@ OR label CONTAINS[c] %@",
                    "reader.toggleSidebar", "ToggleSidebar", "Sidebar")
      ).firstMatch.tap()
    }
    XCTAssertTrue(close.waitForExistence(timeout: 10), "No close button in the sidebar")
    close.tap()
    let front = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND isHittable == true"),
      object: app.buttons["library.settings"].firstMatch
    )
    XCTAssertEqual(XCTWaiter().wait(for: [front], timeout: 10), .completed, "Library did not come back")
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
  private func attachPipelineStatus(_ app: XCUIApplication) {
    let probes = app.descendants(matching: .any).matching(identifier: "debug.pipelineStatus")
    let values = probes.allElementsBoundByIndex.map { $0.value as? String ?? "" }
    let attachment = XCTAttachment(string: values.joined(separator: "\n---\n"))
    attachment.name = "pipeline-status"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The most common gray level (0-255) in the middle of the screen, where
  /// the page sits; colored pixels are skipped.
  private func dominantGray(in image: UIImage) -> Int? {
    guard let cgImage = image.cgImage else { return nil }
    let crop = CGRect(
      x: CGFloat(cgImage.width) * 0.3, y: CGFloat(cgImage.height) * 0.3,
      width: CGFloat(cgImage.width) * 0.4, height: CGFloat(cgImage.height) * 0.4
    ).integral
    guard let region = cgImage.cropping(to: crop) else { return nil }
    let side = 120
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
      data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .none
    context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
    var counts = [Int](repeating: 0, count: 256)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
      guard max(red, green, blue) - min(red, green, blue) < 8 else { continue }
      counts[(red + green + blue) / 3] += 1
    }
    return counts.indices.max { counts[$0] < counts[$1] }
  }
}

/// Opt-in physical-device benchmarks. Seed Documents/pmr-long-20.pdf before running.
/// Uses an optimized build with DEBUG launch hooks; no polling UI probe is enabled.
@available(iOS 26.0, *)
final class LongPDFPerformanceUITests: XCTestCase {
  @MainActor
  private func openLongPDF() throws -> XCUIApplication {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["PMR_RUN_DEVICE_PERF"] == "1", "Opt-in device benchmark")
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "pmr-long-20.pdf"]
    app.launch()
    XCTAssertTrue(app.buttons["reader.moreMenu"].firstMatch.waitForExistence(timeout: 40))
    XCTAssertTrue(app.staticTexts["pmr-long-20.pdf"].firstMatch.waitForExistence(timeout: 10))
    sleep(3)
    return app
  }

  @MainActor
  private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testLongPDFScrollingPerformance() throws {
    let app = try openLongPDF()
    keepScreenshot(app, "long-pdf-scroll-before")
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app),
                      XCTCPUMetric(application: app), XCTHitchMetric(application: app),
                      XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
      let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.86))
      let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
      for _ in 0..<6 { bottom.press(forDuration: 0.05, thenDragTo: top) }
      for _ in 0..<6 { top.press(forDuration: 0.05, thenDragTo: bottom) }
    }
    XCTAssertEqual(app.state, .runningForeground)
    sleep(5)
    keepScreenshot(app, "long-pdf-scroll-after-round-trips")
  }

  @MainActor
  func testLongPDFZoomPerformance() throws {
    let app = try openLongPDF()
    keepScreenshot(app, "long-pdf-zoom-before")
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app),
                      XCTHitchMetric(application: app)], options: options) {
      // The reader fills this portion of the window; pinch acts on its PDF scroll view.
      let target = app.windows.firstMatch
      for _ in 0..<3 {
        target.pinch(withScale: 1.8, velocity: 1.5)
        target.pinch(withScale: 1.0 / 1.8, velocity: -1.5)
      }
    }
    XCTAssertEqual(app.state, .runningForeground)
    sleep(5)
    keepScreenshot(app, "long-pdf-zoom-after-cycles")
  }
}
