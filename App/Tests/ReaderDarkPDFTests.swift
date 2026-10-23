import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

final class ReaderDarkPDFTests: XCTestCase {
  @MainActor
  func testCompositeOverlayCacheReleasesChildrenAndKeepsMountedPages() throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
      .pdfData { renderer in for _ in 0..<24 { renderer.beginPage() } }
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .translated
    preferences.engine = .precise
    preferences.readingLinksEnabled = true
    let translation = ReaderTranslationCoordinator(
      document: document, documentID: UUID().uuidString, preferences: preferences, sourceData: data
    )
    let reading = ReadingAidsOverlayProvider(document: document, preferences: preferences, sourceData: data)
    let provider = ReaderPageOverlayCompositeProvider(providers: [translation, reading])
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let firstPage = try XCTUnwrap(document.page(at: 0))
    let mounted = try XCTUnwrap(provider.overlayView(for: firstPage, in: view))
    let root = UIView()
    root.addSubview(mounted)
    let retained = NSHashTable<UIView>.weakObjects()
    for index in 1..<24 {
      try autoreleasepool {
        let overlay = try XCTUnwrap(provider.overlayView(for: XCTUnwrap(document.page(at: index)), in: view))
        retained.add(overlay)
        overlay.subviews.forEach { retained.add($0) }
      }
    }
    XCTAssertLessThanOrEqual(retained.allObjects.count, 8 * 2 + 16,
                            "Composite/reading caches and the larger warm translation cache stay bounded")
    XCTAssertTrue(mounted === provider.overlayView(for: firstPage, in: view), "Mounted content must survive eviction")
    provider.didEndDisplayingOverlay(root, for: firstPage, in: view)
    XCTAssertFalse(mounted === provider.overlayView(for: firstPage, in: view))
  }

  @MainActor
  func testTranslationOverlayCacheBoundsAndRetirement() throws {
    let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
      .pdfData { renderer in
        for _ in 0..<40 { renderer.beginPage() }
      }
    let document = try XCTUnwrap(ReaderPDFDocument(data: bytes))
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .original
    let coordinator = ReaderTranslationCoordinator(
      document: document, documentID: UUID().uuidString, preferences: preferences, sourceData: bytes
    )
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let retained = NSHashTable<UIView>.weakObjects()
    for index in 0..<40 {
      try autoreleasepool {
        let page = try XCTUnwrap(document.page(at: index))
        retained.add(try XCTUnwrap(coordinator.overlayView(for: page, in: view)))
      }
    }
    autoreleasepool { XCTAssertLessThanOrEqual(retained.allObjects.count, 16) }
    let page = try XCTUnwrap(document.page(at: 0))
    weak var retired: UIView?
    try autoreleasepool {
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view))
      retired = overlay
      let root = UIView()
      root.addSubview(overlay)
      coordinator.didEndDisplayingOverlay(root, for: page, in: view)
      overlay.removeFromSuperview()
    }
    autoreleasepool {
      XCTAssertNotNil(retired, "Retired translations stay warm for reverse scrolling")
      XCTAssertTrue(retired === coordinator.overlayView(for: page, in: view))
    }
    coordinator.releaseDetachedResources()
    XCTAssertNil(retired, "Memory pressure must release detached translation bitmaps")
  }

  @MainActor
  func testLateOverlayRetirementDoesNotEvictReboundContent() throws {
    let data = try XCTUnwrap(blankPage().dataRepresentation)
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .original
    let coordinator = ReaderTranslationCoordinator(
      document: document, documentID: UUID().uuidString, preferences: preferences, sourceData: data
    )
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let page = try XCTUnwrap(document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view))
    let oldRoot = UIView()
    let newRoot = UIView()
    oldRoot.addSubview(overlay)
    newRoot.addSubview(overlay)
    coordinator.didEndDisplayingOverlay(oldRoot, for: page, in: view)
    XCTAssertTrue(overlay === coordinator.overlayView(for: page, in: view))
  }

  @MainActor
  func testIdenticalRemotePDFPreservesTilesButChangedPDFReplacesThem() throws {
    let data = try XCTUnwrap(blankPage().dataRepresentation)
    let view = ReaderTiledPDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.setPDFData(data)
    let layer = try XCTUnwrap(view.layer as? ReaderPDFTileLayer)
    let original = try XCTUnwrap(layer.content.withLock { $0 })
    for _ in 0..<30 { view.setPDFData(data) }
    let unchanged = try XCTUnwrap(layer.content.withLock { $0 })
    XCTAssertTrue(original.document === unchanged.document)
    view.setInverted(true)
    XCTAssertTrue(layer.content.withLock { $0?.inverted == true })
    let changed = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
      .pdfData { renderer in
        renderer.beginPage()
        renderer.cgContext.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
      }
    view.setPDFData(changed)
    let replaced = try XCTUnwrap(layer.content.withLock { $0 })
    XCTAssertFalse(original.document === replaced.document)
    XCTAssertTrue(layer.content.withLock { $0?.inverted == true })
  }

  @MainActor
  func testUnrelatedUpdatesPreserveLiveZoomAndFourUpCustomZoom() throws {
    let document = try XCTUnwrap(ReaderPDFDocument(data: XCTUnwrap(blankPage().dataRepresentation)))
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState()
    coordinator.apply(state)
    view.scaleFactor = 2.3 // Pinch while the persisted mode still says fit-page.
    let liveScale = view.scaleFactor
    for _ in 0..<30 {
      state.sidebarVisible.toggle()
      coordinator.apply(state)
    }
    XCTAssertEqual(view.scaleFactor, liveScale, accuracy: 0.001)
    state.displayMode = .fourPages
    state.scaleMode = .custom
    state.zoom = 1.8
    for _ in 0..<30 {
      coordinator.apply(state)
      state.zoom = Double(view.scaleFactor) // PDFView -> SwiftUI feedback.
    }
    XCTAssertEqual(view.scaleFactor, 1.8, accuracy: 0.001)
  }

  @MainActor
  func testTranslationUpdatesReuseLabelsAndRemoteTiles() throws {
    let document = try XCTUnwrap(ReaderPDFDocument(data: XCTUnwrap(blankPage().dataRepresentation)))
    let page = try XCTUnwrap(document.page(at: 0))
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let overlay = ReaderTranslationPageOverlay(pageIndex: 0, page: page, pdfView: view)
    overlay.frame = view.bounds
    func paragraph(_ id: Int, _ text: String) -> PageTranslationParagraph {
      .init(paragraph: LayoutParagraph(id: id, text: "Source", x: 10, y: Double(id * 80 + 10),
        width: 180, height: 60, fontSize: 12, bold: false), translation: text, status: .ready)
    }
    var state = PageTranslationState(pageIndex: 0, status: .translating,
      paragraphs: [paragraph(0, "First translation")])
    overlay.update(state: state, showTranslations: true)
    let label = try XCTUnwrap(overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }.first)
    state.paragraphs.append(paragraph(1, "Second translation"))
    overlay.update(state: state, showTranslations: true)
    XCTAssertTrue(label === overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }.first { $0.tag == 0 })
    let data = try XCTUnwrap(page.dataRepresentation)
    overlay.setRemotePageData(data)
    let tiles = try XCTUnwrap(overlay.subviews.compactMap { $0 as? ReaderTiledPDFView }.first)
    for _ in 0..<30 { overlay.setRemotePageData(data) }
    XCTAssertTrue(tiles === overlay.subviews.compactMap { $0 as? ReaderTiledPDFView }.first)
  }

  @MainActor
  func testTranslationTextResolutionTracksMagnification() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let page = UIView(frame: container.bounds)
    container.addSubview(page)
    let label = ReaderTranslationLabel(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    page.addSubview(label)
    label.updateRenderingScale(in: container)
    let normal = label.contentScaleFactor
    page.transform = CGAffineTransform(scaleX: 3, y: 3)
    label.updateRenderingScale(in: container)
    XCTAssertGreaterThan(label.contentScaleFactor, normal)
    XCTAssertGreaterThanOrEqual(label.contentScaleFactor, 6)
    page.transform = .identity
    label.updateRenderingScale(in: container)
    XCTAssertEqual(label.contentScaleFactor, normal)
  }

  @MainActor
  func testTranslationStatesCoalesceUntilPDFInteractionIsIdle() async throws {
    let data = try XCTUnwrap(blankPage().dataRepresentation)
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .translated
    let coordinator = ReaderTranslationCoordinator(
      document: document, documentID: UUID().uuidString, preferences: preferences, sourceData: data
    )
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let page = try XCTUnwrap(document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view))
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.cancelAllTranslations()
    for _ in 0..<4 { await Task.yield() }
    let baseline = coordinator.translationRevision
    view.translationRenderResumeTime = CACurrentMediaTime() + 0.35

    coordinator.acceptTranslationState(makeTranslationState(text: "older"))
    coordinator.acceptTranslationState(makeTranslationState(text: "newest"))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(coordinator.translationRevision, baseline)

    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(coordinator.translationRevision, baseline &+ 1)
    let labels = overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }
    XCTAssertTrue(labels.contains { $0.fittedText == "newest" })
    XCTAssertFalse(labels.contains { $0.fittedText == "older" })
  }

  @MainActor
  func testConfigureDropsQueuedTranslationStateBeforeIdleFlush() async throws {
    let data = try XCTUnwrap(blankPage().dataRepresentation)
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .translated
    preferences.engine = .precise
    let coordinator = ReaderTranslationCoordinator(
      document: document, documentID: UUID().uuidString, preferences: preferences, sourceData: data
    )
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    view.document = document
    let page = try XCTUnwrap(document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view))
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.cancelAllTranslations()
    for _ in 0..<4 { await Task.yield() }
    let baseline = coordinator.translationRevision
    view.translationRenderResumeTime = CACurrentMediaTime() + 0.35
    coordinator.acceptTranslationState(makeTranslationState(text: "stale"))

    var changed = preferences
    changed.targetLanguage = changed.targetLanguage == "de" ? "fr" : "de"
    coordinator.updatePreferences(changed)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(coordinator.translationRevision, baseline)

    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    try await Task.sleep(for: .milliseconds(100))
    let labels = overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }
    XCTAssertFalse(labels.contains { $0.fittedText == "stale" })
  }

  private func makeTranslationState(text: String) -> PageTranslationState {
    PageTranslationState(
      pageIndex: 0,
      status: .translating,
      paragraphs: [
        PageTranslationParagraph(
          paragraph: LayoutParagraph(
            id: 0, text: "Source", x: 10, y: 20, width: 180, height: 60,
            fontSize: 12, bold: false
          ),
          translation: text,
          status: .ready
        )
      ]
    )
  }

  /// A blank page: white paper must come out as 0.75 - 0.5 = 0.25 gray.
  private func blankPage() throws -> PDFPage {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
      .pdfData { $0.beginPage() }
    return try XCTUnwrap(ReaderPDFDocument(data: data)?.page(at: 0))
  }

  private func centerGray(_ image: UIImage) throws -> CGFloat {
    let cgImage = try XCTUnwrap(image.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let x = cgImage.width / 2, y = cgImage.height / 2
    context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
    return CGFloat(pixel[0]) / 255
  }

  func testThumbnailInvertsPaper() throws {
    let page = try blankPage()
    let light = ReaderDarkPDF.thumbnail(of: page, fitting: CGSize(width: 140, height: 188), box: .cropBox, inverted: false)
    let dark = ReaderDarkPDF.thumbnail(of: page, fitting: CGSize(width: 140, height: 188), box: .cropBox, inverted: true)
    XCTAssertEqual(try centerGray(light), 1, accuracy: 0.02)
    XCTAssertEqual(try centerGray(dark), 0.25, accuracy: 0.03)
  }

  func testInvertedImageDimsWhite() throws {
    let white = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { renderer in
      UIColor.white.setFill()
      renderer.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    XCTAssertEqual(try centerGray(ReaderDarkPDF.inverted(white)), 0.25, accuracy: 0.03)
  }

  @MainActor
  func testTranslatedPDFTilesKeepFineVectorDetailWhenZoomed() throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
      .pdfData { renderer in
        renderer.beginPage()
        UIColor.black.setFill()
        // One device pixel at 4x; a page-sized 1x bitmap cannot retain it.
        renderer.cgContext.fill(CGRect(x: 50, y: 0, width: 0.25, height: 100))
      }
    let view = ReaderTiledPDFView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    view.setPDFData(data)
    let layer = try XCTUnwrap(view.layer as? ReaderPDFTileLayer)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 4
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { renderer in
      layer.draw(in: renderer.cgContext)
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: 3 * 4)
    let context = try XCTUnwrap(CGContext(
      data: &pixels, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(cgImage, in: CGRect(x: -199, y: -200, width: 400, height: 400))
    XCTAssertGreaterThan(pixels[0], 240)
    XCTAssertLessThan(pixels[4], 15)
    XCTAssertGreaterThan(pixels[8], 240)

    view.setInverted(true)
    let dark = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { renderer in
      layer.draw(in: renderer.cgContext)
    }
    // The center is the fine black line, which becomes light in dark mode.
    XCTAssertEqual(try centerGray(dark), 0.75, accuracy: 0.04)
  }

}
