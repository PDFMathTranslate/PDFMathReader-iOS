import Foundation
import PDFKit
import ReaderCore
import XCTest
@testable import PDFMathReader

private actor HandoffServer: CompanionDocumentServing {
  let pdf: Data
  var urls: [String?] = []
  var saves: [Data] = []
  var releases: [Bool] = []
  init(pdf: Data) { self.pdf = pdf }
  func list(url: String?, pairingCode: String) async throws -> [CompanionRecentDocument] {
    urls.append(url)
    return [.init(id: "remote-id", title: "Handoff paper.pdf", pageCount: 2)]
  }
  func acquire(url: String?, pairingCode: String, documentID: String, deviceID: String,
               deviceName: String, sessionID: String) async throws -> CompanionDocumentSnapshot {
    urls.append(url)
    return .init(sessionID: sessionID, revision: "revision-1", pdf: pdf, pageCount: 2)
  }
  func save(url: String?, pairingCode: String, documentID: String, sessionID: String,
            revision: String, pdf: Data, pageCount: Int, release: Bool) async throws -> String {
    saves.append(pdf)
    releases.append(release)
    return DocumentIdentity.contentHash(for: pdf)
  }
}

private final class OffMainActivityDelegateCall: @unchecked Sendable {
  let delegate: any NSUserActivityDelegate
  let willSaveActivity: NSUserActivity
  let continuedActivity: NSUserActivity

  init(delegate: any NSUserActivityDelegate, willSaveActivity: NSUserActivity,
       continuedActivity: NSUserActivity) {
    self.delegate = delegate
    self.willSaveActivity = willSaveActivity
    self.continuedActivity = continuedActivity
  }
}

@MainActor
final class ReaderHandoffTests: XCTestCase {
  func testPayloadIsMinimalAndRejectsMalformedActivities() {
    let value = ReaderHandoffActivity(documentID: "remote-id", page: 3, serverURL: "http://mac.local:8891")
    XCTAssertEqual(ReaderHandoffActivity(userInfo: value.userInfo), value)
    XCTAssertEqual(Set(value.userInfo.keys.compactMap { $0 as? String }), ["version", "documentID", "page", "serverURL"])
    for invalid: [AnyHashable: Any] in [
      [:], ["version": true, "documentID": "id", "page": 1],
      ["version": 1, "documentID": "../path", "page": 1],
      ["version": 1, "documentID": "id", "page": true],
      ["version": 1, "documentID": "id", "page": 1.5],
      ["version": 1, "documentID": "id", "page": 0],
      ["version": 2, "documentID": "id", "page": 1]
    ] { XCTAssertNil(ReaderHandoffActivity(userInfo: invalid)) }
  }

  func testNativeTypeIsRegistered() throws {
    let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])
    XCTAssertTrue(types.contains(ReaderHandoffActivity.activityType))
  }

  func testActivityDelegateCallbacksAreSafeOffMainAndIgnoreStaleContinuation() async {
    let coordinator = ReaderHandoffCoordinator()
    let willSaveActivity = NSUserActivity(activityType: ReaderHandoffActivity.activityType)
    willSaveActivity.needsSave = true
    let staleActivity = NSUserActivity(activityType: ReaderHandoffActivity.activityType)
    staleActivity.needsSave = true
    let callback = OffMainActivityDelegateCall(
      delegate: coordinator,
      willSaveActivity: willSaveActivity,
      continuedActivity: staleActivity)

    let needsSave = await Task.detached(priority: .utility) {
      callback.delegate.userActivityWillSave?(callback.willSaveActivity)
      callback.delegate.userActivityWasContinued?(callback.continuedActivity)
      return callback.willSaveActivity.needsSave
    }.value

    XCTAssertFalse(needsSave)
    XCTAssertTrue(staleActivity.needsSave)
    XCTAssertNil(coordinator.activity)
  }

  func testContinuationRestoresCompleteSnapshotAndReleasesCompleteRevision() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pdf = PDFDocument()
    for i in 0..<2 {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
      pdf.insert(page, at: i)
    }
    let box = ReaderAnnotationRect(x: 10, y: 20, width: 70, height: 15)
    let comment = ReaderAnnotation(id: "note", page: 1, kind: .comment, text: "quoted text",
      comment: "An edited comment", color: "#fff36a", rects: [box], createdAt: "2026-10-21T00:00:00Z")
    let link = ReaderQuickLink(id: "link", origin: .init(page: 1, box: .init(x: 10, y: 20, width: 70, height: 15)),
      result: .init(page: 2, box: .init(x: 20, y: 30, width: 70, height: 15)))
    let bytes = try ReaderTransferPDF.export(sourceData: XCTUnwrap(pdf.dataRepresentation()),
      annotations: [comment], quickLinks: [link], readingState: .init(page: 2, zoom: 1.7))
    let server = HandoffServer(pdf: bytes)
    let library = LibraryModel(directory: directory.appendingPathComponent("Library"))
    var prefs = library.preferences
    prefs.companionURL = "http://paired.local:8891"
    library.savePreferences(prefs)
    let manager = CompanionDocumentManager(directory: directory.appendingPathComponent("Remote"),
      client: server, readPairingCode: { "TESTCODE" })
    let incoming = ReaderHandoffActivity(documentID: "remote-id", page: 2,
      serverURL: "http://untrusted.invalid")
    let continued = await manager.continueHandoff(incoming, library: library)
    let session = try XCTUnwrap(continued)
    XCTAssertEqual(session.title, "Handoff paper.pdf")
    let tab = ReaderTab(session: session, library: library)
    await tab.annotations.prepare()
    XCTAssertEqual(tab.model.readingState.page, 2)
    XCTAssertEqual(tab.model.readingState.zoom, 1.7)
    XCTAssertEqual(tab.annotations.annotations.map(\.comment), ["An edited comment"])
    XCTAssertEqual(tab.annotations.quickLinks, [link])
    XCTAssertEqual(manager.handoffActivity(for: tab)?.documentID, "remote-id")
    let released = await manager.releaseForHandoff(tab)
    XCTAssertTrue(released)
    XCTAssertNil(manager.handoffActivity(for: tab))
    let saves = await server.saves
    let saved = try XCTUnwrap(saves.last)
    let result = try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(data: saved)))
    XCTAssertEqual(result?.annotations.map(\.comment), ["An edited comment"])
    XCTAssertEqual(result?.quickLinks, [link])
    XCTAssertEqual(result?.readingState.page, 2)
    let urls = await server.urls
    XCTAssertTrue(urls.allSatisfy { $0 == "http://paired.local:8891" })
    let releases = await server.releases
    XCTAssertEqual(releases, [true])
  }
}
