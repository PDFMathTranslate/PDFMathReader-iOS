import Foundation
import PDFKit
import ReaderCore
import XCTest
@testable import PDFMathReader

private actor DocumentServerStub: CompanionDocumentServing {
  let pdf: Data
  var annotations: [ReaderAnnotation]?
  var requestedSessions: [String] = []
  var failAcquire = false
  var failSave = false
  var revision = String(repeating: "a", count: 64)
  var saves: [Data] = []
  var attempts: [Data] = []
  var releases: [Bool] = []
  init(pdf: Data, annotations: [ReaderAnnotation]? = nil) { self.pdf = pdf; self.annotations = annotations }
  func list(url: String?, pairingCode: String) async throws -> [CompanionRecentDocument] { [] }
  func acquire(url: String?, pairingCode: String, documentID: String, deviceID: String,
               deviceName: String, sessionID: String) async throws -> CompanionDocumentSnapshot {
    requestedSessions.append(sessionID)
    if failAcquire { throw URLError(.networkConnectionLost) }
    return .init(sessionID: sessionID, revision: revision, pdf: pdf, pageCount: 1, annotations: annotations)
  }
  func save(url: String?, pairingCode: String, documentID: String, sessionID: String,
            revision: String, pdf: Data, pageCount: Int, release: Bool) async throws -> String {
    attempts.append(pdf)
    if failSave { throw URLError(.networkConnectionLost) }
    saves.append(pdf)
    releases.append(release)
    return DocumentIdentity.contentHash(for: pdf)
  }
  func setFailAcquire(_ value: Bool) { failAcquire = value }
  func setFailSave(_ value: Bool) { failSave = value }
  func changeRevision() { revision = String(repeating: "b", count: 64) }
}

@MainActor
final class CompanionDocumentManagerTests: XCTestCase {
  private func fixture() throws -> Data {
    let pdf = PDFDocument()
    pdf.insert(PDFPage(), at: 0)
    return try ReaderTransferPDF.export(sourceData: XCTUnwrap(pdf.dataRepresentation()),
      annotations: [], quickLinks: [], readingState: .init())
  }

  func testInterruptedAcquireResumesSameDurableSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = DocumentServerStub(pdf: try fixture())
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let recent = CompanionRecentDocument(id: "document-1", title: "Paper", pageCount: 1)
    let manager = CompanionDocumentManager(directory: root.appendingPathComponent("Remote"), client: server,
      readPairingCode: { "TESTCODE" })
    await server.setFailAcquire(true)
    let interrupted = await manager.open(recent, library: library)
    XCTAssertNil(interrupted)
    let restored = CompanionDocumentManager(directory: root.appendingPathComponent("Remote"), client: server,
      readPairingCode: { "TESTCODE" })
    await server.setFailAcquire(false)
    let resumed = await restored.open(recent, library: library)
    XCTAssertNotNil(resumed)
    let requests = await server.requestedSessions
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.first, requests.last)
    let duplicate = await restored.open(recent, library: library)
    XCTAssertNil(duplicate)
    XCTAssertNotNil(restored.toast)
  }

  func testDesktopSidecarHighlightIsEmbeddedAndSavedBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let annotation = ReaderAnnotation(id: "desktop-highlight", page: 1, kind: .highlight,
      text: "Important", comment: "", color: "#fff36a",
      rects: [.init(x: 10, y: 10, width: 80, height: 12)], createdAt: "2026-10-16T00:00:00Z")
    let server = DocumentServerStub(pdf: try fixture(), annotations: [annotation])
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let manager = CompanionDocumentManager(directory: root.appendingPathComponent("Remote"), client: server,
      readPairingCode: { "TESTCODE" })
    let opened = await manager.open(.init(id: "doc", title: "Desktop paper", pageCount: 1), library: library)
    let session = try XCTUnwrap(opened)
    let portable = try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(url: session.url)))
    XCTAssertEqual(portable?.annotations, [annotation])
    XCTAssertEqual(library.recents.first?.title, "Desktop paper")
    let tab = ReaderTab(session: session, library: library)
    await tab.annotations.prepare()
    XCTAssertEqual(tab.annotations.annotations.map(\.id), [annotation.id])
    tab.annotations.delete(annotation, pdfView: nil)
    let saved = await manager.sync(tab, release: true)
    XCTAssertTrue(saved)
    let saves = await server.saves
    let returned = try XCTUnwrap(saves.first)
    let state = try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(data: returned)))
    XCTAssertEqual(state?.annotations, [])
  }

  func testReleasedRemoteReopenRetainsOneRecentIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = DocumentServerStub(pdf: try fixture())
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let remote = root.appendingPathComponent("Library/Computer Documents")
    let recent = CompanionRecentDocument(id: "document-1", title: "Paper", pageCount: 1)
    let manager = CompanionDocumentManager(directory: remote, client: server,
      readPairingCode: { "TESTCODE" })

    let openedResult = await manager.open(recent, library: library)
    let opened = try XCTUnwrap(openedResult)
    let tab = ReaderTab(session: opened, library: library)
    let released = await manager.sync(tab, release: true)
    XCTAssertTrue(released)

    let restored = CompanionDocumentManager(directory: remote, client: server,
      readPairingCode: { "TESTCODE" })
    let reopenedResult = await restored.open(recent, library: library)
    let reopened = try XCTUnwrap(reopenedResult)

    XCTAssertEqual(reopened.id, opened.id)
    XCTAssertEqual(library.recents.count, 1)
    XCTAssertEqual(library.recents.first?.id, opened.id)
  }

  func testDifferentRemoteIDsWithSameBytesRemainSeparateRecents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = DocumentServerStub(pdf: try fixture())
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let manager = CompanionDocumentManager(directory: root.appendingPathComponent("Library/Computer Documents"), client: server,
      readPairingCode: { "TESTCODE" })

    let firstResult = await manager.open(
      .init(id: "document-1", title: "Same paper", pageCount: 1), library: library)
    let first = try XCTUnwrap(firstResult)
    let secondResult = await manager.open(
      .init(id: "document-2", title: "Same paper", pageCount: 1), library: library)
    let second = try XCTUnwrap(secondResult)

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(library.recents.count, 2)
    XCTAssertEqual(Set(library.recents.map(\.id)), Set([first.id, second.id]))
  }

  func testResumedSessionRejectsChangedBaseWithoutReplacingLocalFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = DocumentServerStub(pdf: try fixture())
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let remote = root.appendingPathComponent("Remote")
    let manager = CompanionDocumentManager(directory: remote, client: server, readPairingCode: { "TESTCODE" })
    let recent = CompanionRecentDocument(id: "doc", title: "Paper", pageCount: 1)
    let opened = await manager.open(recent, library: library)
    let session = try XCTUnwrap(opened)
    let original = try Data(contentsOf: session.url)
    await server.changeRevision()
    let restored = CompanionDocumentManager(directory: remote, client: server, readPairingCode: { "TESTCODE" })
    let reopened = await restored.open(recent, library: library)
    XCTAssertNil(reopened)
    XCTAssertNotNil(restored.toast)
    XCTAssertEqual(try Data(contentsOf: session.url), original)
    let saves = await server.saves
    XCTAssertTrue(saves.isEmpty)
  }

  func testFailedReleaseKeepsReaderAndLocalSnapshotThenRetries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = DocumentServerStub(pdf: try fixture())
    let library = LibraryModel(directory: root.appendingPathComponent("Library"))
    var preferences = library.preferences
    preferences.companionURL = "http://computer.local:8891"
    library.savePreferences(preferences)
    let manager = CompanionDocumentManager(directory: root.appendingPathComponent("Remote"), client: server,
      readPairingCode: { "TESTCODE" })
    let recent = CompanionRecentDocument(id: "document-1", title: "Paper", pageCount: 1)
    let opened = await manager.open(recent, library: library)
    let session = try XCTUnwrap(opened)
    let tab = ReaderTab(session: session, library: library)
    await server.setFailSave(true)
    let failed = await manager.sync(tab, release: true)
    XCTAssertFalse(failed)
    XCTAssertTrue(manager.uncertainSessions.contains(session.id))
    XCTAssertNotNil(manager.toast)
    XCTAssertNotNil(try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(url: session.url))))
    let duplicate = await manager.open(recent, library: library)
    XCTAssertNil(duplicate)
    await server.setFailSave(false)
    let saved = await manager.sync(tab, release: true)
    XCTAssertTrue(saved)
    XCTAssertFalse(manager.uncertainSessions.contains(session.id))
    let attempts = await server.attempts
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts.first, attempts.last)
    let releases = await server.releases
    XCTAssertEqual(releases, [true])
    let saves = await server.saves
    let data = try XCTUnwrap(saves.first)
    XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
    XCTAssertNotNil(try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(data: data))))
  }
}
