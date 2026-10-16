import CoreText
import PDFKit
import UIKit
import XCTest
@testable import PDFMathReader

final class TranslationCJKFontTests: XCTestCase {
  func testSerifChineseGlyphFallbackPreservesLatinFamilyAndWeight() {
    for bold in [false, true] {
      let font = ReaderTranslationFont.resolve(name: "Times New Roman", serif: true,
                                               size: 20, bold: bold, language: "zh-TW")
      // Precise fits fonts with withSize; the cascade must survive that operation.
      let names = shapedFonts(font.withSize(16))
      XCTAssertTrue(names.contains { $0.contains("TimesNewRoman") }, "\(names)")
      XCTAssertTrue(names.contains("NotoSerifCJKtc-" + (bold ? "Bold" : "Regular")), "\(names)")
      XCTAssertFalse(names.contains { $0.contains("PingFang") }, "\(names)")
    }
  }

  func testDefaultAndMissingSerifFontsAlsoUseChineseSerifFallback() {
    for name in ["", "Missing-PMR-Font"] {
      let names = shapedFonts(ReaderTranslationFont.resolve(name: name, serif: true,
                                                            size: 20, language: "zh-TW"))
      XCTAssertTrue(names.contains("NotoSerifCJKtc-Regular"), "\(names)")
    }
  }

  func testSansSettingRetainsSystemChineseFallback() {
    let names = shapedFonts(ReaderTranslationFont.resolve(name: "", serif: false,
                                                          size: 20, language: "zh-TW"))
    XCTAssertFalse(names.contains { $0.contains("NotoSerif") }, "\(names)")
  }

  @MainActor
  func testPreciseExportEmbedsSelectableChineseSerifText() throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 150)).pdfData {
      $0.beginPage()
      ("繁體中文漢字" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [
        .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black
      ])
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let renderer = ReaderRemoteTranslationFont(page: try XCTUnwrap(document.page(at: 0)), original: nil)
    XCTAssertFalse(renderer.runs.isEmpty)
    let exported = try renderer.pdfData(name: "Times New Roman", serif: true, language: "zh-TW")
    let output = try XCTUnwrap(PDFDocument(data: exported))
    let page = try XCTUnwrap(output.page(at: 0))
    let text = try XCTUnwrap(page.attributedString)
    var names: [String] = []
    var serifText = ""
    text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
      if let font = value as? UIFont {
        names.append(font.fontName)
        if font.fontName.contains("NotoSerifCJKtc") {
          serifText += (text.string as NSString).substring(with: range)
        }
      }
    }
    XCTAssertTrue(names.contains { $0.contains("NotoSerifCJKtc") }, "\(names)")
    // PDFKit can extract compatibility radicals (for example ⽂ for 文).
    XCTAssertEqual(serifText.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace },
                   "繁體中文漢字")
  }

  private func shapedFonts(_ font: UIFont) -> [String] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
      string: "Traditional 繁體中文漢字", attributes: [.font: font]
    ))
    return (CTLineGetGlyphRuns(line) as! [CTRun]).map {
      let attributes = CTRunGetAttributes($0) as NSDictionary
      return CTFontCopyPostScriptName(attributes[kCTFontAttributeName] as! CTFont) as String
    }
  }
}
