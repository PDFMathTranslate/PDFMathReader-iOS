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

private func temporaryDocument(
  named name: String,
  in directory: URL,
  contents: Data
) throws -> URL {
  let url = directory.appendingPathComponent(name)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try contents.write(to: url)
  return url
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

@Test func recentsUpsertDeduplicatesSameBookmarkAndPreservesMetadata() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let pdfURL = try temporaryDocument(
    named: "Paper.pdf",
    in: directory,
    contents: Data("same document".utf8)
  )
  let bookmarkData = try store.bookmarkData(for: pdfURL)
  let thumbnail = store.thumbnailURL(for: "old-id")
  try FileManager.default.createDirectory(
    at: thumbnail.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("thumbnail".utf8).write(to: thumbnail)

  let original = RecentDocument(
    id: "old-id",
    title: "Paper.pdf",
    pinned: true,
    lastOpened: Date(timeIntervalSince1970: 10),
    pageCount: 42,
    thumbnailCachePath: thumbnail.path,
    bookmarkData: bookmarkData
  )
  let replacement = RecentDocument(
    id: "new-id",
    title: "Paper renamed.pdf",
    lastOpened: Date(timeIntervalSince1970: 20),
    bookmarkData: bookmarkData
  )
  try store.upsert(original)
  let result = try store.upsert(replacement)

  let document = try #require(result.first)
  #expect(result.count == 1)
  #expect(document.id == "new-id")
  #expect(document.pinned)
  #expect(document.pageCount == 42)
  #expect(FileManager.default.fileExists(atPath: pdfURL.path))
  #expect(FileManager.default.fileExists(atPath: thumbnail.path))
}

@Test func recentsUpsertDeduplicatesEqualContentHashesAcrossURLs() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let contents = Data("identical content".utf8)
  let firstURL = try temporaryDocument(named: "one.pdf", in: directory, contents: contents)
  let secondURL = try temporaryDocument(named: "two.pdf", in: directory, contents: contents)
  let hash = DocumentIdentity.contentHash(for: contents)
  let first = RecentDocument(
    id: "one",
    title: "one.pdf",
    lastOpened: Date(timeIntervalSince1970: 10),
    bookmarkData: try store.bookmarkData(for: firstURL),
    contentHash: hash
  )
  let second = RecentDocument(
    id: "two",
    title: "two.pdf",
    lastOpened: Date(timeIntervalSince1970: 20),
    bookmarkData: try store.bookmarkData(for: secondURL),
    contentHash: hash
  )

  try store.upsert(first)
  try store.upsert(second)

  #expect(store.list().count == 1)
  #expect(store.document(matching: secondURL, contentHash: hash)?.id == "two")
  #expect(FileManager.default.fileExists(atPath: firstURL.path))
  #expect(FileManager.default.fileExists(atPath: secondURL.path))
}

@Test func recentsSourceIdentityScopesHashDeduplicationAndMatchesAcrossURLs() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let contents = Data("same bytes, separate origins".utf8)
  let firstURL = try temporaryDocument(named: "origin-a/one.pdf", in: directory, contents: contents)
  let secondURL = try temporaryDocument(named: "origin-b/two.pdf", in: directory, contents: contents)
  let thirdURL = try temporaryDocument(named: "origin-a/three.pdf", in: directory, contents: contents)
  let hash = DocumentIdentity.contentHash(for: contents)
  try store.upsert(RecentDocument(
    id: "origin-a-one",
    title: "one.pdf",
    lastOpened: Date(timeIntervalSince1970: 10),
    bookmarkData: try store.bookmarkData(for: firstURL),
    contentHash: hash,
    sourceIdentity: "origin-a"
  ))
  try store.upsert(RecentDocument(
    id: "origin-b-two",
    title: "two.pdf",
    lastOpened: Date(timeIntervalSince1970: 20),
    bookmarkData: try store.bookmarkData(for: secondURL),
    contentHash: hash,
    sourceIdentity: "origin-b"
  ))
  try store.upsert(RecentDocument(
    id: "origin-a-three",
    title: "three.pdf",
    lastOpened: Date(timeIntervalSince1970: 30),
    bookmarkData: try store.bookmarkData(for: thirdURL),
    contentHash: hash,
    sourceIdentity: "origin-a"
  ))

  #expect(store.list().count == 2)
  #expect(store.document(matching: thirdURL, contentHash: hash, sourceIdentity: "origin-a")?.id ==
    "origin-a-three")
  #expect(store.document(matching: secondURL, contentHash: hash, sourceIdentity: "origin-a")?.id ==
    "origin-a-three")
}

@Test func recentsDoNotMergeDifferentFilesWithTheSameNameOrInvalidBookmarks() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let firstURL = try temporaryDocument(
    named: "first/Report.pdf",
    in: directory,
    contents: Data("first".utf8)
  )
  let secondURL = try temporaryDocument(
    named: "second/Report.pdf",
    in: directory,
    contents: Data("second".utf8)
  )
  try store.upsert(RecentDocument(
    id: "first",
    title: "Report.pdf",
    bookmarkData: try store.bookmarkData(for: firstURL)
  ))
  try store.upsert(RecentDocument(
    id: "second",
    title: "Report.pdf",
    bookmarkData: try store.bookmarkData(for: secondURL)
  ))
  try store.upsert(RecentDocument(id: "invalid-1", title: "Report.pdf", bookmarkData: Data([1])))
  try store.upsert(RecentDocument(id: "invalid-2", title: "Report.pdf", bookmarkData: Data([1])))

  #expect(store.list().count == 4)
  #expect(store.document(matching: firstURL)?.id == "first")
  #expect(store.document(matching: secondURL)?.id == "second")
}

@Test func recentsListRepairsLegacyDuplicatesAndKeepsLatestState() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let pdfURL = try temporaryDocument(
    named: "Legacy.pdf",
    in: directory,
    contents: Data("legacy".utf8)
  )
  let bookmarkData = try store.bookmarkData(for: pdfURL)
  let thumbnail = store.thumbnailURL(for: "old-id")
  try FileManager.default.createDirectory(
    at: thumbnail.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("thumbnail".utf8).write(to: thumbnail)
  let old = RecentDocument(
    id: "old-id",
    title: "Old title",
    pinned: true,
    lastOpened: Date(timeIntervalSince1970: 10),
    pageCount: 17,
    thumbnailCachePath: thumbnail.path,
    bookmarkData: bookmarkData
  )
  let latest = RecentDocument(
    id: "latest-id",
    title: "Latest title",
    lastOpened: Date(timeIntervalSince1970: 20),
    bookmarkData: bookmarkData
  )
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode([old, latest]).write(
    to: directory.appendingPathComponent("recents.json")
  )

  let repaired = try #require(store.list().first)
  #expect(store.list().count == 1)
  #expect(repaired.id == "latest-id")
  #expect(repaired.title == "Latest title")
  #expect(repaired.pinned)
  #expect(repaired.pageCount == 17)
  #expect(FileManager.default.fileExists(atPath: thumbnail.path))

  let persistedData = try Data(contentsOf: directory.appendingPathComponent("recents.json"))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode([RecentDocument].self, from: persistedData).count == 1)
  #expect(FileManager.default.fileExists(atPath: pdfURL.path))
}

@Test func recentsDocumentMatchingChoosesNewestCandidateAcrossURLAndHash() throws {
  let directory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = RecentsStore(directory: directory)
  let queryURL = try temporaryDocument(named: "query.pdf", in: directory, contents: Data("query".utf8))
  let hashURL = try temporaryDocument(named: "hash.pdf", in: directory, contents: Data("hash".utf8))
  let hash = DocumentIdentity.contentHash(for: Data("shared".utf8))
  try store.upsert(RecentDocument(
    id: "url-match",
    title: "Query.pdf",
    pinned: true,
    lastOpened: Date(timeIntervalSince1970: 10),
    bookmarkData: try store.bookmarkData(for: queryURL)
  ))
  try store.upsert(RecentDocument(
    id: "hash-match",
    title: "Hash.pdf",
    lastOpened: Date(timeIntervalSince1970: 20),
    bookmarkData: try store.bookmarkData(for: hashURL),
    contentHash: hash
  ))

  #expect(store.document(matching: queryURL, contentHash: hash)?.id == "hash-match")
}

@Test func recentsResolveMovedThumbnailsAndCleanUpCurrentContainer() throws {
  let originalDirectory = try temporaryLibraryDirectory()
  defer { try? FileManager.default.removeItem(at: originalDirectory) }

  let originalStore = RecentsStore(directory: originalDirectory)
  let originalThumbnailDirectory = originalStore.thumbnailURL(for: "persisted")
    .deletingLastPathComponent()
  try FileManager.default.createDirectory(
    at: originalThumbnailDirectory,
    withIntermediateDirectories: true
  )

  let documents = ["persisted", "legacy"].map { id in
    RecentDocument(
      id: id,
      title: "\(id).pdf",
      lastOpened: Date(timeIntervalSince1970: id == "persisted" ? 20 : 10),
      thumbnailCachePath: originalStore.thumbnailURL(for: id).path,
      bookmarkData: Data(id.utf8)
    )
  }
  for document in documents {
    try Data(document.id.utf8).write(to: originalStore.thumbnailURL(for: document.id))
    try originalStore.upsert(document)
  }

  let movedDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("PDFMathReader-Moved-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.copyItem(at: originalDirectory, to: movedDirectory)
  defer { try? FileManager.default.removeItem(at: movedDirectory) }

  let movedStore = RecentsStore(directory: movedDirectory)
  let movedDocuments = Dictionary(
    uniqueKeysWithValues: movedStore.list().map { ($0.id, $0) }
  )
  for id in ["persisted", "legacy"] {
    #expect(movedDocuments[id]?.thumbnailCachePath == movedStore.thumbnailURL(for: id).path)
  }

  let persistedDocument = try #require(movedDocuments["persisted"])
  try movedStore.upsert(persistedDocument)
  let persistedData = try Data(
    contentsOf: movedDirectory.appendingPathComponent("recents.json")
  )
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let persisted = try decoder.decode([RecentDocument].self, from: persistedData)
  #expect(persisted.first(where: { $0.id == "persisted" })?.thumbnailCachePath ==
    movedStore.thumbnailURL(for: "persisted").path)

  try movedStore.remove(id: "persisted")
  #expect(!FileManager.default.fileExists(atPath: movedStore.thumbnailURL(for: "persisted").path))
  #expect(FileManager.default.fileExists(atPath: originalStore.thumbnailURL(for: "persisted").path))

  try movedStore.clearHistory()
  #expect(movedStore.list().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: movedStore.thumbnailURL(for: "legacy").path))
  #expect(FileManager.default.fileExists(atPath: originalStore.thumbnailURL(for: "legacy").path))
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

@Test func autoAlignDocumentWidthDefaultsFalseAndRoundTrips() throws {
  let defaults = ReaderPreferences()
  #expect(!defaults.autoAlignDocumentWidth)

  let legacy = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data("{}".utf8)
  )
  #expect(!legacy.autoAlignDocumentWidth)

  var preferences = legacy
  preferences.autoAlignDocumentWidth = true
  let encoded = try JSONEncoder().encode(preferences)
  let persisted = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(persisted["autoAlignDocumentWidth"] as? Bool == true)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: encoded) == preferences)
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

@Test func keepAwakePreferenceDefaultsAndPersistsOptOut() throws {
  #expect(ReaderPreferences().keepAwakeWhileReading)
  let legacy = try JSONDecoder().decode(ReaderPreferences.self, from: Data("{}".utf8))
  #expect(legacy.keepAwakeWhileReading)

  var preferences = legacy
  preferences.keepAwakeWhileReading = false
  let data = try JSONEncoder().encode(preferences)
  let restored = try JSONDecoder().decode(ReaderPreferences.self, from: data)
  #expect(!restored.keepAwakeWhileReading)
}
