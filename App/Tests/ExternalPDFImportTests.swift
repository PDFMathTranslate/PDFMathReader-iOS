import Foundation
import PDFKit
import ReaderCore
import XCTest

@testable import PDFMathReader

@MainActor
final class ExternalPDFImportTests: XCTestCase {
  func testExternalPDFIsCopiedAndRecentsReopenAfterSourceDeletion() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root
      .appendingPathComponent("Incoming", isDirectory: true)
      .appendingPathComponent("Paper.pdf")
    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sourceData = try blankPDFData()
    try sourceData.write(to: sourceURL)

    let library = LibraryModel(directory: libraryDirectory)
    let importedSession = await library.receiveExternalPDF(at: sourceURL)
    let imported = try XCTUnwrap(importedSession)
    let hash = DocumentIdentity.contentHash(for: sourceData)
    let expectedURL = libraryDirectory
      .appendingPathComponent("Imported PDFs", isDirectory: true)
      .appendingPathComponent(hash, isDirectory: true)
      .appendingPathComponent("Paper.pdf")

    XCTAssertEqual(imported.url.standardizedFileURL, expectedURL.standardizedFileURL)
    XCTAssertNotEqual(imported.url.standardizedFileURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: imported.url), sourceData)
    XCTAssertEqual(library.recents.count, 1)

    try FileManager.default.removeItem(at: sourceURL)

    let reopenedLibrary = LibraryModel(directory: libraryDirectory)
    let recent = try XCTUnwrap(reopenedLibrary.recents.first)
    let reopenedSession = await reopenedLibrary.makeSession(for: recent)
    let reopened = try XCTUnwrap(reopenedSession)

    XCTAssertEqual(reopened.url.standardizedFileURL, expectedURL.standardizedFileURL)
    XCTAssertEqual(PDFDocument(url: reopened.url)?.pageCount, 1)
    XCTAssertNil(reopenedLibrary.lastError)
  }

  func testInvalidPDFIsRejectedWithoutAddingRecent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root
      .appendingPathComponent("Incoming", isDirectory: true)
      .appendingPathComponent("Not a PDF.pdf")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not a PDF".utf8).write(to: sourceURL)

    let library = LibraryModel(directory: root.appendingPathComponent("Library", isDirectory: true))

    let session = await library.receiveExternalPDF(at: sourceURL)
    XCTAssertNil(session)
    XCTAssertNotNil(library.lastError)
    XCTAssertTrue(library.recents.isEmpty)
  }

  func testNonFileExternalURLIsRejectedWithoutAddingRecent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = LibraryModel(directory: root.appendingPathComponent("Library", isDirectory: true))
    let externalURL = try XCTUnwrap(URL(string: "https://example.com/Paper.pdf"))

    let session = await library.receiveExternalPDF(at: externalURL)
    XCTAssertNil(session)
    XCTAssertNotNil(library.lastError)
    XCTAssertTrue(library.recents.isEmpty)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-ExternalPDFImportTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func blankPDFData() throws -> Data {
    let document = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
    document.insert(page, at: 0)
    return try XCTUnwrap(document.dataRepresentation())
  }
}
