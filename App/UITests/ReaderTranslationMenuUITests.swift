import XCTest

final class ReaderTranslationMenuUITests: XCTestCase {
  @MainActor
  func testReaderMoreMenuSupportsTranslationLanguagesAndUltraFastKernel() {
    continueAfterFailure = false

    let app = XCUIApplication()
    app.launchArguments = ["-PMROpenPDF", "sample.pdf", "-AppleLanguages", "(en)", "-PMRUILanguage", "en", "-AppleLocale", "en_US"]
    app.launch()

    openTranslationMenu(in: app)
    let source = menuEntry("reader.sourceLanguage", label: "Source language", in: app)
    let target = menuEntry("reader.targetLanguage", label: "Target Language", in: app)
    let kernel = menuEntry("reader.kernel", label: "Engine", in: app)
    XCTAssertTrue(source.waitForExistence(timeout: 5), "Source language picker is missing")
    XCTAssertTrue(target.waitForExistence(timeout: 5), "Target Language picker is missing")
    XCTAssertTrue(kernel.waitForExistence(timeout: 5), "Engine submenu is missing")

    expand(source, revealing: menuItem("English", in: app))
    let initialSource = selectedMenuItemLabel(in: app)
    let englishSource = menuItem("English", in: app)
    XCTAssertTrue(englishSource.waitForExistence(timeout: 5), "English source language is missing")
    englishSource.tap()

    openTranslationMenu(in: app)
    expand(source, revealing: menuItem("English", in: app))
    let selectedEnglish = menuItem("English", in: app)
    XCTAssertTrue(selectedEnglish.waitForExistence(timeout: 5), "English source language disappeared")
    if initialSource != nil {
      XCTAssertTrue(selectedEnglish.isSelected, "Selecting English did not update the source checkmark")
    }

    let sourceToRestore = initialSource ?? "Automatic detection"
    let restoreSource = menuItem(sourceToRestore, in: app)
    XCTAssertTrue(restoreSource.waitForExistence(timeout: 5), "Original source language could not be restored")
    restoreSource.tap()

    openTranslationMenu(in: app)
    expand(target, revealing: menuItem("Japanese", in: app))
    let initialTarget = selectedMenuItemLabel(in: app)
    let targetChoice = initialTarget == "English" ? "Japanese" : "English"
    let chosenTarget = menuItem(targetChoice, in: app)
    XCTAssertTrue(chosenTarget.waitForExistence(timeout: 5), "Target language choices are missing")
    chosenTarget.tap()

    openTranslationMenu(in: app)
    expand(target, revealing: menuItem(targetChoice, in: app))
    let selectedTarget = menuItem(targetChoice, in: app)
    XCTAssertTrue(selectedTarget.waitForExistence(timeout: 5), "Selected target language disappeared")
    if initialTarget != nil {
      XCTAssertTrue(selectedTarget.isSelected, "Selecting a target language did not update its checkmark")
      let restoreTarget = menuItem(initialTarget!, in: app)
      XCTAssertTrue(restoreTarget.waitForExistence(timeout: 5), "Original target language could not be restored")
      restoreTarget.tap()
    } else {
      selectedTarget.tap()
    }

    openTranslationMenu(in: app)
    let ultraFast = menuEntry("reader.kernel.ultraFast", label: "Ultra fast on device", in: app)
    expand(kernel, revealing: ultraFast)
    XCTAssertTrue(ultraFast.waitForExistence(timeout: 5), "Ultra Fast kernel entry is missing")
    ultraFast.tap()
  }

  @MainActor
  private func openTranslationMenu(in app: XCUIApplication) {
    openMoreMenu(in: app)
    let translation = menuEntry("reader.translationMenu", label: "Translation", in: app)
    XCTAssertTrue(translation.waitForExistence(timeout: 5), "Translation submenu is missing")
    expand(translation, revealing: menuEntry("reader.sourceLanguage", label: "Source language", in: app))
  }

  /// Opens a submenu and waits for one of its entries to appear.
  @MainActor
  private func expand(_ entry: XCUIElement, revealing child: XCUIElement) {
    entry.tap()
    _ = child.waitForExistence(timeout: 5)
  }

  @MainActor
  private func openMoreMenu(in app: XCUIApplication) {
    let more = element(withIdentifier: "reader.moreMenu", in: app)
    if more.exists, more.isHittable {
      more.tap()
      return
    }
    // Compact toolbars put the app menu inside the system overflow menu.
    let overflow = app.navigationBars.buttons["More"].firstMatch
    XCTAssertTrue(overflow.waitForExistence(timeout: 30), "Reader More menu did not appear")
    overflow.tap()
    if more.exists, more.isHittable {
      more.tap()
    } else {
      let submenu = app.collectionViews.buttons["More"].firstMatch
      XCTAssertTrue(submenu.waitForExistence(timeout: 5))
      submenu.tap()
    }
  }

  /// iPadOS 27 drops accessibility identifiers from nested SwiftUI menus, so
  /// entries fall back to the English titles pinned by `-PMRUILanguage en`.
  @MainActor
  private func menuEntry(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ OR (label == %@ AND elementType == %d)",
        identifier,
        label,
        XCUIElement.ElementType.button.rawValue
      )
    ).firstMatch
  }

  @MainActor
  private func element(withIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @MainActor
  private func menuItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
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
  private func selectedMenuItemLabel(in app: XCUIApplication) -> String? {
    let selected = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "selected == true AND (elementType == %d OR elementType == %d)",
        XCUIElement.ElementType.button.rawValue,
        XCUIElement.ElementType.menuItem.rawValue
      )
    )
    return selected.allElementsBoundByIndex
      .map(\.label)
      .first {
        !$0.isEmpty &&
          !$0.localizedCaseInsensitiveContains("source language") &&
          !$0.localizedCaseInsensitiveContains("target language") &&
          !$0.localizedCaseInsensitiveContains("engine")
      }
  }
}
