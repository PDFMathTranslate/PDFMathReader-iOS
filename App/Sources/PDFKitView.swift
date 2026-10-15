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
  let provider: any ReaderPageOverlayProviding

  init(provider: any ReaderPageOverlayProviding) {
    self.provider = provider
  }

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    provider.overlayView(for: page, in: view)
  }
}

@MainActor
struct PDFKitView: UIViewRepresentable {
  let document: PDFDocument
  @Binding var readingState: ReadingState
  @ObservedObject var reference: PDFViewReference
  let overlayProvider: (any ReaderPageOverlayProviding)?
  let annotationModel: ReaderAnnotationViewModel?
  let onStateChanged: (PDFView) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onStateChanged: onStateChanged, annotationModel: annotationModel)
  }

  func makeUIView(context: Context) -> PDFView {
    let view = ReaderAnnotationPDFView()
    view.backgroundColor = UIColor.secondarySystemBackground
    view.pageShadowsEnabled = true
    view.minScaleFactor = 0.25
    view.maxScaleFactor = 5
    view.document = document
    context.coordinator.attach(view, overlayProvider: overlayProvider)
    reference.attach(view)
    context.coordinator.apply(readingState)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    // Annotation actions replace the PDFDocument instance after writing its
    // managed markup. Keep that live document during SwiftUI updates.
    if view.document == nil || view.document?.pageCount != document.pageCount {
      view.document = document
    }
    context.coordinator.updateOverlayProvider(overlayProvider)
    context.coordinator.apply(readingState)
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var pdfView: PDFView?
    private var overlayBridge: PDFPageOverlayBridge?
    private var annotationController: ReaderAnnotationInteractionController?
    private let onStateChanged: (PDFView) -> Void
    private let annotationModel: ReaderAnnotationViewModel?

    init(
      onStateChanged: @escaping (PDFView) -> Void,
      annotationModel: ReaderAnnotationViewModel?
    ) {
      self.onStateChanged = onStateChanged
      self.annotationModel = annotationModel
    }

    func attach(_ view: PDFView, overlayProvider: (any ReaderPageOverlayProviding)?) {
      pdfView = view
      updateOverlayProvider(overlayProvider)
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

    func updateOverlayProvider(_ provider: (any ReaderPageOverlayProviding)?) {
      guard let view = pdfView else { return }
      if let provider {
        let bridge = PDFPageOverlayBridge(provider: provider)
        overlayBridge = bridge
        view.pageOverlayViewProvider = bridge
      } else {
        overlayBridge = nil
        view.pageOverlayViewProvider = nil
      }
    }

    @objc private func handleViewChanged(_ notification: Notification) {
      guard let view = pdfView else { return }
      onStateChanged(view)
    }

    @MainActor
    func apply(_ state: ReadingState) {
      guard let view = pdfView else { return }
      view.displayDirection = state.scrollDirection == .vertical ? .vertical : .horizontal
      switch state.displayMode {
      case .singlePage:
        view.displayMode = state.scrollDirection == .vertical ? .singlePageContinuous : .singlePage
      case .twoPages:
        view.displayMode = state.scrollDirection == .vertical ? .twoUpContinuous : .twoUp
      case .fourPages:
        // PDFKit has no four-up mode. P1 uses two-up with a compact scale so four pages can
        // be scanned across two facing-page pairs without inventing a second page renderer.
        view.displayMode = state.scrollDirection == .vertical ? .twoUpContinuous : .twoUp
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
