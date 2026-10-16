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

@Test func recentsRemovePersistsHistoryAndPreservesDocumentFilesAndReadingState() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let pdfURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("PDFMathReader-Original-\(UUID().uuidString).pdf")
  let pdfData = Data("%PDF-1.7\noriginal document\n".utf8)
  try pdfData.write(to: pdfURL)
  defer { try? FileManager.default.removeItem(at: pdfURL) }

  let store = RecentsStore(directory: directory)
  let ownedThumbnail = store.thumbnailURL(for: "remove-me")
  let sharedThumbnail = store.thumbnailURL(for: "shared")
  let unownedThumbnail = FileManager.default.temporaryDirectory
    .appendingPathComponent("PDFMathReader-Unowned-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: unownedThumbnail) }
  let importedPDFURL = directory
    .appendingPathComponent("Imported", isDirectory: true)
    .appendingPathComponent("Imported.pdf")
  let importedPDFData = Data("%PDF-1.7\nimported document\n".utf8)
  try FileManager.default.createDirectory(
    at: importedPDFURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try importedPDFData.write(to: importedPDFURL)
  try FileManager.default.createDirectory(
    at: ownedThumbnail.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("owned".utf8).write(to: ownedThumbnail)
  try Data("shared".utf8).write(to: sharedThumbnail)
  try Data("unowned".utf8).write(to: unownedThumbnail)

  let readingStateStore = ReadingStateStore(directory: directory)
  try readingStateStore.save(
    ReadingState(page: 8, zoom: 1.25, scaleMode: .custom, displayMode: .twoPages),
    for: "remove-me"
  )
  let savedState = readingStateStore.state(for: "remove-me")

  let removed = RecentDocument(
    id: "remove-me",
    title: "Original.pdf",
    lastOpened: Date(timeIntervalSince1970: 10),
    pageCount: 4,
    thumbnailCachePath: ownedThumbnail.path,
    bookmarkData: Data([1, 2, 3])
  )
  let kept = RecentDocument(
    id: "keep-me",
    title: "Kept.pdf",
    lastOpened: Date(timeIntervalSince1970: 20),
    pageCount: 9,
    thumbnailCachePath: unownedThumbnail.path,
    bookmarkData: Data([4, 5, 6])
  )
  let sharedRemoved = RecentDocument(
    id: "shared-removed",
    title: "Shared removed.pdf",
    lastOpened: Date(timeIntervalSince1970: 12),
    thumbnailCachePath: sharedThumbnail.path,
    bookmarkData: Data([7])
  )
  let sharedKept = RecentDocument(
    id: "shared-kept",
    title: "Shared kept.pdf",
    lastOpened: Date(timeIntervalSince1970: 15),
    thumbnailCachePath: sharedThumbnail.path,
    bookmarkData: Data([8])
  )
  let importedPDF = RecentDocument(
    id: "imported-pdf",
    title: "Imported.pdf",
    lastOpened: Date(timeIntervalSince1970: 5),
    thumbnailCachePath: importedPDFURL.path,
    bookmarkData: Data([9])
  )
  try store.upsert(removed)
  try store.upsert(kept)
  try store.upsert(sharedRemoved)
  try store.upsert(sharedKept)
  try store.upsert(importedPDF)

  let afterImportedPDFRemoval = try store.remove(id: importedPDF.id)
  #expect(afterImportedPDFRemoval == [kept, sharedKept, sharedRemoved, removed])
  #expect(FileManager.default.fileExists(atPath: importedPDFURL.path))
  #expect(try Data(contentsOf: importedPDFURL) == importedPDFData)

  let afterSharedRemoval = try store.remove(id: sharedRemoved.id)
  #expect(afterSharedRemoval == [kept, sharedKept, removed])
  #expect(FileManager.default.fileExists(atPath: sharedThumbnail.path))

  let updated = try store.remove(id: removed.id)
  #expect(updated == [kept, sharedKept])
  #expect(!FileManager.default.fileExists(atPath: ownedThumbnail.path))
  #expect(FileManager.default.fileExists(atPath: unownedThumbnail.path))
  #expect(FileManager.default.fileExists(atPath: sharedThumbnail.path))
  #expect(FileManager.default.fileExists(atPath: pdfURL.path))
  #expect(try Data(contentsOf: pdfURL) == pdfData)
  #expect(readingStateStore.state(for: removed.id) == savedState)

  let reopenedStore = RecentsStore(directory: directory)
  #expect(reopenedStore.list() == [kept, sharedKept])
  #expect(reopenedStore.document(id: removed.id) == nil)
  #expect(reopenedStore.document(id: kept.id) == kept)

  #expect(try reopenedStore.remove(id: sharedKept.id) == [kept])
  #expect(!FileManager.default.fileExists(atPath: sharedThumbnail.path))
}

@Test func recentsPinningSortsPersistsAndDecodesLegacyEntries() throws {
  let legacy = RecentDocument(
    id: "legacy",
    title: "Legacy.pdf",
    bookmarkData: Data([7])
  )
  let encoded = try JSONEncoder().encode(legacy)
  var legacyObject = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  legacyObject.removeValue(forKey: "pinned")
  let decoded = try JSONDecoder().decode(
    RecentDocument.self,
    from: try JSONSerialization.data(withJSONObject: legacyObject)
  )
  #expect(!decoded.pinned)

  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let oldPinned = RecentDocument(
    id: "old-pinned",
    title: "Old pinned.pdf",
    pinned: true,
    lastOpened: Date(timeIntervalSince1970: 10),
    bookmarkData: Data([1])
  )
  let newest = RecentDocument(
    id: "newest",
    title: "Newest.pdf",
    lastOpened: Date(timeIntervalSince1970: 30),
    bookmarkData: Data([2])
  )
  let oldest = RecentDocument(
    id: "oldest",
    title: "Oldest.pdf",
    lastOpened: Date(timeIntervalSince1970: 5),
    bookmarkData: Data([3])
  )
  try store.upsert(oldPinned)
  try store.upsert(newest)
  try store.upsert(oldest)
  #expect(store.list().map(\.id) == [oldPinned.id, newest.id, oldest.id])

  let pinned = try store.setPinned(true, for: newest.id)
  #expect(pinned.map(\.id) == [newest.id, oldPinned.id, oldest.id])
  #expect(pinned.first?.pinned == true)

  let reopenedStore = RecentsStore(directory: directory)
  #expect(reopenedStore.list().map(\.id) == [newest.id, oldPinned.id, oldest.id])
  #expect(reopenedStore.document(id: newest.id)?.pinned == true)

  let replacement = RecentDocument(
    id: newest.id,
    title: "Newest renamed.pdf",
    pinned: reopenedStore.document(id: newest.id)?.pinned ?? false,
    lastOpened: Date(timeIntervalSince1970: 40),
    bookmarkData: newest.bookmarkData
  )
  try reopenedStore.upsert(replacement)
  #expect(reopenedStore.document(id: newest.id)?.pinned == true)
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

@Test func translationCachePreferencesDefaultFalseAndRoundTrip() throws {
  let defaults = ReaderPreferences()
  #expect(!defaults.reuseTranslations)
  #expect(!defaults.ignoreCache)

  let decodedDefaults = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data("{}".utf8)
  )
  #expect(!decodedDefaults.reuseTranslations)
  #expect(!decodedDefaults.ignoreCache)

  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PreferencesStore(directory: directory)
  let preferences = ReaderPreferences(reuseTranslations: true, ignoreCache: true)
  try store.save(preferences)
  let loaded = store.load()
  #expect(loaded.reuseTranslations)
  #expect(loaded.ignoreCache)
  #expect(loaded == preferences)
}

@Test func interactionModeDefaultsToReadingAndKeepsSavedComparison() throws {
  let legacy = Data(#"{"targetLanguage":"de"}"#.utf8)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: legacy).interactionMode == .reading)

  let unknown = Data(#"{"interactionMode":"split"}"#.utf8)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: unknown).interactionMode == .reading)

  let saved = try JSONEncoder().encode(ReaderPreferences(interactionMode: .comparison))
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: saved).interactionMode == .comparison)
}

@Test func documentOpeningPreferencesDefaultSafelyAndRoundTrip() throws {
  let defaults = ReaderPreferences()
  #expect(defaults.documentOpenMode == .original)
  #expect(defaults.restoreDocumentsOnLaunch)
  #expect(defaults.autoHideTitleBar)

  let legacy = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"showTranslations":true}"#.utf8)
  )
  #expect(legacy.documentOpenMode == .original)
  #expect(legacy.showTranslations)
  #expect(legacy.restoreDocumentsOnLaunch)
  #expect(legacy.autoHideTitleBar)

  let unknown = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"documentOpenMode":"futureMode","showTranslations":true}"#.utf8)
  )
  #expect(unknown.documentOpenMode == .original)
  #expect(unknown.showTranslations)

  for mode in ReaderDocumentOpenMode.allCases {
    let preferences = ReaderPreferences(
      documentOpenMode: mode,
      restoreDocumentsOnLaunch: false,
      autoHideTitleBar: false
    )
    let encoded = try JSONEncoder().encode(preferences)
    let persisted = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(persisted["documentOpenMode"] as? String == mode.rawValue)
    #expect(persisted["restoreDocumentsOnLaunch"] as? Bool == false)
    #expect(persisted["autoHideTitleBar"] as? Bool == false)
    #expect(try JSONDecoder().decode(ReaderPreferences.self, from: encoded) == preferences)
  }
}

@Test func translationModeMigratesLegacyBoolAndRoundTripsEveryMode() throws {
  let legacyFull = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"translateFullDocument":true,"targetLanguage":"de"}"#.utf8)
  )
  #expect(legacyFull.translationMode == .full)
  #expect(legacyFull.translateFullDocument)
  #expect(legacyFull.targetLanguage == "de")

  let legacyReadingAhead = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"translateFullDocument":false}"#.utf8)
  )
  #expect(legacyReadingAhead.translationMode == .readingAhead)
  #expect(!legacyReadingAhead.translateFullDocument)

  let missingLegacyValue = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data("{}".utf8)
  )
  #expect(missingLegacyValue.translationMode == .readingAhead)

  let unknownMode = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"translationMode":"futureMode","translateFullDocument":true}"#.utf8)
  )
  #expect(unknownMode.translationMode == .readingAhead)

  for mode in TranslationMode.allCases {
    let preferences = ReaderPreferences(translationMode: mode)
    let encoded = try JSONEncoder().encode(preferences)
    let persisted = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(persisted["translationMode"] as? String == mode.rawValue)
    #expect(persisted["translateFullDocument"] == nil)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: encoded)
    #expect(decoded.translationMode == mode)
    #expect(decoded == preferences)
  }

  var alias = ReaderPreferences(translationMode: .reading)
  #expect(!alias.translateFullDocument)
  alias.translateFullDocument = true
  #expect(alias.translationMode == .full)
  alias.translateFullDocument = false
  #expect(alias.translationMode == .readingAhead)
}

@Test func translationFontsMigrateLegacyPreferencesAndPersist() throws {
  let legacy = try JSONDecoder().decode(ReaderPreferences.self, from: Data("{}".utf8))
  #expect(!legacy.translationSerif)
  #expect(legacy.translationFont.isEmpty)
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PreferencesStore(directory: directory)
  let preferences = ReaderPreferences(translationSerif: true, translationFont: "  Georgia  ")
  try store.save(preferences)
  #expect(store.load().translationFont == "Georgia")
  #expect(store.load().translationSerif)
  #expect(store.load() == preferences)
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

@Test func accentColorMigratesAndPersistsWithoutResettingOtherPreferences() throws {
  let legacy = try JSONDecoder().decode(ReaderPreferences.self, from: Data(#"{"targetLanguage":"de"}"#.utf8))
  #expect(legacy.accentColor == "system")
  #expect(legacy.targetLanguage == "de")

  for value in ["invalid", "#123", "#gggggg"] {
    let data = Data("{\"accentColor\":\"\(value)\",\"targetLanguage\":\"de\"}".utf8)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
    #expect(decoded.accentColor == "system")
    #expect(decoded.targetLanguage == "de")
  }

  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = PreferencesStore(directory: directory)
  let preferences = ReaderPreferences(targetLanguage: "de", accentColor: "#AF52DE")
  try store.save(preferences)
  #expect(store.load().accentColor == "#af52de")
  #expect(store.load() == preferences)
  try store.save(ReaderPreferences(accentColor: "system"))
  #expect(store.load().accentColor == "system")
}
