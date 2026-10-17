import Foundation
import PDFKit
import ReaderCore
import XCTest

@testable import PDFMathReader

@MainActor
final class ExternalPDFImportTests: XCTestCase {
  func testRecentPinSurvivesReopeningAndRemovalPreservesReadingState() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Paper.pdf")
    let data = try blankPDFData()
    try data.write(to: url)
    let libraryDirectory = root.appendingPathComponent("Library")
    let library = LibraryModel(directory: libraryDirectory)
    let opened = await library.makeSession(for: url)
    let session = try XCTUnwrap(opened)
    library.saveReadingState(ReadingState(page: 7), for: session)
    library.togglePinned(try XCTUnwrap(library.recents.first))

    let changedData = try blankPDFData(pageCount: 2)
    try changedData.write(to: url)
    let reopened = await library.makeSession(for: url)
    let reopenedSession = try XCTUnwrap(reopened)
    XCTAssertEqual(reopenedSession.id, session.id)
    XCTAssertEqual(library.recents.count, 1)
    XCTAssertTrue(try XCTUnwrap(library.recents.first).pinned)
    let restoredLibrary = LibraryModel(directory: libraryDirectory)
    XCTAssertTrue(try XCTUnwrap(restoredLibrary.recents.first).pinned)
    restoredLibrary.removeRecent(try XCTUnwrap(restoredLibrary.recents.first))
    XCTAssertTrue(restoredLibrary.recents.isEmpty)
    XCTAssertTrue(LibraryModel(directory: libraryDirectory).recents.isEmpty)
    XCTAssertEqual(restoredLibrary.readingState(for: reopenedSession).page, 7)
    XCTAssertEqual(try Data(contentsOf: url), changedData)
    XCTAssertNil(restoredLibrary.lastError)
  }

  func testIdenticalPDFBytesAtDifferentURLsShareOneRecent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = root.appendingPathComponent("Original.pdf")
    let secondURL = root.appendingPathComponent("Copy.pdf")
    let data = try blankPDFData()
    try data.write(to: firstURL)
    try data.write(to: secondURL)
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))

    let firstCandidate = await library.makeSession(for: firstURL)
    let first = try XCTUnwrap(firstCandidate)
    let secondCandidate = await library.makeSession(for: secondURL)
    let second = try XCTUnwrap(secondCandidate)

    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(library.recents.count, 1)
  }

  func testDifferentPDFBytesWithTheSameBasenameRemainSeparateRecents() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = root.appendingPathComponent("First", isDirectory: true)
      .appendingPathComponent("Paper.pdf")
    let secondURL = root.appendingPathComponent("Second", isDirectory: true)
      .appendingPathComponent("Paper.pdf")
    try FileManager.default.createDirectory(
      at: firstURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: secondURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try blankPDFData().write(to: firstURL)
    try blankPDFData(pageCount: 2).write(to: secondURL)
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))

    let firstCandidate = await library.makeSession(for: firstURL)
    let first = try XCTUnwrap(firstCandidate)
    let secondCandidate = await library.makeSession(for: secondURL)
    let second = try XCTUnwrap(secondCandidate)

    XCTAssertNotEqual(second.id, first.id)
    XCTAssertEqual(library.recents.count, 2)
  }

  func testLegacyRecentsWithTheSameBookmarkDeduplicateOnLibraryInit() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appendingPathComponent("Paper.pdf")
    try blankPDFData().write(to: url)
    let libraryDirectory = root.appendingPathComponent("Library")
    let store = RecentsStore(directory: libraryDirectory)
    let bookmarkData = try store.bookmarkData(for: url)
    let older = RecentDocument(
      id: "legacy-old-id",
      title: "Paper.pdf",
      pinned: true,
      lastOpened: Date(timeIntervalSince1970: 1),
      bookmarkData: bookmarkData
    )
    let newer = RecentDocument(
      id: "legacy-new-id",
      title: "Paper.pdf",
      lastOpened: Date(timeIntervalSince1970: 2),
      bookmarkData: bookmarkData
    )
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([older, newer]).write(
      to: libraryDirectory.appendingPathComponent("recents.json")
    )

    let library = LibraryModel(directory: libraryDirectory)

    XCTAssertEqual(library.recents.count, 1)
    XCTAssertEqual(library.recents.first?.bookmarkData, bookmarkData)
  }

  func testReconcileLegacyIdenticalPDFsKeepsNewestPinnedEntryAndSidecars() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = root.appendingPathComponent("First.pdf")
    let secondURL = root.appendingPathComponent("Second.pdf")
    let data = try blankPDFData()
    try data.write(to: firstURL)
    try data.write(to: secondURL)

    let libraryDirectory = root.appendingPathComponent("Library")
    let store = RecentsStore(directory: libraryDirectory)
    let firstBookmark = try store.bookmarkData(for: firstURL)
    let secondBookmark = try store.bookmarkData(for: secondURL)
    let olderID = "legacy-older-id"
    let newerID = "legacy-newer-id"
    let olderThumbnail = store.thumbnailURL(for: olderID)
    let newerThumbnail = store.thumbnailURL(for: newerID)
    try FileManager.default.createDirectory(
      at: olderThumbnail.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("older-thumbnail".utf8).write(to: olderThumbnail)
    try Data("newer-thumbnail".utf8).write(to: newerThumbnail)
    try store.upsert(RecentDocument(
      id: olderID,
      title: "First.pdf",
      pinned: true,
      lastOpened: Date(timeIntervalSince1970: 1),
      thumbnailCachePath: olderThumbnail.path,
      bookmarkData: firstBookmark
    ))
    try store.upsert(RecentDocument(
      id: newerID,
      title: "Second.pdf",
      lastOpened: Date(timeIntervalSince1970: 2),
      thumbnailCachePath: newerThumbnail.path,
      bookmarkData: secondBookmark
    ))

    let library = LibraryModel(directory: libraryDirectory)
    XCTAssertEqual(library.recents.count, 2)

    await library.reconcileRecentDocuments()

    let recent = try XCTUnwrap(library.recents.first)
    XCTAssertEqual(library.recents.count, 1)
    XCTAssertEqual(recent.id, newerID)
    XCTAssertTrue(recent.pinned)
    XCTAssertTrue(FileManager.default.fileExists(atPath: olderThumbnail.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newerThumbnail.path))
  }

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

  private func blankPDFData(pageCount: Int = 1) throws -> Data {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
      document.insert(page, at: index)
    }
    return try XCTUnwrap(document.dataRepresentation())
  }
}
