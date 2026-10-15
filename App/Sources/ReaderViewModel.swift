import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

struct SearchResult: Identifiable, Hashable {
  let id: String
  let page: Int
  let text: String
}

struct OutlineEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let page: Int?
  let depth: Int
}

@MainActor
final class ReaderViewModel: ObservableObject {
  let session: DocumentSession
  let document: PDFDocument?
  let library: LibraryModel
  let pdfViewReference = PDFViewReference()

  @Published var readingState: ReadingState
  @Published var searchQuery = ""
  @Published private(set) var searchResults: [SearchResult] = []
  @Published private(set) var translationCoordinator: ReaderTranslationCoordinator?
  // Generated TOC extracts every page, so compute it once per document.
  private var cachedGeneratedTOC: [OutlineEntry]?

  init(session: DocumentSession, library: LibraryModel) {
    self.session = session
    self.library = library
    self.readingState = library.readingState(for: session)
    self.document = PDFDocument(url: session.url)
    self.translationCoordinator = nil
    if let document {
      library.updateDocumentMetadata(for: session, document: document)
      cacheThumbnail(document: document)
      translationCoordinator = ReaderTranslationCoordinator(
        document: document,
        documentID: session.id,
        preferences: library.preferences
      )
    }
  }

  var pageCount: Int { document?.pageCount ?? 0 }

  var outlineEntries: [OutlineEntry] {
    if let root = document?.outlineRoot {
      var entries: [OutlineEntry] = []
      appendOutlineEntries(from: root, depth: 0, path: "", into: &entries)
      if !entries.isEmpty { return entries }
    }
    guard let document, library.preferences.tocGenerationEnabled else { return [] }
    if let cachedGeneratedTOC { return cachedGeneratedTOC }
    let generated = generatedTOCFallback(for: document).map { item in
      OutlineEntry(id: item.id, title: item.title, page: item.page, depth: item.depth)
    }
    cachedGeneratedTOC = generated
    return generated
  }

  func receivePDFViewState(_ view: PDFView) {
    var next = readingState
    if let page = view.currentPage, let document {
      let index = document.index(for: page)
      if index != NSNotFound { next.page = index + 1 }
    }
    if readingState.scaleMode == .custom {
      next.zoom = Double(view.scaleFactor)
    }
    if next != readingState {
      readingState = next
      persistReadingState()
    }
  }

  func goToPage(_ page: Int) {
    let page = max(1, min(pageCount, page))
    guard pageCount > 0 else { return }
    readingState.page = page
    persistReadingState()
    if let target = document?.page(at: page - 1) {
      pdfViewReference.view?.go(to: target)
    }
  }

  func movePage(by offset: Int) {
    goToPage(readingState.page + offset)
  }

  func zoomIn() {
    guard let view = pdfViewReference.view else { return }
    view.autoScales = false
    view.zoomIn(nil)
    readingState.scaleMode = .custom
    readingState.zoom = Double(view.scaleFactor)
    persistReadingState()
  }

  func zoomOut() {
    guard let view = pdfViewReference.view else { return }
    view.autoScales = false
    view.zoomOut(nil)
    readingState.scaleMode = .custom
    readingState.zoom = Double(view.scaleFactor)
    persistReadingState()
  }

  func setScaleMode(_ mode: ReaderScaleMode) {
    readingState.scaleMode = mode
    if mode == .custom, let view = pdfViewReference.view {
      readingState.zoom = Double(view.scaleFactor)
    }
    persistReadingState()
  }

  func setDisplayMode(_ mode: ReaderDisplayMode) {
    readingState.displayMode = mode
    persistReadingState()
  }

  func setScrollDirection(_ direction: ReaderScrollDirection) {
    readingState.scrollDirection = direction
    persistReadingState()
  }

  func toggleSidebar() {
    readingState.sidebarVisible.toggle()
    persistReadingState()
  }

  func search() {
    guard let document, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      searchResults = []
      return
    }
    let selections = document.findString(searchQuery, withOptions: [.caseInsensitive])
    searchResults = selections.enumerated().compactMap { index, selection in
      guard let page = selection.pages.first else { return nil }
      let pageIndex = document.index(for: page)
      guard pageIndex != NSNotFound else { return nil }
      let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines)
      return SearchResult(
        id: "\(pageIndex)-\(index)-\(text ?? "")",
        page: pageIndex + 1,
        text: text?.isEmpty == false ? text! : "Page \(pageIndex + 1)"
      )
    }
  }

  func clearSearch() {
    searchQuery = ""
    searchResults = []
  }

  func updateTranslationPreferences(_ preferences: ReaderPreferences) {
    translationCoordinator?.updatePreferences(preferences)
  }

  func toggleTranslations() {
    translationCoordinator?.toggleTranslations()
    guard let visible = translationCoordinator?.showTranslations else { return }
    var preferences = library.preferences
    preferences.showTranslations = visible
    library.savePreferences(preferences)
  }

  func persistReadingState() {
    library.saveReadingState(readingState, for: session)
  }

  private func appendOutlineEntries(
    from outline: PDFOutline,
    depth: Int,
    path: String,
    into entries: inout [OutlineEntry]
  ) {
    for index in 0..<outline.numberOfChildren {
      guard let child = outline.child(at: index) else { continue }
      let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
      var pageNumber: Int?
      if let page = child.destination?.page, let document {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound { pageNumber = pageIndex + 1 }
      }
      entries.append(
        OutlineEntry(
          id: childPath,
          title: child.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? child.label!
            : "Untitled section",
          page: pageNumber,
          depth: depth
        )
      )
      appendOutlineEntries(from: child, depth: depth + 1, path: childPath, into: &entries)
    }
  }

  private func cacheThumbnail(document: PDFDocument) {
    guard let page = document.page(at: 0) else { return }
    let image = page.thumbnail(of: CGSize(width: 480, height: 640), for: .mediaBox)
    guard let data = image.pngData() else { return }
    library.cacheThumbnail(data, for: session)
  }
}
