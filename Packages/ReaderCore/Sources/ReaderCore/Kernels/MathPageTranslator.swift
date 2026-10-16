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
      return "Page is out of range"
    case .invalidDocument:
      return "The PDF document cannot be serialized"
    case .cacheMiss:
      return "No cached translated page exists"
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
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    let normalizedURL = normalizeRemoteKernelUrl(serverURL)
    guard !normalizedURL.isEmpty else { throw RemoteKernelError.invalidServerURL }
    let client = client
    return try await translate(
      document: document,
      pageIndex: pageIndex,
      forceRetranslation: forceRetranslation,
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
    onProgress: (@Sendable (RemoteKernelProgress) -> Void)? = nil
  ) async throws -> Data {
    let normalizedURL = normalizeCompanionURL(companionURL)
    guard !normalizedURL.isEmpty else { throw CompanionKernelError.invalidServerURL }
    let companionClient = companionClient
    return try await translate(
      document: document,
      pageIndex: pageIndex,
      forceRetranslation: forceRetranslation,
      descriptor: { pageNumber in
        [
          "companion": 1,
          "id": engine,
          "url": normalizedURL,
          "page": pageNumber,
          "language": language,
          "sourceLanguage": sourceLanguage ?? "",
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
    descriptor: (Int) -> [String: Any],
    run: (Data) async throws -> Data
  ) async throws -> Data {
    try Task.checkCancellation()
    guard pageIndex >= 0, pageIndex < document.pageCount else {
      throw MathPageTranslatorError.invalidPage
    }
    guard let sourceData = document.dataRepresentation(),
      let sourcePage = document.page(at: pageIndex)
    else {
      throw MathPageTranslatorError.invalidDocument
    }
    let onePage = try makeSinglePage(sourcePage)
    let key = try cacheKey(sourceData: sourceData, descriptor: descriptor(pageIndex + 1))
    let resultURL = cacheDirectory.appendingPathComponent(key).appendingPathExtension("pdf")

    if !forceRetranslation {
      do {
        if let cached = try readCachedPDF(at: resultURL) {
          return cached
        }
      } catch {
        try? fileManager.removeItem(at: resultURL)
      }
    }
    try Task.checkCancellation()
    let result = try await run(onePage)
    try Task.checkCancellation()
    guard PDFDocument(data: result)?.pageCount == 1 else {
      throw RemoteKernelError.invalidPDF
    }
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try result.write(to: resultURL, options: .atomic)
    return result
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
      sourceData: sourceData,
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
    return cacheDirectory.appendingPathComponent(key).appendingPathExtension("pdf")
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


