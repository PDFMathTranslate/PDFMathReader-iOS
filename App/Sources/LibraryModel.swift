import Combine
import Foundation
import PDFKit
import ReaderCore

struct DocumentSession: Hashable, Identifiable {
  let id: String
  let title: String
  let url: URL
}

@MainActor
final class LibraryModel: ObservableObject {
  let recentsStore: RecentsStore
  let readingStateStore: ReadingStateStore
  let preferencesStore: PreferencesStore

  @Published private(set) var recents: [RecentDocument]
  @Published private(set) var preferences: ReaderPreferences
  @Published var lastError: String?

  init(directory: URL = LibraryDirectory.default) {
    recentsStore = RecentsStore(directory: directory)
    readingStateStore = ReadingStateStore(directory: directory)
    preferencesStore = PreferencesStore(directory: directory)
    recents = recentsStore.list()
    preferences = preferencesStore.load()
  }

  func makeSession(for url: URL) -> DocumentSession? {
    guard url.isFileURL else {
      lastError = "PDFMathReader can open local PDF files only."
      return nil
    }

    let id: String
    do {
      id = try DocumentIdentity.contentHash(for: url)
    } catch {
      lastError = "This PDF could not be read."
      return nil
    }

    let previous = recentsStore.document(id: id)
    let bookmarkData = (try? recentsStore.bookmarkData(for: url)) ?? previous?.bookmarkData ?? Data()
    let title = url.lastPathComponent.isEmpty ? "PDF document" : url.lastPathComponent
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
      lastError = "The recent-document history could not be saved."
      return nil
    }
    return DocumentSession(id: id, title: title, url: url)
  }

  func makeSession(for recent: RecentDocument) -> DocumentSession? {
    guard !recent.bookmarkData.isEmpty else {
      lastError = "This recent PDF no longer has a file bookmark."
      return nil
    }

    do {
      let url = try recentsStore.resolveBookmarkData(recent.bookmarkData)
      let accessStarted = url.startAccessingSecurityScopedResource()
      defer {
        if accessStarted { url.stopAccessingSecurityScopedResource() }
      }
      return makeSession(for: url)
    } catch {
      lastError = "This PDF is unavailable. Choose it again from Files."
      return nil
    }
  }

  func refreshRecents() {
    recents = recentsStore.list()
  }

  func clearHistory() {
    do {
      try recentsStore.clearHistory()
      recents = []
    } catch {
      lastError = "The recent-document history could not be cleared."
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
      lastError = "The PDF metadata could not be saved."
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
      try preferencesStore.save(value)
      preferences = value
    } catch {
      lastError = "Preferences could not be saved."
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
