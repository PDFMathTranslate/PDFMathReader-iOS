import Foundation
import PDFKit
import ReaderCore
import XCTest
@testable import PDFMathReader

private actor LocalTransferServerStub: CompanionDocumentServing, CompanionDocumentUploading {
  struct SaveCall: Sendable {
    let revision: String
    let sessionID: String
    let pdf: Data
    let pageCount: Int
    let release: Bool
  }

  private(set) var uploads: [Data] = []
  private(set) var uploadSourceIDs: [String] = []
  private(set) var acquisitions: [String] = []
  private(set) var saves: [SaveCall] = []
  private var documentID = "desktop-document-1"
  private var currentRevision = "desktop-revision-1"
  private var currentPDF = Data()
  private var currentPageCount = 1
  private var failNextSaveAfterCommit = false

  func list(url: String?, pairingCode: String) async throws -> [CompanionRecentDocument] {
    []
  }

  func upload(
    url: String?,
    pairingCode: String,
    sourceID: String,
    title: String,
    pdf: Data,
    pageCount: Int
  ) async throws -> CompanionDocumentUploadReceipt {
    uploads.append(pdf)
    uploadSourceIDs.append(sourceID)
    if currentPDF.isEmpty {
      currentPDF = pdf
      currentPageCount = pageCount
    }
    return CompanionDocumentUploadReceipt(
      documentID: documentID,
      revision: currentRevision,
      sha256: DocumentIdentity.contentHash(for: pdf),
      byteCount: pdf.count,
      pageCount: pageCount
    )
  }

  func acquire(
    url: String?,
    pairingCode: String,
    documentID: String,
    deviceID: String,
    deviceName: String,
    sessionID: String
  ) async throws -> CompanionDocumentSnapshot {
    acquisitions.append(sessionID)
    return CompanionDocumentSnapshot(
      sessionID: sessionID,
      revision: currentRevision,
      pdf: currentPDF,
      pageCount: currentPageCount
    )
  }

  func save(
    url: String?,
    pairingCode: String,
    documentID: String,
    sessionID: String,
    revision: String,
    pdf: Data,
    pageCount: Int,
    release: Bool
  ) async throws -> String {
    saves.append(SaveCall(
      revision: revision,
      sessionID: sessionID,
      pdf: pdf,
      pageCount: pageCount,
      release: release
    ))
    // This models a response lost after the desktop has committed the exact
    // request. A retry with the same payload is therefore idempotent.
    currentPDF = pdf
    currentPageCount = pageCount
    currentRevision = DocumentIdentity.contentHash(for: pdf)
    if failNextSaveAfterCommit {
      failNextSaveAfterCommit = false
      throw URLError(.networkConnectionLost)
    }
    return currentRevision
  }

  func setFailNextSaveAfterCommit() {
    failNextSaveAfterCommit = true
  }

  func setExternalRevision(_ revision: String, pdf: Data, pageCount: Int) {
    currentRevision = revision
    currentPDF = pdf
    currentPageCount = pageCount
  }
}

@MainActor
final class ReaderHandoffLocalTransferTests: XCTestCase {
  func testInitialUploadPersistsRichPortableMetadataAndIsDurable() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixture = try portableFixture(zoom: 1.7)
    let server = LocalTransferServerStub()
    let transfer = ReaderHandoffLocalTransfer(directory: directory, client: server)
    let documentID = try await transfer.save(
      sourceID: "tab-session-1",
      title: "Annotated paper.pdf",
      computerURL: "http://computer.local:8891/",
      pairingCode: " TESTCODE ",
      pdf: fixture.bytes,
      pageCount: 2
    )

    XCTAssertEqual(documentID, "desktop-document-1")
    let uploads = await server.uploads
    let uploadSourceIDs = await server.uploadSourceIDs
    let acquisitions = await server.acquisitions
    let saveCount = await server.saves.count
    XCTAssertEqual(uploads, [fixture.bytes])
    XCTAssertEqual(uploadSourceIDs, ["tab-session-1"])
    XCTAssertEqual(acquisitions, [])
    XCTAssertEqual(saveCount, 0)

    let uploadedBytes = try XCTUnwrap(uploads.first)
    let uploaded = try XCTUnwrap(PDFDocument(data: uploadedBytes))
    XCTAssertEqual(try ReaderTransferPDF.metadata(from: uploaded), fixture.metadata)

    // Reopening the transport reads the durable journal and returns the same
    // committed identity without creating or updating a second document.
    let restored = ReaderHandoffLocalTransfer(directory: directory, client: server)
    let repeatedID = try await restored.save(
      sourceID: "tab-session-1",
      title: "Annotated paper.pdf",
      computerURL: "http://computer.local:8891",
      pairingCode: "TESTCODE",
      pdf: fixture.bytes,
      pageCount: 2
    )
    XCTAssertEqual(repeatedID, documentID)
    let repeatedUploadCount = await server.uploads.count
    let repeatedSaveCount = await server.saves.count
    XCTAssertEqual(repeatedUploadCount, 1)
    XCTAssertEqual(repeatedSaveCount, 0)
  }

  func testLostSaveResponseReplaysExactBytesBeforeNewerUpdate() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let initial = try portableFixture(zoom: 1.0)
    let changed = try portableFixture(zoom: 1.25)
    let newer = try portableFixture(zoom: 1.5)
    let server = LocalTransferServerStub()
    let transfer = ReaderHandoffLocalTransfer(directory: directory, client: server)
    _ = try await transfer.save(
      sourceID: "tab-session-2",
      title: "Paper.pdf",
      computerURL: "http://computer.local:8891",
      pairingCode: "TESTCODE",
      pdf: initial.bytes,
      pageCount: 2
    )

    await server.setFailNextSaveAfterCommit()
    do {
      _ = try await transfer.save(
        sourceID: "tab-session-2",
        title: "Paper.pdf",
        computerURL: "http://computer.local:8891",
        pairingCode: "TESTCODE",
        pdf: changed.bytes,
        pageCount: 2
      )
      XCTFail("The simulated lost response should be surfaced to the caller")
    } catch {
      XCTAssertTrue(error is URLError)
    }

    // A newer update may only proceed after the exact pending request has
    // been replayed. The first two save calls must carry identical bytes and
    // the same durable session/base revision.
    _ = try await transfer.save(
      sourceID: "tab-session-2",
      title: "Paper.pdf",
      computerURL: "http://computer.local:8891",
      pairingCode: "TESTCODE",
      pdf: newer.bytes,
      pageCount: 2
    )
    let saves = await server.saves
    XCTAssertEqual(saves.count, 3)
    XCTAssertEqual(saves[0].pdf, changed.bytes)
    XCTAssertEqual(saves[1].pdf, changed.bytes)
    XCTAssertEqual(saves[0].sessionID, saves[1].sessionID)
    XCTAssertEqual(saves[0].revision, saves[1].revision)
    XCTAssertEqual(saves[2].pdf, newer.bytes)
    XCTAssertNotEqual(saves[2].sessionID, saves[1].sessionID)
    XCTAssertTrue(saves.allSatisfy(\.release))
  }

  func testExternalRevisionConflictDoesNotOverwriteDesktopBytes() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let initial = try portableFixture(zoom: 1.0)
    let desktopEdit = try portableFixture(zoom: 1.1)
    let localEdit = try portableFixture(zoom: 1.2)
    let server = LocalTransferServerStub()
    let transfer = ReaderHandoffLocalTransfer(directory: directory, client: server)
    _ = try await transfer.save(
      sourceID: "tab-session-3",
      title: "Paper.pdf",
      computerURL: "http://computer.local:8891",
      pairingCode: "TESTCODE",
      pdf: initial.bytes,
      pageCount: 2
    )
    await server.setExternalRevision("desktop-edit-revision", pdf: desktopEdit.bytes, pageCount: 2)

    do {
      _ = try await transfer.save(
        sourceID: "tab-session-3",
        title: "Paper.pdf",
        computerURL: "http://computer.local:8891",
        pairingCode: "TESTCODE",
        pdf: localEdit.bytes,
        pageCount: 2
      )
      XCTFail("An externally changed desktop revision must be rejected")
    } catch let error as CompanionDocumentError {
      XCTAssertEqual(error, .documentBusy)
    }

    let conflictSaveCount = await server.saves.count
    let desktopBytes = await server.currentPDFForTest
    XCTAssertEqual(conflictSaveCount, 0)
    XCTAssertEqual(desktopBytes, desktopEdit.bytes)
  }

  private func portableFixture(zoom: Double) throws -> (bytes: Data, metadata: ReaderTransferMetadata) {
    let document = PDFDocument()
    for index in 0..<2 {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
      document.insert(page, at: index)
    }
    let box = ReaderAnnotationRect(x: 10, y: 20, width: 70, height: 15)
    let annotation = ReaderAnnotation(
      id: "note-1",
      page: 1,
      kind: .comment,
      text: "quoted text",
      comment: "An edited comment",
      color: "#fff36a",
      rects: [box],
      createdAt: "2026-10-21T00:00:00Z"
    )
    let quickLink = ReaderQuickLink(
      id: "link-1",
      origin: .init(page: 1, box: .init(x: 10, y: 20, width: 70, height: 15)),
      result: .init(page: 2, box: .init(x: 20, y: 30, width: 70, height: 15))
    )
    let state = ReadingState(
      page: 2,
      zoom: zoom,
      scaleMode: .custom,
      displayMode: .twoPages,
      scrollDirection: .horizontal,
      sidebarVisible: false,
      lastUpdated: Date(timeIntervalSince1970: 1_729_468_800)
    )
    let bytes = try ReaderTransferPDF.export(
      sourceData: try XCTUnwrap(document.dataRepresentation()),
      annotations: [annotation],
      quickLinks: [quickLink],
      readingState: state
    )
    let metadata = try XCTUnwrap(
      ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(data: bytes)))
    )
    return (bytes, metadata)
  }
}

private extension LocalTransferServerStub {
  var currentPDFForTest: Data { currentPDF }
}
