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
  final class Coordinator: NSObject {
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
      view.document = document
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
    }

    func setDrawingModel(_ model: ReaderDrawingModel?) {
      overlayBridge.drawingModel = model
      pdfView?.isInMarkupMode = model?.isDrawing == true
    }

    @objc private func handleViewChanged(_ notification: Notification) {
      guard let view = pdfView, !isReloadingAppearance else { return }
      observeScrolling()
      onStateChanged(view)
    }

    @MainActor
    func apply(_ state: ReadingState) {
      guard let view = pdfView else { return }
      view.displayDirection = state.scrollDirection == .vertical ? .vertical : .horizontal
      switch state.displayMode {
      case .singlePage:
        view.displayMode = .singlePageContinuous
      case .twoPages:
        view.displayMode = .twoUpContinuous
      case .fourPages:
        // PDFKit has no four-up mode. P1 uses two-up with a compact scale so four pages can
        // be scanned across two facing-page pairs without inventing a second page renderer.
        view.displayMode = .twoUpContinuous
      }

      let baseScale: CGFloat
      switch state.scaleMode {
      case .fitPage:
        view.autoScales = false
        baseScale = view.scaleFactorForSizeToFit
      case .fitWidth:
        view.autoScales = false
        baseScale = view.scaleFactorForSizeToFit
      case .actualSize:
        view.autoScales = false
        baseScale = 1
      case .custom:
        view.autoScales = false
        baseScale = CGFloat(state.zoom)
      }
      view.scaleFactor = state.displayMode == .fourPages
        ? max(view.minScaleFactor, baseScale * 0.75)
        : baseScale

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
