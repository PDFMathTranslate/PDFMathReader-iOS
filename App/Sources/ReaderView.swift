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
  @State private var isLandscape: Bool?
  @State private var sidebarMode: ReaderSidebarMode = .thumbnails
  @State private var isCompactSidebarPresented = false
  @State private var isSearchPresented = false
  @State private var isComparePresented = false
  @State private var exportRequest: ReaderExportKind?
  private let onClose: (() -> Void)?

  init(session: DocumentSession, library: LibraryModel, onClose: (() -> Void)? = nil) {
    _model = StateObject(wrappedValue: ReaderViewModel(session: session, library: library))
    _annotationModel = StateObject(wrappedValue: ReaderAnnotationViewModel(session: session))
    _columnVisibility = State(initialValue: Self.defaultColumnVisibility(landscape: Self.sceneIsLandscape()))
    self.onClose = onClose
  }

  private static func defaultColumnVisibility(landscape: Bool) -> NavigationSplitViewVisibility {
    landscape ? .all : .detailOnly
  }

  /// Best guess before the first layout: the split view applies its initial
  /// visibility reliably but can drop a change made while it first lays out.
  private static func sceneIsLandscape() -> Bool {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
      return true
    }
    let size = scene.coordinateSpace.bounds.size
    return size.width > size.height
  }

  var body: some View {
    Group {
      if let document = model.document {
        if horizontalSizeClass == .regular {
          NavigationSplitView(columnVisibility: $columnVisibility) {
            ReaderSidebar(model: model, annotations: annotationModel, mode: $sidebarMode)
              .navigationTitle(L10n.string("ios.reader"))
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                if let onClose {
                  ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("menu.extra.messages.Close Document"), systemImage: "xmark") {
                      model.persistReadingState()
                      onClose()
                    }
                    .accessibilityIdentifier("reader.closeDocument")
                  }
                }
              }
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
    // iPad default: sidebar off in portrait, on in landscape. Each rotation
    // resets it; the toolbar toggle still works in between.
    .onGeometryChange(for: Bool.self) { proxy in
      proxy.size.width > proxy.size.height
    } action: { landscape in
      isLandscape = landscape
    }
    // Applied from a task: the split view ignores visibility set during its
    // first layout pass.
    .task(id: isLandscape) {
      guard let isLandscape else { return }
      let target = Self.defaultColumnVisibility(landscape: isLandscape)
      columnVisibility = target
      // Reassert once layout settles in case the split view dropped it.
      try? await Task.sleep(for: .milliseconds(400))
      if columnVisibility != target { columnVisibility = target }
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
  }

  @ViewBuilder
  private func readerDetail(document: PDFDocument, regular: Bool) -> some View {
    ReaderDetail(
      model: model,
      annotations: annotationModel,
      regular: regular,
      onToggleSidebar: toggleSidebar,
      onSearch: { isSearchPresented = true },
      onCompare: { isComparePresented = true },
      onExport: { exportRequest = $0 }
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
      coordinator: model.translationCoordinator,
      request: $exportRequest
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
  @StateObject private var pagerVisibility = ReaderPagerVisibility()
  @StateObject private var translateAll: TranslateAllPagesJob
  let regular: Bool
  let onToggleSidebar: () -> Void
  let onSearch: () -> Void
  let onCompare: () -> Void
  let onExport: (ReaderExportKind) -> Void

  init(
    model: ReaderViewModel,
    annotations: ReaderAnnotationViewModel,
    regular: Bool,
    onToggleSidebar: @escaping () -> Void,
    onSearch: @escaping () -> Void,
    onCompare: @escaping () -> Void,
    onExport: @escaping (ReaderExportKind) -> Void
  ) {
    self.model = model
    self.annotations = annotations
    self.regular = regular
    self.onToggleSidebar = onToggleSidebar
    self.onSearch = onSearch
    self.onCompare = onCompare
    self.onExport = onExport
    // The detail only exists with a document, and every document gets a
    // coordinator. The job lives here so menu rebuilds keep its progress.
    _translateAll = StateObject(wrappedValue: TranslateAllPagesJob(coordinator: model.translationCoordinator!))
  }

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
      onStateChanged: model.receivePDFViewState,
      onScroll: pagerVisibility.show
    )
    .background(Color(uiColor: .secondarySystemBackground))
    .overlay {
      ReaderPager(model: model, visibility: pagerVisibility, compact: !regular)
    }
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
        // NavigationSplitView supplies its own sidebar button in regular width.
        if !regular {
          Button(action: onToggleSidebar) {
            Label(L10n.string("sidebar.thumbnails"), systemImage: "sidebar.left")
          }
          .labelStyle(.iconOnly)
        }

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
      }

      // Desktop order: annotation visibility, translation, search, then
      // everything else in one menu.
      ToolbarItemGroup(placement: .topBarTrailing) {
        if !annotations.annotations.isEmpty {
          Button {
            annotations.setShowsAnnotations(!annotations.showsAnnotations, in: model.pdfViewReference.view)
          } label: {
            Label(
              L10n.string(annotations.showsAnnotations ? "toolbar.hideAnnotations" : "toolbar.showAnnotations"),
              systemImage: annotations.showsAnnotations ? "eye" : "eye.slash"
            )
          }
          .accessibilityIdentifier("reader.toggleAnnotations")
        }

        Button {
          model.toggleTranslations()
        } label: {
          if translateAll.isRunning {
            Label {
              Text(L10n.string("toolbar.translating", String(Int(translateAll.progress.fraction * 100))))
            } icon: {
              TranslationProgressRing(fraction: translateAll.progress.fraction)
            }
          } else {
            Label(
              model.translationCoordinator?.showTranslations == true
                ? L10n.string("toolbar.showOriginalText")
                : L10n.string("toolbar.showTranslatedText"),
              systemImage: model.translationCoordinator?.showTranslations == true
                ? "text.page"
                : "character.book.closed"
            )
          }
        }
        .accessibilityIdentifier("reader.toggleTranslations")

        Button(action: onSearch) {
          Label(L10n.string("toolbar.searchDocument"), systemImage: "magnifyingglass")
        }

        Menu {
          moreMenu
        } label: {
          Label(L10n.string("parallel.more"), systemImage: "ellipsis")
        }
        .accessibilityIdentifier("reader.moreMenu")
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

  @ViewBuilder
  private var moreMenu: some View {
    Section {
      Button {
        translateAll.isRunning ? translateAll.cancel() : translateAll.start()
      } label: {
        Label {
          Text(translateAll.menuTitle)
          if let subtitle = translateAll.menuSubtitle { Text(subtitle) }
        } icon: {
          Image(systemName: translateAll.menuSymbol)
        }
      }
      .disabled(translateAll.isFinished && !translateAll.isRunning)
      .accessibilityIdentifier("reader.translateAllPages")

      if regular {
        Button(L10n.string("ios.compare"), systemImage: "rectangle.split.2x1", action: onCompare)
      }
    }

    Section {
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
    }

    Section {
      Menu {
        Button(ReaderExportKind.original.title, systemImage: "doc") { onExport(.original) }
        Button(ReaderExportKind.translated.title, systemImage: "character.book.closed") { onExport(.translated) }
      } label: {
        Label(L10n.string("ios.export"), systemImage: "square.and.arrow.up")
      }
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
    // Overlays change outside SwiftUI (taps, document swaps), so poll.
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("debug.overlayText")
        .accessibilityValue(coordinator.debugDisplayedText)
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("debug.pipelineStatus")
        .accessibilityValue(coordinator.debugPipelineStatus)
    }
  }
}
#endif

/// Desktop-style progress ring shown on the translation toggle while every
/// page is being translated.
private struct TranslationProgressRing: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: max(0.02, fraction))
        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 18, height: 18)
    .animation(.easeOut(duration: 0.2), value: fraction)
  }
}
