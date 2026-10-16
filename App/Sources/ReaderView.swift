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

struct ReaderView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: ReaderViewModel
  @StateObject private var annotationModel: ReaderAnnotationViewModel
  @StateObject private var drawingModel: ReaderDrawingModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var isLandscape: Bool?
  @State private var sidebarMode: ReaderSidebarMode = .thumbnails
  @State private var isCompactSidebarPresented = false
  @State private var sidebarInteractionVersion = 0
  @State private var isSearchPresented = false
  @State private var isComparePresented = false
  @State private var exportRequest: ReaderExportKind?
  private let onClose: (() -> Void)?

  init(session: DocumentSession, library: LibraryModel, onClose: (() -> Void)? = nil) {
    _model = StateObject(wrappedValue: ReaderViewModel(session: session, library: library))
    _annotationModel = StateObject(wrappedValue: ReaderAnnotationViewModel(session: session))
    _drawingModel = StateObject(wrappedValue: ReaderDrawingModel(session: session))
    _columnVisibility = State(initialValue: Self.defaultColumnVisibility(landscape: Self.sceneIsLandscape()))
    self.onClose = onClose
  }

  init(tab: ReaderTab, onClose: @escaping () -> Void) {
    _model = StateObject(wrappedValue: tab.model)
    _annotationModel = StateObject(wrappedValue: tab.annotations)
    _drawingModel = StateObject(wrappedValue: tab.drawings)
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
            ReaderSidebar(model: model, annotations: annotationModel, drawings: drawingModel, mode: $sidebarMode)
              .navigationSplitViewColumnWidth(256)
              .simultaneousGesture(sidebarDismissGesture)
              .navigationTitle(L10n.string("ios.reader"))
              .navigationBarTitleDisplayMode(.inline)
              // Both split-view columns can contribute a system toggle.
              // Keep only the detail's custom tap/hold sidebar control.
              .toolbar(removing: .sidebarToggle)
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
    .task { await model.loadDocument() }
    .task { await annotationModel.prepare() }
    .task { await drawingModel.prepare() }
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
      let interactionVersion = sidebarInteractionVersion
      columnVisibility = target
      // Reassert once layout settles in case the split view dropped it.
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, sidebarInteractionVersion == interactionVersion else { return }
      if columnVisibility != target { columnVisibility = target }
    }
    .onChange(of: isCompactSidebarPresented) { _, presented in
      if !presented && model.readingState.sidebarVisible {
        model.readingState.sidebarVisible = false
        model.persistReadingState()
      }
    }
    .onAppear {
      ReaderCommandRouter.shared.activate(model)
    }
    .onDisappear {
      drawingModel.isDrawing = false
      drawingModel.flush()
      ReaderCommandRouter.shared.deactivate(model)
      model.persistReadingState()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { drawingModel.flush() }
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
    sidebarInteractionVersion += 1
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

}

private struct ReaderDetail: View {
  @ObservedObject var model: ReaderViewModel
  @ObservedObject var annotations: ReaderAnnotationViewModel
  @ObservedObject var drawings: ReaderDrawingModel
  @Environment(\.readerPageOverlayProvider) private var environmentOverlayProvider
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openReaderTab) private var openReaderTab
  @Environment(\.readerTabStrip) private var readerTabStrip
  @State private var isImporting = false
  @State private var importError: String?
  @StateObject private var pagerVisibility = ReaderPagerVisibility()
  @StateObject private var translateAll: TranslateAllPagesJob
  @StateObject private var kernelAvailability = ReaderKernelMenuAvailability()
  let regular: Bool
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
    PDFKitView(
      document: model.document!,
      readingState: $model.readingState,
      reference: model.pdfViewReference,
      overlayProvider: ReaderPageOverlayCompositeProvider(providers: overlayProviders),
      annotationModel: annotations,
      drawingModel: drawings,
      onStateChanged: model.receivePDFViewState,
      onScroll: pagerVisibility.show
    )
    .background(Color(uiColor: .secondarySystemBackground))
    .background {
      if let coordinator = model.translationCoordinator {
        ReaderAppleTranslationPreparation(coordinator: coordinator)
      }
    }
    .background {
      ReaderKernelAvailabilityMonitor(library: model.library, availability: kernelAvailability)
    }
    .overlay {
      ReaderPager(model: model, visibility: pagerVisibility, compact: !regular)
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
    #endif
    .safeAreaInset(edge: .top, spacing: 0) {
      if let readerTabStrip { readerTabStrip() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !regular {
        PDFThumbnailRepresentable(reference: model.pdfViewReference, horizontal: true)
          .frame(height: 92)
          .background(.bar)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .translationCacheDidClear)) { notification in
      if let id = notification.userInfo?["documentID"] as? String,
        id != model.translationCoordinator?.translationDocumentID { return }
      translateAll.resetForCurrentConfiguration()
    }
    .navigationTitle(model.session.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(removing: .sidebarToggle)
    .toolbar {
      ToolbarItemGroup(placement: .topBarLeading) {
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
            Label(L10n.string("ios.importPDF"), systemImage: "doc.badge.plus")
          }
          .labelStyle(.iconOnly)
        }
      }

      // Keep drawing, translation, and search directly accessible;
      // additional reader controls live in the menu.
      ToolbarItemGroup(placement: .topBarTrailing) {
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
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.pdf],
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
      Button(ReaderExportKind.airDrop.title, systemImage: "airdrop") { onExport(.airDrop) }
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
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      switch mode {
      case .thumbnails:
        ReaderThumbnailList(model: model)
      case .outline:
        OutlineList(model: model)
      case .annotations:
        ReaderAnnotationsSidebar(
          model: annotations,
          drawings: drawings,
          pdfViewReference: model.pdfViewReference,
          onJump: model.goToPage
        )
      }
    }
    .background(.regularMaterial)
  }
}

/// Own the sidebar layout rather than relying on PDFKit's intrinsic thumbnail
/// strip size, which can overflow the split view's proposed width.
private struct ReaderThumbnailList: View {
  @ObservedObject var model: ReaderViewModel

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 16) {
            ForEach(0..<model.pageCount, id: \.self) { index in
              if let page = model.document?.page(at: index) {
                Button {
                  model.goToPage(index + 1)
                } label: {
                  ReaderThumbnail(
                    page: page,
                    session: model.session,
                    number: index + 1,
                    width: geometry.size.width * 0.9,
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

private struct ReaderThumbnail: View {
  let page: PDFPage
  let session: DocumentSession
  let number: Int
  let width: CGFloat
  let isSelected: Bool
  @State private var image: UIImage?
  @ScaledMetric(relativeTo: .caption) private var labelHeight = 20

  private var thumbnailAspectRatio: CGFloat {
    if let image, image.size.width > 0, image.size.height > 0 {
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
        if let image {
          ReaderAppearanceImage(image: image)
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
    .task(id: ObjectIdentifier(page)) {
      let session = session
      let pageIndex = number - 1
      let data = await Task.detached(priority: .utility) {
        withExtendedLifetime(session.access) {
          guard let document = PDFDocument(url: session.url),
            let page = document.page(at: pageIndex) else { return Data?.none }
          return withExtendedLifetime(document) {
            ReaderDarkPDF.thumbnail(
              of: page, fitting: CGSize(width: 280, height: 376), box: .cropBox, inverted: false
            ).pngData()
          }
        }
      }.value
      guard !Task.isCancelled, let data, let thumbnail = UIImage(data: data) else { return }
      image = ReaderDarkPDF.appearanceImage(thumbnail)
    }
  }
}

/// Shows an appearance-dependent image through UIKit. The split view keeps a
/// second sidebar whose SwiftUI `colorScheme` can stay stale after a live
/// appearance switch; `UIImageView` resolves the asset from its own traits.
private struct ReaderAppearanceImage: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.contentMode = .scaleAspectFit
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    return view
  }

  func updateUIView(_ view: UIImageView, context: Context) {
    if view.image !== image { view.image = image }
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
          }
          .buttonStyle(.plain)
          .disabled(entry.page == nil)
        }
        .listStyle(.plain)
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
