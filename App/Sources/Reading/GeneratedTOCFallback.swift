import Foundation
import PDFKit
import ReaderCore

/// Generates an outline only when the PDF does not provide one.
public func generatedTOCFallback(
  for document: PDFDocument,
  enabled: Bool = true
) -> [TOCItem] {
  guard enabled, !documentHasOutline(document) else { return [] }

  let extractor = PDFKitTextExtractor()
  var pages: [TOCPage] = []
  pages.reserveCapacity(document.pageCount)
  for pageIndex in 0..<document.pageCount {
    guard let page = document.page(at: pageIndex) else { continue }
    let bounds = page.bounds(for: .cropBox)
    let items = extractor.extract(page: page, pageNumber: pageIndex + 1)
    pages.append(
      TOCPage(
        number: pageIndex + 1,
        width: Double(bounds.width),
        height: Double(bounds.height),
        lines: TOCGenerator.buildLines(
          items,
          number: pageIndex + 1,
          width: Double(bounds.width),
          height: Double(bounds.height)
        )
      )
    )
  }
  return generateTOC(pages).items
}

@MainActor
public final class GeneratedTOCFallbackProvider {
  public let document: PDFDocument
  public var enabled: Bool
  private var cachedItems: [TOCItem]?

  public init(document: PDFDocument, enabled: Bool = true) {
    self.document = document
    self.enabled = enabled
  }

  public func items() -> [TOCItem] {
    guard enabled else { return [] }
    if let cachedItems { return cachedItems }
    let result = generatedTOCFallback(for: document, enabled: enabled)
    cachedItems = result
    return result
  }

  public func invalidate() {
    cachedItems = nil
  }
}

private func documentHasOutline(_ document: PDFDocument) -> Bool {
  guard let root = document.outlineRoot else { return false }
  return root.numberOfChildren > 0
}
