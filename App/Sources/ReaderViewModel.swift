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

struct OutlineEntry: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let page: Int?
  let depth: Int
}

@MainActor
final class ReaderViewModel: ObservableObject {
  let session: DocumentSession
  @Published private(set) var document: PDFDocument?
  @Published private(set) var isLoadingDocument = true
  private var loadingDocument = false
  let library: LibraryModel
  let pdfViewReference = PDFViewReference()

  @Published var readingState: ReadingState
  @Published var searchQuery = ""
  @Published private(set) var searchResults: [SearchResult] = []
  @Published private(set) var translationCoordinator: ReaderTranslationCoordinator?
  // Generated TOC extracts every page, so compute it once per document.
  @Published private var cachedGeneratedTOC: [OutlineEntry]?
  private var cancellables = Set<AnyCancellable>()
  private var readingStateSaveTask: Task<Void, Never>?

  init(session: DocumentSession, library: LibraryModel) {
    self.session = session
    self.library = library
    self.readingState = library.readingState(for: session)
    if self.readingState.pageCrop == nil {
      let preferences = library.preferences
      self.readingState.pageCrop = preferences.defaultPageCropEnabled
        ? PageCrop(x: preferences.defaultPageCropX, y: preferences.defaultPageCropY)
        : PageCrop()
    }
    self.document = nil
    self.translationCoordinator = nil
    // The reader observes this model, not the nested LibraryModel. Apply
    // settings directly so completed overlays also update in another window.
    library.$preferences
      .removeDuplicates()
      .sink { [weak self] preferences in
        guard let self else { return }
        self.updateTranslationPreferences(preferences)
        self.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  /// Only opening the display document gates the reader. Translation and
  /// previews use separate PDFKit documents and never serialize this one.
  func loadDocument() async {
    guard document == nil, !loadingDocument else { return }
    loadingDocument = true
    isLoadingDocument = true
    defer { loadingDocument = false }
    let session = session
    let loaded = await Task.detached(priority: .userInitiated) {
      withExtendedLifetime(session.access) {
        LoadedReaderPDF(document: ReaderPDFDocument(url: session.url))
      }
    }.value
    guard !Task.isCancelled else { return }
    if let document = loaded.document {
      translationCoordinator = ReaderTranslationCoordinator(
        document: document, documentID: session.id, preferences: library.preferences
      )
      translationCoordinator?.$showTranslations
        .removeDuplicates()
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
      self.document = document
      isLoadingDocument = false
      library.updateDocumentMetadata(for: session, document: document)
      await library.prepareThumbnail(for: session)
    } else {
      isLoadingDocument = false
    }
  }

  var pageCount: Int { document?.pageCount ?? 0 }

  var outlineEntries: [OutlineEntry] {
    if let root = document?.outlineRoot {
      var entries: [OutlineEntry] = []
      appendOutlineEntries(from: root, depth: 0, path: "", into: &entries)
      if !entries.isEmpty { return entries }
    }
    guard library.preferences.tocGenerationEnabled else { return [] }
    return cachedGeneratedTOC ?? []
  }

  func loadGeneratedTOC() async {
    guard cachedGeneratedTOC == nil, library.preferences.tocGenerationEnabled else { return }
    let session = session
    let entries = await Task.detached(priority: .utility) {
      withExtendedLifetime(session.access) {
        guard let document = PDFDocument(url: session.url) else { return [OutlineEntry]() }
        return generatedTOCFallback(for: document).map { item in
          OutlineEntry(id: item.id, title: item.title, page: item.page, depth: item.depth)
        }
      }
    }.value
    guard !Task.isCancelled else { return }
    cachedGeneratedTOC = entries
  }

  func receivePDFViewState(_ view: PDFView) {
    var next = readingState
    // Annotation edits replace the view's document, so index its pages there.
    if let page = view.currentPage, let document = view.document ?? document {
      let index = document.index(for: page)
      if index != NSNotFound { next.page = index + 1 }
    }
    if let displayDocument = view.document {
      translationCoordinator?.updateViewport(
        currentPageIndex: next.page - 1,
        visiblePageIndices: view.visiblePages.compactMap { page in
          let index = displayDocument.index(for: page)
          return index == NSNotFound ? nil : index
        }
      )
    }
    if readingState.scaleMode == .custom {
      next.zoom = Double(view.scaleFactor)
    }
    if next != readingState {
      readingState = next
      // Page and pinch notifications arrive on the rendering path. Coalesce
      // their JSON writes until the viewport has stopped changing.
      readingStateSaveTask?.cancel()
      readingStateSaveTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        self?.persistReadingState()
      }
    }
  }

  func goToPage(_ page: Int) {
    let page = max(1, min(pageCount, page))
    guard pageCount > 0 else { return }
    readingState.page = page
    persistReadingState()
    if let view = pdfViewReference.view, let target = (view.document ?? document)?.page(at: page - 1) {
      if let reader = view as? ReaderAnnotationPDFView {
        reader.navigate(to: target)
      } else {
        view.go(to: target)
      }
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
    pdfViewReference.scaleRevision += 1
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

  func setPageCrop(_ crop: PageCrop) {
    readingState.pageCrop = crop
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
        text: text?.isEmpty == false
          ? text!
          : L10n.string("sidebar.page", String(pageIndex + 1))
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
  }

  func persistReadingState() {
    readingStateSaveTask?.cancel()
    readingStateSaveTask = nil
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
            : L10n.string("ios.untitledSection"),
          page: pageNumber,
          depth: depth
        )
      )
      appendOutlineEntries(from: child, depth: depth + 1, path: childPath, into: &entries)
    }
  }

}

/// A one-way ownership transfer: the worker stops touching the document
/// before the main actor installs it in PDFView.
private struct LoadedReaderPDF: @unchecked Sendable {
  let document: PDFDocument?
}
