import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderTranslationPrefetchTests: XCTestCase {
  func testOverlayViewReturnsShellBeforeIdleHydration() async throws {
    let fixture = try makeFixture(pageCount: 1)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    coordinator.acceptTranslationState(makeState(pageIndex: 0, text: "Hydrated later"))
    let page = try XCTUnwrap(fixture.document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
      as? ReaderTranslationPageOverlay)

    XCTAssertTrue(labels(in: overlay).isEmpty, "overlayView must return an empty shell")
    try await waitForLabel("Hydrated later", in: overlay)
  }

  func testInteractionDefersTranslationRenderingUntilPDFViewIsIdle() async throws {
    let fixture = try makeFixture(pageCount: 1)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    let page = try XCTUnwrap(fixture.document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
      as? ReaderTranslationPageOverlay)
    view.translationRenderResumeTime = CACurrentMediaTime() + 1.0
    coordinator.acceptTranslationState(makeState(pageIndex: 0, text: "After interaction"))

    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(labels(in: overlay).isEmpty, "translation rendering must yield to PDF interaction")

    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    try await waitForLabel("After interaction", in: overlay)
  }

  func testIdleViewportPrefetchesVisiblePagesAndTwoPageNeighbors() async throws {
    let fixture = try makeFixture(pageCount: 7)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    coordinator.updateViewport(currentPageIndex: 3, visiblePageIndices: [3])
    let currentPage = try XCTUnwrap(fixture.document.page(at: 3))
    let currentOverlay = try XCTUnwrap(coordinator.overlayView(for: currentPage, in: view)
      as? ReaderTranslationPageOverlay)
    try await Task.sleep(for: .milliseconds(100))
    let baselineRevision = coordinator.translationRevision

    view.translationRenderResumeTime = CACurrentMediaTime() + 1.0
    for index in 0..<fixture.document.pageCount {
      coordinator.acceptTranslationState(makeState(pageIndex: index, text: "Page " + String(index)))
    }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(labels(in: currentOverlay).isEmpty, "prefetch must wait for an idle PDF view")

    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    try await waitForRevision(after: baselineRevision, coordinator: coordinator)

    // The render queue has already created and fitted the visible page plus
    // two pages on either side. Accessing those overlays must reuse the warm
    // instances rather than starting first-frame hydration now.
    for index in 1...5 {
      let page = try XCTUnwrap(fixture.document.page(at: index))
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
        as? ReaderTranslationPageOverlay)
      XCTAssertEqual(labels(in: overlay).map(\.fittedText), ["Page \(index)"])
    }

    // Pages outside the neighborhood remain shells until requested.
    for index in [0, 6] {
      let page = try XCTUnwrap(fixture.document.page(at: index))
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
        as? ReaderTranslationPageOverlay)
      XCTAssertTrue(labels(in: overlay).isEmpty, "page \(index) is outside the prefetch neighborhood")
    }
  }

  func testIdleViewportPrefetchesAVisibleSpreadAndItsTwoPageNeighbors() async throws {
    let fixture = try makeFixture(pageCount: 12)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    // A two-page visible spread should warm both pages and two pages on each
    // side: pages 3...8 for the visible spread 5...6.
    coordinator.updateViewport(currentPageIndex: 5, visiblePageIndices: [5, 6])
    _ = coordinator.overlayView(for: try XCTUnwrap(fixture.document.page(at: 5)), in: view)
    try await Task.sleep(for: .milliseconds(100))
    let baselineRevision = coordinator.translationRevision
    view.translationRenderResumeTime = CACurrentMediaTime() + 1.0
    for index in 0..<fixture.document.pageCount {
      coordinator.acceptTranslationState(
        makeState(pageIndex: index, text: "Spread " + String(index))
      )
    }
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(coordinator.translationRevision, baselineRevision,
                   "A moving PDF view must hold the whole neighbor batch")

    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    try await waitForRevision(after: baselineRevision, coordinator: coordinator)

    for index in 3...8 {
      let page = try XCTUnwrap(fixture.document.page(at: index))
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
        as? ReaderTranslationPageOverlay)
      XCTAssertEqual(labels(in: overlay).map(\.fittedText), ["Spread \(index)"])
    }

    for index in [0, 1, 2, 9, 10, 11] {
      let page = try XCTUnwrap(fixture.document.page(at: index))
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
        as? ReaderTranslationPageOverlay)
      XCTAssertTrue(labels(in: overlay).isEmpty,
                    "page \(index) is outside the visible spread neighborhood")
    }
  }

  func testOverlayCacheEvictsOldDetachedPagesAndMemoryWarningReleasesWarmPages() async throws {
    let fixture = try makeFixture(pageCount: 24)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    coordinator.updateViewport(currentPageIndex: 10, visiblePageIndices: [10])
    view.translationRenderResumeTime = CACurrentMediaTime() - 1

    var firstPageOverlay: ReaderTranslationPageOverlay?
    for index in 0..<fixture.document.pageCount {
      let page = try XCTUnwrap(fixture.document.page(at: index))
      let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
        as? ReaderTranslationPageOverlay)
      if index == 0 { firstPageOverlay = overlay }
    }

    // The cache is capped at 16 detached overlays. Page 0 is the oldest
    // eligible entry once the viewport neighborhood has been populated.
    weak var detachedAfterWarning: ReaderTranslationPageOverlay?
    do {
      let remountedPage = try XCTUnwrap(fixture.document.page(at: 0))
      let remounted = try XCTUnwrap(coordinator.overlayView(for: remountedPage, in: view)
        as? ReaderTranslationPageOverlay)
      XCTAssertFalse(remounted === firstPageOverlay,
                     "an old detached overlay must be evicted once the cache is full")
      detachedAfterWarning = remounted
    }
    NotificationCenter.default.post(
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
    await Task.yield()
    XCTAssertNil(detachedAfterWarning,
                 "memory pressure must release detached warm translation overlays")
  }

  func testDetachedLabelGeometryUsesPageSpaceForRotatedPage() async throws {
    let fixture = try makeFixture(pageCount: 1)
    let page = try XCTUnwrap(fixture.document.page(at: 0))
    let cropBox = CGRect(x: 30, y: 50, width: 300, height: 400)
    page.setBounds(cropBox, for: .cropBox)
    page.rotation = 90

    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 900, y: 1200, width: 500, height: 700))
    view.autoScales = false
    view.displayBox = .cropBox
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
      as? ReaderTranslationPageOverlay)
    XCTAssertNil(overlay.window, "the prefetch overlay must still be detached")
    let paragraph = LayoutParagraph(
      id: 7,
      text: "Source geometry",
      x: 75,
      y: 105,
      width: 120,
      height: 36,
      fontSize: 18,
      bold: false
    )
    coordinator.acceptTranslationState(
      makeState(pageIndex: 0, text: "Translated geometry", paragraph: paragraph)
    )
    try await waitForLabel("Translated geometry", in: overlay)
    overlay.layoutIfNeeded()
    let label = try XCTUnwrap(labels(in: overlay).first)

    let pageBounds = page.bounds(for: view.displayBox)
    let pageSize = pageBounds.size
    let paragraphHeight = max(CGFloat(paragraph.height), CGFloat(paragraph.fontSize) * 1.1)
    let pageRect = CGRect(
      x: pageBounds.minX + CGFloat(paragraph.x),
      y: pageBounds.maxY - CGFloat(paragraph.y) - paragraphHeight,
      width: CGFloat(paragraph.width),
      height: paragraphHeight
    )
    let expectedBox = CGRect(
      x: (pageRect.minX - pageBounds.minX) * overlay.bounds.width / pageSize.width,
      y: (pageBounds.maxY - pageRect.maxY) * overlay.bounds.height / pageSize.height,
      width: pageRect.width * overlay.bounds.width / pageSize.width,
      height: pageRect.height * overlay.bounds.height / pageSize.height
    )
    let pdfArea = CGFloat(paragraph.width) * paragraphHeight
    let fittingScale = sqrt(max(0, expectedBox.width * expectedBox.height) / pdfArea)
    let cover = max(3, CGFloat(paragraph.fontSize) * 0.28) * fittingScale
    let expectedFrame = expectedBox.insetBy(dx: -cover, dy: -cover)

    XCTAssertEqual(label.frame.minX, expectedFrame.minX, accuracy: 0.5)
    XCTAssertEqual(label.frame.minY, expectedFrame.minY, accuracy: 0.5)
    XCTAssertEqual(label.frame.width, expectedFrame.width, accuracy: 0.5)
    XCTAssertEqual(label.frame.height, expectedFrame.height, accuracy: 0.5)

    // Rebinding the retained detached overlay to a differently positioned PDF
    // view must not pull scroll or rotation transforms into page-space labels.
    let movedView = ReaderAnnotationPDFView(frame: CGRect(x: -700, y: 1800, width: 700, height: 500))
    movedView.autoScales = false
    movedView.displayBox = .cropBox
    movedView.document = fixture.document
    _ = coordinator.overlayView(for: page, in: movedView)
    overlay.layoutIfNeeded()
    XCTAssertEqual(label.frame.minX, expectedFrame.minX, accuracy: 0.5)
    XCTAssertEqual(label.frame.minY, expectedFrame.minY, accuracy: 0.5)
    XCTAssertEqual(label.frame.width, expectedFrame.width, accuracy: 0.5)
    XCTAssertEqual(label.frame.height, expectedFrame.height, accuracy: 0.5)
  }

  func testRetainedOverlayIsReusedAfterRemount() async throws {
    let fixture = try makeFixture(pageCount: 1)
    let coordinator = makeCoordinator(for: fixture)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    view.document = fixture.document
    try await waitForInitialCoordinatorWork()

    coordinator.acceptTranslationState(makeState(pageIndex: 0, text: "Warm overlay"))
    let page = try XCTUnwrap(fixture.document.page(at: 0))
    let overlay = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
      as? ReaderTranslationPageOverlay)
    try await waitForLabel("Warm overlay", in: overlay)

    let retiredRoot = UIView(frame: overlay.bounds)
    retiredRoot.addSubview(overlay)
    coordinator.didEndDisplayingOverlay(retiredRoot, for: page, in: view)
    overlay.removeFromSuperview()

    let remounted = try XCTUnwrap(coordinator.overlayView(for: page, in: view)
      as? ReaderTranslationPageOverlay)
    XCTAssertTrue(remounted === overlay, "a retained overlay must be reused on remount")
    XCTAssertEqual(labels(in: remounted).map(\.fittedText), ["Warm overlay"])
  }

  private struct Fixture {
    let data: Data
    let document: PDFDocument
  }

  private func makeFixture(pageCount: Int) throws -> Fixture {
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
    let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
      for index in 0..<pageCount {
        renderer.beginPage()
        let attributes: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 18),
          .foregroundColor: UIColor.black,
        ]
        ("Source page \(index)" as NSString)
          .draw(at: CGPoint(x: 24, y: 48), withAttributes: attributes)
      }
    }
    return Fixture(data: data, document: try XCTUnwrap(PDFDocument(data: data)))
  }

  private func makeCoordinator(for fixture: Fixture) -> ReaderTranslationCoordinator {
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .original
    preferences.translationService = .openAICompatible
    preferences.openAIBaseURL = "http://["
    return ReaderTranslationCoordinator(
      document: fixture.document,
      documentID: "prefetch-\(UUID().uuidString)",
      preferences: preferences,
      sourceData: fixture.data
    )
  }

  private func makeState(
    pageIndex: Int,
    text: String,
    paragraph: LayoutParagraph? = nil
  ) -> PageTranslationState {
    let paragraph = paragraph ?? LayoutParagraph(
      id: pageIndex,
      text: "Source page \(pageIndex)",
      x: 24,
      y: 48,
      width: 240,
      height: 36,
      fontSize: 18,
      bold: false
    )
    return PageTranslationState(
      pageIndex: pageIndex,
      status: .ready,
      paragraphs: [
        PageTranslationParagraph(
          paragraph: paragraph,
          translation: text,
          status: .ready
        )
      ]
    )
  }

  private func labels(in overlay: ReaderTranslationPageOverlay) -> [ReaderTranslationLabel] {
    overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }
  }

  private func waitForInitialCoordinatorWork() async throws {
    // The coordinator prepares source bytes in a detached task and configures
    // once that task completes. Keep all injected test states after that reset.
    try await Task.sleep(for: .milliseconds(100))
  }

  private func waitForLabel(
    _ text: String,
    in overlay: ReaderTranslationPageOverlay
  ) async throws {
    for _ in 0..<300 {
      if labels(in: overlay).contains(where: { $0.fittedText == text }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for translation label \(text)")
  }

  private func waitForRevision(
    after baseline: Int,
    coordinator: ReaderTranslationCoordinator
  ) async throws {
    for _ in 0..<300 {
      if coordinator.translationRevision > baseline { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the idle render queue")
  }
}
