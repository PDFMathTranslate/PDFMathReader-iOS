import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

/// A journal is written before requesting a lock. A lost HTTP response or app
/// termination can therefore resume the same session, never take over another.
struct ComputerDocumentJournal: Codable {
  var documentID: String
  var title: String
  var computerURL: String
  var deviceID: String
  var sessionID: String
  var revision: String?
  var pageCount: Int?
  var localID: String?
  var released = false
  var pendingRevision: String?
  var pendingRelease: Bool?
}

@MainActor
final class CompanionDocumentManager: ObservableObject {
  @Published private(set) var documents: [CompanionRecentDocument] = []
  @Published private(set) var isLoading = false
  @Published var toast: String?
  @Published private(set) var busyDocumentIDs: Set<String> = []
  @Published private(set) var uncertainSessions: Set<String> = []

  private let directory: URL
  private let client: any CompanionDocumentServing
  private let readPairingCode: @Sendable () async throws -> String
  private var journals: [String: ComputerDocumentJournal] = [:]
  private var activeSessions: Set<String> = []
  private var operations: Set<String> = []
  private var lastUploadedHash: [String: String] = [:]
  private var loadFailed = false
  private var lastOpenError: (any Error)?

  init(directory: URL = LibraryDirectory.default.appendingPathComponent("Computer Documents"),
       client: any CompanionDocumentServing = CompanionDocumentClient(),
       readPairingCode: @escaping @Sendable () async throws -> String = {
         try await KeychainCredentialStore().read(account: companionPairingCodeAccount) ?? ""
       }) {
    self.directory = directory
    self.client = client
    self.readPairingCode = readPairingCode
    do {
      if FileManager.default.fileExists(atPath: journalURL.path) {
        journals = try JSONDecoder().decode([String: ComputerDocumentJournal].self,
                                          from: Data(contentsOf: journalURL))
        uncertainSessions = Set(journals.values.filter { $0.pendingRelease == true }.compactMap(\.localID))
      }
    } catch { loadFailed = true }
  }

  private var journalURL: URL { directory.appendingPathComponent("sessions.json") }
  private func persist() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(journals).write(to: journalURL, options: .atomic)
  }
  private func fileURL(_ journal: ComputerDocumentJournal) -> URL {
    directory.appendingPathComponent(journal.sessionID, isDirectory: true).appendingPathComponent("Document.pdf")
  }
  private func key(computer: String, document: String) -> String {
    DocumentIdentity.contentHash(for: Data("\(computer)\n\(document)".utf8))
  }

  /// Returns the identity shared by every local snapshot of one Companion
  /// document. The snapshot URL contains a per-acquire session ID, so it is
  /// not itself a durable document identity.
  func stableDocumentIdentity(for managedURL: URL) -> String? {
    guard handles(managedURL) else { return nil }
    let originURL = managedURL.deletingLastPathComponent().appendingPathComponent("origin.json")
    guard let data = try? Data(contentsOf: originURL),
          let journal = try? JSONDecoder().decode(ComputerDocumentJournal.self, from: data),
          !journal.computerURL.isEmpty, !journal.documentID.isEmpty else {
      return nil
    }
    let stableKey = "CompanionDocument:\(journal.computerURL)\n\(journal.documentID)"
    return DocumentIdentity.contentHash(for: Data(stableKey.utf8))
  }

  private func credentials() async throws -> String {
    let code = try await readPairingCode()
    guard !normalizeCompanionPairingCode(code).isEmpty else { throw CompanionKernelError.missingPairingCode }
    return code
  }

  func refresh(preferences: ReaderPreferences) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let code = try await credentials()
      documents = try await client.list(url: preferences.companionURL, pairingCode: code)
    } catch { documents = []; toast = error.localizedDescription }
  }

  func open(_ document: CompanionRecentDocument, library: LibraryModel) async -> DocumentSession? {
    let computer = normalizeCompanionURL(library.preferences.companionURL)
    return await open(documentID: document.id, title: document.title, computer: computer, library: library)
  }

  /// Managed copies are never opened as ordinary offline files via Recents or
  /// restored windows. Reacquire/resume their computer session first.
  func handles(_ url: URL) -> Bool {
    url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
  }

  func reopen(_ url: URL, library: LibraryModel) async -> DocumentSession? {
    let savedOrigin = try? JSONDecoder().decode(ComputerDocumentJournal.self,
      from: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("origin.json")))
    guard let journal = journals.values.first(where: { fileURL($0).standardizedFileURL == url.standardizedFileURL }) ?? savedOrigin else {
      toast = L10n.string("ios.computerSessionUnavailable")
      return nil
    }
    return await open(documentID: journal.documentID, title: journal.title,
                      computer: journal.computerURL, library: library)
  }

  private func open(documentID: String, title: String, computer: String,
                    library: LibraryModel) async -> DocumentSession? {
    lastOpenError = nil
    let key = key(computer: computer, document: documentID)
    guard !loadFailed else { toast = L10n.string("ios.computerSessionUnavailable"); return nil }
    guard !operations.contains(key), !activeSessions.contains(key) else {
      toast = L10n.string("ios.computerAlreadyOpen"); return nil
    }
    operations.insert(key)
    busyDocumentIDs.insert(documentID)
    defer { operations.remove(key); busyDocumentIDs.remove(documentID) }
    do {
      let code = try await credentials()
      if let previous = journals[key], previous.pendingRevision != nil {
        _ = try await flushPending(key: key, code: code)
      }
      var journal: ComputerDocumentJournal
      if let previous = journals[key], !previous.released {
        journal = previous
      } else {
        // Per-install ID and per-request session ID; neither is a credential.
        let deviceKey = "computerDocuments.deviceID"
        let deviceID = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: deviceKey)
        journal = ComputerDocumentJournal(documentID: documentID, title: title, computerURL: computer,
                                           deviceID: deviceID, sessionID: UUID().uuidString)
        journals[key] = journal
        try persist()
      }
      // Also persist resumed journals: a previous disk-write failure must not
      // turn the next attempt into an unjournaled remote lock.
      try persist()
      let snapshot = try await client.acquire(url: computer, pairingCode: code,
        documentID: documentID, deviceID: journal.deviceID, deviceName: UIDevice.current.name,
        sessionID: journal.sessionID)
      let localURL = fileURL(journal)
      if FileManager.default.fileExists(atPath: localURL.path),
         let revision = journal.revision, revision != snapshot.revision {
        // This session's base must never advance underneath unsent local edits.
        throw CompanionDocumentError.documentBusy
      }
      try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(journal).write(
        to: localURL.deletingLastPathComponent().appendingPathComponent("origin.json"), options: .atomic)
      // Existing local edits are authoritative while this lock is held. Never
      // replace them with an older download after a crash or failed upload.
      if !FileManager.default.fileExists(atPath: localURL.path) {
        let sourceDocument = PDFDocument(data: snapshot.pdf)
        let transferred = try sourceDocument.flatMap { try ReaderTransferPDF.metadata(from: $0) }
        let annotations = try snapshot.annotations
          ?? transferred?.annotations
          ?? ReaderAnnotationPDF.importAnnotations(from: snapshot.pdf).annotations
        let annotated = try ReaderAnnotationPDF.embedAnnotations(annotations, in: snapshot.pdf,
          nativeRefs: snapshot.nativeRefs ?? annotations.compactMap(\.nativeRef))
        let portable = try ReaderTransferPDF.export(sourceData: annotated,
          annotations: annotations, quickLinks: snapshot.quickLinks ?? transferred?.quickLinks ?? [],
          readingState: snapshot.readingState ?? transferred?.readingState ?? ReadingState())
        try portable.write(to: localURL, options: .atomic)
      }
      journal.revision = snapshot.revision
      journal.pageCount = snapshot.pageCount
      journals[key] = journal
      try persist()
      guard let session = await library.makeSession(for: localURL, computerAuthorized: true, displayTitle: title) else {
        toast = library.lastError ?? L10n.string("ios.pdfReadFailed")
        library.lastError = nil
        return nil
      }
      journal.localID = session.id
      journals[key] = journal
      try persist()
      activeSessions.insert(key)
      return DocumentSession(id: session.id, title: title, url: session.url, access: session.access)
    } catch { lastOpenError = error; toast = error.localizedDescription; return nil }
  }

  /// Serialize the native continuation after any periodic save already in
  /// flight. Never drop a requested release because a heartbeat save is busy.
  func releaseForHandoff(_ tab: ReaderTab) async -> Bool {
    guard let key = journals.first(where: { fileURL($0.value) == tab.session.url })?.key else { return false }
    for _ in 0..<300 {
      if !operations.contains(key) { return await sync(tab, release: true) }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    toast = L10n.string("ios.computerSaving")
    return false
  }

  /// The native activity identifies the paired computer's document, never a
  /// sandbox URL. A released session cannot advertise editable ownership.
  func handoffActivity(for tab: ReaderTab) -> ReaderHandoffActivity? {
    guard let journal = journals.values.first(where: { fileURL($0) == tab.session.url }),
          !journal.released else { return nil }
    return ReaderHandoffActivity(documentID: journal.documentID,
      page: tab.model.readingState.page, serverURL: journal.computerURL)
  }

  /// Handoff selects an ID on the configured, authenticated computer. Never
  /// send stored pairing credentials to an address supplied by userInfo.
  func continueHandoff(_ activity: ReaderHandoffActivity, library: LibraryModel) async -> DocumentSession? {
    let computer = normalizeCompanionURL(library.preferences.companionURL)
    guard !computer.isEmpty else {
      toast = CompanionDocumentError.invalidServerURL.localizedDescription
      return nil
    }
    let title: String
    do {
      let available = try await client.list(url: computer, pairingCode: try await credentials())
      title = available.first(where: { $0.id == activity.documentID })?.title ?? "PDFMathReader"
    } catch { toast = error.localizedDescription; return nil }
    var continued: DocumentSession?
    // Native activity delivery and the sender's final save run concurrently.
    // Retry a held lock, never force takeover or load an older local copy.
    for _ in 0..<60 {
      continued = await open(documentID: activity.documentID, title: title,
        computer: computer, library: library)
      if continued != nil { break }
      guard let error = lastOpenError as? CompanionDocumentError, error == .documentBusy else { return nil }
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
    }
    guard let session = continued else { return nil }
    toast = nil
    do {
      let data = try Data(contentsOf: session.url)
      guard let pdf = PDFDocument(data: data), activity.page <= pdf.pageCount else {
        throw CompanionDocumentError.invalidDocument
      }
      // This explicit continuation receives the latest remote revision. Old
      // local sidecars (including deletions) belong to the previous revision.
      let state = try ReaderAnnotationPDF.importAnnotations(from: data)
      _ = try ReaderAnnotationStore().save(state.annotations, nativeRefs: state.nativeRefs,
        for: session.id, sourceData: data)
      let metadata = try ReaderTransferPDF.metadata(from: pdf)
      try ReaderQuickLinkStore().save(metadata?.quickLinks ?? [], for: session.id)
      var reading = metadata?.readingState ?? library.readingState(for: session)
      reading.page = activity.page
      library.saveReadingState(reading, for: session)
      return session
    } catch {
      toast = error.localizedDescription
      return nil
    }
  }

  func isManaged(_ session: DocumentSession) -> Bool { handles(session.url) }

  /// Replay the exact upload after a lost acknowledgement. The server keeps
  /// successful release receipts; revisions prevent replay over a new owner.
  @discardableResult
  private func flushPending(key: String, code: String) async throws -> Bool {
    guard var journal = journals[key], let revision = journal.pendingRevision,
          let pageCount = journal.pageCount else { return false }
    let release = journal.pendingRelease ?? false
    let pendingURL = fileURL(journal).deletingLastPathComponent().appendingPathComponent("pending.pdf")
    let data = try Data(contentsOf: pendingURL)
    let updated = try await client.save(url: journal.computerURL, pairingCode: code,
      documentID: journal.documentID, sessionID: journal.sessionID, revision: revision,
      pdf: data, pageCount: pageCount, release: release)
    journal.revision = updated
    journal.released = release
    journal.pendingRevision = nil
    journal.pendingRelease = nil
    let previous = journals[key]
    journals[key] = journal
    do { try persist() } catch { journals[key] = previous; throw error }
    if release {
      activeSessions.remove(key)
      if let localID = journal.localID { uncertainSessions.remove(localID) }
    }
    return release
  }

  /// Persist the exact portable snapshot before sending it. Release is part of
  /// the same server transaction as saving, so another reader never sees an
  /// older annotation revision between save and unlock.
  func sync(_ tab: ReaderTab, release: Bool) async -> Bool {
    guard let key = journals.first(where: { fileURL($0.value) == tab.session.url })?.key,
          var journal = journals[key], !journal.released else { return !isManaged(tab.session) }
    guard !operations.contains(key) else {
      if release { toast = L10n.string("ios.computerSaving") }
      return false
    }
    if journal.pendingRelease == true, !release { return false }
    operations.insert(key)
    busyDocumentIDs.insert(journal.documentID)
    defer { operations.remove(key); busyDocumentIDs.remove(journal.documentID) }
    do {
      let code = try await credentials()
      if journal.pendingRevision != nil {
        let wasRelease = try await flushPending(key: key, code: code)
        if wasRelease { return true }
        journal = journals[key]!
      }
      await tab.annotations.prepare()
      await tab.annotations.flushPendingSaves()
      await tab.drawings.prepare()
      guard tab.annotations.lastError == nil, tab.drawings.lastError == nil,
            let source = tab.annotations.exportSourceData else { throw CocoaError(.fileReadCorruptFile) }
      tab.model.persistReadingState()
      let annotations = tab.annotations.annotations
      let quickLinks = tab.annotations.quickLinks
      let readingState = tab.model.readingState
      let nativeRefs = tab.annotations.exportNativeRefs
      let drawings = try tab.drawings.exportDrawings()
      let portable = try await Task.detached(priority: .utility) {
        try ReaderTransferPDF.export(sourceData: source, annotations: annotations,
          quickLinks: quickLinks, readingState: readingState, nativeRefs: nativeRefs)
      }.value
      let data = try ReaderDrawingPDF.embed(drawings, in: portable)
      guard let pdf = PDFDocument(data: data), pdf.pageCount == journal.pageCount else {
        throw CocoaError(.fileReadCorruptFile)
      }
      try data.write(to: fileURL(journal), options: .atomic)
      let hash = DocumentIdentity.contentHash(for: data)
      if !release, lastUploadedHash[key] == hash { return true }
      guard let revision = journal.revision else { throw CocoaError(.fileReadCorruptFile) }
      let pendingURL = fileURL(journal).deletingLastPathComponent().appendingPathComponent("pending.pdf")
      try data.write(to: pendingURL, options: .atomic)
      journal.pendingRevision = revision
      journal.pendingRelease = release
      journals[key] = journal
      try persist()
      if release { uncertainSessions.insert(tab.id) }
      _ = try await flushPending(key: key, code: code)
      lastUploadedHash[key] = hash
      return true
    } catch {
      toast = L10n.string("ios.computerSyncFailed", error.localizedDescription)
      return false
    }
  }
}
