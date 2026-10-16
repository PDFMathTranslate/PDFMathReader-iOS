import Combine
@preconcurrency import PDFKit
import ReaderCore
import SwiftUI
@preconcurrency import UIKit

@MainActor
final class PDFViewReference: ObservableObject {
  @Published private(set) var version = 0
  private(set) weak var view: PDFView?

  func attach(_ view: PDFView) {
    self.view = view
    version += 1
  }
}

// P2 hook: translation overlays can supply a provider through this environment value.
@MainActor
public protocol ReaderPageOverlayProviding: AnyObject, Sendable {
  func overlayView(for page: PDFPage, in pdfView: PDFView) -> UIView?
}

private struct ReaderPageOverlayProviderKey: EnvironmentKey {
  static let defaultValue: (any ReaderPageOverlayProviding)? = nil
}

public extension EnvironmentValues {
  var readerPageOverlayProvider: (any ReaderPageOverlayProviding)? {
    get { self[ReaderPageOverlayProviderKey.self] }
    set { self[ReaderPageOverlayProviderKey.self] = newValue }
  }
}

@MainActor
private final class PDFPageOverlayBridge: NSObject, @preconcurrency PDFPageOverlayViewProvider {
  var provider: (any ReaderPageOverlayProviding)?
  var drawingModel: ReaderDrawingModel?

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    let content = provider?.overlayView(for: page, in: view)
    guard let drawingModel, let document = view.document else { return content }
    let index = document.index(for: page)
    guard index != NSNotFound else { return content }
    return ReaderDrawingPageOverlay(
      canvas: drawingModel.canvas(for: index, page: page),
      pageSize: page.bounds(for: .cropBox).size,
      visibleSize: page.bounds(for: view.displayBox).size,
      content: content
    )
  }

  func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
    if let overlay = overlayView as? ReaderDrawingPageOverlay,
       overlay.canvas.superview === overlay {
      drawingModel?.release(overlay.canvas)
    }
  }
}

@MainActor
struct PDFKitView: UIViewRepresentable {
  let document: PDFDocument
  @Binding var readingState: ReadingState
  @ObservedObject var reference: PDFViewReference
  let overlayProvider: (any ReaderPageOverlayProviding)?
  let annotationModel: ReaderAnnotationViewModel?
  var drawingModel: ReaderDrawingModel? = nil
  let onStateChanged: (PDFView) -> Void
  var onScroll: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(onStateChanged: onStateChanged, annotationModel: annotationModel)
  }

  func makeUIView(context: Context) -> PDFView {
    let view = ReaderAnnotationPDFView()
    view.backgroundColor = UIColor.secondarySystemBackground
    view.pageShadowsEnabled = true
    view.minScaleFactor = 0.25
    view.maxScaleFactor = 5
    context.coordinator.setDrawingModel(drawingModel)
    // The view has no window yet, so take the appearance from SwiftUI.
    (document as? ReaderPDFDocument)?.pageCrop = readingState.pageCrop ?? PageCrop()
    view.displayBox = .artBox
    (document as? ReaderPDFDocument)?.invertsPages = context.environment.colorScheme == .dark
    context.coordinator.attach(view, document: document, overlayProvider: overlayProvider)
    reference.attach(view)
    context.coordinator.apply(readingState)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    // Annotation actions replace the PDFDocument instance after writing its
    // managed markup. Keep that live document during SwiftUI updates.
    if view.document == nil || view.document?.pageCount != document.pageCount {
      (document as? ReaderPDFDocument)?.invertsPages = context.environment.colorScheme == .dark
      view.document = document
    }
    context.coordinator.setDarkAppearance(context.environment.colorScheme == .dark, in: view)
    context.coordinator.updateOverlayProvider(overlayProvider)
    context.coordinator.setDrawingModel(drawingModel)
    context.coordinator.onScroll = onScroll
    context.coordinator.observeScrolling()
    context.coordinator.apply(readingState)
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private weak var pdfView: PDFView?
    // PDFKit only asks for overlay views while laying out pages, so the
    // bridge must be installed before the document and then kept stable.
    private let overlayBridge = PDFPageOverlayBridge()
    private var annotationController: ReaderAnnotationInteractionController?
    private let onStateChanged: (PDFView) -> Void
    private let annotationModel: ReaderAnnotationViewModel?
    var onScroll: (() -> Void)?
    private var scrollObservation: NSKeyValueObservation?
    private weak var observedScrollView: UIScrollView?
    private var isReloadingAppearance = false
    private weak var drawingModel: ReaderDrawingModel?
    private var drawingSubscription: AnyCancellable?
    private let fingerPress = UILongPressGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var defaultPanTouchTypes: [NSNumber]?

    init(
      onStateChanged: @escaping (PDFView) -> Void,
      annotationModel: ReaderAnnotationViewModel?
    ) {
      self.onStateChanged = onStateChanged
      self.annotationModel = annotationModel
    }

    func attach(
      _ view: PDFView,
      document: PDFDocument,
      overlayProvider: (any ReaderPageOverlayProviding)?
    ) {
      pdfView = view
      overlayBridge.provider = overlayProvider
      view.pageOverlayViewProvider = overlayBridge
      (document as? ReaderPDFDocument)?.bionicOptions =
        (overlayProvider as? ReadingAidsConfigurationProviding)?.readingAidsConfiguration.bionicOptions
        ?? BionicReadingOptions()
      view.document = document
      fingerPress.addTarget(self, action: #selector(fingerPressed(_:)))
      fingerPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      fingerPress.delegate = self
      view.addGestureRecognizer(fingerPress)
      view.addInteraction(editMenu)
      syncDrawingMode()
      view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: PDFView, _) in
        self?.setDarkAppearance(view.traitCollection.userInterfaceStyle == .dark, in: view)
      }
      if let annotationView = view as? ReaderAnnotationPDFView, let annotationModel {
        let controller = ReaderAnnotationInteractionController(model: annotationModel, pdfView: view)
        annotationController = controller
        annotationView.annotationController = controller
      }

      let center = NotificationCenter.default
      center.addObserver(
        self,
        selector: #selector(handleViewChanged(_:)),
        name: Notification.Name.PDFViewPageChanged,
        object: view
      )
      center.addObserver(
        self,
        selector: #selector(handleViewChanged(_:)),
        name: Notification.Name.PDFViewScaleChanged,
        object: view
      )
    }

    /// PDFView scrolls through a private UIScrollView; watch its offset so
    /// floating controls can react to every scroll, including programmatic ones.
    func observeScrolling() {
      guard let view = pdfView, let scrollView = Self.scrollView(in: view),
            scrollView !== observedScrollView else { return }
      observedScrollView = scrollView
      scrollObservation = scrollView.observe(\.contentOffset, options: [.new, .old]) { [weak self] _, change in
        guard change.newValue != change.oldValue else { return }
        MainActor.assumeIsolated { self?.onScroll?() }
      }
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
      for subview in view.subviews {
        if let scrollView = subview as? UIScrollView { return scrollView }
        if let nested = scrollView(in: subview) { return nested }
      }
      return nil
    }

    /// Dark appearance inverts pages by 0.75, like the desktop reader.
    /// PDFKit caches rendered tiles, so a flip reloads the document while
    /// keeping the reading position and zoom.
    func setDarkAppearance(_ dark: Bool, in view: PDFView) {
      guard let document = view.document as? ReaderPDFDocument, document.invertsPages != dark else { return }
      document.invertsPages = dark
      let destination = view.currentDestination
      let scale = view.scaleFactor
      isReloadingAppearance = true
      view.document = nil
      view.document = document
      view.scaleFactor = scale
      if let destination { view.go(to: destination) }
      isReloadingAppearance = false
      onStateChanged(view)
    }

    func updateOverlayProvider(_ provider: (any ReaderPageOverlayProviding)?) {
      overlayBridge.provider = provider
      guard let view = pdfView, let document = view.document as? ReaderPDFDocument else { return }
      let options = (provider as? ReadingAidsConfigurationProviding)?.readingAidsConfiguration.bionicOptions
        ?? BionicReadingOptions()
      guard options != document.bionicOptions else { return }
      document.bionicOptions = options
      // PDFKit caches page tiles. Rebuild them without resetting live zoom or position.
      let destination = view.currentDestination
      let scale = view.scaleFactor
      isReloadingAppearance = true
      view.document = nil
      view.document = document
      view.scaleFactor = scale
      if let destination { view.go(to: destination) }
      isReloadingAppearance = false
    }

    func setDrawingModel(_ model: ReaderDrawingModel?) {
      overlayBridge.drawingModel = model
      guard model !== drawingModel else { return }
      drawingModel = model
      // @Published emits before the property changes, so use the sent values.
      drawingSubscription = model.map {
        $0.$isDrawing.combineLatest($0.$usesFinger).sink { [weak self] drawing, finger in
          self?.syncDrawingMode(drawing: drawing, finger: finger)
        }
      }
      syncDrawingMode()
    }

    private func syncDrawingMode() {
      syncDrawingMode(drawing: drawingModel?.isDrawing == true, finger: drawingModel?.usesFinger == true)
    }

    private func syncDrawingMode(drawing: Bool, finger: Bool) {
      guard let view = pdfView else { return }
      // Markup mode stops PDFKit text selection from competing with ink.
      view.isInMarkupMode = drawing
      let pencilOnly = drawing && !finger
      fingerPress.isEnabled = pencilOnly
      // Pencil drags ink instead of scrolling; fingers keep scrolling.
      guard let pan = Self.scrollView(in: view)?.panGestureRecognizer else { return }
      if defaultPanTouchTypes == nil { defaultPanTouchTypes = pan.allowedTouchTypes }
      pan.allowedTouchTypes = pencilOnly
        ? pan.allowedTouchTypes.filter { $0.intValue != UITouch.TouchType.pencil.rawValue }
        : defaultPanTouchTypes ?? pan.allowedTouchTypes
    }

    /// A finger long-press in Pencil mode returns to reading mode and selects
    /// the pressed word with the annotation menu, as a long-press does there.
    @objc private func fingerPressed(_ gesture: UILongPressGestureRecognizer) {
      guard gesture.state == .began, let view = pdfView,
            let model = drawingModel, model.exitsOnFingerPress else { return }
      model.isDrawing = false
      let point = gesture.location(in: view)
      guard let page = view.page(for: point, nearest: false),
            let word = page.selectionForWord(at: view.convert(point, to: page)),
            word.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else { return }
      view.setCurrentSelection(word, animate: false)
      view.becomeFirstResponder()
      editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    nonisolated func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func editMenuInteraction(
      _ interaction: UIEditMenuInteraction,
      menuFor configuration: UIEditMenuConfiguration,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      let id = UIMenu.Identifier("com.pdfmathreader.annotate")
      guard !suggestedActions.contains(where: { ($0 as? UIMenu)?.identifier == id }),
            let commands = annotationController?.menuCommands(), !commands.isEmpty
      else { return UIMenu(children: suggestedActions) }
      let annotate = UIMenu(title: L10n.string("ios.annotate"), identifier: id, options: .displayInline, children: commands)
      return UIMenu(children: [annotate] + suggestedActions)
    }

    @objc private func handleViewChanged(_ notification: Notification) {
      guard let view = pdfView, !isReloadingAppearance else { return }
      observeScrolling()
      onStateChanged(view)
    }

    @MainActor
    func apply(_ state: ReadingState) {
      guard let view = pdfView else { return }
      let crop = state.pageCrop ?? PageCrop()
      if let document = view.document as? ReaderPDFDocument, document.pageCrop != crop {
        let destination = view.currentDestination
        let scale = view.scaleFactor
        document.pageCrop = crop
        isReloadingAppearance = true
        view.document = nil
        view.document = document
        view.scaleFactor = scale
        if let destination { view.go(to: destination) }
        isReloadingAppearance = false
      }
      let direction: PDFDisplayDirection = state.scrollDirection == .vertical ? .vertical : .horizontal
      if view.displayDirection != direction { view.displayDirection = direction }
      let displayMode: PDFDisplayMode
      switch state.displayMode {
      case .singlePage:
        displayMode = .singlePageContinuous
      case .twoPages:
        displayMode = .twoUpContinuous
      case .fourPages:
        // PDFKit has no four-up mode. P1 uses two-up with a compact scale so four pages can
        // be scanned across two facing-page pairs without inventing a second page renderer.
        displayMode = .twoUpContinuous
      }

      if view.displayMode != displayMode { view.displayMode = displayMode }
      if view.autoScales { view.autoScales = false }
      let baseScale: CGFloat
      switch state.scaleMode {
      case .fitPage:
        baseScale = view.scaleFactorForSizeToFit
      case .fitWidth:
        baseScale = view.scaleFactorForSizeToFit
      case .actualSize:
        baseScale = 1
      case .custom:
        baseScale = CGFloat(state.zoom)
      }
      let targetScale = state.displayMode == .fourPages
        ? max(view.minScaleFactor, baseScale * 0.75)
        : baseScale
      // Translation progress causes frequent SwiftUI updates. Reapplying the
      // same zoom needlessly invalidates PDFKit's high-resolution page tiles.
      if targetScale.isFinite, targetScale > 0, abs(view.scaleFactor - targetScale) > 0.001 {
        view.scaleFactor = targetScale
      }

      let targetIndex = max(0, min((view.document?.pageCount ?? 1) - 1, state.page - 1))
      if let page = view.document?.page(at: targetIndex), view.currentPage !== page {
        view.go(to: page)
      }
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }
}

@MainActor
struct PDFThumbnailRepresentable: UIViewRepresentable {
  @ObservedObject var reference: PDFViewReference
  let horizontal: Bool

  func makeUIView(context: Context) -> PDFKit.PDFThumbnailView {
    let view = PDFKit.PDFThumbnailView()
    view.layoutMode = horizontal ? .horizontal : .vertical
    view.thumbnailSize = horizontal ? CGSize(width: 52, height: 72) : CGSize(width: 128, height: 174)
    view.contentInset = horizontal
      ? UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
      : UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
    view.backgroundColor = .clear
    view.pdfView = reference.view
    return view
  }

  func updateUIView(_ view: PDFKit.PDFThumbnailView, context: Context) {
    _ = reference.version
    view.layoutMode = horizontal ? .horizontal : .vertical
    view.pdfView = reference.view
  }
}
