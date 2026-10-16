import PDFKit
import ReaderCore
import UIKit
import XCTest
@testable import PDFMathReader

@MainActor
final class ParagraphCompactionTests: XCTestCase {
  private func document() throws -> ReaderPDFDocument {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { renderer in
      renderer.beginPage()
      let font = UIFont.systemFont(ofSize: 12)
      ("First paragraph" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: font])
      ("Second paragraph" as NSString).draw(at: CGPoint(x: 30, y: 340), withAttributes: [.font: font])
      // Non-text content must survive whitespace analysis.
      renderer.cgContext.fill(CGRect(x: 30, y: 200, width: 100, height: 20))
    }
    return try XCTUnwrap(ReaderPDFDocument(data: data))
  }

  func testCompactedVectorPageAndCoordinateRoundTrip() throws {
    let document = try document()
    let source = try XCTUnwrap(document.page(at: 0))
    let compact = try XCTUnwrap(ReaderPageCompaction.make(page: source))
    XCTAssertFalse(compact.cuts.contains { $0.start < 220 && $0.end > 200 }, "Graphics must remain occupied")
    let page = try XCTUnwrap(compact.makePage())
    XCTAssertLessThan(page.bounds(for: .cropBox).height, 400)
    let point = CGPoint(x: 35, y: 150)
    let restored = compact.sourcePoint(compact.displayPoint(point))
    XCTAssertEqual(restored.y, point.y, accuracy: 0.01)
    document.removePage(at: 0)
    document.insert(page, at: 0)
    let second = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox))?.string)
    XCTAssertTrue(second.contains("First paragraph"), second.debugDescription)
    XCTAssertTrue(second.contains("Second paragraph"), second.debugDescription)
    XCTAssertEqual(second.components(separatedBy: "Second paragraph").count - 1, 1)
    let saved = try XCTUnwrap(document.uncompactedData())
    let restoredPage = try XCTUnwrap(PDFDocument(data: saved)?.page(at: 0))
    XCTAssertEqual(restoredPage.bounds(for: .cropBox).height, 500, accuracy: 0.1)
  }

  func testRotatedPageStaysUnchanged() throws {
    let document = try document()
    let page = try XCTUnwrap(document.page(at: 0))
    page.rotation = 90
    XCTAssertNil(ReaderPageCompaction.make(page: page))
  }

  func testLatestAnnotationsRestoreToSourceCoordinates() throws {
    let document = try document()
    let source = try XCTUnwrap(document.page(at: 0))
    let compact = try XCTUnwrap(ReaderPageCompaction.make(page: source))
    let page = try XCTUnwrap(compact.makePage())
    document.removePage(at: 0)
    document.insert(page, at: 0)
    let point = compact.displayPoint(CGPoint(x: 40, y: 150))
    let note = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y, width: 10, height: 5),
                             forType: .text, withProperties: nil)
    note.contents = "Latest edit"
    note.shouldDisplay = false
    page.addAnnotation(note)
    compact.synchronizeAnnotations(from: page)
    let restored = try XCTUnwrap(compact.sourcePage.annotations.first { $0.contents == "Latest edit" })
    XCTAssertEqual(restored.contents, "Latest edit")
    XCTAssertEqual(restored.bounds.minY, 150, accuracy: 0.01)
    XCTAssertFalse(restored.shouldDisplay)
  }

  func testPreferenceMigrationAndPersistence() throws {
    XCTAssertTrue(try JSONDecoder().decode(ReaderPreferences.self, from: Data("{}".utf8)).paragraphGapOptimization)
    var preferences = ReaderPreferences()
    preferences.paragraphGapOptimization = false
    XCTAssertFalse(try JSONDecoder().decode(ReaderPreferences.self,
      from: JSONEncoder().encode(preferences)).paragraphGapOptimization)
  }
}
