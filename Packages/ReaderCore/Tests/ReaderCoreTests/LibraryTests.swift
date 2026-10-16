import Foundation
import Testing

@testable import ReaderCore

private func temporaryLibraryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("PDFMathReader-LibraryTests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@Test func documentIdentityIsStableForTheSameContent() {
  let content = Data("reader parity".utf8)
  #expect(DocumentIdentity.contentHash(for: content) == DocumentIdentity.contentHash(for: content))
  #expect(DocumentIdentity.contentHash(for: content) != DocumentIdentity.contentHash(for: Data("other".utf8)))
}

@Test func recentsRoundTripAndClearHistory() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let thumbnail = store.thumbnailURL(for: "document")
  try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("thumbnail".utf8).write(to: thumbnail)
  let document = RecentDocument(
    id: "document",
    title: "Paper.pdf",
    pageCount: 12,
    thumbnailCachePath: thumbnail.path,
    bookmarkData: Data([1, 2, 3])
  )

  try store.upsert(document)
  let loaded = try #require(store.list().first)
  #expect(loaded.id == document.id)
  #expect(loaded.title == document.title)
  #expect(loaded.pageCount == 12)
  #expect(loaded.bookmarkData == Data([1, 2, 3]))
  #expect(FileManager.default.fileExists(atPath: thumbnail.path))

  try store.clearHistory()
  #expect(store.list().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
}

@Test func readingStateIsKeyedByDocumentIdentity() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = ReadingStateStore(directory: directory)
  #expect(store.state(for: "missing").page == 1)

  var state = ReadingState(page: 7, zoom: 1.25, scaleMode: .custom, displayMode: .twoPages)
  state.scrollDirection = .horizontal
  state.sidebarVisible = false
  try store.save(state, for: "hash-a")

  let loaded = store.state(for: "hash-a")
  #expect(loaded.page == 7)
  #expect(loaded.zoom == 1.25)
  #expect(loaded.scaleMode == .custom)
  #expect(loaded.displayMode == .twoPages)
  #expect(loaded.scrollDirection == .horizontal)
  #expect(!loaded.sidebarVisible)
  let missing = store.state(for: "hash-b")
  #expect(missing.page == 1)
  #expect(missing.scaleMode == .fitPage)
  #expect(missing.displayMode == .singlePage)
}

@Test func preferencesRoundTripWithInjectedDirectory() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = PreferencesStore(directory: directory)
  #expect(store.load() == ReaderPreferences())

  let preferences = ReaderPreferences(
    uiLanguage: "zh-Hans",
    targetLanguage: "de",
    engine: .precise,
    theme: .dark
  )
  try store.save(preferences)
  #expect(store.load() == preferences)
}

@Test func interactionModeDefaultsToReadingAndKeepsSavedComparison() throws {
  let legacy = Data(#"{"targetLanguage":"de"}"#.utf8)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: legacy).interactionMode == .reading)

  let unknown = Data(#"{"interactionMode":"split"}"#.utf8)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: unknown).interactionMode == .reading)

  let saved = try JSONEncoder().encode(ReaderPreferences(interactionMode: .comparison))
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: saved).interactionMode == .comparison)
}

@Test func glossaryStoreRoundTripsAndRejectsInvalidValues() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = GlossaryStore(directory: directory)
  let libraries = [
    GlossaryLibrary(
      id: "research",
      name: "Research terms",
      enabled: true,
      entries: [GlossaryEntry(source: "effect size", target: "效应量")]
    )
  ]

  try store.save(libraries)
  #expect(store.load() == libraries)

  let invalid = [
    GlossaryLibrary(
      id: "invalid",
      name: "Invalid",
      enabled: true,
      entries: [GlossaryEntry(source: String(repeating: "x", count: 501), target: "term")]
    )
  ]
  #expect(throws: GlossaryStoreError.invalidGlossary) {
    try store.save(invalid)
  }
}
