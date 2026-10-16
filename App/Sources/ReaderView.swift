import PDFKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

private enum ReaderSidebarMode: String, CaseIterable {
  case thumbnails
  case outline
  case annotations

  var title: String {
    switch self {
    case .thumbnails: L10n.string("sidebar.thumbnails")
    case .outline: L10n.string("sidebar.outline")
    case .annotations: L10n.string("sidebar.annotations")
    }
  }
}

struct ReaderView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @StateObject private var model: ReaderViewModel
  @StateObject private var annotationModel: ReaderAnnotationViewModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var sidebarMode: ReaderSidebarMode = .thumbnails
  @State private var isCompactSidebarPresented = false
  @State private var isSearchPresented = false
  @State private var isGoToPagePresented = false
  @State private var isComparePresented = false

  init(session: DocumentSession, library: LibraryModel) {
    _model = StateObject(wrappedValue: ReaderViewModel(session: session, library: library))
    _annotationModel = StateObject(wrappedValue: ReaderAnnotationViewModel(session: session))
  }

  var body: some View {
    Group {
      if let document = model.document {
        if horizontalSizeClass == .regular {
          NavigationSplitView(columnVisibility: $columnVisibility) {
            ReaderSidebar(model: model, annotations: annotationModel, mode: $sidebarMode)
              .navigationTitle(L10n.string("ios.reader"))
              .navigationBarTitleDisplayMode(.inline)
          } detail: {
            readerDetail(document: document, regular: true)
          }
          .navigationSplitViewStyle(.balanced)
          .onChange(of: columnVisibility) { _, value in
            let visible = value != .detailOnly
            if model.readingState.sidebarVisible != visible {
              model.readingState.sidebarVisible = visible
              model.persistReadingState()
            }
          }
        } else {
          readerDetail(document: document, regular: false)
            .sheet(isPresented: $isCompactSidebarPresented) {
              NavigationStack {
                ReaderSidebar(model: model, annotations: annotationModel, mode: $sidebarMode)
                  .navigationTitle(L10n.string("ios.readerTools"))
                  .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                      Button(L10n.string("search.done")) { isCompactSidebarPresented = false }
                    }
                  }
              }
              .presentationDetents([.medium, .large])
            }
        }
      } else {
        ContentUnavailableView(
          L10n.string("ios.pdfUnavailable"),
          systemImage: "exclamationmark.triangle",
          description: Text(L10n.string("ios.chooseFileAgain"))
        )
      }
    }
    .task {
      if horizontalSizeClass == .regular {
        columnVisibility = model.readingState.sidebarVisible ? .all : .detailOnly
      }
    }
    .onChange(of: isCompactSidebarPresented) { _, presented in
      if !presented && model.readingState.sidebarVisible {
        model.readingState.sidebarVisible = false
        model.persistReadingState()
      }
    }
    .onChange(of: model.library.preferences) { _, value in
      model.updateTranslationPreferences(value)
    }
    .onAppear {
      ReaderCommandRouter.shared.activate(model)
    }
    .onDisappear {
      ReaderCommandRouter.shared.deactivate(model)
      model.persistReadingState()
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerNextPage)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      model.movePage(by: 1)
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerPreviousPage)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      model.movePage(by: -1)
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerZoomIn)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      model.zoomIn()
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerZoomOut)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      model.zoomOut()
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerToggleSidebar)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      toggleSidebar()
    }
    .onReceive(NotificationCenter.default.publisher(for: .readerOpenSearch)) { notification in
      guard notification.object as? ReaderViewModel === model else { return }
      isSearchPresented = true
    }
    .sheet(isPresented: $isSearchPresented) {
      SearchSheet(model: model)
    }
    .sheet(isPresented: $isGoToPagePresented) {
      GoToPageSheet(model: model)
    }
  }

  @ViewBuilder
  private func readerDetail(document: PDFDocument, regular: Bool) -> some View {
    ReaderDetail(
      model: model,
      annotations: annotationModel,
      regular: regular,
      onToggleSidebar: toggleSidebar,
      onSearch: { isSearchPresented = true },
      onGoToPage: { isGoToPagePresented = true },
      onCompare: { isComparePresented = true }
    )
    .readerReadingAids(
      document: document,
      preferences: model.library.preferences,
      documentID: model.session.id
    )
    .readerExport(
      document: document,
      originalName: model.session.title,
      annotations: annotationModel.annotations,
      coordinator: model.translationCoordinator
    )
    .sheet(isPresented: $isComparePresented) {
      if let coordinator = model.translationCoordinator {
        NavigationStack {
          ReaderCompareView(
            document: document,
            coordinator: coordinator,
            currentPage: Binding(
              get: { model.readingState.page },
              set: { model.goToPage($0) }
            ),
            onShowOverlay: model.toggleTranslations
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button(L10n.string("search.done")) { isComparePresented = false }
            }
          }
        }
      }
    }
  }

  private func toggleSidebar() {
    if horizontalSizeClass == .regular {
      let visible = columnVisibility == .detailOnly
      columnVisibility = visible ? .all : .detailOnly
      model.readingState.sidebarVisible = visible
      model.persistReadingState()
    } else {
      isCompactSidebarPresented = true
      model.readingState.sidebarVisible = true
      model.persistReadingState()
    }
  }
}

private struct ReaderDetail: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var annotations: ReaderAnnotationViewModel
  @Environment(\.readerPageOverlayProvider) private var environmentOverlayProvider
  @Environment(\.openWindow) private var openWindow
  @State private var isImporting = false
  @State private var importError: String?
  let regular: Bool
  let onToggleSidebar: () -> Void
  let onSearch: () -> Void
  let onGoToPage: () -> Void
  let onCompare: () -> Void

  var body: some View {
    // Reading aids come first so translation labels draw above glyph overlays.
    let overlayProviders: [any ReaderPageOverlayProviding] = [
      environmentOverlayProvider,
      model.translationCoordinator as (any ReaderPageOverlayProviding)?
    ].compactMap { $0 }
    PDFKitView(
      document: model.document!,
      readingState: $model.readingState,
      reference: model.pdfViewReference,
      overlayProvider: ReaderPageOverlayCompositeProvider(providers: overlayProviders),
      annotationModel: annotations,
      onStateChanged: model.receivePDFViewState
    )
    .background(Color(uiColor: .secondarySystemBackground))
    #if DEBUG
    .overlay(alignment: .topLeading) {
      if let coordinator = model.translationCoordinator, TranslationStatusProbe.isEnabled {
        TranslationStatusProbe(coordinator: coordinator)
      }
    }
    #endif
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !regular {
        PDFThumbnailRepresentable(reference: model.pdfViewReference, horizontal: true)
          .frame(height: 92)
          .background(.bar)
      }
    }
    .navigationTitle(model.session.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarLeading) {
        Button(action: onToggleSidebar) {
          Label(L10n.string("sidebar.thumbnails"), systemImage: "sidebar.left")
        }
        .labelStyle(.iconOnly)

        // iPad can relaunch straight into reader windows with no library
        // scene, so readers need their own way to open another PDF.
        if regular {
          Button {
            isImporting = true
          } label: {
            Label(L10n.string("ios.importPDF"), systemImage: "doc.badge.plus")
          }
          .labelStyle(.iconOnly)
        }

        Button(action: onGoToPage) {
          Text(
            L10n.string(
              "status.pageOf",
              String(model.readingState.page),
              String(model.pageCount)
            )
          )
            .monospacedDigit()
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel(L10n.string("ios.goToPage"))
      }

      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Button(L10n.string("toolbar.zoomIn"), systemImage: "plus.magnifyingglass") { model.zoomIn() }
          Button(L10n.string("toolbar.zoomOut"), systemImage: "minus.magnifyingglass") { model.zoomOut() }
          Divider()
          ForEach(ReaderScaleMode.allCases, id: \.self) { mode in
            Button {
              model.setScaleMode(mode)
            } label: {
              Label(scaleTitle(mode), systemImage: model.readingState.scaleMode == mode ? "checkmark" : "")
            }
          }
        } label: {
          Label(L10n.string("toolbar.zoom"), systemImage: "plus.magnifyingglass")
        }

        Menu {
          ForEach(ReaderDisplayMode.allCases, id: \.self) { mode in
            Button {
              model.setDisplayMode(mode)
            } label: {
              Label(displayTitle(mode), systemImage: model.readingState.displayMode == mode ? "checkmark" : "")
            }
          }
          Divider()
          ForEach(ReaderScrollDirection.allCases, id: \.self) { direction in
            Button {
              model.setScrollDirection(direction)
            } label: {
              Label(directionTitle(direction), systemImage: model.readingState.scrollDirection == direction ? "checkmark" : "")
            }
          }
        } label: {
          Label(L10n.string("menu.extra.messages.Layout"), systemImage: "rectangle.split.2x1")
        }

        Button(action: onSearch) {
          Label(L10n.string("toolbar.searchDocument"), systemImage: "magnifyingglass")
        }

        Button {
          model.toggleTranslations()
        } label: {
          Label(
            model.translationCoordinator?.showTranslations == true
              ? L10n.string("toolbar.showOriginalText")
              : L10n.string("toolbar.showTranslatedText"),
            systemImage: model.translationCoordinator?.showTranslations == true
              ? "text.page"
              : "character.book.closed"
          )
        }
        .accessibilityIdentifier("reader.toggleTranslations")

        if regular {
          Button(action: onCompare) {
            Label(L10n.string("ios.compare"), systemImage: "rectangle.split.2x1")
          }
          .disabled(model.translationCoordinator == nil)
        }

        if let coordinator = model.translationCoordinator {
          TranslateAllPagesButton(coordinator: coordinator)
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.pdf],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        guard let session = model.library.makeSession(for: url) else {
          // The library scene's alert may not exist here; report locally.
          importError = model.library.lastError ?? L10n.string("ios.pdfReadFailed")
          model.library.lastError = nil
          return
        }
        openWindow(value: model.library.windowValue(for: session))
      case .failure:
        importError = L10n.string("ios.importPDFFailed")
      }
    }
    .alert(
      "PDFMathReader",
      isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    ) {
      Button(L10n.string("ios.ok")) { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }

  private func scaleTitle(_ mode: ReaderScaleMode) -> String {
    switch mode {
    case .fitPage: L10n.string("ios.fitPage")
    case .fitWidth: L10n.string("menu.extra.messages.Fit Width")
    case .actualSize: L10n.string("ios.actualSize")
    case .custom: L10n.string("appearance.custom")
    }
  }

  private func displayTitle(_ mode: ReaderDisplayMode) -> String {
    switch mode {
    case .singlePage: L10n.string("ios.singlePage")
    case .twoPages: L10n.string("ios.twoPages")
    case .fourPages: L10n.string("ios.fourPages")
    }
  }

  private func directionTitle(_ direction: ReaderScrollDirection) -> String {
    direction == .vertical
      ? L10n.string("ios.verticalScroll")
      : L10n.string("ios.horizontalScroll")
  }
}

private struct ReaderSidebar: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var annotations: ReaderAnnotationViewModel
  @Binding var mode: ReaderSidebarMode

  var body: some View {
    VStack(spacing: 0) {
      Picker(L10n.string("ios.readerSidebar"), selection: $mode) {
        ForEach(ReaderSidebarMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      switch mode {
      case .thumbnails:
        PDFThumbnailRepresentable(reference: model.pdfViewReference, horizontal: false)
      case .outline:
        OutlineList(model: model)
      case .annotations:
        ReaderAnnotationsSidebar(
          model: annotations,
          pdfViewReference: model.pdfViewReference,
          onJump: model.goToPage
        )
      }
    }
    .background(.regularMaterial)
  }
}

private struct OutlineList: View {
  @ObservedObject var model: ReaderViewModel

  var body: some View {
    if model.outlineEntries.isEmpty {
      ContentUnavailableView(
        L10n.string("ios.noOutline"),
        systemImage: "list.bullet.indent",
        description: Text(L10n.string("ios.noBookmarks"))
      )
    } else {
      List(model.outlineEntries) { entry in
        Button {
          if let page = entry.page { model.goToPage(page) }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.title)
              .lineLimit(2)
            Spacer(minLength: 4)
            if let page = entry.page {
              Text("\(page)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .padding(.leading, CGFloat(entry.depth * 14))
        }
        .buttonStyle(.plain)
        .disabled(entry.page == nil)
      }
      .listStyle(.plain)
    }
  }
}

private struct SearchSheet: View {
  @ObservedObject var model: ReaderViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if model.searchResults.isEmpty {
          ContentUnavailableView(
            model.searchQuery.isEmpty
              ? L10n.string("ios.searchThisPDF")
              : L10n.string("search.noMatches"),
            systemImage: "magnifyingglass",
            description: Text(L10n.string("ios.searchDescription"))
          )
          .listRowBackground(Color.clear)
        } else {
          ForEach(model.searchResults) { result in
            Button {
              model.goToPage(result.page)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(result.text)
                  .lineLimit(2)
                Text(L10n.string("sidebar.page", String(result.page)))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .listStyle(.plain)
      .navigationTitle(L10n.string("search.documentText"))
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
      .onSubmit(of: .search) { model.search() }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("search.done")) { dismiss() }
        }
      }
      .onChange(of: model.searchQuery) { _, _ in model.search() }
    }
    .presentationDetents([.medium, .large])
    .onDisappear { model.clearSearch() }
  }
}

private struct GoToPageSheet: View {
  @ObservedObject var model: ReaderViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var pageText = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.string("navigator.pageNumber")) {
          TextField(L10n.string("ios.pageRange", String(model.pageCount)), text: $pageText)
            .keyboardType(.numberPad)
            .submitLabel(.go)
            .onSubmit { submit() }
        }
      }
      .navigationTitle(L10n.string("ios.goToPage"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("ios.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("menu.extra.messages.Go")) { submit() }
            .disabled(Int(pageText) == nil)
        }
      }
    }
    .presentationDetents([.height(170)])
    .onAppear { pageText = "\(model.readingState.page)" }
  }

  private func submit() {
    guard let page = Int(pageText) else { return }
    model.goToPage(page)
    dismiss()
  }
}

#if DEBUG
/// PDFKit replaces page accessibility children with its own text elements, so
/// translation overlays are invisible to XCUITest. With `-PMRUITestProbe`, this
/// exposes the first translated paragraph as an accessibility value instead.
private struct TranslationStatusProbe: View {
  static let isEnabled = ProcessInfo.processInfo.arguments.contains("-PMRUITestProbe")
  @ObservedObject var coordinator: ReaderTranslationCoordinator

  var body: some View {
    let _ = coordinator.translationRevision
    Color.clear
      .frame(width: 1, height: 1)
      .accessibilityElement()
      .accessibilityIdentifier("debug.translationStatus")
      .accessibilityValue(coordinator.debugTranslations)
  }
}
#endif
