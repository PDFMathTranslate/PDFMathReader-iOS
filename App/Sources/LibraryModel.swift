import Combine
import Foundation
import PDFKit
import ReaderCore

/// Holds a document-provider URL's security scope (iCloud Drive, Files,
/// other apps) for as long as any session copy is alive.
final class SecurityScopedAccess: @unchecked Sendable {
  let url: URL
  private let started: Bool

  init(url: URL) {
    self.url = url
    started = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if started { url.stopAccessingSecurityScopedResource() }
  }
}

struct DocumentSession: Hashable, Identifiable {
  let id: String
  let title: String
  let url: URL
  let access: SecurityScopedAccess

  static func == (lhs: DocumentSession, rhs: DocumentSession) -> Bool {
    lhs.id == rhs.id && lhs.url == rhs.url
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(url)
  }
}

/// Scene value for iPad reader windows. Security scope does not survive
/// encoding, so windows reopen by document ID rather than by raw URL.
struct ReaderWindowValue: Codable, Hashable {
  let documentID: String
  let url: URL
}

@MainActor
final class LibraryModel: ObservableObject {
  private let importedPDFDirectory: URL
  let recentsStore: RecentsStore
  let readingStateStore: ReadingStateStore
  let preferencesStore: PreferencesStore

  @Published private(set) var recents: [RecentDocument]
  @Published private(set) var preferences: ReaderPreferences
  @Published var lastError: String?
  /// Sessions handed to a newly opened window, keeping their live scope.
  private var pendingWindowSessions: [String: DocumentSession] = [:]

  init(directory: URL = LibraryDirectory.default) {
    importedPDFDirectory = directory.appendingPathComponent("Imported PDFs", isDirectory: true)
    recentsStore = RecentsStore(directory: directory)
    readingStateStore = ReadingStateStore(directory: directory)
    preferencesStore = PreferencesStore(directory: directory)
    recents = recentsStore.list()
    preferences = preferencesStore.load()
    #if DEBUG
    // UI tests pin the service with `-PMRTranslationService <raw value>`; the
    // override stays in memory so the saved choice on the device is untouched.
    let arguments = ProcessInfo.processInfo.arguments
    if let flag = arguments.firstIndex(of: "-PMRTranslationService"), flag + 1 < arguments.count,
       let service = ReaderTranslationService(rawValue: arguments[flag + 1]) {
      preferences.translationService = service
      translationServiceOverride = service
    }
    #endif
  }

  #if DEBUG
  private var translationServiceOverride: ReaderTranslationService?
  #endif

  func makeSession(for url: URL) -> DocumentSession? {
    guard url.isFileURL else {
      lastError = L10n.string("ios.localPDFOnly")
      return nil
    }

    // Must start before any read; picked and opened-in-place files are
    // otherwise outside the sandbox.
    let access = SecurityScopedAccess(url: url)
    let id: String
    let transferredState: ReadingState?
    do {
      let data = try Self.coordinatedData(at: url)
      let transferred = try PDFDocument(data: data).flatMap {
        try ReaderTransferPDF.metadata(from: $0)
      }
      // Transfer identity survives PDF annotation rewrites. Hashing the whole
      // rewritten file would orphan local comments, links, and reading state.
      if let transferID = transferred?.documentID {
        id = DocumentIdentity.contentHash(for: Data("PDFMathReaderTransfer:\(transferID)".utf8))
      } else {
        id = DocumentIdentity.contentHash(for: data)
      }
      transferredState = transferred?.readingState
    } catch {
      lastError = L10n.string("ios.pdfReadFailed")
      return nil
    }

    let previous = recentsStore.document(id: id)
    // A received PDF restores its reading position once. Reopening a local
    // document must keep the recipient's more recent reading progress.
    if previous == nil, let transferredState {
      do {
        try readingStateStore.save(transferredState, for: id)
      } catch {
        lastError = error.localizedDescription
        return nil
      }
    }
    let bookmarkData = (try? recentsStore.bookmarkData(for: url)) ?? previous?.bookmarkData ?? Data()
    let title = url.lastPathComponent.isEmpty ? L10n.string("ios.pdfDocument") : url.lastPathComponent
    let thumbnailPath = previous?.thumbnailCachePath ?? recentsStore.thumbnailURL(for: id).path
    let record = RecentDocument(
      id: id,
      title: title,
      pageCount: previous?.pageCount,
      thumbnailCachePath: thumbnailPath,
      bookmarkData: bookmarkData
    )

    do {
      recents = try recentsStore.upsert(record)
    } catch {
      lastError = L10n.string("error.saveRecentHistory")
      return nil
    }
    return DocumentSession(id: id, title: title, url: url, access: access)
  }

  /// Open-in/Share deliveries can be temporary. Keep a local copy so the
  /// reader and Recents survive the sender removing its file.
  func receiveExternalPDF(at url: URL) -> DocumentSession? {
    guard url.isFileURL else {
      lastError = L10n.string("ios.localPDFOnly")
      return nil
    }
    let access = SecurityScopedAccess(url: url)
    do {
      let localURL = try withExtendedLifetime(access) {
        let data = try Self.coordinatedData(at: url)
        guard PDFDocument(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let directory = importedPDFDirectory.appendingPathComponent(
          DocumentIdentity.contentHash(for: data), isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
          try data.write(to: destination, options: .atomic)
        }
        return destination
      }
      return makeSession(for: localURL)
    } catch {
      lastError = L10n.string("ios.pdfReadFailed")
      return nil
    }
  }

  /// Coordinated read so iCloud Drive files are materialized and not read
  /// mid-sync.
  private static func coordinatedData(at url: URL) throws -> Data {
    var coordinationError: NSError?
    var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
      result = Result { try Data(contentsOf: readURL, options: [.mappedIfSafe]) }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }

  func makeSession(for recent: RecentDocument) -> DocumentSession? {
    guard !recent.bookmarkData.isEmpty else {
      lastError = L10n.string("ios.missingBookmark")
      return nil
    }

    do {
      let url = try recentsStore.resolveBookmarkData(recent.bookmarkData)
      return makeSession(for: url)
    } catch {
      lastError = L10n.string("ios.pdfUnavailableFromFiles")
      return nil
    }
  }

  func windowValue(for session: DocumentSession) -> ReaderWindowValue {
    pendingWindowSessions[session.id] = session
    return ReaderWindowValue(documentID: session.id, url: session.url)
  }

  #if DEBUG
  private var launchArgumentConsumed = false

  /// UI tests pass `-PMROpenPDF <name-or-path>`; a bare name resolves against
  /// Documents. iPad may relaunch into restored reader windows only, so every
  /// scene asks and the first one opens it.
  func consumeLaunchArgumentPDF() -> URL? {
    guard !launchArgumentConsumed else { return nil }
    launchArgumentConsumed = true
    let arguments = ProcessInfo.processInfo.arguments
    guard let flag = arguments.firstIndex(of: "-PMROpenPDF"), flag + 1 < arguments.count else { return nil }
    let value = arguments[flag + 1]
    return value.hasPrefix("/")
      ? URL(fileURLWithPath: value)
      : URL.documentsDirectory.appendingPathComponent(value)
  }
  #endif

  /// Live handoff first, then the saved bookmark (restored windows), then
  /// the raw URL for files inside the app container.
  func session(for value: ReaderWindowValue, fallbackURL: URL) -> DocumentSession? {
    if let session = pendingWindowSessions.removeValue(forKey: value.documentID) {
      return session
    }
    if let recent = recentsStore.document(id: value.documentID),
       !recent.bookmarkData.isEmpty,
       let session = makeSession(for: recent) {
      return session
    }
    lastError = nil
    return makeSession(for: fallbackURL)
  }

  func refreshRecents() {
    recents = recentsStore.list()
  }

  func clearHistory() {
    do {
      try recentsStore.clearHistory()
      recents = []
    } catch {
      lastError = L10n.string("ios.recentHistoryClearFailed")
    }
  }

  func updateDocumentMetadata(for session: DocumentSession, document: PDFDocument) {
    let pageCount = document.pageCount
    let thumbnailPath = recentsStore.thumbnailURL(for: session.id).path
    do {
      try recentsStore.updateMetadata(
        for: session.id,
        pageCount: pageCount,
        thumbnailCachePath: thumbnailPath
      )
      refreshRecents()
    } catch {
      lastError = L10n.string("ios.pdfMetadataSaveFailed")
    }
  }

  func cacheThumbnail(_ data: Data, for session: DocumentSession) {
    let url = recentsStore.thumbnailURL(for: session.id)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: [.atomic])
      try recentsStore.updateMetadata(for: session.id, thumbnailCachePath: url.path)
      refreshRecents()
    } catch {
      // A missing preview should never prevent opening the document.
    }
  }

  func savePreferences(_ value: ReaderPreferences) {
    do {
      var stored = value
      #if DEBUG
      if let override = translationServiceOverride, value.translationService == override {
        stored.translationService = preferencesStore.load().translationService
      }
      #endif
      try preferencesStore.save(stored)
      preferences = value
    } catch {
      lastError = L10n.string("ios.preferencesSaveFailed")
    }
  }

  func readingState(for session: DocumentSession) -> ReadingState {
    readingStateStore.state(for: session.id)
  }

  func saveReadingState(_ state: ReadingState, for session: DocumentSession) {
    do {
      try readingStateStore.save(state, for: session.id)
    } catch {
      // Reading position is best-effort and should not interrupt reading.
    }
  }
}
