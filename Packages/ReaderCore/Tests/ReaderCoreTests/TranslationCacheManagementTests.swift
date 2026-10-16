import Foundation
import Testing

@testable import ReaderCore

@Suite(.serialized)
struct TranslationCacheManagementTests {
  @Test
  func documentClearIsScopedAndAdvancesGeneration() throws {
    let (root, paragraphDirectory, mathDirectory) = try makeCacheRoots()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = TranslationCacheManagement(
      paragraphDirectory: paragraphDirectory,
      mathDirectory: mathDirectory
    )

    let documentID = "doc-a"
    let otherDocumentID = "doc-b"
    let initialScope = manager.scope(documentID: documentID)
    #expect(initialScope == documentID)
    try writeCacheFile(
      paragraphDirectory
        .appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(initialScope, isDirectory: true)
        .appendingPathComponent("paragraph.json"),
      bytes: 3
    )
    try writeCacheFile(
      mathDirectory
        .appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(sha256Hex(Data(initialScope.utf8)), isDirectory: true)
        .appendingPathComponent("page.png"),
      bytes: 3
    )
    try writeCacheFile(
      paragraphDirectory
        .appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(otherDocumentID, isDirectory: true)
        .appendingPathComponent("paragraph.json"),
      bytes: 5
    )

    try manager.clear(documentID: documentID)
    let generatedScope = manager.scope(documentID: documentID)
    #expect(generatedScope != initialScope)
    #expect(!FileManager.default.fileExists(
      atPath: paragraphDirectory
        .appendingPathComponent("documents/doc-a/paragraph.json").path
    ))
    #expect(!FileManager.default.fileExists(
      atPath: mathDirectory
        .appendingPathComponent("documents/\(sha256Hex(Data(initialScope.utf8)))/page.png").path
    ))
    #expect(FileManager.default.fileExists(
      atPath: paragraphDirectory
        .appendingPathComponent("documents/doc-b/paragraph.json").path
    ))

    // A second clear must remove the generated math scope too.
    try writeCacheFile(
      mathDirectory
        .appendingPathComponent("documents", isDirectory: true)
        .appendingPathComponent(sha256Hex(Data(generatedScope.utf8)), isDirectory: true)
        .appendingPathComponent("page.png"),
      bytes: 3
    )
    try manager.clear(documentID: documentID)
    #expect(!FileManager.default.fileExists(
      atPath: mathDirectory
        .appendingPathComponent("documents/\(sha256Hex(Data(generatedScope.utf8)))/page.png").path
    ))
    #expect(manager.scope(documentID: documentID) != generatedScope)
  }

  @Test
  func clearPreservesGenerationMarkersAndGlobalClearRemovesRoots() throws {
    let (root, paragraphDirectory, mathDirectory) = try makeCacheRoots()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = TranslationCacheManagement(
      paragraphDirectory: paragraphDirectory,
      mathDirectory: mathDirectory
    )
    let documentID = "document"

    try writeCacheFile(
      paragraphDirectory.appendingPathComponent("documents/document/value.json"),
      bytes: 7
    )
    try manager.clear(documentID: documentID)
    let generationDirectory = paragraphDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("translation-cache-generations", isDirectory: true)
    let documentMarker = generationDirectory
      .appendingPathComponent(sha256Hex(Data(documentID.utf8)))
    #expect(FileManager.default.fileExists(atPath: documentMarker.path))
    let documentScope = manager.scope(documentID: documentID)

    try writeCacheFile(
      mathDirectory.appendingPathComponent("documents/other/value.json"),
      bytes: 11
    )
    try manager.clear()
    let globalMarker = generationDirectory.appendingPathComponent("global")
    #expect(manager.scope(documentID: documentID) != documentScope)
    #expect(FileManager.default.fileExists(atPath: documentMarker.path))
    #expect(FileManager.default.fileExists(atPath: globalMarker.path))
    #expect(!FileManager.default.fileExists(atPath: paragraphDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: mathDirectory.path))
  }

  @Test
  func trimEvictsOldestFilesAcrossBothRoots() throws {
    let (root, paragraphDirectory, mathDirectory) = try makeCacheRoots()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = TranslationCacheManagement(
      paragraphDirectory: paragraphDirectory,
      mathDirectory: mathDirectory
    )
    let oldFile = paragraphDirectory.appendingPathComponent("old.bin")
    let middleFile = mathDirectory.appendingPathComponent("middle.bin")
    let newestFile = paragraphDirectory.appendingPathComponent("newest.bin")
    try writeCacheFile(oldFile, bytes: 4)
    try writeCacheFile(middleFile, bytes: 4)
    try writeCacheFile(newestFile, bytes: 4)
    let dates = [
      oldFile: Date(timeIntervalSince1970: 10),
      middleFile: Date(timeIntervalSince1970: 20),
      newestFile: Date(timeIntervalSince1970: 30),
    ]
    for (url, date) in dates {
      try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: url.path
      )
    }

    #expect(manager.usageBytes() == 12)
    let finalUsage = try manager.trim(toBytes: 5)
    #expect(finalUsage == 4)
    #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    #expect(!FileManager.default.fileExists(atPath: middleFile.path))
    #expect(FileManager.default.fileExists(atPath: newestFile.path))
    #expect(try manager.trim(toBytes: nil) == 4)
  }
}

private func makeCacheRoots() throws -> (URL, URL, URL) {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("reader-core-cache-\(UUID().uuidString)", isDirectory: true)
  let paragraphDirectory = root.appendingPathComponent("paragraph", isDirectory: true)
  let mathDirectory = root.appendingPathComponent("math", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  return (root, paragraphDirectory, mathDirectory)
}

private func writeCacheFile(_ url: URL, bytes: Int) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(repeating: 0xA5, count: bytes).write(to: url)
}
