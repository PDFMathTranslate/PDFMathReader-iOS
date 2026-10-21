import Foundation
import ReaderCore

/// The two companion surfaces needed to import a local PDF and then update
/// the resulting desktop document. Keeping the composition here means tests
/// can provide one small actor that records both kinds of requests.
typealias ReaderHandoffLocalTransferClient =
  any CompanionDocumentServing & CompanionDocumentUploading

/// Durable transport for handing an iOS-local PDF to the paired desktop.
///
/// A create-only import is journaled before it is sent. Once the desktop has
/// returned an identity, later saves use the normal exclusive document
/// session and release that session in the same request as the PDF update.
/// The actor serializes calls while the journal makes retries safe across
/// process termination and lost HTTP responses.
final actor ReaderHandoffLocalTransfer {
  private static let maximumDocumentBytes = 200 * 1024 * 1024
  private static let journalVersion = 1
  private static let deviceName = "PDFMathReader iOS"

  private enum PendingOperation: String, Codable, Sendable {
    case initialUpload
    case save
  }

  private struct Pending: Codable, Sendable, Equatable {
    let operation: PendingOperation
    let sourceID: String
    let pageCount: Int
    let byteCount: Int
    let sha256: String
    let baseRevision: String?
    let sessionID: String?
  }

  private struct Journal: Codable, Sendable, Equatable {
    let sourceID: String
    let computerURL: String
    var title: String
    var pageCount: Int
    var deviceID: String
    var sessionID: String
    var documentID: String?
    var revision: String?
    var committedSHA256: String?
    var released: Bool
    var pending: Pending?
  }

  private struct JournalFile: Codable, Sendable {
    let version: Int
    var entries: [String: Journal]

    init(entries: [String: Journal] = [:]) {
      self.version = ReaderHandoffLocalTransfer.journalVersion
      self.entries = entries
    }
  }

  /// A revision mismatch is deliberately surfaced as the same busy error
  /// used by the existing companion manager. It tells the caller that the
  /// desktop changed while this local snapshot was being handed off, and no
  /// desktop bytes are written in that case.
  private var loadFailed = false
  private var entries: [String: Journal] = [:]
  private var inFlightKeys: Set<String> = []
  private let directory: URL
  private let client: ReaderHandoffLocalTransferClient

  init(
    directory: URL = LibraryDirectory.default.appendingPathComponent("Handoff", isDirectory: true),
    client: ReaderHandoffLocalTransferClient = CompanionDocumentClient()
  ) {
    self.directory = directory
    self.client = client
    let url = directory.appendingPathComponent("sessions.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let data = try Data(contentsOf: url)
      let file = try JSONDecoder().decode(JournalFile.self, from: data)
      guard file.version == Self.journalVersion else {
        loadFailed = true
        return
      }
      entries = file.entries
    } catch {
      // A malformed journal must fail closed. In particular, do not send a
      // new PDF when the previous operation's source bytes are unknowable.
      loadFailed = true
    }
  }

  /// Saves one complete portable PDF and returns its desktop document ID only
  /// after the create-only import or an update-plus-release is committed.
  func save(
    sourceID: String,
    title: String,
    computerURL: String,
    pairingCode: String,
    pdf: Data,
    pageCount: Int
  ) async throws -> String {
    guard !loadFailed else { throw CompanionDocumentError.invalidRequest }
    guard !sourceID.isEmpty, sourceID.utf8.count <= 256,
          sourceID.unicodeScalars.allSatisfy(Self.isSafeIdentifierScalar),
          !title.isEmpty,
          title.utf8.count <= 256,
          title.unicodeScalars.allSatisfy(Self.isSafeFieldScalar),
          pageCount > 0,
          pdf.count <= Self.maximumDocumentBytes
    else {
      throw pdf.count > Self.maximumDocumentBytes
        ? CompanionDocumentError.documentTooLarge
        : CompanionDocumentError.invalidRequest
    }

    let computer = normalizeCompanionURL(computerURL)
    guard !computer.isEmpty else { throw CompanionDocumentError.invalidServerURL }
    guard !normalizeCompanionPairingCode(pairingCode).isEmpty else {
      throw CompanionDocumentError.missingPairingCode
    }

    let key = Self.journalKey(sourceID: sourceID, computerURL: computer)
    guard inFlightKeys.insert(key).inserted else {
      throw CompanionDocumentError.documentBusy
    }
    defer { inFlightKeys.remove(key) }

    var journal = try journalForSave(
      key: key,
      sourceID: sourceID,
      title: title,
      computerURL: computer,
      pageCount: pageCount
    )

    // A response may have been lost after the desktop committed. Replay the
    // exact old bytes first. Only after that succeeds may a newer PDF proceed.
    if journal.pending != nil {
      journal = try await replayPending(
        key: key,
        journal: journal,
        computerURL: computer,
        pairingCode: pairingCode
      )
    }

    if journal.documentID == nil {
      return try await createDocument(
        key: key,
        journal: journal,
        computerURL: computer,
        pairingCode: pairingCode,
        pdf: pdf,
        pageCount: pageCount
      )
    }

    let documentID = try Self.requireNonEmpty(journal.documentID)
    if journal.committedSHA256 == Self.sha256(pdf), journal.pageCount == pageCount {
      return documentID
    }

    guard let acknowledgedRevision = journal.revision, !acknowledgedRevision.isEmpty else {
      throw CompanionDocumentError.invalidRequest
    }

    // A released session cannot be reacquired with the same session ID. The
    // new ID is written before acquire so a crash can safely resume the lock.
    if journal.released {
      journal.sessionID = UUID().uuidString
      journal.released = false
      entries[key] = journal
      try persist()
    }

    let snapshot = try await client.acquire(
      url: computer,
      pairingCode: pairingCode,
      documentID: documentID,
      deviceID: journal.deviceID,
      deviceName: Self.deviceName,
      sessionID: journal.sessionID
    )
    guard snapshot.sessionID == journal.sessionID,
          !snapshot.revision.isEmpty
    else {
      throw CompanionDocumentError.invalidResponse
    }
    guard snapshot.revision == acknowledgedRevision else {
      // The snapshot is intentionally never used as the save payload. The
      // local caller must resolve the conflict before any desktop edit can be
      // changed.
      let released = await releaseIfSupported(
        computerURL: computer,
        pairingCode: pairingCode,
        documentID: documentID,
        sessionID: journal.sessionID
      )
      if released {
        journal.released = true
        entries[key] = journal
        try? persist()
      }
      throw CompanionDocumentError.documentBusy
    }
    guard snapshot.pageCount == journal.pageCount else {
      throw CompanionDocumentError.invalidResponse
    }

    let pending = Pending(
      operation: .save,
      sourceID: sourceID,
      pageCount: pageCount,
      byteCount: pdf.count,
      sha256: Self.sha256(pdf),
      baseRevision: acknowledgedRevision,
      sessionID: journal.sessionID
    )
    try stagePending(pending, key: key, journal: &journal, pdf: pdf)

    do {
      let revision = try await client.save(
        url: computer,
        pairingCode: pairingCode,
        documentID: documentID,
        sessionID: journal.sessionID,
        revision: acknowledgedRevision,
        pdf: pdf,
        pageCount: pageCount,
        release: true
      )
      guard !revision.isEmpty else { throw CompanionDocumentError.invalidResponse }
      try acknowledgeSave(
        key: key,
        journal: journal,
        revision: revision,
        sha256: pending.sha256
      )
      return documentID
    } catch {
      // Keep the pending file and its base revision/session ID untouched. A
      // later call will replay the same request before it can send newer data.
      throw error
    }
  }

  private func journalForSave(
    key: String,
    sourceID: String,
    title: String,
    computerURL: String,
    pageCount: Int
  ) throws -> Journal {
    if let existing = entries[key] {
      guard existing.sourceID == sourceID,
            existing.computerURL == computerURL
      else { throw CompanionDocumentError.invalidRequest }
      guard existing.pageCount == pageCount || existing.documentID == nil else {
        throw CompanionDocumentError.invalidRequest
      }
      var updated = existing
      updated.title = title
      if existing.documentID == nil { updated.pageCount = pageCount }
      if updated != existing {
        entries[key] = updated
        do {
          try persist()
        } catch {
          entries[key] = existing
          throw error
        }
      }
      return updated
    }

    let journal = Journal(
      sourceID: sourceID,
      computerURL: computerURL,
      title: title,
      pageCount: pageCount,
      deviceID: UUID().uuidString,
      sessionID: UUID().uuidString,
      documentID: nil,
      revision: nil,
      committedSHA256: nil,
      released: true,
      pending: nil
    )
    entries[key] = journal
    try persist()
    return journal
  }

  private func createDocument(
    key: String,
    journal: Journal,
    computerURL: String,
    pairingCode: String,
    pdf: Data,
    pageCount: Int
  ) async throws -> String {
    var journal = journal
    let pending = Pending(
      operation: .initialUpload,
      sourceID: journal.sourceID,
      pageCount: pageCount,
      byteCount: pdf.count,
      sha256: Self.sha256(pdf),
      baseRevision: nil,
      sessionID: nil
    )
    try stagePending(pending, key: key, journal: &journal, pdf: pdf)

    do {
      let receipt = try await client.upload(
        url: computerURL,
        pairingCode: pairingCode,
        sourceID: journal.sourceID,
        title: journal.title,
        pdf: pdf,
        pageCount: pageCount
      )
      try Self.validate(receipt: receipt, expectedSHA256: pending.sha256, byteCount: pdf.count,
        pageCount: pageCount)
      var committed = journal
      committed.documentID = receipt.documentID
      committed.revision = receipt.revision
      committed.committedSHA256 = pending.sha256
      committed.pageCount = pageCount
      committed.released = true
      committed.pending = nil
      try commitJournal(committed, key: key, deletingPending: true)
      return receipt.documentID
    } catch {
      // Leave the exact pending bytes/source ID journaled for an idempotent
      // retry. This also covers a successful server write whose response was
      // lost in transit.
      throw error
    }
  }

  private func replayPending(
    key: String,
    journal: Journal,
    computerURL: String,
    pairingCode: String
  ) async throws -> Journal {
    guard let pending = journal.pending else { return journal }
    let bytes = try loadPendingBytes(key: key, pending: pending)
    guard bytes.count == pending.byteCount,
          Self.sha256(bytes).caseInsensitiveCompare(pending.sha256) == .orderedSame,
          pending.sourceID == journal.sourceID
    else { throw CompanionDocumentError.invalidRequest }

    switch pending.operation {
    case .initialUpload:
      let receipt = try await client.upload(
        url: computerURL,
        pairingCode: pairingCode,
        sourceID: pending.sourceID,
        title: journal.title,
        pdf: bytes,
        pageCount: pending.pageCount
      )
      try Self.validate(receipt: receipt, expectedSHA256: pending.sha256,
        byteCount: pending.byteCount, pageCount: pending.pageCount)
      var committed = journal
      committed.documentID = receipt.documentID
      committed.revision = receipt.revision
      committed.committedSHA256 = pending.sha256
      committed.pageCount = pending.pageCount
      committed.released = true
      committed.pending = nil
      try commitJournal(committed, key: key, deletingPending: true)
      return committed

    case .save:
      guard let documentID = journal.documentID,
            let baseRevision = pending.baseRevision,
            let sessionID = pending.sessionID
      else { throw CompanionDocumentError.invalidRequest }
      let revision = try await client.save(
        url: computerURL,
        pairingCode: pairingCode,
        documentID: documentID,
        sessionID: sessionID,
        revision: baseRevision,
        pdf: bytes,
        pageCount: pending.pageCount,
        release: true
      )
      guard !revision.isEmpty else { throw CompanionDocumentError.invalidResponse }
      var committed = journal
      committed.revision = revision
      committed.committedSHA256 = pending.sha256
      committed.pageCount = pending.pageCount
      committed.released = true
      committed.pending = nil
      try commitJournal(committed, key: key, deletingPending: true)
      return committed
    }
  }

  private func stagePending(
    _ pending: Pending,
    key: String,
    journal: inout Journal,
    pdf: Data
  ) throws {
    let old = entries[key]
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try pdf.write(to: pendingURL(for: key), options: [.atomic])
    journal.pending = pending
    entries[key] = journal
    do {
      try persist()
    } catch {
      entries[key] = old
      throw error
    }
  }

  private func acknowledgeSave(
    key: String,
    journal: Journal,
    revision: String,
    sha256: String
  ) throws {
    var committed = journal
    committed.revision = revision
    committed.committedSHA256 = sha256
    committed.released = true
    committed.pending = nil
    try commitJournal(committed, key: key, deletingPending: true)
  }

  private func commitJournal(
    _ journal: Journal,
    key: String,
    deletingPending: Bool
  ) throws {
    let previous = entries[key]
    entries[key] = journal
    do {
      try persist()
    } catch {
      entries[key] = previous
      throw error
    }
    if deletingPending {
      try? FileManager.default.removeItem(at: pendingURL(for: key))
    }
  }

  private func loadPendingBytes(key: String, pending: Pending) throws -> Data {
    let url = pendingURL(for: key)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CompanionDocumentError.invalidRequest
    }
    return try Data(contentsOf: url)
  }

  private func persist() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = JournalFile(entries: entries)
    let data = try JSONEncoder().encode(file)
    try data.write(to: directory.appendingPathComponent("sessions.json"), options: [.atomic])
  }

  private func pendingURL(for key: String) -> URL {
    directory.appendingPathComponent("\(key).pending.pdf")
  }

  private func releaseIfSupported(
    computerURL: String,
    pairingCode: String,
    documentID: String,
    sessionID: String
  ) async -> Bool {
    guard let releaser = client as? any ReaderHandoffLocalTransferReleasing else { return false }
    do {
      try await releaser.release(
        url: computerURL,
        pairingCode: pairingCode,
        documentID: documentID,
        sessionID: sessionID
      )
      return true
    } catch {
      return false
    }
  }

  private static func validate(
    receipt: CompanionDocumentUploadReceipt,
    expectedSHA256: String,
    byteCount: Int,
    pageCount: Int
  ) throws {
    guard !receipt.documentID.isEmpty,
          !receipt.revision.isEmpty,
          receipt.byteCount == byteCount,
          receipt.pageCount == pageCount,
          receipt.sha256.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    else { throw CompanionDocumentError.invalidResponse }
  }

  private static func journalKey(sourceID: String, computerURL: String) -> String {
    DocumentIdentity.contentHash(for: Data("\(sourceID)\n\(computerURL)".utf8))
  }

  private static func sha256(_ data: Data) -> String {
    DocumentIdentity.contentHash(for: data)
  }

  private static func requireNonEmpty(_ value: String?) throws -> String {
    guard let value, !value.isEmpty else { throw CompanionDocumentError.invalidRequest }
    return value
  }

  private static func isSafeIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-")
      .contains(scalar)
  }

  private static func isSafeFieldScalar(_ scalar: UnicodeScalar) -> Bool {
    scalar.value >= 0x20 && scalar.value != 0x7f
  }
}

/// Optional cleanup used when a conflict is detected after acquire. The
/// shipping client supports release, while minimal test doubles only need the
/// serving and uploading requirements.
private protocol ReaderHandoffLocalTransferReleasing: Sendable {
  func release(url: String?, pairingCode: String, documentID: String, sessionID: String) async throws
}

extension CompanionDocumentClient: ReaderHandoffLocalTransferReleasing {}
