import Foundation
import PDFKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderViewModelOutlineTests: XCTestCase {
  func testNativeOutlineIsCachedAndPreventsGeneratedTOCScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = PDFDocument()
    for index in 0..<2 {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
      source.insert(page, at: index)
    }
    let outlineRoot = PDFOutline()
    let chapter = PDFOutline()
    chapter.label = "Chapter 1"
    chapter.destination = PDFDestination(
      page: try XCTUnwrap(source.page(at: 0)), at: CGPoint(x: 0, y: 0)
    )
    outlineRoot.insertChild(chapter, at: 0)
    source.outlineRoot = outlineRoot

    let url = root.appendingPathComponent("outline.pdf")
    try XCTUnwrap(source.dataRepresentation()).write(to: url)

    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.tocGenerationEnabled = true
    library.savePreferences(preferences)
    let session = DocumentSession(
      id: "outline-test",
      title: "outline.pdf",
      url: url,
      access: SecurityScopedAccess(url: url)
    )
    let model = ReaderViewModel(session: session, library: library)

    await model.loadDocument()

    let display = try XCTUnwrap(model.displayDocument)
    XCTAssertFalse(display === model.document, "Display mutations must remain isolated from search and translation")
    XCTAssertEqual(display.pageCount, model.pageCount)
    XCTAssertEqual(display.documentURL, url)

    let firstEntries = model.outlineEntries
    let secondEntries = model.outlineEntries
    XCTAssertEqual(firstEntries.map(\.title), ["Chapter 1"])
    XCTAssertEqual(secondEntries, firstEntries)
    XCTAssertEqual(model.debugOutlineCacheBuildCount, 1)

    await model.loadGeneratedTOC()

    XCTAssertEqual(model.debugGeneratedTOCLoadCount, 0)
    XCTAssertEqual(model.outlineEntries, firstEntries)
  }
}
