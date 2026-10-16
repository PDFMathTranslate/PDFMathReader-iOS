import PDFKit
import ReaderCore
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderTransferImportTests: XCTestCase {
  func testReceivedReadingPositionRestoresOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Received.pdf")
    try transferData().write(to: url)
    let library = LibraryModel(directory: directory.appendingPathComponent("Library"))
    let session = try XCTUnwrap(library.makeSession(for: url))
    XCTAssertEqual(library.readingState(for: session).page, 2)
    var local = library.readingState(for: session)
    local.page = 1
    library.saveReadingState(local, for: session)
    // Annotation edits change the PDF bytes, but must keep the recipient's
    // local identity and reading state on the next open.
    let rewritten = try ReaderAnnotationPDF.embedAnnotations([], in: Data(contentsOf: url))
    try rewritten.write(to: url)
    let reopened = try XCTUnwrap(library.makeSession(for: url))
    XCTAssertEqual(reopened.id, session.id)
    XCTAssertEqual(library.readingState(for: reopened).page, 1)
  }

  func testReceivedQuickLinksRestoreButDoNotResurrectDeletedLinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Received.pdf")
    try transferData().write(to: url)
    let session = DocumentSession(id: "transfer-test", title: "Received.pdf", url: url, access: SecurityScopedAccess(url: url))
    let annotations = ReaderAnnotationStore(directory: directory.appendingPathComponent("Annotations"))
    let links = ReaderQuickLinkStore(directory: directory.appendingPathComponent("Links"))
    let first = ReaderAnnotationViewModel(session: session, store: annotations, quickLinkStore: links)
    XCTAssertNil(first.lastError)
    XCTAssertEqual(first.quickLinks.map(\.id), ["link-1"])
    XCTAssertEqual(try links.load(session.id), first.quickLinks)
    try links.save([], for: session.id)
    let reopened = ReaderAnnotationViewModel(session: session, store: annotations, quickLinkStore: links)
    XCTAssertNil(reopened.lastError)
    XCTAssertTrue(reopened.quickLinks.isEmpty)
  }

  private func transferData() throws -> Data {
    let document = PDFDocument()
    for index in 0..<2 {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
      document.insert(page, at: index)
    }
    let link = ReaderQuickLink(
      id: "link-1",
      origin: ReaderQuickLinkEndpoint(page: 1, box: ReaderQuickLinkBox(x: 10, y: 10, width: 20, height: 10)),
      result: ReaderQuickLinkEndpoint(page: 2, box: ReaderQuickLinkBox(x: 20, y: 20, width: 20, height: 10))
    )
    return try ReaderTransferPDF.export(
      sourceData: XCTUnwrap(document.dataRepresentation()),
      annotations: [],
      quickLinks: [link],
      readingState: ReadingState(page: 2)
    )
  }
}
