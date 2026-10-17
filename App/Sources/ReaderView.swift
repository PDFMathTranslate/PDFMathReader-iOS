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

  var systemImage: String {
    switch self {
    case .thumbnails: "square.grid.2x2"
    case .outline: "list.bullet"
    case .annotations: "highlighter"
    }
  }
}

/// UIApplication's idle timer is shared by all windows. One reader closing must
/// not release another active reader's request to keep the display awake.
@MainActor
private enum ReaderIdleTimer {
  static var owners: Set<UUID> = []

  static func update(owner: UUID, keepAwake: Bool) {
    if keepAwake { owners.insert(owner) } else { owners.remove(owner) }
    UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
  }
}

/// Shared by the revealed drag background and the remote-save closing screen.
struct ReaderCloseBackdrop: View {
  let message: String
  var revealedHeight: CGFloat? = nil
  var saving = false
  var retry: (() -> Void)? = nil

  var body: some View {
    ZStack(alignment: .top) {
      Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
      VStack(spacing: 12) {
        if saving { ProgressView() }
        else { Image(systemName: retry == nil ? "arrow.down" : "exclamationmark.icloud").font(.title2) }
        Text(message).font(.subheadline).multilineTextAlignment(.center)
        if let retry {
          Button(L10n.string("companion.retry"), action: retry).buttonStyle(.borderedProminent)
        }
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity)
      .frame(height: revealedHeight.map { max(0, $0) })
      .frame(maxHeight: revealedHeight == nil ? .infinity : nil)
      .clipped()
      .opacity(revealedHeight.map { min(1, max(0, ($0 - 24) / 40)) } ?? 1)
      .accessibilityHidden(revealedHeight.map { $0 < 40 } ?? false)
    }
    .accessibilityIdentifier("reader.closeBackdrop")
  }
}

struct ReaderView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: ReaderViewModel
  @StateObject private var annotationModel: ReaderAnnotationViewModel
  @StateObject private var drawingModel: ReaderDrawingModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var sidebarMode: ReaderSidebarMode = .thumbnails
  @State private var isCompactSidebarPresented = false
  @State private var isSearchPresented = false
  @State private var isComparePresented = false
  @State private var exportRequest: ReaderExportKind?
  @State private var idleTimerOwner = UUID()
  @State private var isReaderVisible = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.32, dampingFraction: 0.86)))
  private var headerDragOffset: CGFloat = 0
  @State private var closingOffset: CGFloat = 0
  @State private var readerHeight: CGFloat = 1000
  private let onClose: (() -> Void)?
  private let onDragClose: (() -> Void)?

  init(session: DocumentSession, library: LibraryModel, onClose: (() -> Void)? = nil) {
    _model = StateObject(wrappedValue: ReaderViewModel(session: session, library: library))
    _annotationModel = StateObject(wrappedValue: ReaderAnnotationViewModel(session: session))
    _drawingModel = StateObject(wrappedValue: ReaderDrawingModel(session: session))
    _columnVisibility = State(initialValue: Self.defaultColumnVisibility(landscape: Self.sceneIsLandscape()))
    self.onClose = onClose
    self.onDragClose = nil
  }

  init(tab: ReaderTab, onDragClose: (() -> Void)? = nil, onClose: @escaping () -> Void) {
    _model = StateObject(wrappedValue: tab.model)
    _annotationModel = StateObject(wrappedValue: tab.annotations)
    _drawingModel = StateObject(wrappedValue: tab.drawings)
    _columnVisibility = State(initialValue: Self.defaultColumnVisibility(landscape: Self.sceneIsLandscape()))
    self.onClose = onClose
    self.onDragClose = onDragClose
  }

  private var shouldKeepAwake: Bool {
    isReaderVisible && scenePhase == .active && model.document != nil
      && model.library.preferences.keepAwakeWhileReading
  }

  /// `.inactive` is transient on iOS (app switcher, Control Center), so only
  /// a hidden reader or a backgrounded scene suspends reader work.
  private var isReaderActive: Bool {
    isReaderVisible && scenePhase != .background
  }

  /// Matches the desktop's delayed bitmap reset: a quick tab switch or
  /// return keeps overlays; a reader still inactive after 1 s releases them.
  private func deactivateReader() {
    model.setReaderActive(false)
    let model = model
    let drawings = drawingModel
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      guard !model.isReaderActive else { return }
      model.releaseDetachedResources()
      drawings.releaseDetachedCanvases()
    }
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
          NavigationSplitView(columnVisibility: Binding(
            get: { columnVisibility },
            // Layout and scene restoration can propose a different visibility.
            // Only our explicit sidebar controls own this state.
            set: { _ in }
          )) {
            ReaderSidebar(model: model, annotations: annotationModel, drawings: drawingModel, mode: $sidebarMode)
              .navigationSplitViewColumnWidth(143.36)
              .simultaneousGesture(sidebarDismissGesture)
              .navigationTitle(L10n.string("ios.reader"))
              .navigationBarTitleDisplayMode(.inline)
              // Both split-view columns can contribute a system toggle.
              // Keep only the detail's custom tap/hold sidebar control.
              .toolbar(removing: .sidebarToggle)
              .background(ReaderSystemSidebarToggleSuppressor())
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
                ReaderSidebar(model: model, annotations: annotationModel, drawings: drawingModel, mode: $sidebarMode)
                  .simultaneousGesture(sidebarDismissGesture)
                  .navigationTitle(L10n.string("ios.readerTools"))
                  .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                      Button(L10n.string("search.done")) { isCompactSidebarPresented = false }
                    }
                  }
              }
              .presentationDetents([.medium, .large])
              .presentationBackground(.clear)
            }
        }
      } else if model.isLoadingDocument {
        ProgressView(L10n.string("status.openingPDF"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("reader.loadingDocument")
      } else {
        ContentUnavailableView(
          L10n.string("ios.pdfUnavailable"),
          systemImage: "exclamationmark.triangle",
          description: Text(L10n.string("ios.chooseFileAgain"))
        )
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { readerHeight = $0 }
    .offset(y: reduceMotion ? 0 : (closingOffset > 0 ? closingOffset : headerDragOffset))
    .opacity(reduceMotion && closingOffset > 0 ? 0 : 1)
    .background {
      ReaderCloseBackdrop(
        message: L10n.string(headerDragOffset >= min(180, readerHeight * 0.22)
          ? "ios.readerReleaseToClose" : "ios.readerPullToClose"),
        revealedHeight: closingOffset > 0 ? readerHeight : headerDragOffset
      )
    }
    .task { await model.loadDocument() }
    .onChange(of: model.document, initial: true) { _, document in
      guard document != nil else { return }
      sidebarMode = model.outlineEntries.isEmpty ? .thumbnails : .outline
    }
    .task { await annotationModel.prepare() }
    .task { await drawingModel.prepare() }
    .onChange(of: isCompactSidebarPresented) { _, presented in
      if !presented && model.readingState.sidebarVisible {
        model.readingState.sidebarVisible = false
        model.persistReadingState()
      }
    }
    .onAppear {
      isReaderVisible = true
      ReaderCommandRouter.shared.activate(model)
    }
    .onChange(of: shouldKeepAwake, initial: true) { _, keepAwake in
      ReaderIdleTimer.update(owner: idleTimerOwner, keepAwake: keepAwake)
    }
    .onDisappear {
      isReaderVisible = false
      deactivateReader()
      ReaderIdleTimer.update(owner: idleTimerOwner, keepAwake: false)
      drawingModel.isDrawing = false
      drawingModel.flush()
      ReaderCommandRouter.shared.deactivate(model)
      model.persistReadingState()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        drawingModel.flush()
        model.persistReadingState()
      }
      if phase == .background {
        Task { await ReaderThumbnailCache.shared.clear() }
      }
    }
    .onChange(of: isReaderActive) { _, active in
      if active { model.setReaderActive(true) } else { deactivateReader() }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
      Task { await ReaderThumbnailCache.shared.clear() }
      drawingModel.releaseDetachedCanvases()
    }
    .alert(L10n.string("ios.drawingSaveFailed"), isPresented: Binding(
      get: { drawingModel.lastError != nil },
      set: { if !$0 { drawingModel.lastError = nil } }
    )) {
      Button(L10n.string("ios.ok")) { drawingModel.lastError = nil }
    } message: {
      Text(drawingModel.lastError ?? "")
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
    .onReceive(NotificationCenter.default.publisher(for: .readerSearchSelectedText)) { notification in
      guard notification.object as? PDFView === model.pdfViewReference.view,
        let text = notification.userInfo?["text"] as? String else { return }
      model.searchQuery = text
      model.search()
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
      drawings: drawingModel,
      regular: regular,
      onToggleSidebar: toggleSidebar,
      headerDismissGesture: AnyGesture(headerDismissGesture),
      onClose: onClose.map { close in
        {
          model.persistReadingState()
          close()
        }
      },
      onSearch: { isSearchPresented = true },
      onCompare: { isComparePresented = true },
      onExport: { exportRequest = $0 }
    )
    .simultaneousGesture(
      DragGesture(minimumDistance: 50)
        .onEnded { value in
          guard !drawingModel.isDrawing,
                value.startLocation.x <= 32,
                value.translation.width > 60,
                value.translation.width > abs(value.translation.height) * 2 else { return }
          setSidebarVisible(true)
        }
    )
    .readerReadingAids(
      document: document,
      preferences: model.library.preferences,
      documentID: model.session.id
    )
    .readerExport(
      document: document,
      originalName: model.session.title,
      sourceData: annotationModel.exportSourceData,
      nativeRefs: annotationModel.exportNativeRefs,
      annotations: annotationModel.annotations,
      quickLinks: annotationModel.quickLinks,
      readingState: model.readingState,
      coordinator: model.translationCoordinator,
      drawings: drawingModel,
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

  /// Only the header owns this gesture; scrolling the PDF never dismisses it.
  private var headerDismissGesture: some Gesture<DragGesture.Value> {
    DragGesture(minimumDistance: 10, coordinateSpace: .global)
      .updating($headerDragOffset) { value, offset, transaction in
        guard onClose != nil, !drawingModel.isDrawing, closingOffset == 0,
              value.translation.height > abs(value.translation.width) else { return }
        transaction.animation = nil
        offset = max(0, value.translation.height)
        deferTranslationRenderingForMotion()
      }
      .onEnded { value in
        guard let onClose, !drawingModel.isDrawing, closingOffset == 0 else { return }
        let distance = value.translation.height
        let threshold = min(180, readerHeight * 0.22)
        guard distance > abs(value.translation.width), distance > 24,
              distance > threshold || value.predictedEndTranslation.height > threshold * 1.5 else { return }
        // Continue from the finger's release point before removing the document.
        closingOffset = distance
        deferTranslationRenderingForMotion()
        model.persistReadingState()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1),
                      completionCriteria: .logicallyComplete) {
          closingOffset = readerHeight + 100
        } completion: {
          // Keep the reader offscreen while the workspace saves remote changes.
          (onDragClose ?? onClose)()
        }
      }
  }

  private func toggleSidebar() {
    setSidebarVisible(horizontalSizeClass == .regular ? columnVisibility == .detailOnly : !isCompactSidebarPresented)
  }

  private var sidebarDismissGesture: some Gesture {
    DragGesture(minimumDistance: 50)
      .onEnded { value in
        guard !drawingModel.isDrawing,
              value.translation.width < -60,
              -value.translation.width > abs(value.translation.height) * 2 else { return }
        setSidebarVisible(false)
      }
  }

  private func setSidebarVisible(_ visible: Bool) {
    deferTranslationRenderingForMotion()
    withAnimation {
      if horizontalSizeClass == .regular {
        columnVisibility = visible ? .all : .detailOnly
      } else {
        isCompactSidebarPresented = visible
      }
    }
    model.readingState.sidebarVisible = visible
    model.persistReadingState()
  }

  private func deferTranslationRenderingForMotion() {
    guard let view = model.pdfViewReference.view as? ReaderAnnotationPDFView else { return }
    view.translationRenderResumeTime = max(view.translationRenderResumeTime, CACurrentMediaTime() + 0.45)
  }

}

private struct ReaderDetail: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var annotations: ReaderAnnotationViewModel
  @ObservedObject var drawings: ReaderDrawingModel
  @Environment(\.readerPageOverlayProvider) private var environmentOverlayProvider
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openReaderTab) private var openReaderTab
  @Environment(\.readerTabStrip) private var readerTabStrip
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isImporting = false
  @State private var importError: String?
  @State private var titleBarHidden = false
  @StateObject private var pagerVisibility = ReaderPagerVisibility()
  @StateObject private var translateAll: TranslateAllPagesJob
  @StateObject private var kernelAvailability = ReaderKernelMenuAvailability()
  let regular: Bool
  let headerDismissGesture: AnyGesture<DragGesture.Value>
  let onToggleSidebar: () -> Void
  let onClose: (() -> Void)?
  let onSearch: () -> Void
  let onCompare: () -> Void
  let onExport: (ReaderExportKind) -> Void

  init(
    model: ReaderViewModel,
    annotations: ReaderAnnotationViewModel,
    drawings: ReaderDrawingModel,
    regular: Bool,
    onToggleSidebar: @escaping () -> Void,
    headerDismissGesture: AnyGesture<DragGesture.Value>,
    onClose: (() -> Void)?,
    onSearch: @escaping () -> Void,
    onCompare: @escaping () -> Void,
    onExport: @escaping (ReaderExportKind) -> Void
  ) {
    self.model = model
    self.annotations = annotations
    self.drawings = drawings
    self.regular = regular
    self.onToggleSidebar = onToggleSidebar
    self.headerDismissGesture = headerDismissGesture
    self.onClose = onClose
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
    // Keep the pager outside the document’s extended safe area so SwiftUI
    // positions it above the keyboard while the page field is focused.
    ZStack {
      documentView(overlayProviders: overlayProviders)
      ReaderPager(model: model, visibility: pagerVisibility, compact: !regular)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func documentView(overlayProviders: [any ReaderPageOverlayProviding]) -> some View {
    PDFKitView(
      document: model.document!,
      readingState: $model.readingState,
      reference: model.pdfViewReference,
      overlayProvider: ReaderPageOverlayCompositeProvider(providers: overlayProviders),
      annotationModel: annotations,
      drawingModel: drawings,
      onStateChanged: model.receivePDFViewState,
      onScroll: pagerVisibility.show,
      onUserScroll: { distance in
        guard model.library.preferences.autoHideTitleBar, !drawings.isDrawing else { return }
        titleBarHidden = distance > 0
      },
      onBackgroundTap: {
        guard !drawings.isDrawing else { return }
        titleBarHidden.toggle()
      }
    )
    // Let the page use the landscape camera inset too. Only the document
    // extends edge to edge; chrome and the pager retain their safe areas.
    .ignoresSafeArea(.container)
    .onChange(of: drawings.isDrawing || !drawings.isPrepared || !drawings.drawings.isEmpty, initial: true) { _, suspended in
      model.translationCoordinator?.setCompactionSuspended(suspended)
    }
    .background(Color(uiColor: .secondarySystemBackground))
    .background {
      if let coordinator = model.translationCoordinator {
        ReaderAppleTranslationPreparation(coordinator: coordinator)
      }
    }
    .background {
      ReaderKernelAvailabilityMonitor(library: model.library, availability: kernelAvailability)
    }
    #if DEBUG
    .overlay(alignment: .topLeading) {
      if let coordinator = model.translationCoordinator, TranslationStatusProbe.isEnabled {
        TranslationStatusProbe(coordinator: coordinator)
      }
    }
    // Toolbar buttons drop their accessibility value, so expose drawing mode here.
    .overlay(alignment: .topTrailing) {
      if TranslationStatusProbe.isEnabled {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityIdentifier("debug.drawingMode")
          .accessibilityValue(drawings.isDrawing ? "on" : "off")
      }
    }
    .overlay(alignment: .bottomLeading) {
      if TranslationStatusProbe.isEnabled {
        ReaderViewportProbe(reference: model.pdfViewReference)
      }
    }
    #endif
    // Chrome overlays a stable viewport. Its visibility never changes the
    // PDFView's bounds, fit scale, safe-area insets or reading destination.
    .overlay(alignment: .top) {
      VStack(spacing: 0) {
        readerHeader
          .contentShape(Rectangle())
          .simultaneousGesture(headerDismissGesture)
        if let readerTabStrip { readerTabStrip() }
      }
      .background {
        // Cover the status bar and the full chrome, then soften the edge
        // into the document without changing the PDF viewport.
        Rectangle()
          .fill(.regularMaterial)
          .mask {
            LinearGradient(
              stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.65),
                .init(color: .clear, location: 1)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          }
          .padding(.bottom, -24)
          .ignoresSafeArea(.container, edges: .top)
      }
      .opacity(titleBarHidden ? 0 : 1)
      .offset(y: titleBarHidden && !reduceMotion ? -12 : 0)
      .allowsHitTesting(!titleBarHidden)
      .accessibilityHidden(titleBarHidden)
      .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: titleBarHidden)
    }
    .onReceive(NotificationCenter.default.publisher(for: .translationCacheDidClear)) { notification in
      if let id = notification.userInfo?["documentID"] as? String,
        id != model.translationCoordinator?.translationDocumentID { return }
      translateAll.resetForCurrentConfiguration()
    }
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: model.library.preferences.autoHideTitleBar) { _, _ in
      titleBarHidden = false
    }
    .onChange(of: drawings.isDrawing) { _, drawing in
      if drawing { titleBarHidden = false }
    }
    .onChange(of: model.readingState.scrollDirection) { _, _ in
      titleBarHidden = false
    }
    .navigationTitle(model.session.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(removing: .sidebarToggle)
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.pdf, .epub],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        Task {
          guard let session = await model.library.makeSession(for: url) else {
            // The library scene's alert may not exist here; report locally.
            importError = model.library.lastError ?? L10n.string("ios.pdfReadFailed")
            model.library.lastError = nil
            return
          }
          if let openReaderTab {
            openReaderTab(session)
          } else {
            openWindow(value: model.library.windowValue(for: session))
          }
        }
      case .failure:
        importError = L10n.string("ios.importDocumentFailed")
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

  private var readerHeader: some View {
    HStack(spacing: 12) {
      HStack(spacing: 4) {
        Button(action: onToggleSidebar) {
          Label(L10n.string("sidebar.thumbnails"), systemImage: "sidebar.left")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ReaderSidebarHoldStyle(onClose: onClose))
        .accessibilityIdentifier("reader.toggleSidebar")

        // iPad can relaunch straight into reader windows with no library
        // scene, so readers need their own way to open another PDF.
        if regular {
          Button {
            isImporting = true
          } label: {
            Label(L10n.string("ios.importDocument"), systemImage: "doc.badge.plus")
          }
          .labelStyle(.iconOnly)
        }
      }
      Text(model.session.title)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 4) {
        Button {
          drawings.isDrawing.toggle()
        } label: {
          Label(L10n.string("ios.drawingTools"), systemImage: drawings.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .tint(drawings.isDrawing ? .accentColor : .primary)
        .disabled(!drawings.isPrepared)
        .accessibilityIdentifier("reader.drawingTools")
        .accessibilityValue(drawings.isDrawing ? L10n.string("ios.drawingActive") : L10n.string("ios.drawingInactive"))

        if let coordinator = model.translationCoordinator {
          ReaderTranslationButton(
            coordinator: coordinator,
            translateAll: translateAll,
            action: model.toggleTranslations
          )
        }

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
    .labelStyle(.iconOnly)
    .buttonStyle(ReaderHeaderButtonStyle())
    .padding(.horizontal, 8)
    .frame(minHeight: 52)
    .modifier(ReaderHeaderGlassSurface())
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private var moreMenu: some View {
    Section {
      Menu {
        ReaderTranslationMenu(library: model.library, availability: kernelAvailability) { preferences in
          guard preferences != model.library.preferences else { return }
          translateAll.cancel()
          model.library.savePreferences(preferences)
          model.updateTranslationPreferences(model.library.preferences)
        }
        Section {
          Button {
            translateAll.cancel()
            model.translationCoordinator?.forceRetranslate()
            translateAll.resetForCurrentConfiguration()
          } label: {
            Label(L10n.string("menu.extra.messages.Force Retranslate"), systemImage: "arrow.clockwise")
          }
          .accessibilityIdentifier("reader.forceRetranslate")
          Button {
            translateAll.cancel()
            do { try model.translationCoordinator?.clearDocumentCache() }
            catch { importError = error.localizedDescription }
          } label: {
            Label(L10n.string("ios.clearDocumentTranslationCache"), systemImage: "trash")
          }
          .accessibilityIdentifier("reader.clearDocumentTranslationCache")
        }
      } label: {
        Label(L10n.string("settings.translation"), systemImage: "character.bubble")
      }
      .accessibilityIdentifier("reader.translationMenu")

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
    }

    Section {
      Toggle(isOn: Binding(
        get: { model.library.preferences.keepAwakeWhileReading },
        set: { enabled in
          var preferences = model.library.preferences
          preferences.keepAwakeWhileReading = enabled
          model.library.savePreferences(preferences)
        }
      )) {
        Label(L10n.string("reader.keepAwakeWhileReading"), systemImage: "sun.max")
      }
      .accessibilityIdentifier("reader.keepAwakeWhileReading")

      Menu {
        Button(L10n.string("toolbar.zoomIn"), systemImage: "plus.magnifyingglass") { model.zoomIn() }
        Button(L10n.string("toolbar.zoomOut"), systemImage: "minus.magnifyingglass") { model.zoomOut() }
        Divider()
        ForEach(ReaderScaleMode.allCases, id: \.self) { mode in
          Button { model.setScaleMode(mode) } label: {
            HStack {
              Label(scaleTitle(mode), systemImage: scaleSymbol(mode))
              if model.readingState.scaleMode == mode { Image(systemName: "checkmark") }
            }
          }
        }
      } label: {
        Label(L10n.string("toolbar.zoom"), systemImage: "plus.magnifyingglass")
      }

      Menu {
        ForEach(ReaderDisplayMode.allCases, id: \.self) { mode in
          Toggle(isOn: Binding(
            get: { model.readingState.displayMode == mode },
            set: { if $0 { model.setDisplayMode(mode) } }
          )) {
            Label(displayTitle(mode), systemImage: displaySymbol(mode))
          }
        }
        Divider()
        ForEach(ReaderScrollDirection.allCases, id: \.self) { direction in
          Toggle(isOn: Binding(
            get: { model.readingState.scrollDirection == direction },
            set: { if $0 { model.setScrollDirection(direction) } }
          )) {
            Label(directionTitle(direction), systemImage: direction == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
          }
          .accessibilityIdentifier("reader.scrollDirection.\(direction.rawValue)")
        }
        Divider()
        Toggle(isOn: Binding(
          get: { model.library.preferences.reducePadding },
          set: { enabled in
            var preferences = model.library.preferences
            preferences.reducePadding = enabled
            model.library.savePreferences(preferences)
          }
        )) {
          Label(L10n.string("appearance.reducePadding"), systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .accessibilityIdentifier("reader.reducePadding")
      } label: {
        Label(L10n.string("menu.extra.messages.Layout"), systemImage: "rectangle.split.2x1")
      }
      .accessibilityIdentifier("reader.layoutMenu")

      Menu {
        let crop = model.readingState.pageCrop ?? PageCrop()
        Text("\(L10n.string("settings.cropHorizontal")): \(Int((crop.x * 100).rounded()))% · \(L10n.string("settings.cropVertical")): \(Int((crop.y * 100).rounded()))%")
        Button(L10n.string("menu.extra.messages.Crop More Horizontally"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
          model.setPageCrop(PageCrop(x: crop.x + PageCrop.adjustmentStep, y: crop.y))
        }
        .disabled(crop.x >= PageCrop.maximumFraction)
        .accessibilityIdentifier("reader.cropMoreHorizontally")
        Button(L10n.string("menu.extra.messages.Crop Less Horizontally"), systemImage: "arrow.left.and.right") {
          model.setPageCrop(PageCrop(x: crop.x - PageCrop.adjustmentStep, y: crop.y))
        }
        .disabled(crop.x <= 0)
        .accessibilityIdentifier("reader.cropLessHorizontally")
        Divider()
        Button(L10n.string("menu.extra.messages.Crop More Vertically"), systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
          model.setPageCrop(PageCrop(x: crop.x, y: crop.y + PageCrop.adjustmentStep))
        }
        .disabled(crop.y >= PageCrop.maximumFraction)
        .accessibilityIdentifier("reader.cropMoreVertically")
        Button(L10n.string("menu.extra.messages.Crop Less Vertically"), systemImage: "arrow.up.and.down") {
          model.setPageCrop(PageCrop(x: crop.x, y: crop.y - PageCrop.adjustmentStep))
        }
        .disabled(crop.y <= 0)
        .accessibilityIdentifier("reader.cropLessVertically")
        Divider()
        Button(L10n.string("menu.extra.messages.Reset Crop"), systemImage: "arrow.counterclockwise") {
          model.setPageCrop(PageCrop())
        }
        .disabled(!crop.isActive)
        .accessibilityIdentifier("reader.resetCrop")
      } label: {
        Label(L10n.string("menu.extra.messages.Page Crop"), systemImage: "crop")
      }
      .accessibilityIdentifier("reader.pageCrop")

      if regular {
        Button(L10n.string("ios.compare"), systemImage: "rectangle.split.2x1", action: onCompare)
      }
    }

    Section {
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

      Menu {
        Toggle(isOn: $drawings.usesFinger) {
          Label(L10n.string("ios.drawWithFinger"), systemImage: "applepencil")
        }
        .accessibilityIdentifier("reader.drawWithFinger")
        Button(L10n.string("ios.undoDrawing"), systemImage: "arrow.uturn.backward") { drawings.undo() }
          .disabled(!drawings.isDrawing)
        Button(L10n.string("ios.redoDrawing"), systemImage: "arrow.uturn.forward") { drawings.redo() }
          .disabled(!drawings.isDrawing)
      } label: {
        Label(L10n.string("ios.drawingTools"), systemImage: "pencil.tip.crop.circle")
      }
      .accessibilityIdentifier("reader.drawingMenu")
    }

    Section {
      Button(ReaderExportKind.airDrop.title, systemImage: "desktopcomputer") { onExport(.airDrop) }
        .disabled(!annotations.isPrepared || !drawings.isPrepared)
        .accessibilityIdentifier("reader.airDropToComputer")
      Menu {
        Button(ReaderExportKind.original.title, systemImage: "doc") { onExport(.original) }
        Button(ReaderExportKind.translated.title, systemImage: "character.book.closed") { onExport(.translated) }
      } label: {
        Label(L10n.string("ios.export"), systemImage: "square.and.arrow.up")
      }
      .disabled(!annotations.isPrepared || !drawings.isPrepared)
    }
  }

  private func scaleSymbol(_ mode: ReaderScaleMode) -> String {
    switch mode {
    case .fitPage: "arrow.up.left.and.arrow.down.right"
    case .fitWidth: "arrow.left.and.right"
    case .fitHeight: "arrow.up.and.down"
    case .actualSize: "1.magnifyingglass"
    case .custom: "slider.horizontal.3"
    }
  }

  private func displaySymbol(_ mode: ReaderDisplayMode) -> String {
    switch mode {
    case .singlePage: "rectangle"
    case .twoPages: "rectangle.split.2x1"
    case .fourPages: "square.grid.2x2"
    }
  }

  private func scaleTitle(_ mode: ReaderScaleMode) -> String {
    switch mode {
    case .fitPage: L10n.string("ios.fitPage")
    case .fitWidth: L10n.string("menu.extra.messages.Fit Width")
    case .fitHeight: L10n.string("menu.extra.messages.Fit Height")
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

/// SwiftUI's toolbar removal can leave UIKit's Liquid Glass split-view
/// button visible. Suppress that system button while retaining our control.
private struct ReaderSystemSidebarToggleSuppressor: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Controller {
    Controller()
  }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.hideSystemToggle()
  }

  final class Controller: UIViewController {
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
      super.didMove(toParent: parent)
      hideSystemToggle()
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      hideSystemToggle()
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      hideSystemToggle()
    }

    func hideSystemToggle() {
      guard let split = splitViewController,
            split.displayModeButtonVisibility != .never else { return }
      split.displayModeButtonVisibility = .never
    }
  }
}

private struct ReaderSidebar: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var annotations: ReaderAnnotationViewModel
  @ObservedObject var drawings: ReaderDrawingModel
  @Binding var mode: ReaderSidebarMode

  var body: some View {
    VStack(spacing: 0) {
      Picker(L10n.string("ios.readerSidebar"), selection: $mode) {
        ForEach(ReaderSidebarMode.allCases, id: \.self) { mode in
          Image(systemName: mode.systemImage)
            .accessibilityLabel(mode.title)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)

      switch mode {
      case .thumbnails:
        ReaderThumbnailList(model: model)
      case .outline:
        OutlineList(model: model)
          .padding(.horizontal, 8)
      case .annotations:
        ReaderAnnotationsSidebar(
          model: annotations,
          drawings: drawings,
          pdfViewReference: model.pdfViewReference,
          onJump: model.goToPage
        )
        .padding(.horizontal, 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scrollContentBackground(.hidden)
    .containerBackground(.clear, for: .navigation)
    .toolbarBackground(.hidden, for: .navigationBar)
    .background {
      ReaderSidebarGlassBackground()
        .ignoresSafeArea()
    }
  }
}

private struct ReaderSidebarGlassBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if reduceTransparency {
      Color(uiColor: .systemBackground)
    } else if #available(iOS 26.0, *) {
      Color.clear
        .glassEffect(.regular, in: Rectangle())
    } else {
      Rectangle().fill(.ultraThinMaterial)
    }
  }
}

/// Own the sidebar layout rather than relying on PDFKit's intrinsic thumbnail
/// strip size, which can overflow the split view's proposed width.
private struct ReaderThumbnailList: View {
  @ObservedObject var model: ReaderViewModel

  private var columnCount: Int {
    UIDevice.current.userInterfaceIdiom == .phone ? 2 : 1
  }

  var body: some View {
    GeometryReader { geometry in
      let spacing: CGFloat = 12
      let horizontalPadding: CGFloat = 24
      let thumbnailWidth = max(0,
        (geometry.size.width - horizontalPadding * 2 - spacing * CGFloat(columnCount - 1))
          / CGFloat(columnCount)) * 0.8
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount),
            alignment: .center,
            spacing: 16
          ) {
            ForEach(0..<model.pageCount, id: \.self) { index in
              if let page = model.document?.page(at: index) {
                Button {
                  model.goToPage(index + 1)
                } label: {
                  ReaderThumbnail(
                    page: page,
                    session: model.session,
                    number: index + 1,
                    width: thumbnailWidth,
                    isSelected: model.readingState.page == index + 1
                  )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("sidebar.page", String(index + 1)))
                .accessibilityAddTraits(model.readingState.page == index + 1 ? .isSelected : [])
                .accessibilityIdentifier("reader.thumbnail.\(index + 1)")
                .id(index + 1)
              }
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal, horizontalPadding)
          .padding(.vertical, 16)
        }
        .task { proxy.scrollTo(model.readingState.page, anchor: .center) }
        .onChange(of: model.readingState.page) { _, page in
          proxy.scrollTo(page, anchor: .center)
        }
      }
    }
  }
}

/// The file revision is part of a thumbnail's identity. A document can keep
/// the same URL while annotations or a companion sync replace its contents.
internal struct ReaderThumbnailFileRevision: Hashable, Sendable {
  let fileIdentifier: UInt64?
  let modificationTime: Int64?
  let fileSize: Int64?

  static func current(for url: URL) -> Self {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileIdentifier = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
    let modificationTime: Int64?
    if let date = attributes?[.modificationDate] as? Date {
      let nanoseconds = date.timeIntervalSince1970 * 1_000_000_000
      modificationTime = nanoseconds.isFinite ? Int64(nanoseconds.rounded()) : nil
    } else {
      modificationTime = nil
    }
    return Self(
      fileIdentifier: fileIdentifier,
      modificationTime: modificationTime,
      fileSize: fileSize
    )
  }
}

internal struct ReaderThumbnailRenderSize: Hashable, Sendable {
  let width: Int
  let height: Int

  init(_ size: CGSize) {
    width = Self.dimension(size.width)
    height = Self.dimension(size.height)
  }

  var cgSize: CGSize {
    CGSize(width: width, height: height)
  }

  private static func dimension(_ value: CGFloat) -> Int {
    guard value.isFinite else { return 1 }
    return max(1, Int(value.rounded(.up)))
  }
}

internal struct ReaderThumbnailCacheKey: Hashable, Sendable {
  let sourceURL: URL
  let revision: ReaderThumbnailFileRevision
  let pageIndex: Int
  let size: ReaderThumbnailRenderSize
}

private struct ReaderThumbnailDocumentKey: Hashable, Sendable {
  let sourceURL: URL
  let revision: ReaderThumbnailFileRevision
}

/// UIKit images are immutable after rendering. The wrapper makes that
/// ownership explicit when a rendered pair crosses the thumbnail actor.
internal struct ReaderThumbnailImagePair: @unchecked Sendable {
  let light: UIImage
  let dark: UIImage

  var estimatedByteCount: Int {
    let lightCost = Self.estimatedByteCount(of: light)
    let darkCost = Self.estimatedByteCount(of: dark)
    if lightCost > Int.max - darkCost { return Int.max }
    return lightCost + darkCost
  }

  private static func estimatedByteCount(of image: UIImage) -> Int {
    let width = image.cgImage?.width ?? max(1, Int((image.size.width * image.scale).rounded()))
    let height = image.cgImage?.height ?? max(1, Int((image.size.height * image.scale).rounded()))
    if width > Int.max / max(1, height) / 4 { return Int.max }
    return max(1, width * height * 4)
  }
}

internal struct ReaderThumbnailCacheStatistics: Sendable {
  let imageCount: Int
  let imageBytes: Int
  let documentCount: Int
  let documentOpenCount: Int
  let renderCount: Int
}

/// Renders thumbnails on a serial actor so each document has one independent
/// PDFDocument, separate from the live PDFView document. The actor also owns
/// the LRU image cache and in-flight tasks.
internal actor ReaderThumbnailCache {
  static let shared = ReaderThumbnailCache()
  static let defaultImageByteBudget = 24 * 1024 * 1024
  static let defaultDocumentLimit = 3

  private struct DocumentEntry {
    let document: PDFDocument
    let access: SecurityScopedAccess
    var lastUsed: UInt64
  }

  private struct ImageEntry {
    let images: ReaderThumbnailImagePair
    let byteCount: Int
    var lastUsed: UInt64
  }

  private let imageByteBudget: Int
  private let documentLimit: Int
  private var images: [ReaderThumbnailCacheKey: ImageEntry] = [:]
  private var imageBytes = 0
  private var documents: [ReaderThumbnailDocumentKey: DocumentEntry] = [:]
  private var inFlight: [ReaderThumbnailCacheKey: Task<ReaderThumbnailImagePair?, Never>] = [:]
  private var useCounter: UInt64 = 0
  private(set) var documentOpenCount = 0
  private(set) var renderCount = 0

  init(
    imageByteBudget: Int = ReaderThumbnailCache.defaultImageByteBudget,
    documentLimit: Int = ReaderThumbnailCache.defaultDocumentLimit
  ) {
    self.imageByteBudget = max(1, imageByteBudget)
    self.documentLimit = max(1, documentLimit)
  }

  func image(
    url: URL,
    access: SecurityScopedAccess,
    pageIndex: Int,
    fitting size: CGSize
  ) async -> ReaderThumbnailImagePair? {
    guard pageIndex >= 0 else { return nil }
    let sourceURL = url.standardizedFileURL
    let key = ReaderThumbnailCacheKey(
      sourceURL: sourceURL,
      revision: ReaderThumbnailFileRevision.current(for: sourceURL),
      pageIndex: pageIndex,
      size: ReaderThumbnailRenderSize(size)
    )
    purgeStaleEntries(for: key)

    if let entry = images[key] {
      touchImage(key)
      return Task.isCancelled ? nil : entry.images
    }

    if let task = inFlight[key] {
      let result = await task.value
      return Task.isCancelled ? nil : result
    }

    // This task is owned by the cache rather than the requesting view. A
    // cancelled row task can stop awaiting it, but cannot cancel shared work.
    let task = Task { [self] in
      render(key: key, access: access)
    }
    inFlight[key] = task
    let result = await task.value
    inFlight[key] = nil

    if let result,
       ReaderThumbnailFileRevision.current(for: key.sourceURL) == key.revision {
      insert(result, for: key)
    }
    return Task.isCancelled ? nil : result
  }

  func statistics() -> ReaderThumbnailCacheStatistics {
    ReaderThumbnailCacheStatistics(
      imageCount: images.count,
      imageBytes: imageBytes,
      documentCount: documents.count,
      documentOpenCount: documentOpenCount,
      renderCount: renderCount
    )
  }

  func clear() {
    images.removeAll(keepingCapacity: false)
    imageBytes = 0
    documents.removeAll(keepingCapacity: false)
  }

  private func render(
    key: ReaderThumbnailCacheKey,
    access: SecurityScopedAccess
  ) -> ReaderThumbnailImagePair? {
    withExtendedLifetime(access) {
      guard ReaderThumbnailFileRevision.current(for: key.sourceURL) == key.revision else {
        return nil
      }

      let documentKey = ReaderThumbnailDocumentKey(sourceURL: key.sourceURL, revision: key.revision)
      let document: PDFDocument
      if var entry = documents[documentKey] {
        useCounter &+= 1
        entry.lastUsed = useCounter
        documents[documentKey] = entry
        document = entry.document
      } else {
        guard let opened = PDFDocument(url: key.sourceURL) else { return nil }
        useCounter &+= 1
        documents[documentKey] = DocumentEntry(
          document: opened,
          access: access,
          lastUsed: useCounter
        )
        documentOpenCount += 1
        trimDocuments()
        document = opened
      }

      guard let page = document.page(at: key.pageIndex) else { return nil }
      renderCount += 1
      let light = ReaderDarkPDF.thumbnail(
        of: page,
        fitting: key.size.cgSize,
        box: .cropBox,
        inverted: false
      )
      let dark = ReaderDarkPDF.inverted(light)
      guard ReaderThumbnailFileRevision.current(for: key.sourceURL) == key.revision else {
        return nil
      }
      return ReaderThumbnailImagePair(light: light, dark: dark)
    }
  }

  private func insert(_ result: ReaderThumbnailImagePair, for key: ReaderThumbnailCacheKey) {
    let byteCount = result.estimatedByteCount
    guard byteCount <= imageByteBudget else { return }
    if let previous = images.removeValue(forKey: key) {
      imageBytes -= previous.byteCount
    }
    while imageBytes > imageByteBudget - byteCount {
      guard let oldest = images.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
      if let removed = images.removeValue(forKey: oldest) {
        imageBytes -= removed.byteCount
      }
    }
    useCounter &+= 1
    images[key] = ImageEntry(images: result, byteCount: byteCount, lastUsed: useCounter)
    imageBytes += byteCount
  }

  private func touchImage(_ key: ReaderThumbnailCacheKey) {
    guard var entry = images[key] else { return }
    useCounter &+= 1
    entry.lastUsed = useCounter
    images[key] = entry
  }

  private func trimDocuments() {
    while documents.count > documentLimit {
      guard let oldest = documents.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
      documents.removeValue(forKey: oldest)
    }
  }

  private func purgeStaleEntries(for key: ReaderThumbnailCacheKey) {
    let staleImages = images.keys.filter {
      $0.sourceURL == key.sourceURL && $0.revision != key.revision
    }
    for staleKey in staleImages {
      if let removed = images.removeValue(forKey: staleKey) {
        imageBytes -= removed.byteCount
      }
    }
    let staleDocuments = documents.keys.filter {
      $0.sourceURL == key.sourceURL && $0.revision != key.revision
    }
    for staleKey in staleDocuments {
      documents.removeValue(forKey: staleKey)
    }
  }
}

private struct ReaderThumbnail: View {
  let page: PDFPage
  let session: DocumentSession
  let number: Int
  let width: CGFloat
  let isSelected: Bool
  @State private var images: ReaderThumbnailImagePair?
  @ScaledMetric(relativeTo: .caption) private var labelHeight = 20

  private static let renderSize = CGSize(width: 280, height: 376)

  private var requestKey: ReaderThumbnailCacheKey {
    let url = session.url.standardizedFileURL
    return ReaderThumbnailCacheKey(
      sourceURL: url,
      revision: ReaderThumbnailFileRevision.current(for: url),
      pageIndex: number - 1,
      size: ReaderThumbnailRenderSize(Self.renderSize)
    )
  }

  private var thumbnailAspectRatio: CGFloat {
    if let image = images?.light, image.size.width > 0, image.size.height > 0 {
      return image.size.width / image.size.height
    }
    let bounds = page.bounds(for: .cropBox)
    guard bounds.width > 0, bounds.height > 0 else { return 140 / 188 }
    return page.rotation % 180 == 0
      ? bounds.width / bounds.height
      : bounds.height / bounds.width
  }

  var body: some View {
    VStack(spacing: 8) {
      Group {
        if let images {
          ReaderAppearanceImage(images: images)
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .frame(width: max(0, width - 12), height: max(0, width - 12) / thumbnailAspectRatio)
      .padding(6)
      .background(isSelected ? Color.accentColor.opacity(0.12) : .clear,
                  in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
      }

      Text(verbatim: "\(number)")
        .font(.caption.monospacedDigit())
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .frame(minHeight: labelHeight)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .task(id: requestKey) {
      images = nil
      let rendered = await ReaderThumbnailCache.shared.image(
        url: session.url,
        access: session.access,
        pageIndex: number - 1,
        fitting: Self.renderSize
      )
      guard !Task.isCancelled, let rendered else { return }
      images = rendered
    }
  }
}

/// Resolve the cached pair from UIKit traits. A shared UIImage must not be
/// registered into multiple per-row UIImageAssets, which changes its asset.
internal final class ReaderThumbnailImageView: UIImageView {
  var images: ReaderThumbnailImagePair? {
    didSet { refreshAppearance() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: ReaderThumbnailImageView, _: UITraitCollection) in
      view.refreshAppearance()
    }
  }

  required init?(coder: NSCoder) { nil }

  private func refreshAppearance() {
    image = traitCollection.userInterfaceStyle == .dark ? images?.dark : images?.light
  }
}

private struct ReaderAppearanceImage: UIViewRepresentable {
  let images: ReaderThumbnailImagePair

  func makeUIView(context: Context) -> ReaderThumbnailImageView {
    let view = ReaderThumbnailImageView(frame: .zero)
    view.contentMode = .scaleAspectFit
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    return view
  }

  func updateUIView(_ view: ReaderThumbnailImageView, context: Context) {
    view.images = images
  }
}

private struct OutlineList: View {
  @ObservedObject var model: ReaderViewModel

  var body: some View {
    Group {
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
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(entry.page == nil)
          .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .task(id: model.library.preferences.tocGenerationEnabled) { await model.loadGeneratedTOC() }
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
/// A test-only snapshot of the live UIKit viewport, independent of SwiftUI's
/// chrome state. It catches layout, zoom and destination jumps on reveal.
private struct ReaderViewportProbe: View {
  @ObservedObject var reference: PDFViewReference
  @State private var snapshot = ""

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .accessibilityElement()
      .accessibilityIdentifier("debug.pdfViewport")
      .accessibilityValue(snapshot)
      .task {
        while !Task.isCancelled {
          if let view = reference.view, let scroll = readerPDFScrollView(in: view) {
            let frame = view.convert(view.bounds, to: view.window)
            let nextSnapshot = [frame.minX, frame.minY, frame.width, frame.height,
                        view.scaleFactor, scroll.contentOffset.x, scroll.contentOffset.y]
              .map { String(format: "%.3f", Double($0)) }.joined(separator: ",")
            if snapshot != nextSnapshot { snapshot = nextSnapshot }
          }
          do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
      }
  }
}

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

/// Observe the coordinator directly so paragraph and kernel progress refresh
/// the toolbar without rebuilding the PDF reader on every update.
private struct ReaderTranslationButton: View {
  @ObservedObject var coordinator: ReaderTranslationCoordinator
  @ObservedObject var translateAll: TranslateAllPagesJob
  let action: () -> Void

  var body: some View {
    let fraction = translateAll.isRunning
      ? translateAll.progress.fraction
      : coordinator.activeTranslationProgress
    let title = L10n.string(coordinator.showTranslations
      ? "toolbar.showOriginalText" : "toolbar.showTranslatedText")
    Button(action: action) {
      if let fraction {
        TranslationProgressRing(fraction: fraction)
      } else {
        Image(systemName: coordinator.showTranslations ? "text.page" : "character.book.closed")
      }
    }
    .accessibilityLabel(title)
    .accessibilityValue(fraction.map {
      L10n.string("toolbar.translating", String(Int($0 * 100)))
    } ?? "")
    .accessibilityIdentifier("reader.toggleTranslations")
  }
}

/// Desktop-style progress ring on the translation toggle.
private struct TranslationProgressRing: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: 2.2)
      Circle()
        .trim(from: 0, to: min(1, max(0, fraction)))
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(3)
    .frame(width: 22, height: 22)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: fraction)
  }
}


private struct ReaderHeaderGlassSurface: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
    } else {
      content
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
    }
  }
}

private struct ReaderHeaderButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.55 : 1)
  }
}

/// An exclusive gesture prevents a completed hold from also toggling the sidebar.
private struct ReaderSidebarHoldStyle: PrimitiveButtonStyle {
  let onClose: (() -> Void)?

  func makeBody(configuration: Configuration) -> some View {
    HoldControl(configuration: configuration, onClose: onClose)
  }

  private struct HoldControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isPressing = false
    let configuration: PrimitiveButtonStyle.Configuration
    let onClose: (() -> Void)?
    private let holdDuration = 1.3

    var body: some View {
      configuration.label
        .frame(width: 44, height: 44)
        .background {
          Circle()
            .fill(Color.accentColor.opacity(isPressing ? 0.12 : 0))
            .padding(3)
        }
        .overlay {
          if onClose != nil {
            Circle()
              .trim(from: 0, to: isPressing ? 1 : 0)
              .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .rotationEffect(.degrees(-90))
              .padding(3)
              .animation(isPressing ? .linear(duration: holdDuration) : .easeOut(duration: 0.16), value: isPressing)
              .accessibilityHidden(true)
          }
        }
        .scaleEffect(isPressing && !reduceMotion ? 0.95 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .contentShape(Rectangle())
        .onTapGesture { configuration.trigger() }
        .simultaneousGesture(
          LongPressGesture(minimumDuration: holdDuration, maximumDistance: 16)
            .updating($isPressing) { value, state, _ in state = value }
            .onEnded { recognized in
              if recognized, let onClose {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onClose()
              }
            }
        )
        .accessibilityAction { configuration.trigger() }
        .accessibilityActions {
          if let onClose {
            Button(L10n.string("menu.extra.messages.Close Document"), action: onClose)
          }
        }
    }
  }
}
