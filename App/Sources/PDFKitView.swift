import Combine
@preconcurrency import PDFKit
import ReaderCore
import SwiftUI
@preconcurrency import UIKit

@MainActor
func readerPDFScrollView(in view: UIView) -> UIScrollView? {
  for subview in view.subviews {
    if let scrollView = subview as? UIScrollView { return scrollView }
    if let nested = readerPDFScrollView(in: subview) { return nested }
  }
  return nil
}

/// Animate only viewport-sized layers. PDFKit performs the actual jump after
/// motion ends, so expensive destination tiles never compete with the slide.
@MainActor
extension ReaderAnnotationPDFView {
  func navigate(to page: PDFPage) {
    navigate(to: PDFDestination(page: page, at: CGPoint(
      x: page.bounds(for: displayBox).minX, y: page.bounds(for: displayBox).maxY
    )))
  }

  func navigate(to destination: PDFDestination) {
    navigationAnimator?.stopAnimation(true)
    navigationCover?.removeFromSuperview()
    navigationAnimator = nil
    navigationCover = nil
    guard let target = destination.page, let document,
          window != nil, !bounds.isEmpty, currentPage !== target,
          !UIAccessibility.isReduceMotionEnabled else {
      go(to: destination)
      return
    }
    let forward = currentPage.map { document.index(for: target) >= document.index(for: $0) } ?? true
    let sign: CGFloat = forward ? 1 : -1
    let vertical = displayDirection == .vertical
    let distance = vertical ? bounds.height : bounds.width
    let cover = UIView(frame: bounds)
    cover.clipsToBounds = true
    cover.backgroundColor = backgroundColor
    // Never drawHierarchy or render a PDF layer synchronously for animation.
    let outgoing = snapshotView(afterScreenUpdates: false) ?? UIView(frame: cover.bounds)
    outgoing.frame = cover.bounds
    let placeholder = UIView(frame: cover.bounds)
    placeholder.backgroundColor = traitCollection.userInterfaceStyle == .dark
      ? UIColor(white: 0.16, alpha: 1) : .systemBackground
    let label = UILabel(frame: placeholder.bounds.insetBy(dx: 24, dy: 24))
    label.text = "\(document.index(for: target) + 1) / \(document.pageCount)"
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.font = .preferredFont(forTextStyle: .subheadline)
    placeholder.addSubview(label)
    let incoming = CGAffineTransform(translationX: vertical ? 0 : sign * distance,
                                     y: vertical ? sign * distance : 0)
    placeholder.transform = incoming
    cover.addSubview(outgoing)
    cover.addSubview(placeholder)
    // Pass subsequent taps through so a new destination can interrupt this jump.
    cover.isUserInteractionEnabled = false
    addSubview(cover)
    navigationCover = cover
    translationRenderResumeTime = CACurrentMediaTime() + 0.5
    let animator = UIViewPropertyAnimator(duration: 0.24, curve: .easeOut) {
      outgoing.transform = CGAffineTransform(translationX: vertical ? 0 : -sign * distance,
                                            y: vertical ? -sign * distance : 0)
      placeholder.transform = .identity
    }
    navigationAnimator = animator
    animator.addCompletion { [weak self, weak cover] position in
      guard let self, let cover, self.navigationCover === cover, position == .end else { return }
      self.go(to: destination)
      cover.removeFromSuperview()
      self.navigationCover = nil
      self.navigationAnimator = nil
      self.translationRenderResumeTime = CACurrentMediaTime() + 0.2
    }
    animator.startAnimation()
  }
}

/// Include a quiet interval after the final offset/scale change, so a result
/// arriving between finger-up and deceleration cannot replace the active tiles.
@MainActor
func readerPDFInteractionIsActive(_ view: PDFView) -> Bool {
  if let scroll = readerPDFScrollView(in: view),
     scroll.isTracking || scroll.isDragging || scroll.isDecelerating
       || scroll.isZooming || scroll.isZoomBouncing { return true }
  return ((view as? ReaderAnnotationPDFView)?.translationRenderResumeTime ?? 0) > CACurrentMediaTime()
}

@MainActor
final class PDFViewReference: ObservableObject {
  @Published private(set) var version = 0
  @Published var scaleRevision = 0
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
  func didEndDisplayingOverlay(_ overlay: UIView, for page: PDFPage, in pdfView: PDFView)
}

public extension ReaderPageOverlayProviding {
  func didEndDisplayingOverlay(_ overlay: UIView, for page: PDFPage, in pdfView: PDFView) {}
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
    provider?.didEndDisplayingOverlay(overlayView, for: page, in: pdfView)
    if let overlay = overlayView as? ReaderDrawingPageOverlay,
       overlay.canvas.superview === overlay {
      drawingModel?.release(overlay.canvas)
    }
  }
}

@MainActor
struct PDFKitView: UIViewRepresentable {
  @EnvironmentObject private var library: LibraryModel
  let document: PDFDocument
  @Binding var readingState: ReadingState
  @ObservedObject var reference: PDFViewReference
  let overlayProvider: (any ReaderPageOverlayProviding)?
  let annotationModel: ReaderAnnotationViewModel?
  var drawingModel: ReaderDrawingModel? = nil
  let onStateChanged: (PDFView) -> Void
  var onScroll: (() -> Void)?
  /// Positive follows the reading axis (down/right); negative goes back.
  var onUserScroll: ((CGFloat) -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(onStateChanged: onStateChanged, annotationModel: annotationModel)
  }

  func makeUIView(context: Context) -> PDFView {
    let view = ReaderAnnotationPDFView()
    view.backgroundColor = UIColor.secondarySystemBackground
    view.displaysPageBreaks = !library.preferences.reducePadding
    view.pageShadowsEnabled = !library.preferences.reducePadding
    view.minScaleFactor = 0.25
    view.maxScaleFactor = 5
    context.coordinator.setDrawingModel(drawingModel)
    // The view has no window yet, so take the appearance from SwiftUI.
    // Keep search, outlines and translation requests on the source document;
    // the view owns temporary compacted pages independently.
    let displayDocument = document.documentURL.flatMap { ReaderPDFDocument(url: $0) }
      ?? document.dataRepresentation().flatMap { ReaderPDFDocument(data: $0) }
      ?? document
    (displayDocument as? ReaderPDFDocument)?.pageCrop = readingState.pageCrop ?? PageCrop()
    view.displayBox = .artBox
    (displayDocument as? ReaderPDFDocument)?.invertsPages = context.environment.colorScheme == .dark
    context.coordinator.attach(view, document: displayDocument, overlayProvider: overlayProvider)
    reference.attach(view)
    context.coordinator.apply(readingState, scaleRevision: reference.scaleRevision)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    // Keep the live display document and its in-place annotation edits.
    if view.document == nil || view.document?.pageCount != document.pageCount {
      (document as? ReaderPDFDocument)?.invertsPages = context.environment.colorScheme == .dark
      view.document = document
    }
    let showsPageBreaks = !library.preferences.reducePadding
    if view.displaysPageBreaks != showsPageBreaks {
      let destination = view.currentDestination
      view.displaysPageBreaks = showsPageBreaks
      view.pageShadowsEnabled = showsPageBreaks
      view.layoutDocumentView()
      if let destination { view.go(to: destination) }
    }
    context.coordinator.setDarkAppearance(context.environment.colorScheme == .dark, in: view)
    context.coordinator.updateOverlayProvider(overlayProvider)
    context.coordinator.setDrawingModel(drawingModel)
    context.coordinator.onScroll = onScroll
    context.coordinator.onUserScroll = onUserScroll
    context.coordinator.observeScrolling()
    context.coordinator.apply(readingState, scaleRevision: reference.scaleRevision)
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
    var onUserScroll: ((CGFloat) -> Void)?
    private var lastPanTranslation: CGFloat = 0
    private var pendingPanDistance: CGFloat = 0
    private var scrollObservation: NSKeyValueObservation?
    private weak var observedScrollView: UIScrollView?
    private var isReloadingAppearance = false
    private weak var drawingModel: ReaderDrawingModel?
    private var drawingSubscription: AnyCancellable?
    private let fingerPress = UILongPressGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var defaultPanTouchTypes: [NSNumber]?
    private struct ScaleRequest: Equatable {
      let mode: ReaderScaleMode
      let zoom: Double
      let displayMode: ReaderDisplayMode
      let direction: ReaderScrollDirection
      let size: CGSize
      let showsPageBreaks: Bool
      let pageIndex: Int
      let revision: Int
    }
    private var latestReadingState: ReadingState?
    private var latestScaleRevision = 0
    private var appliedScaleRequest: ScaleRequest?
    private weak var scaleDocument: PDFDocument?

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
      (view as? ReaderAnnotationPDFView)?.onViewportLayout = { [weak self] in
        guard let self, let state = self.latestReadingState else { return }
        self.apply(state, restorePage: false)
      }
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
      observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handleReadingPan(_:)))
      observedScrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(handleReadingPinch(_:)))
      observedScrollView = scrollView
      scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleReadingPan(_:)))
      scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(handleReadingPinch(_:)))
      scrollObservation = scrollView.observe(\.contentOffset, options: [.new, .old]) { [weak self] scrollView, change in
        guard change.newValue != change.oldValue else { return }
        MainActor.assumeIsolated {
          if let view = self?.pdfView, readerPDFInteractionIsActive(view) {
            self?.deferTranslationRendering()
          }
          self?.onScroll?()
        }
      }
    }

    private func deferTranslationRendering() {
      (pdfView as? ReaderAnnotationPDFView)?.translationRenderResumeTime = CACurrentMediaTime() + 0.2
    }

    @objc private func handleReadingPinch(_ pinch: UIPinchGestureRecognizer) {
      deferTranslationRendering()
    }

    /// Read the gesture rather than contentOffset: changing the header's safe
    /// area, restoring a page, zooming and edge bounce must not flip the chrome.
    @objc private func handleReadingPan(_ pan: UIPanGestureRecognizer) {
      deferTranslationRendering()
      guard let view = pdfView else { return }
      let translation = pan.translation(in: view)
      let position = view.displayDirection == .vertical ? translation.y : translation.x
      if pan.state == .began {
        lastPanTranslation = position
        pendingPanDistance = 0
        return
      }
      guard pan.state == .changed else {
        pendingPanDistance = 0
        return
      }
      let delta = lastPanTranslation - position
      lastPanTranslation = position
      guard pan.numberOfTouches == 1 else {
        pendingPanDistance = 0
        return
      }
      if delta * pendingPanDistance < 0 { pendingPanDistance = 0 }
      pendingPanDistance += delta
      // Match desktop hysteresis: deliberate forward travel hides the bars,
      // while a small reverse movement makes the controls available again.
      guard pendingPanDistance >= 18 || pendingPanDistance <= -6 else { return }
      onUserScroll?(pendingPanDistance)
      pendingPanDistance = 0
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
      readerPDFScrollView(in: view)
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
      guard let view = pdfView, !isReloadingAppearance,
        (view as? ReaderAnnotationPDFView)?.isUpdatingPageGeometry != true else { return }
      observeScrolling()
      onStateChanged(view)
    }

    @MainActor
    func apply(_ state: ReadingState, restorePage: Bool = true, scaleRevision: Int? = nil) {
      latestReadingState = state
      if let scaleRevision { latestScaleRevision = scaleRevision }
      guard let view = pdfView else { return }
      let crop = state.pageCrop ?? PageCrop()
      if let document = view.document as? ReaderPDFDocument, document.pageCrop != crop {
        let destination = view.currentDestination
        let scale = view.scaleFactor
        document.pageCrop = crop
        appliedScaleRequest = nil
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
      let request = ScaleRequest(
        mode: state.scaleMode, zoom: state.scaleMode == .custom ? state.zoom : 0,
        displayMode: state.displayMode, direction: state.scrollDirection, size: view.bounds.size,
        showsPageBreaks: view.displaysPageBreaks, pageIndex: state.page - 1,
        revision: latestScaleRevision
      )
      // A pinch can change PDFKit's live zoom while the saved mode is still
      // fit-page. Translation/pager updates must not snap it back and discard
      // sharp tiles. Apply zoom only for a new setting, document or viewport size.
      if request != appliedScaleRequest || scaleDocument !== view.document {
        appliedScaleRequest = request
        scaleDocument = view.document
        let baseScale: CGFloat
        switch state.scaleMode {
        case .fitPage, .fitWidth:
          baseScale = fittedScale(in: view, state: state) ?? view.scaleFactorForSizeToFit
        case .actualSize: baseScale = 1
        case .custom: baseScale = CGFloat(state.zoom)
        }
        // Custom zoom is already the live PDFView scale, including four-up.
        let targetScale = state.displayMode == .fourPages && state.scaleMode != .custom
          ? max(view.minScaleFactor, baseScale * 0.75) : baseScale
        if targetScale.isFinite, targetScale > 0, abs(view.scaleFactor - targetScale) > 0.001 {
          view.scaleFactor = targetScale
        }
        if state.scaleMode == .fitPage || state.scaleMode == .fitWidth {
          view.layoutIfNeeded()
          alignFittedPage(in: view, state: state)
          // PDFKit can finish its zoom layout on the next turn. Reconcile the
          // offset once more, unless a newer request or pinch has superseded it.
          DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.appliedScaleRequest == request,
              abs(view.scaleFactor - targetScale) < 0.001 else { return }
            view.layoutIfNeeded()
            self.alignFittedPage(in: view, state: state)
          }
        }
      }

      guard restorePage else { return }
      let targetIndex = max(0, min((view.document?.pageCount ?? 1) - 1, state.page - 1))
      if let page = view.document?.page(at: targetIndex), view.currentPage !== page,
         (view as? ReaderAnnotationPDFView)?.navigationAnimator == nil {
        view.go(to: page)
      }
    }

    private func alignFittedPage(in view: PDFView, state: ReadingState) {
      guard let document = view.document, document.pageCount > 0,
        let scroll = Self.scrollView(in: view),
        !scroll.isTracking, !scroll.isDragging, !scroll.isZooming else { return }
      let index = max(0, min(document.pageCount - 1, state.page - 1))
      let twoUp = state.displayMode != .singlePage
      let start = twoUp
        ? (view.displaysAsBook ? (index == 0 ? 0 : 1 + ((index - 1) / 2) * 2) : (index / 2) * 2)
        : index
      let count = twoUp && !(view.displaysAsBook && start == 0) ? 2 : 1
      var rect = CGRect.null
      for i in start..<min(document.pageCount, start + count) {
        guard let page = document.page(at: i) else { continue }
        rect = rect.union(view.convert(page.bounds(for: view.displayBox), from: page))
      }
      guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
      // Horizontal continuous layout starts its first page at x=0. Without
      // leading/trailing scroll room the offset clamp pins a fitted narrow
      // page to one edge, even though the crop itself is symmetric.
      let horizontalPadding = state.scrollDirection == .horizontal
        ? max(0, (view.bounds.width - rect.width) / 2) : 0
      var contentInset = scroll.contentInset
      contentInset.left = horizontalPadding
      contentInset.right = horizontalPadding
      if scroll.contentInset != contentInset { scroll.contentInset = contentInset }
      var offset = scroll.contentOffset
      offset.x += rect.minX - max(0, (view.bounds.width - rect.width) / 2)
      if state.scaleMode == .fitPage {
        offset.y += rect.minY - max(0, (view.bounds.height - rect.height) / 2)
      }
      let insets = scroll.adjustedContentInset
      offset.x = min(max(-insets.left, offset.x), max(-insets.left,
        scroll.contentSize.width - scroll.bounds.width + insets.right))
      offset.y = min(max(-insets.top, offset.y), max(-insets.top,
        scroll.contentSize.height - scroll.bounds.height + insets.bottom))
      scroll.setContentOffset(offset, animated: false)
    }

    /// PDFKit's continuous-layout auto scale always fits width, even when the
    /// user requested a whole page. Measure the retained, rotated page instead.
    private func fittedScale(in view: PDFView, state: ReadingState) -> CGFloat? {
      guard let document = view.document, document.pageCount > 0,
        view.bounds.width > 0, view.bounds.height > 0 else { return nil }
      let index = max(0, min(document.pageCount - 1, state.page - 1))
      let twoUp = state.displayMode != .singlePage
      let start: Int
      if twoUp, view.displaysAsBook {
        start = index == 0 ? 0 : 1 + ((index - 1) / 2) * 2
      } else { start = twoUp ? (index / 2) * 2 : index }
      let count = twoUp && !(view.displaysAsBook && start == 0) ? 2 : 1
      let margins = view.pageBreakMargins
      var size = CGSize.zero
      for pageIndex in start..<min(document.pageCount, start + count) {
        guard let page = document.page(at: pageIndex) else { continue }
        let bounds = page.bounds(for: view.displayBox)
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        size.width += width + margins.left + margins.right
        size.height = max(size.height, height + margins.top + margins.bottom)
      }
      guard size.width > 0, size.height > 0 else { return nil }
      let widthScale = view.bounds.width / size.width
      return state.scaleMode == .fitWidth ? widthScale
        : min(widthScale, view.bounds.height / size.height)
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
