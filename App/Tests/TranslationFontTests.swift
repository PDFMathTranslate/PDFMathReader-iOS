import UIKit
import XCTest
@testable import PDFMathReader

final class TranslationFontTests: XCTestCase {
  func testInstalledFontIsUsedAndBoldIsPreserved() {
    let font = ReaderTranslationFont.resolve(name: "Georgia", serif: false, size: 18, bold: true)
    XCTAssertEqual(font.familyName, "Georgia")
    XCTAssertEqual(font.pointSize, 18)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
  }

  func testUnavailableFontUsesChosenDefault() {
    for serif in [false, true] {
      let fallback = ReaderTranslationFont.resolve(name: "", serif: serif, size: 16)
      let missing = ReaderTranslationFont.resolve(name: "Missing-PMR-Font", serif: serif, size: 16)
      XCTAssertEqual(missing.fontName, fallback.fontName)
      XCTAssertEqual(missing.pointSize, 16)
    }
  }

  @MainActor
  func testBionicEmphasisKeepsSelectedFontFamily() {
    let font = ReaderTranslationFont.resolve(name: "Georgia", serif: false, size: 18)
    let text = readingAidsAttributedString(
      text: "Reading", font: font,
      configuration: ReadingAidsConfiguration(
        bionicOptions: .init(mode: .fixed, fixedLength: 2), bionicOriginalOnly: false
      ),
      isOriginal: false
    )
    let emphasized = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    XCTAssertEqual(emphasized?.familyName, font.familyName)
    XCTAssertTrue(emphasized?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
  }
}
