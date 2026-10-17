import CryptoKit
import Foundation
import PDFKit
import ReaderCore
import UIKit
import WebKit

/// Errors raised while turning an EPUB package into a PDF document.
enum EPUBConversionError: LocalizedError {
  case invalidPackage(String?)
  case cacheUnavailable
  case emptyBook
  case chapterFailed(String, String)
  case chapterTimedOut(String)
  case webContentTerminated
  case outputTooLarge
  case tooManyPages
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case let .invalidPackage(detail):
      let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return detail.isEmpty
        ? "The EPUB package is invalid or cannot be read."
        : "The EPUB package is invalid or cannot be read: \(detail)"
    case .cacheUnavailable:
      return "The EPUB conversion cache is unavailable."
    case .emptyBook:
      return "The EPUB has no printable chapters."
    case let .chapterFailed(path, message):
      return "The EPUB chapter \(path) could not be rendered: \(message)"
    case let .chapterTimedOut(path):
      return "The EPUB chapter \(path) timed out while loading."
    case .webContentTerminated:
      return "The EPUB renderer stopped unexpectedly."
    case .outputTooLarge:
      return "The converted EPUB exceeds the PDF size limit."
    case .tooManyPages:
      return "The converted EPUB has too many pages."
    case .invalidOutput:
      return "The EPUB did not produce a valid PDF."
    }
  }
}

/// Converts a read-only EPUB package into the PDF representation used by the
/// rest of the iOS reader.
enum EPUBConverter {
  // Keep this value in the cache key. Layout changes must invalidate old PDFs.
  private static let converterVersion = 2
  private static let maximumPDFBytes = 200 * 1024 * 1024
  private static let maximumPages = 10_000
  private static let chapterTimeout: TimeInterval = 30
  private static let epubScheme = "epub"
  private static let epubHost = "book"
  private static let pageRect = CGRect(x: 0, y: 0, width: 420, height: 595)
  private static let printableRect = pageRect.insetBy(dx: 30, dy: 30)
  @MainActor private static var inFlight: [String: Task<URL, Error>] = [:]

  /// Converts an EPUB to a durable, content-addressed PDF in `directory`.
  ///
  /// The method is main-actor isolated because WebKit and UIKit printing are
  /// main-thread APIs. Package parsing and hashing still happen off the main
  /// actor where possible.
  @MainActor
  static func convert(data: Data, directory: URL, fontName: String = "", serif: Bool = false) async throws -> URL {
    try Task.checkCancellation()

    let name = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
    let family = UIFont.familyNames.first { $0.caseInsensitiveCompare(name) == .orderedSame }
      ?? UIFont(name: name, size: 12)?.familyName ?? (serif ? "serif" : "")
    let key = cacheKey(for: data, fontFamily: family)
    let destination = directory.appendingPathComponent(key).appendingPathExtension("pdf")
    if isValidCachedPDF(at: destination) {
      return destination
    }

    let identity = "\(directory.standardizedFileURL.path):\(key)"
    if let existing = inFlight[identity] {
      return try await existing.value
    }
    let operation = Task { @MainActor in
      try await convertUncached(data: data, directory: directory, key: key, destination: destination, fontFamily: family)
    }
    inFlight[identity] = operation
    defer { inFlight.removeValue(forKey: identity) }
    return try await operation.value
  }

  @MainActor
  private static func convertUncached(
    data: Data,
    directory: URL,
    key: String,
    destination: URL,
    fontFamily: String
  ) async throws -> URL {

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw EPUBConversionError.cacheUnavailable
    }

    // A second caller can enter after the first await above. Recheck the
    // cache after creating the directory before doing any WebKit work.
    if isValidCachedPDF(at: destination) {
      return destination
    }

    let package: EPUBPackage
    do {
      package = try await Task.detached(priority: .userInitiated) {
        try EPUBPackage(data: data)
      }.value
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw EPUBConversionError.invalidPackage(error.localizedDescription)
    }
    try Task.checkCancellation()

    let pdfData = try await render(package: package, fontFamily: fontFamily)
    try Task.checkCancellation()
    guard pdfData.count <= maximumPDFBytes else {
      throw EPUBConversionError.outputTooLarge
    }
    guard PDFDocument(data: pdfData)?.pageCount ?? 0 > 0 else {
      throw EPUBConversionError.invalidOutput
    }

    // Do not overwrite an existing valid PDF. This is important because the
    // PDF is also the annotation store for converted EPUBs.
    if isValidCachedPDF(at: destination) {
      return destination
    }
    let temporary = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
    do {
      try pdfData.write(to: temporary, options: [.atomic])
      if FileManager.default.fileExists(atPath: destination.path),
         !isValidCachedPDF(at: destination) {
        try? FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch CocoaError.fileWriteFileExists {
      // A conversion racing from another process won the rename. Preserve
      // its valid result and do not replace its annotations.
      try? FileManager.default.removeItem(at: temporary)
      if isValidCachedPDF(at: destination) { return destination }
      throw EPUBConversionError.cacheUnavailable
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw EPUBConversionError.cacheUnavailable
    }
    return destination
  }

  @MainActor
  private static func render(package: EPUBPackage, fontFamily: String) async throws -> Data {
    guard !package.chapters.isEmpty else { throw EPUBConversionError.emptyBook }

    let files = EPUBAssetStore(files: package.files, mediaTypes: package.mediaTypes, fontFamily: fontFamily)
    let schemeHandler = EPUBSchemeHandler(store: files)
    let configuration = try await makeWebViewConfiguration(schemeHandler: schemeHandler)
    let webView = WKWebView(frame: pageRect, configuration: configuration)
    webView.isOpaque = true
    webView.backgroundColor = .white
    webView.scrollView.backgroundColor = .white
    webView.scrollView.contentInsetAdjustmentBehavior = .never

    defer {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      webView.removeFromSuperview()
    }

    let output = PDFDocument()
    var chapterStarts: [String: Int] = [:]
    var accumulatedPDFBytes = 0
    for chapter in package.chapters {
      try Task.checkCancellation()
      let path = normalizedAssetPath(chapter.path) ?? chapter.path
      guard files.data(for: path) != nil else {
        throw EPUBConversionError.chapterFailed(chapter.path, "The chapter file is missing.")
      }

      let chapterStart = output.pageCount
      do {
        let chapterURL = try epubURL(for: path)
        let waiter = WebViewLoadWaiter(webView: webView, timeout: chapterTimeout)
        try await withTaskCancellationHandler(operation: {
          try await waiter.load(chapterURL)
        }, onCancel: {
          Task { @MainActor in waiter.cancel() }
        })
        try Task.checkCancellation()

        let formatter = webView.viewPrintFormatter()
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")

        let pageCount = renderer.numberOfPages
        guard pageCount > 0 else {
          throw EPUBConversionError.chapterFailed(chapter.path, "The chapter has no printable pages.")
        }
        guard pageCount <= maximumPages, output.pageCount <= maximumPages - pageCount else {
          throw EPUBConversionError.tooManyPages
        }

        let chapterPDF = try print(renderer: renderer, pageCount: pageCount)
        guard chapterPDF.count <= maximumPDFBytes,
              accumulatedPDFBytes <= maximumPDFBytes - chapterPDF.count else {
          throw EPUBConversionError.outputTooLarge
        }
        accumulatedPDFBytes += chapterPDF.count
        guard let document = PDFDocument(data: chapterPDF), document.pageCount == pageCount else {
          throw EPUBConversionError.chapterFailed(chapter.path, "The printed chapter is not a valid PDF.")
        }
        chapterStarts[path] = chapterStart
        for index in 0..<document.pageCount {
          guard let page = document.page(at: index)?.copy() as? PDFPage else {
            throw EPUBConversionError.chapterFailed(chapter.path, "A printed page could not be copied.")
          }
          document.retainBacking(of: page)
          output.insert(page, at: output.pageCount)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as EPUBConversionError {
        throw error
      } catch {
        throw EPUBConversionError.chapterFailed(chapter.path, error.localizedDescription)
      }
    }

    guard output.pageCount > 0 else { throw EPUBConversionError.emptyBook }
    addMetadata(to: output, package: package)
    addOutline(to: output, package: package, chapterStarts: chapterStarts)
    guard output.pageCount <= maximumPages,
          let data = output.dataRepresentation(),
          data.count <= maximumPDFBytes else {
      throw EPUBConversionError.outputTooLarge
    }
    return data
  }

  @MainActor
  private static func makeWebViewConfiguration(schemeHandler: EPUBSchemeHandler) async throws -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: epubScheme)

    // CSP is injected into every HTML document by EPUBAssetStore. The rule
    // list is defense in depth for resources referenced from stylesheets or
    // malformed markup. A renderer without the rule list is not isolated
    // enough to process an untrusted book, so fail closed if compilation fails.
    let rules = try await compileNetworkBlockingRuleList()
    configuration.userContentController.add(rules)
    return configuration
  }

  private static func compileNetworkBlockingRuleList() async throws -> WKContentRuleList {
    let source = #"[{"trigger":{"url-filter":"^http:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ws:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss:"},"action":{"type":"block"}}]"#
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "PDFMathReader.EPUB.NetworkBlock.v1",
        encodedContentRuleList: source
      ) { list, error in
        if let list {
          continuation.resume(returning: list)
        } else {
          continuation.resume(throwing: error ?? EPUBConversionError.webContentTerminated)
        }
      }
    }
  }

  private static func print(renderer: UIPrintPageRenderer, pageCount: Int) throws -> Data {
    let data = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, pageRect, nil)
    var contextIsOpen = true
    defer {
      if contextIsOpen {
        UIGraphicsEndPDFContext()
      }
    }
    for page in 0..<pageCount {
      try Task.checkCancellation()
      UIGraphicsBeginPDFPageWithInfo(pageRect, nil)
      renderer.drawPage(at: page, in: pageRect)
    }
    UIGraphicsEndPDFContext()
    contextIsOpen = false
    return data as Data
  }

  private static func addMetadata(to document: PDFDocument, package: EPUBPackage) {
    var attributes = document.documentAttributes ?? [:]
    if !package.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      attributes[PDFDocumentAttribute.titleAttribute] = package.title
    }
    if !package.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      attributes[PDFDocumentAttribute.authorAttribute] = package.author
    }
    attributes[PDFDocumentAttribute.creatorAttribute] = "PDFMathReader"
    attributes[PDFDocumentAttribute.producerAttribute] = "PDFMathReader EPUB Converter"
    document.documentAttributes = attributes
  }

  private struct OutlineEntry {
    let path: String
    let title: String
    let fragment: String
    let depth: Int
  }

  private static func addOutline(
    to document: PDFDocument,
    package: EPUBPackage,
    chapterStarts: [String: Int]
  ) {
    var entries: [OutlineEntry] = []
    if package.navigation.isEmpty {
      entries = package.chapters.map {
        OutlineEntry(
          path: normalizedAssetPath($0.path) ?? $0.path,
          title: $0.title,
          fragment: "",
          depth: 0
        )
      }
    } else {
      entries = package.navigation.map {
        OutlineEntry(
          path: normalizedAssetPath($0.path) ?? $0.path,
          title: $0.title,
          fragment: $0.fragment ?? "",
          depth: max(0, $0.depth)
        )
      }
    }

    let root = PDFOutline()
    var stack: [(outline: PDFOutline, depth: Int)] = [(root, -1)]
    var seen = Set<String>()
    for entry in entries {
      guard let pageIndex = chapterStarts[entry.path],
            let page = document.page(at: pageIndex) else { continue }
      let key = "\(entry.path)#\(entry.fragment)"
      guard seen.insert(key).inserted else { continue }
      while stack.count > 1, stack.last?.depth ?? -1 >= entry.depth {
        stack.removeLast()
      }
      let item = PDFOutline()
      item.label = entry.title.isEmpty ? entry.path : entry.title
      item.destination = PDFDestination(
        page: page,
        at: CGPoint(x: page.bounds(for: .cropBox).minX, y: page.bounds(for: .cropBox).maxY)
      )
      stack[stack.count - 1].outline.insertChild(item, at: stack[stack.count - 1].outline.numberOfChildren)
      stack.append((item, entry.depth))
    }
    if root.numberOfChildren > 0 {
      document.outlineRoot = root
    }
  }

  private static func cacheKey(for data: Data, fontFamily: String) -> String {
    var input = Data("epub:\(converterVersion):".utf8)
    input.append(data)
    if !fontFamily.isEmpty { input.append(Data("\0font-v1:\(fontFamily)".utf8)) }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  private static func isValidCachedPDF(at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber,
          size.intValue > 0,
          size.intValue <= maximumPDFBytes,
          let document = PDFDocument(url: url),
          document.pageCount > 0 else {
      return false
    }
    return true
  }

  private static func epubURL(for path: String) throws -> URL {
    guard let normalized = normalizedAssetPath(path) else {
      throw EPUBConversionError.invalidPackage("The chapter path is not a safe package path.")
    }
    var components = URLComponents()
    components.scheme = epubScheme
    components.host = epubHost
    components.path = "/\(normalized)"
    guard let url = components.url else {
      throw EPUBConversionError.invalidPackage("The chapter URL could not be created.")
    }
    return url
  }

  fileprivate static func normalizedAssetPath(_ path: String) -> String? {
    // Archive keys are already canonicalized by EPUBPackage. URL.path is
    // decoded once by Foundation before the scheme handler sees it. Decoding
    // here again would make a literal `%20` archive name collide with a space
    // and could turn a literal `%2e%2e` component into traversal.
    guard !path.contains("\0"), !path.contains("\\") else { return nil }
    var parts: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
      default:
        parts.append(component)
      }
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "/")
  }
}

private final class EPUBAssetStore: @unchecked Sendable {
  private let values: [String: Data]
  private let mediaTypes: [String: String]

  init(files: [String: Data], mediaTypes: [String: String], fontFamily: String) {
    var values: [String: Data] = [:]
    var normalizedMediaTypes: [String: String] = [:]
    for (path, mediaType) in mediaTypes {
      guard let normalized = EPUBConverter.normalizedAssetPath(path) else { continue }
      normalizedMediaTypes[normalized] = mediaType
    }
    for (path, data) in files {
      guard let normalized = EPUBConverter.normalizedAssetPath(path) else { continue }
      values[normalized] = Self.preparedData(
        data,
        path: normalized,
        mediaType: normalizedMediaTypes[normalized],
        fontFamily: fontFamily
      )
    }
    self.values = values
    self.mediaTypes = normalizedMediaTypes
  }

  func data(for path: String) -> Data? {
    values[path]
  }

  func mimeType(for path: String) -> String {
    mediaTypes[path] ?? Self.fallbackMimeType(for: path)
  }

  func textEncodingName(for path: String) -> String? {
    let mimeType = mediaTypes[path]?.lowercased()
    if mimeType == "text/html" || mimeType == "application/xhtml+xml" || mimeType == "text/css" {
      return "utf-8"
    }
    return Self.isTextualExtension(path) ? "utf-8" : nil
  }

  private static func preparedData(_ data: Data, path: String, mediaType: String?, fontFamily: String) -> Data {
    let lower = path.lowercased()
    let normalizedMediaType = mediaType?.split(separator: ";", maxSplits: 1).first.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml") ||
      normalizedMediaType == "text/html" || normalizedMediaType == "application/xhtml+xml"
    else {
      return data
    }
    guard var html = String(data: data, encoding: .utf8) else { return data }
    // Escape every scalar so a font name cannot inject CSS or HTML. Use the
    // family, rather than a specific face, to preserve bold and italic text.
    let escapedFamily = fontFamily.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
    let cssFamily = fontFamily == "serif" ? "serif" : "\"\(escapedFamily)\""
    let fontRule = fontFamily.isEmpty ? "" : "body, body *:not(svg):not(svg *):not(math):not(math *) { font-family: \(cssFamily) !important; }"
    let style = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; script-src 'none'; img-src epub: data:; style-src 'self' epub: 'unsafe-inline'; font-src epub: data:; media-src epub: data:;" />
    <style data-pdfmathreader-epub="true">
    \(fontRule)
    @page { size: A5; margin: 0; }
    html { background: #fff !important; }
    body { margin: 0 !important; padding: 0 !important; color: #111 !important; background: #fff !important; }
    img, svg, video, canvas, table { max-width: 100% !important; }
    img, svg { height: auto; break-inside: avoid; }
    h1, h2, h3, h4, h5, h6 { break-after: avoid; }
    pre { white-space: pre-wrap; }
    </style>
    """
    if let headRange = html.range(of: "<head", options: [.caseInsensitive]) {
      if let close = html.range(of: ">", range: headRange.lowerBound..<html.endIndex) {
        html.insert(contentsOf: style, at: close.upperBound)
      } else {
        html = style + html
      }
    } else {
      html = style + html
    }
    return Data(html.utf8)
  }

  private static func isTextualExtension(_ path: String) -> Bool {
    switch path.lowercased().split(separator: ".").last.map(String.init) {
    case "html", "htm", "xhtml", "css", "xml", "ncx", "svg": return true
    default: return false
    }
  }

  private static func fallbackMimeType(for path: String) -> String {
    switch path.lowercased().split(separator: ".").last.map(String.init) {
    case "html", "htm": return "text/html"
    case "xhtml": return "application/xhtml+xml"
    case "css": return "text/css"
    case "xml", "ncx": return "application/xml"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    case "mp3": return "audio/mpeg"
    case "mp4": return "video/mp4"
    default: return "application/octet-stream"
    }
  }
}

private final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
  private let store: EPUBAssetStore

  init(store: EPUBAssetStore) {
    self.store = store
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url,
          url.scheme?.lowercased() == "epub",
          url.host?.lowercased() == "book",
          let path = EPUBConverter.normalizedAssetPath(url.path) else {
      urlSchemeTask.didFailWithError(EPUBConversionError.invalidPackage("The resource URL is outside the EPUB package."))
      return
    }
    // Let WebKit skip missing stylesheets, images and fonts like a browser.
    // Missing chapter documents still fail the preflight or navigation load.
    guard let data = store.data(for: path) else {
      urlSchemeTask.didFailWithError(EPUBConversionError.chapterFailed(path, "The resource is missing."))
      return
    }
    let response = URLResponse(
      url: url,
      mimeType: store.mimeType(for: path),
      expectedContentLength: data.count,
      textEncodingName: store.textEncodingName(for: path)
    )
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

}

@MainActor
private final class WebViewLoadWaiter: NSObject, WKNavigationDelegate, WKUIDelegate, @unchecked Sendable {
  private weak var webView: WKWebView?
  private let timeout: TimeInterval
  private var continuation: CheckedContinuation<Void, Error>?
  private var timeoutWorkItem: DispatchWorkItem?
  private var didCancel = false

  init(webView: WKWebView, timeout: TimeInterval) {
    self.webView = webView
    self.timeout = timeout
  }

  func load(_ url: URL) async throws {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      guard self.continuation == nil else {
        continuation.resume(throwing: EPUBConversionError.chapterFailed(url.path, "A load was already in progress."))
        return
      }
      self.continuation = continuation
      if didCancel {
        finish(.failure(CancellationError()))
        return
      }
      webView?.navigationDelegate = self
      webView?.uiDelegate = self
      guard webView?.load(URLRequest(url: url)) != nil else {
        finish(.failure(EPUBConversionError.chapterFailed(url.path, "The chapter could not be loaded.")))
        return
      }
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          self.webView?.stopLoading()
          self.finish(.failure(EPUBConversionError.chapterTimedOut(url.path)))
        }
      }
      timeoutWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }
  }

  func cancel() {
    didCancel = true
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    webView?.stopLoading()
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<Void, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    switch result {
    case .success:
      continuation.resume()
    case let .failure(error):
      continuation.resume(throwing: error)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finish(.success(()))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(.failure(error))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finish(.failure(error))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(EPUBConversionError.webContentTerminated))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(navigationAction.request.url?.scheme?.lowercased() == "epub" ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(navigationResponse.response.url?.scheme?.lowercased() == "epub" ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }
}
