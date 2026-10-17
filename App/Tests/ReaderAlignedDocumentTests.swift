import Foundation
import PDFKit
import ReaderCore
import XCTest
@testable import PDFMathReader

@MainActor
final class ReaderAlignedDocumentTests: XCTestCase {
  func testAlignmentFailureStillOpensOriginalPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = PDFDocument()
    for (index, width) in [200.0, 400.0].enumerated() {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: width, height: 600), for: .mediaBox)
      document.insert(page, at: index)
    }
    let data = try XCTUnwrap(document.dataRepresentation())
    let url = root.appendingPathComponent("Mixed.pdf")
    try data.write(to: url)
    let directory = root.appendingPathComponent("Library")
    let links = ReaderQuickLinkStore(directory: directory.appendingPathComponent("quick-links"))
    let corruptURL = try links.url(for: DocumentIdentity.contentHash(for: data))
    try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("invalid sidecar".utf8).write(to: corruptURL)
    let library = LibraryModel(directory: directory)
    var preferences = library.preferences
    preferences.autoAlignDocumentWidth = true
    library.savePreferences(preferences)
    let candidate = await library.makeSession(for: url)
    let session = try XCTUnwrap(candidate)
    XCTAssertEqual(session.url, url)
    XCTAssertEqual(try Data(contentsOf: url), data)
    XCTAssertNotNil(library.lastError)
    XCTAssertEqual(library.recents.count, 1)
  }

  func testOptInCreatesStableCopyPreservingReaderStateAndOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Mixed.pdf")
    let pdf = PDFDocument()
    for (index, width) in [200.0, 400.0, 200.0].enumerated() {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: width, height: 600), for: .mediaBox)
      pdf.insert(page, at: index)
    }
    let original = try XCTUnwrap(pdf.dataRepresentation())
    try original.write(to: url)
    let directory = root.appendingPathComponent("Library")
    let library = LibraryModel(directory: directory)
    let initialCandidate = await library.makeSession(for: url)
    let initial = try XCTUnwrap(initialCandidate)
    XCTAssertEqual(initial.url, url)
    library.saveReadingState(ReadingState(page: 2), for: initial)
    library.togglePinned(try XCTUnwrap(library.recents.first))
    let rect = ReaderAnnotationRect(x: 40, y: 60, width: 80, height: 20)
    let annotation = ReaderAnnotation(id: "note", page: 2, kind: .highlight,
      text: "kept", comment: "note", color: "#FFFF00", rects: [rect],
      createdAt: "2026-10-17T00:00:00Z", sourceRect: rect)
    let store = ReaderAnnotationStore(directory: directory.appendingPathComponent("annotations"))
    try store.save(ReaderAnnotationState(annotations: [annotation]), for: initial.id)
    var preferences = library.preferences
    preferences.autoAlignDocumentWidth = true
    library.savePreferences(preferences)
    let alignedCandidate = await library.makeSession(for: url)
    let aligned = try XCTUnwrap(alignedCandidate, library.lastError ?? "no session")
    XCTAssertNotEqual(aligned.id, initial.id)
    XCTAssertNotEqual(aligned.url, url)
    XCTAssertEqual(try Data(contentsOf: url), original)
    let alignedPDF = try XCTUnwrap(PDFDocument(url: aligned.url))
    for index in 0..<3 {
      XCTAssertEqual(try XCTUnwrap(alignedPDF.page(at: index)).bounds(for: .cropBox).width, 200, accuracy: 0.01)
    }
    let metadata = try XCTUnwrap(ReaderTransferPDF.metadata(from: alignedPDF))
    XCTAssertEqual(metadata.annotations.first?.rects.first?.x, 20)
    XCTAssertEqual(metadata.annotations.first?.sourceRect?.width, 40)
    XCTAssertEqual(metadata.readingState.page, 2)
    XCTAssertEqual(library.recents.count, 1)
    XCTAssertTrue(try XCTUnwrap(library.recents.first).pinned)
    let againCandidate = await library.makeSession(for: url)
    let again = try XCTUnwrap(againCandidate)
    XCTAssertEqual(again.id, aligned.id)
    XCTAssertEqual(again.url, aligned.url)
    XCTAssertEqual(library.recents.count, 1)
  }
}
