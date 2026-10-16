import CryptoKit
import Foundation

@preconcurrency import PDFKit

public enum MathPageTranslatorError: Error, LocalizedError, Sendable, Equatable {
  case invalidPage
  case invalidDocument
  case cacheMiss

  public var errorDescription: String? {
    switch self {
    case .invalidPage:
      return ReaderLocalization.resolve("Page is out of range")
    case .invalidDocument:
      return ReaderLocalization.resolve("The PDF document cannot be serialized")
    case .cacheMiss:
      return ReaderLocalization.resolve("No cached translated page exists")
    }
  }
}

/// Translates and caches a single PDF page through a remote math kernel: a
/// zotero-pdf2zh server, or PDFMathReader on the user's computer.
///
/// PDFKit is main-actor bound by the app, so page extraction and cache I/O are
/// kept on the main actor while the network work remains isolated in the
/// kernel client actors.
@MainActor
public final class MathPageTranslator {
  public let client: RemoteKernelClient
  public let companionClient: CompanionKernelClient
  public let cacheDirectory: URL

  private struct PendingPage {
    let id: UUID
    let task: Task<Data, Error>
    var waiters: Set<UUID>
  }
  private static var pending: [String: PendingPage] = [:]
  private let fileManager: FileManager

  public init(
    client: RemoteKernelClient,
    companionClient: CompanionKernelClient = CompanionKernelClient(),
    cacheDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.client = client
    self.companionClient = companionClient
    self.fileManager = fileManager
    self.cacheDirectory =
      cacheDirectory
      ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PDFMathReader/remote-math-pages", isDirectory: true)
  }

  /// pageIndex is zero-based, as used by PDFKit.
  public func translatePage(
    document: PDFDocument,
    pageIndex: Int,
    serverURL: String,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "",
    engine: String = "pdf_math_precise",
    threads: Int = 2,
    cacheScope: String = "",
    forceRetranslation: Bool = false,
    reuseTranslations: Bool = false,
    cacheOnly: Bool = false,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    let normalizedURL = normalizeRemoteKernelUrl(serverURL)
    guard !normalizedURL.isEmpty else { throw RemoteKernelError.invalidServerURL }
    let client = client
    return try await translate(
      document: document,
      pageIndex: pageIndex,
      forceRetranslation: forceRetranslation,
      reuseTranslations: reuseTranslations,
      cacheOnly: cacheOnly,
      cacheScope: cacheScope,
      descriptor: { pageNumber in
        Self.remoteDescriptor(
          serverURL: normalizedURL,
          pageNumber: pageNumber,
          language: language,
          sourceLanguage: sourceLanguage,
          service: service,
          engine: engine,
          cacheScope: cacheScope
        )
      },
      run: { onePage in
        try await client.translatePage(
          url: normalizedURL,
          bytes: onePage,
          page: 1,
          language: language,
          sourceLanguage: sourceLanguage,
          service: service,
          threads: threads,
          onProgress: onProgress
        )
      }
    )
  }

  /// Translates a page with the Fast or Precise kernel of PDFMathReader on
  /// the user's computer. pageIndex is zero-based. The pairing code is not part
  /// of the cache key, so re-pairing keeps translated pages.
  public func translatePage(
    document: PDFDocument,
    pageIndex: Int,
    companionURL: String,
    pairingCode: String,
    language: String,
    sourceLanguage: String? = nil,
    engine: String,
    service: String = "auto",
    glossary: [GlossaryEntry] = [],
    cacheScope: String = "",
    forceRetranslation: Bool = false,
    reuseTranslations: Bool = false,
    cacheOnly: Bool = false,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    let normalizedURL = normalizeCompanionURL(companionURL)
    guard !normalizedURL.isEmpty else { throw CompanionKernelError.invalidServerURL }
    let companionClient = companionClient
    return try await translate(
      document: document,
      pageIndex: pageIndex,
      forceRetranslation: forceRetranslation,
      reuseTranslations: reuseTranslations,
      cacheOnly: cacheOnly,
      cacheScope: cacheScope,
      descriptor: { pageNumber in
        [
          "companion": 1,
          "id": engine,
          "url": normalizedURL,
          "page": pageNumber,
          "language": language,
          "sourceLanguage": sourceLanguage ?? "English",
          "service": service,
          "glossary": glossary.map { [$0.source, $0.target] },
          "layoutSchema": 1,
          "cacheScope": cacheScope,
        ]
      },
      run: { onePage in
        try await companionClient.translatePage(
          url: normalizedURL,
          pairingCode: pairingCode,
          bytes: onePage,
          engine: engine,
          language: language,
          sourceLanguage: sourceLanguage,
          service: service,
          glossary: glossary,
          onProgress: onProgress
        )
      }
    )
  }

  private func translate(
    document: PDFDocument,
    pageIndex: Int,
    forceRetranslation: Bool,
    reuseTranslations: Bool,
    cacheOnly: Bool,
    cacheScope: String,
    descriptor: (Int) -> [String: Any],
    run: @escaping @MainActor (Data) async throws -> Data
  ) async throws -> Data {
    try Task.checkCancellation()
    guard pageIndex >= 0, pageIndex < document.pageCount else {
      throw MathPageTranslatorError.invalidPage
    }
    guard let sourcePage = document.page(at: pageIndex) else {
      throw MathPageTranslatorError.invalidDocument
    }
    // A stable document identity avoids PDFKit's regenerated metadata and
    // annotation changes invalidating translations on each open.
    let sourceData: Data
    if cacheScope.isEmpty {
      guard let data = document.dataRepresentation() else {
        throw MathPageTranslatorError.invalidDocument
      }
      sourceData = data
    } else {
      sourceData = Data(cacheScope.utf8)
    }
    let options = descriptor(pageIndex + 1)
    let key = try cacheKey(sourceData: sourceData, descriptor: options)
    var compatible = options
    for field in ["url", "service", "remote", "companion", "layoutSchema"] {
      compatible.removeValue(forKey: field)
    }
    compatible["compatibleSchema"] = 1
    let compatibleKey = try cacheKey(sourceData: sourceData, descriptor: compatible)
    let directory = cacheScope.isEmpty ? cacheDirectory : cacheDirectory
      .appendingPathComponent("documents", isDirectory: true)
      .appendingPathComponent(sha256Hex(Data(cacheScope.utf8)), isDirectory: true)
      .appendingPathComponent(sha256Hex(Data((options["id"] as? String ?? "math").utf8)), isDirectory: true)
    let resultURL = directory.appendingPathComponent(key).appendingPathExtension("pdf")
    let compatibleURL = directory.appendingPathComponent(compatibleKey).appendingPathExtension("pdf")

    if !forceRetranslation {
      let candidates = reuseTranslations ? [resultURL, compatibleURL] : [resultURL]
      for url in candidates {
        if let cached = try? readCachedPDF(at: url) { return cached }
      }
      // Import pre-document-directory entries once; a cache upgrade must not
      // repeat a translation that has already completed.
      if !cacheScope.isEmpty, let serialized = document.dataRepresentation() {
        var legacy = options
        if legacy["remote"] != nil { legacy.removeValue(forKey: "glossary") }
        if legacy["companion"] != nil, legacy["sourceLanguage"] as? String == "English" {
          legacy["sourceLanguage"] = ""
        }
        let legacyKey = try cacheKey(sourceData: serialized, descriptor: legacy)
        let legacyURL = cacheDirectory.appendingPathComponent(legacyKey).appendingPathExtension("pdf")
        if let cached = try? readCachedPDF(at: legacyURL) {
          try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
          try? cached.write(to: resultURL, options: .atomic)
          try? cached.write(to: compatibleURL, options: .atomic)
          return cached
        }
      }
    }
    if cacheOnly { throw MathPageTranslatorError.cacheMiss }
    try Task.checkCancellation()
    let flightKey = (reuseTranslations ? compatibleURL.path : resultURL.path)
      + (forceRetranslation ? ":force" : "")
    let waiter = UUID()
    let pending: PendingPage
    if let existing = Self.pending[flightKey] {
      pending = existing
    } else {
      let onePage = try makeSinglePage(sourcePage)
      let writeDestinations = [resultURL.path, compatibleURL.path]
      let ticket = TranslationCacheWriteTickets.shared.issue(destinations: writeDestinations)
      let task = Task { @MainActor in
        let result = try await run(onePage)
        try Task.checkCancellation()
        guard PDFDocument(data: result)?.pageCount == 1 else {
          throw RemoteKernelError.invalidPDF
        }
        // Cache failures must never discard a successful paid request.
        TranslationCacheWriteTickets.shared.withCurrentTicket(ticket, destinations: writeDestinations) {
          try? self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
          try? result.write(to: resultURL, options: .atomic)
          try? result.write(to: compatibleURL, options: .atomic)
        }
        return result
      }
      pending = PendingPage(id: UUID(), task: task, waiters: [])
      Self.pending[flightKey] = pending
    }
    Self.pending[flightKey]?.waiters.insert(waiter)
    defer { Self.releasePending(flightKey, id: pending.id, waiter: waiter) }
    return try await withTaskCancellationHandler {
      let result = try await pending.task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      Task { @MainActor in
        Self.releasePending(flightKey, id: pending.id, waiter: waiter)
      }
    }
  }

  private static func releasePending(_ key: String, id: UUID, waiter: UUID) {
    guard var value = pending[key], value.id == id,
      value.waiters.remove(waiter) != nil else { return }
    if value.waiters.isEmpty {
      pending.removeValue(forKey: key)
      value.task.cancel()
    } else {
      pending[key] = value
    }
  }

  /// One-based convenience overload for parity with the desktop request API.
  public func translatePage(
    document: PDFDocument,
    pageNumber: Int,
    serverURL: String,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "",
    engine: String = "pdf_math_precise",
    threads: Int = 2,
    cacheScope: String = "",
    forceRetranslation: Bool = false,
    reuseTranslations: Bool = false,
    cacheOnly: Bool = false,
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    try await translatePage(
      document: document,
      pageIndex: pageNumber - 1,
      serverURL: serverURL,
      language: language,
      sourceLanguage: sourceLanguage,
      service: service,
      engine: engine,
      threads: threads,
      cacheScope: cacheScope,
      forceRetranslation: forceRetranslation,
      reuseTranslations: reuseTranslations,
      cacheOnly: cacheOnly,
      onProgress: onProgress
    )
  }

  public func cacheURL(
    document: PDFDocument,
    pageIndex: Int,
    serverURL: String,
    language: String,
    sourceLanguage: String? = nil,
    service: String = "",
    engine: String = "pdf_math_precise",
    cacheScope: String = ""
  ) throws -> URL {
    guard pageIndex >= 0, pageIndex < document.pageCount,
      let sourceData = document.dataRepresentation()
    else {
      throw MathPageTranslatorError.invalidDocument
    }
    let normalizedURL = normalizeRemoteKernelUrl(serverURL)
    guard !normalizedURL.isEmpty else { throw RemoteKernelError.invalidServerURL }
    let key = try cacheKey(
      sourceData: cacheScope.isEmpty ? sourceData : Data(cacheScope.utf8),
      descriptor: Self.remoteDescriptor(
        serverURL: normalizedURL,
        pageNumber: pageIndex + 1,
        language: language,
        sourceLanguage: sourceLanguage,
        service: service,
        engine: engine,
        cacheScope: cacheScope
      )
    )
    let directory = cacheScope.isEmpty ? cacheDirectory : cacheDirectory
      .appendingPathComponent("documents", isDirectory: true)
      .appendingPathComponent(sha256Hex(Data(cacheScope.utf8)), isDirectory: true)
      .appendingPathComponent(sha256Hex(Data(engine.utf8)), isDirectory: true)
    return directory.appendingPathComponent(key).appendingPathExtension("pdf")
  }

  public func removeCachedPage(at url: URL) throws {
    try fileManager.removeItem(at: url)
  }

  private func makeSinglePage(_ sourcePage: PDFPage) throws -> Data {
    let output = PDFDocument()
    let page = (sourcePage.copy() as? PDFPage) ?? sourcePage
    output.insert(page, at: 0)
    guard let data = output.dataRepresentation() else {
      throw MathPageTranslatorError.invalidDocument
    }
    return data
  }

  private func readCachedPDF(at url: URL) throws -> Data? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard data.prefix(1024).range(of: Data("%PDF".utf8)) != nil,
      PDFDocument(data: data)?.pageCount == 1
    else {
      try? fileManager.removeItem(at: url)
      return nil
    }
    return data
  }

  private static func remoteDescriptor(
    serverURL: String,
    pageNumber: Int,
    language: String,
    sourceLanguage: String?,
    service: String,
    engine: String,
    cacheScope: String
  ) -> [String: Any] {
    [
      "remote": 1,
      "glossary": [[String]](),
      "id": engine,
      "url": serverURL,
      "service": service.trimmingCharacters(in: .whitespacesAndNewlines),
      "page": pageNumber,
      "language": language,
      "sourceLanguage": sourceLanguage ?? "English",
      "layoutSchema": 3,
      "cacheScope": cacheScope,
    ]
  }

  private func cacheKey(sourceData: Data, descriptor: [String: Any]) throws -> String {
    let descriptorData = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
    var input = Data()
    input.append(Self.stablePDFData(sourceData))
    input.append(descriptorData)
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  private static func stablePDFData(_ data: Data) -> Data {
    // PDFKit regenerates the trailer identifier on every serialization. It is
    // not document content and would otherwise make the page cache miss.
    let text = String(decoding: data, as: UTF8.self)
    guard let expression = try? NSRegularExpression(
      pattern: #"/ID\s*\[\s*<[^>]*>\s*<[^>]*>\s*\]"#
    ) else {
      return data
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let normalized = expression.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: "/ID []"
    )
    return Data(normalized.utf8)
  }
}


