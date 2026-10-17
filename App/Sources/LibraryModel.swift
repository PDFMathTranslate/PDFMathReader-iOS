import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

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
  private let epubPDFDirectory: URL
  @Published private(set) var epubConversionsInProgress = 0
  let computerDocuments: CompanionDocumentManager
  let recentsStore: RecentsStore
  let readingStateStore: ReadingStateStore
  let preferencesStore: PreferencesStore

  @Published private(set) var recents: [RecentDocument]
  @Published private(set) var preferences: ReaderPreferences
  @Published var lastError: String?
  /// Sessions handed to a newly opened window, keeping their live scope.
  private var pendingWindowSessions: [String: DocumentSession] = [:]
  private var thumbnailTasks: [String: Task<Data?, Never>] = [:]
  private var isReconcilingRecents = false

  init(directory: URL = LibraryDirectory.default) {
    ReaderErrorLocalization.configure()
    epubPDFDirectory = directory.appendingPathComponent("EPUB PDFs", isDirectory: true)
    computerDocuments = CompanionDocumentManager(directory: directory.appendingPathComponent("Computer Documents"))
    importedPDFDirectory = directory.appendingPathComponent("Imported PDFs", isDirectory: true)
    recentsStore = RecentsStore(directory: directory)
    readingStateStore = ReadingStateStore(directory: directory)
    preferencesStore = PreferencesStore(directory: directory)
    recents = recentsStore.list()
    preferences = preferencesStore.load()
    L10n.languageChoice = preferences.uiLanguage
    #if DEBUG
    // UI tests pin the service with `-PMRTranslationService <raw value>`; the
    // override stays in memory so the saved choice on the device is untouched.
    let arguments = ProcessInfo.processInfo.arguments
    if let flag = arguments.firstIndex(of: "-PMRTranslationService"), flag + 1 < arguments.count,
       let service = ReaderTranslationService(rawValue: arguments[flag + 1]) {
      preferences.translationService = service
      translationServiceOverride = service
    }
    // `-PMRUILanguage <code>` pins the interface language; the in-app choice
    // otherwise wins over `-AppleLanguages`.
    if let flag = arguments.firstIndex(of: "-PMRUILanguage"), flag + 1 < arguments.count {
      uiLanguageOverride = arguments[flag + 1]
      L10n.languageChoice = arguments[flag + 1]
    }
    #endif
  }

  #if DEBUG
  private var translationServiceOverride: ReaderTranslationService?
  private var uiLanguageOverride: String?
  #endif

  func makeSession(for url: URL, computerAuthorized: Bool = false, displayTitle: String? = nil, allowWidthAlignment: Bool = true) async -> DocumentSession? {
    if !computerAuthorized, computerDocuments.handles(url) {
      return await computerDocuments.reopen(url, library: self)
    }
    guard url.isFileURL else {
      lastError = L10n.string("ios.localPDFOnly")
      return nil
    }

    // Must start before any read; picked and opened-in-place files are
    // otherwise outside the sandbox.
    let access = SecurityScopedAccess(url: url)
    if url.pathExtension.lowercased() == "epub" {
      epubConversionsInProgress += 1
      defer { epubConversionsInProgress -= 1 }
      do {
        let data = try await Task.detached(priority: .userInitiated) {
          try withExtendedLifetime(access) {
            try Self.coordinatedData(at: url, maximumBytes: 128 * 1024 * 1024)
          }
        }.value
        try Task.checkCancellation()
        let pdfURL = try await EPUBConverter.convert(
          data: data, directory: epubPDFDirectory,
          fontName: preferences.translationFont, serif: preferences.translationSerif
        )
        try Task.checkCancellation()
        return await makeSession(for: pdfURL, displayTitle: displayTitle ?? url.lastPathComponent)
      } catch is CancellationError {
        return nil
      } catch {
        lastError = L10n.string("ios.epubOpenFailed", error.localizedDescription)
        return nil
      }
    }
    let id: String
    let contentHash: String
    let sourceIdentity: String?
    let transferredState: ReadingState?
    do {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try withExtendedLifetime(access) {
          let data = try Self.coordinatedData(at: url)
          guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
          let transferred = try ReaderTransferPDF.metadata(from: document)
          let contentHash = DocumentIdentity.contentHash(for: data)
          let id = transferred?.documentID.map {
            DocumentIdentity.contentHash(for: Data("PDFMathReaderTransfer:\($0)".utf8))
          } ?? contentHash
          return (id, transferred?.readingState, contentHash, transferred?.documentID)
        }
      }.value
      guard !Task.isCancelled else { return nil }
      let isCachedEPUB = url.deletingLastPathComponent().standardizedFileURL == epubPDFDirectory.standardizedFileURL
      let computerIdentity = computerAuthorized ? computerDocuments.stableDocumentIdentity(for: url) : nil
      sourceIdentity = isCachedEPUB ? "epub:\(url.deletingPathExtension().lastPathComponent)"
        : computerAuthorized ? "companion:\(computerIdentity ?? DocumentIdentity.contentHash(for: Data(url.standardizedFileURL.absoluteString.utf8)))"
        : prepared.3.map { "transfer:\($0)" }
      let proposedID = isCachedEPUB
        ? DocumentIdentity.contentHash(for: Data("EPUB:\(url.deletingPathExtension().lastPathComponent)".utf8))
        : computerAuthorized
        ? computerIdentity ?? DocumentIdentity.contentHash(for: Data(url.standardizedFileURL.absoluteString.utf8))
        : prepared.0
      // Content changes (embedded annotations, provider rewrites) must not
      // create a new reading-state identity for an already known file.
      id = recentsStore.document(matching: url, contentHash: prepared.2, sourceIdentity: sourceIdentity)?.id ?? proposedID
      contentHash = prepared.2
      transferredState = prepared.1
    } catch {
      lastError = L10n.string("ios.pdfReadFailed")
      return nil
    }

    let previous = recentsStore.document(id: id)
    // Companion PDFs remain journal-owned: replacing their URL would detach
    // edits from the desktop synchronization journal.
    if allowWidthAlignment, preferences.autoAlignDocumentWidth, !computerAuthorized {
      do {
        let sourceData = try await Task.detached(priority: .userInitiated) {
          try withExtendedLifetime(access) { try Self.coordinatedData(at: url) }
        }.value
        let state = previous != nil ? readingStateStore.state(for: id) : transferredState ?? ReadingState()
        if let alignedURL = try await ReaderAlignedDocument.prepare(
          sourceData: sourceData, sourceURL: url, sourceID: id,
          contentHash: contentHash, directory: recentsStore.directory, readingState: state
        ) {
          guard !Task.isCancelled else { return nil }
          if let session = await makeSession(
            for: alignedURL, displayTitle: displayTitle ?? previous?.title ?? url.lastPathComponent,
            allowWidthAlignment: false
          ) {
            if previous != nil, session.id != id {
              if previous?.pinned == true { recents = try recentsStore.setPinned(true, for: session.id) }
              recents = try recentsStore.remove(id: id)
            }
            return session
          }
        }
      } catch is CancellationError {
        return nil
      } catch {
        // Alignment is an optional import enhancement. An unsupported PDF or
        // damaged sidecar must not prevent reading the unchanged original.
        lastError = error.localizedDescription
      }
    }
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
    let cachedEPUBTitle = url.deletingLastPathComponent().standardizedFileURL == epubPDFDirectory.standardizedFileURL
      ? previous?.title : nil
    let title = displayTitle ?? cachedEPUBTitle
      ?? (url.lastPathComponent.isEmpty ? L10n.string("ios.pdfDocument") : url.lastPathComponent)
    let contentChanged = previous?.contentHash.map { $0 != contentHash } ?? false
    let thumbnailURL = recentsStore.thumbnailURL(for: id)
    if contentChanged { try? FileManager.default.removeItem(at: thumbnailURL) }
    let thumbnailPath = contentChanged ? thumbnailURL.path : previous?.thumbnailCachePath ?? thumbnailURL.path
    let record = RecentDocument(
      id: id,
      title: title,
      pinned: previous?.pinned ?? false,
      pageCount: previous?.pageCount,
      thumbnailCachePath: thumbnailPath,
      bookmarkData: bookmarkData,
      contentHash: contentHash,
      sourceIdentity: sourceIdentity
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
  func receiveExternalPDF(at url: URL) async -> DocumentSession? {
    // EPUB conversion produces a durable local PDF before adding a Recent.
    if url.isFileURL, url.pathExtension.lowercased() == "epub" {
      return await makeSession(for: url)
    }
    guard url.isFileURL else {
      lastError = L10n.string("ios.localPDFOnly")
      return nil
    }
    let access = SecurityScopedAccess(url: url)
    do {
      let importedPDFDirectory = importedPDFDirectory
      let localURL = try await Task.detached(priority: .userInitiated) {
        try withExtendedLifetime(access) {
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
      }.value
      guard !Task.isCancelled else { return nil }
      return await makeSession(for: localURL)
    } catch {
      lastError = L10n.string("ios.pdfReadFailed")
      return nil
    }
  }

  /// Coordinated read so iCloud Drive files are materialized and not read
  /// mid-sync.
  nonisolated private static func coordinatedData(at url: URL, maximumBytes: Int? = nil) throws -> Data {
    var coordinationError: NSError?
    var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
      result = Result {
        if let maximumBytes,
           let size = try readURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumBytes {
          throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: readURL, options: [.mappedIfSafe])
        if let maximumBytes, data.count > maximumBytes { throw CocoaError(.fileReadTooLarge) }
        return data
      }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }

  func isRemoteDocument(_ recent: RecentDocument) -> Bool {
    guard let url = try? recentsStore.resolveBookmarkData(recent.bookmarkData) else { return false }
    return computerDocuments.handles(url)
  }

  func makeSession(for recent: RecentDocument) async -> DocumentSession? {
    guard !recent.bookmarkData.isEmpty else {
      lastError = L10n.string("ios.missingBookmark")
      return nil
    }

    do {
      let url = try recentsStore.resolveBookmarkData(recent.bookmarkData)
      return await makeSession(for: url)
    } catch {
      lastError = L10n.string("ios.pdfUnavailableFromFiles")
      return nil
    }
  }

  func windowValue(for session: DocumentSession) -> ReaderWindowValue {
    pendingWindowSessions[session.id] = session
    return ReaderWindowValue(documentID: session.id, url: session.url)
  }

  /// Returns whether a reader window was just opened by this process. A live
  /// handoff must take precedence over UIKit's restored scene value.
  func hasPendingWindowSession(for value: ReaderWindowValue) -> Bool {
    pendingWindowSessions[value.documentID] != nil
  }

  #if DEBUG
  private var launchArgumentsConsumed = false

  /// UI tests pass `-PMROpenPDF <name-or-path>`; a bare name resolves against
  /// Documents. iPad may relaunch into restored reader windows only, so every
  /// scene asks and the first one opens it.
  func consumeLaunchArgumentPDF() -> URL? {
    consumeLaunchArgumentPDFs().first
  }

  /// Consumes all explicit PDF launch arguments once for the process so a
  /// restored reader scene cannot open the same test documents twice.
  func consumeLaunchArgumentPDFs() -> [URL] {
    guard !launchArgumentsConsumed else { return [] }
    launchArgumentsConsumed = true
    let arguments = ProcessInfo.processInfo.arguments
    var urls: [URL] = []
    if let flag = arguments.firstIndex(of: "-PMROpenPDF"), flag + 1 < arguments.count {
      urls.append(Self.launchArgumentURL(arguments[flag + 1]))
    }
    if let flag = arguments.firstIndex(of: "-PMRTabPDFs") {
      for path in arguments.dropFirst(flag + 1).prefix(while: { !$0.hasPrefix("-") }) {
        urls.append(Self.launchArgumentURL(path))
      }
    }
    return urls
  }

  private static func launchArgumentURL(_ value: String) -> URL {
    value.hasPrefix("/")
      ? URL(fileURLWithPath: value)
      : URL.documentsDirectory.appendingPathComponent(value)
  }
  #endif

  /// Live handoff first, then the saved bookmark (restored windows), then
  /// the raw URL for files inside the app container.
  func session(for value: ReaderWindowValue, fallbackURL: URL) async -> DocumentSession? {
    if let session = pendingWindowSessions.removeValue(forKey: value.documentID) {
      return session
    }
    if let recent = recentsStore.document(id: value.documentID),
       !recent.bookmarkData.isEmpty,
       let session = await makeSession(for: recent) {
      return session
    }
    lastError = nil
    return await makeSession(for: fallbackURL)
  }

  func refreshRecents() {
    recents = recentsStore.list()
  }

  /// Backfill old records so copies imported through different routes can be
  /// recognized without relying on their titles or changing document files.
  func reconcileRecentDocuments() async {
    guard !isReconcilingRecents else { return }
    isReconcilingRecents = true
    defer { isReconcilingRecents = false }
    for recent in recentsStore.list().sorted(by: { $0.lastOpened < $1.lastOpened }) {
      guard !Task.isCancelled else { break }
      guard recent.contentHash == nil, !recent.bookmarkData.isEmpty else { continue }
      guard let url = try? recentsStore.resolveBookmarkData(recent.bookmarkData) else { continue }
      let computerIdentity = computerDocuments.stableDocumentIdentity(for: url)
      let isComputerDocument = computerDocuments.handles(url)
      let isCachedEPUB = url.deletingLastPathComponent().standardizedFileURL == epubPDFDirectory.standardizedFileURL
      let prepared = await Task.detached(priority: .utility) {
        let access = SecurityScopedAccess(url: url)
        return withExtendedLifetime(access) { () -> (String, String?)? in
          guard let data = try? Self.coordinatedData(at: url) else { return nil }
          let transferID = PDFDocument(data: data).flatMap { try? ReaderTransferPDF.metadata(from: $0)?.documentID }
          return (DocumentIdentity.contentHash(for: data), transferID)
        }
      }.value
      guard let prepared,
        var current = recentsStore.document(id: recent.id),
        current.contentHash == nil,
        current.bookmarkData == recent.bookmarkData else { continue }
      current.contentHash = prepared.0
      current.sourceIdentity = isCachedEPUB ? "epub:\(url.deletingPathExtension().lastPathComponent)"
        : isComputerDocument ? "companion:\(computerIdentity ?? DocumentIdentity.contentHash(for: Data(url.standardizedFileURL.absoluteString.utf8)))"
        : prepared.1.map { "transfer:\($0)" }
      if let updated = try? recentsStore.upsert(current) { recents = updated }
    }
  }

  func removeRecent(_ recent: RecentDocument) {
    do {
      recents = try recentsStore.remove(id: recent.id)
    } catch {
      lastError = L10n.string("ios.recentRemoveFailed")
    }
  }

  func togglePinned(_ recent: RecentDocument) {
    do {
      recents = try recentsStore.setPinned(!recent.pinned, for: recent.id)
    } catch {
      lastError = L10n.string("ios.recentPinFailed")
    }
  }

  func copyLocation(for recent: RecentDocument) {
    do {
      let url = try recentsStore.resolveBookmarkData(recent.bookmarkData)
      UIPasteboard.general.string = url.path
    } catch {
      lastError = L10n.string("ios.pdfUnavailableFromFiles")
    }
  }

  func clearTranslationCache(for recent: RecentDocument) async {
    do {
      try await Task.detached(priority: .utility) {
        try TranslationCacheManagement().clear(documentID: recent.id)
      }.value
      NotificationCenter.default.post(
        name: .translationCacheDidClear,
        object: nil,
        userInfo: [TranslationCacheNotification.documentIDKey: recent.id]
      )
    } catch {
      lastError = L10n.string("ios.cacheClearFailed", error.localizedDescription)
    }
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
    cacheThumbnail(data, documentID: session.id)
  }

  private func cacheThumbnail(_ data: Data, documentID: String) {
    // A preview finishing after history was cleared must not recreate its entry.
    guard recentsStore.document(id: documentID) != nil else { return }
    let url = recentsStore.thumbnailURL(for: documentID)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: [.atomic])
      try recentsStore.updateMetadata(for: documentID, thumbnailCachePath: url.path)
      refreshRecents()
    } catch {
      // A missing preview should never prevent opening the document.
    }
  }

  /// The preview belongs to the library, not the lifetime of a reader view.
  /// Finish and persist it even when the user immediately closes that reader.
  func prepareThumbnail(for session: DocumentSession) async {
    let destination = recentsStore.thumbnailURL(for: session.id)
    if UIImage(contentsOfFile: destination.path) != nil { return }
    if let pending = thumbnailTasks[session.id] {
      if let data = await pending.value { cacheThumbnail(data, for: session) }
      return
    }
    let task = Task.detached(priority: .utility) {
      withExtendedLifetime(session.access) {
        guard let document = PDFDocument(url: session.url),
          let page = document.page(at: 0) else { return Data?.none }
        return withExtendedLifetime(document) {
          page.thumbnail(of: CGSize(width: 480, height: 640), for: .mediaBox).pngData()
        }
      }
    }
    thumbnailTasks[session.id] = task
    let data = await task.value
    if let data { cacheThumbnail(data, for: session) }
    thumbnailTasks[session.id] = nil
  }

  /// Repair missing/corrupt previews without opening the reader or changing
  /// recent ordering. Existing previews remain available if the PDF is offline.
  func recentThumbnailURL(for recent: RecentDocument) async -> URL? {
    let destination = recentsStore.thumbnailURL(for: recent.id)
    if UIImage(contentsOfFile: destination.path) != nil { return destination }
    if let path = recent.thumbnailCachePath, let image = UIImage(contentsOfFile: path),
      let data = image.pngData() {
      // Migrate a legacy preview into the library's current container.
      cacheThumbnail(data, documentID: recent.id)
      return destination
    }
    guard !recent.bookmarkData.isEmpty,
      let url = try? recentsStore.resolveBookmarkData(recent.bookmarkData) else { return nil }
    let session = DocumentSession(id: recent.id, title: recent.title, url: url,
                                  access: SecurityScopedAccess(url: url))
    await prepareThumbnail(for: session)
    return UIImage(contentsOfFile: destination.path) != nil ? destination : nil
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
      L10n.languageChoice = value.uiLanguage
      #if DEBUG
      if let uiLanguageOverride { L10n.languageChoice = uiLanguageOverride }
      #endif
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
