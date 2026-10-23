import XCTest
import PDFKit
import UIKit
import ReaderCore

@testable import PDFMathReader

final class AppSmokeTests: XCTestCase {
  @MainActor
  func testLayoutNotificationsPublishAfterUpdateAndCoalesce() async throws {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
    let delivered = expectation(description: "settled viewport")
    var notifications = 0
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in
      notifications += 1
      delivered.fulfill()
    }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    for _ in 0..<3 {
      NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
    }
    XCTAssertEqual(notifications, 0, "Layout must not publish during a SwiftUI update")
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(notifications, 1)
    withExtendedLifetime(coordinator) {}
  }

  @MainActor
  func testSameSizePageChangePreservesContinuousScrollAndLiveZoom() async throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 900)).pdfData {
      for _ in 0..<8 { $0.beginPage() }
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
    view.displaysPageBreaks = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState()
    state.scrollDirection = .vertical
    state.scaleMode = .fitPage
    coordinator.apply(state)
    try await Task.sleep(for: .milliseconds(100))
    let scroll = try XCTUnwrap(readerPDFScrollView(in: view))
    scroll.contentOffset.y = 730
    let offset = scroll.contentOffset
    state.page = 2
    coordinator.apply(state, restorePage: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1,
      "Crossing a uniform page must not snap the continuous scroll to a page edge")

    view.scaleFactor *= 1.25
    view.layoutIfNeeded()
    let liveScale = view.scaleFactor
    state.page = 3
    coordinator.apply(state, restorePage: false)
    XCTAssertEqual(view.scaleFactor, liveScale, accuracy: 0.001,
      "A page notification must not discard a live pinch and rebuild PDF tiles")
  }

  @MainActor
  func testFitWidthRealignsPageAfterZoomPreservesOldScrollOffset() async throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 900)).pdfData {
      for _ in 0..<3 { $0.beginPage() }
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    view.displaysPageBreaks = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState()
    state.scrollDirection = .horizontal
    state.scaleMode = .custom
    state.zoom = 3
    coordinator.apply(state)
    view.layoutIfNeeded()
    let scroll = try XCTUnwrap(readerPDFScrollView(in: view))
    scroll.contentOffset = CGPoint(x: 400, y: 200)
    state.scaleMode = .fitWidth
    coordinator.apply(state)
    try await Task.sleep(for: .milliseconds(100))
    let page = try XCTUnwrap(document.page(at: 0))
    let rect = view.convert(page.bounds(for: view.displayBox), from: page)
    XCTAssertEqual(rect.width, view.bounds.width, accuracy: 1)
    XCTAssertEqual(rect.minX, 0, accuracy: 1, "Fit must reset the stale horizontal zoom offset")
    XCTAssertEqual(rect.maxX, view.bounds.maxX, accuracy: 1)
    state.scaleMode = .fitPage
    coordinator.apply(state)
    try await Task.sleep(for: .milliseconds(100))
    let wholePage = view.convert(page.bounds(for: view.displayBox), from: page)
    XCTAssertEqual(wholePage.minY, 0, accuracy: 1)
    XCTAssertEqual(wholePage.height, view.bounds.height, accuracy: 1)
  }

  @MainActor
  func testPDFFitUpdatesAfterSidebarViewportResizeWithoutResettingCustomZoom() async throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
    }
    let document = PDFDocument()
    document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    // UIKit need not lay out an unattached view on a physical device.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.displaysPageBreaks = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState()
    state.scaleMode = .fitPage
    coordinator.apply(state)
    let initialScale = view.scaleFactor
    let resize = expectation(description: "Fit recalculated after viewport expands")
    let update = view.onViewportLayout
    view.onViewportLayout = { update?(); resize.fulfill() }
    view.frame.size.width = 800
    view.setNeedsLayout()
    view.layoutIfNeeded()
    await fulfillment(of: [resize], timeout: 3)
    XCTAssertGreaterThan(view.scaleFactor, initialScale + 0.05)
    XCTAssertEqual(view.scaleFactor, min(800.0 / 600, 800.0 / 900), accuracy: 0.01)

    state.scaleMode = .custom
    state.zoom = 1.25
    coordinator.apply(state)
    let customResize = expectation(description: "Custom zoom survives viewport resize")
    view.onViewportLayout = { update?(); customResize.fulfill() }
    view.frame.size.width = 500
    view.setNeedsLayout()
    view.layoutIfNeeded()
    await fulfillment(of: [customResize], timeout: 3)
    XCTAssertEqual(view.scaleFactor, 1.25, accuracy: 0.01)
  }

  @MainActor
  func testFitWidthAndPageUseDistinctCroppedGeometryWithAndWithoutPadding() throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 900)).pdfData {
      $0.beginPage()
    }
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
    view.displayBox = .artBox
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState(pageCrop: PageCrop(x: 0.2, y: 0.2))
    for breaks in [true, false, true] {
      view.displaysPageBreaks = breaks
      let margins = view.pageBreakMargins
      state.scaleMode = .fitWidth
      coordinator.apply(state)
      XCTAssertEqual(view.scaleFactor, 800.0 / 360.0, accuracy: 0.01)
      state.scaleMode = .fitPage
      coordinator.apply(state)
      XCTAssertEqual(view.scaleFactor, 400 / (540 + margins.top + margins.bottom), accuracy: 0.01)
    }
    let fitted = view.scaleFactor
    view.scaleFactor = 1.5
    coordinator.apply(state)
    XCTAssertEqual(view.scaleFactor, 1.5, accuracy: 0.01, "Unrelated refresh preserves a pinch")
    coordinator.apply(state, scaleRevision: 1)
    XCTAssertEqual(view.scaleFactor, fitted, accuracy: 0.01, "Selecting fit again reapplies it")
    state.scaleMode = .custom
    state.zoom = 1.25
    coordinator.apply(state)
    view.displaysPageBreaks = false
    coordinator.apply(state)
    XCTAssertEqual(view.scaleFactor, 1.25, accuracy: 0.01)
  }

  @MainActor
  func testFitWidthVerticalLocksHorizontalOffsetUntilZoomed() async throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 1800)).pdfData {
      $0.beginPage()
    }
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))

    for displaysPageBreaks in [true, false] {
      let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
      view.displaysPageBreaks = displaysPageBreaks
      view.displayBox = .artBox
      view.minScaleFactor = 0.1
      view.maxScaleFactor = 5
      let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
      coordinator.attach(view, document: document, overlayProvider: nil)

      var state = ReadingState(pageCrop: PageCrop(x: 0.1, y: 0.1))
      state.scrollDirection = .vertical
      state.scaleMode = .fitWidth
      coordinator.apply(state)
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))

      let page = try XCTUnwrap(document.page(at: 0))
      let fittedPage = view.convert(page.bounds(for: view.displayBox), from: page)
      XCTAssertEqual(fittedPage.width, view.bounds.width, accuracy: 1,
        "Fit width must consume the viewport width without page-break margins (\(displaysPageBreaks))")
      XCTAssertEqual(fittedPage.minX, 0, accuracy: 1,
        "Fit width must not leave a horizontal cross-axis margin (\(displaysPageBreaks))")

      coordinator.observeScrolling()
      let fitOffset = scrollOffset(for: view)
      let scroll = try XCTUnwrap(readerPDFScrollView(in: view))
      let insets = scroll.adjustedContentInset
      let maxY = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
      let mainOffset = min(maxY, fitOffset.y + 80)
      XCTAssertGreaterThan(mainOffset, fitOffset.y + 10, "The fitted page must retain vertical scrolling")

      scroll.contentOffset = CGPoint(x: fitOffset.x + 80, y: mainOffset)
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(scroll.contentOffset.x, fitOffset.x, accuracy: 1,
        "Fit width must clamp horizontal cross-axis movement (\(displaysPageBreaks))")
      XCTAssertEqual(scroll.contentOffset.y, mainOffset, accuracy: 1,
        "Clamping the cross-axis must preserve vertical scrolling (\(displaysPageBreaks))")

      let fittedScale = view.scaleFactor
      // A live pinch changes PDFKit's scale before the saved fit mode changes.
      view.scaleFactor = fittedScale * 1.25
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      scroll.contentOffset = CGPoint(x: fitOffset.x + 40, y: mainOffset)
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertGreaterThan(scroll.contentOffset.x, fitOffset.x + 10,
        "Cross-axis movement must be available above the fitted width")
      XCTAssertEqual(scroll.contentOffset.y, mainOffset, accuracy: 1,
        "Zooming must preserve the main-axis offset")
    }
  }

  @MainActor
  func testFitHeightHorizontalLocksVerticalOffsetUntilZoomed() async throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 1800)).pdfData {
      $0.beginPage()
    }
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    let page = try XCTUnwrap(document.page(at: 0))
    page.rotation = 90

    for displaysPageBreaks in [true, false] {
      let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
      view.displaysPageBreaks = displaysPageBreaks
      view.displayBox = .artBox
      view.minScaleFactor = 0.1
      view.maxScaleFactor = 5
      let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
      coordinator.attach(view, document: document, overlayProvider: nil)

      var state = ReadingState(pageCrop: PageCrop(x: 0.1, y: 0.15))
      state.scrollDirection = .horizontal
      state.scaleMode = .fitHeight
      coordinator.apply(state)
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))

      let fittedPage = view.convert(page.bounds(for: view.displayBox), from: page)
      XCTAssertEqual(fittedPage.height, view.bounds.height, accuracy: 1,
        "Fit height must consume the viewport height without page-break margins (\(displaysPageBreaks))")
      XCTAssertEqual(fittedPage.minY, 0, accuracy: 1,
        "Fit height must not leave a vertical cross-axis margin (\(displaysPageBreaks))")

      coordinator.observeScrolling()
      let fitOffset = scrollOffset(for: view)
      let scroll = try XCTUnwrap(readerPDFScrollView(in: view))
      let insets = scroll.adjustedContentInset
      let maxX = max(-insets.left, scroll.contentSize.width - scroll.bounds.width + insets.right)
      let mainOffset = min(maxX, fitOffset.x + 80)
      XCTAssertGreaterThan(mainOffset, fitOffset.x + 10, "The fitted page must retain horizontal scrolling")

      scroll.contentOffset = CGPoint(x: mainOffset, y: fitOffset.y + 80)
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(scroll.contentOffset.y, fitOffset.y, accuracy: 1,
        "Fit height must clamp vertical cross-axis movement (\(displaysPageBreaks))")
      XCTAssertEqual(scroll.contentOffset.x, mainOffset, accuracy: 1,
        "Clamping the cross-axis must preserve horizontal scrolling (\(displaysPageBreaks))")

      let fittedScale = view.scaleFactor
      // A live pinch changes PDFKit's scale before the saved fit mode changes.
      view.scaleFactor = fittedScale * 1.25
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      scroll.contentOffset = CGPoint(x: mainOffset, y: fitOffset.y + 40)
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertGreaterThan(scroll.contentOffset.y, fitOffset.y + 10,
        "Cross-axis movement must be available above the fitted height")
      XCTAssertEqual(scroll.contentOffset.x, mainOffset, accuracy: 1,
        "Zooming must preserve the main-axis offset")
    }
  }

  @MainActor
  func testChangingCropKeepsFittedPageCentered() async throws {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 900)).pdfData {
      for _ in 0..<3 { $0.beginPage() }
    }
    let document = try XCTUnwrap(ReaderPDFDocument(data: data))
    let view = ReaderAnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
    view.displayBox = .artBox
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: nil)
    var state = ReadingState()
    for direction in [ReaderScrollDirection.vertical, .horizontal] {
      state.scrollDirection = direction
      for mode in [ReaderScaleMode.fitWidth, .fitPage] {
        state.scaleMode = mode
        for crop in [PageCrop(), PageCrop(x: 0.15, y: 0.1), PageCrop(x: 0.25, y: 0.2)] {
          state.pageCrop = crop
          coordinator.apply(state)
          try await Task.sleep(for: .milliseconds(100))
          let page = try XCTUnwrap(document.page(at: 0))
          let visible = view.convert(page.bounds(for: .artBox), from: page)
          XCTAssertEqual(visible.midX, view.bounds.midX, accuracy: 1,
            "Crop must retain equal left/right viewport margins (\(direction), \(mode), \(crop))")
          if mode == .fitPage {
            XCTAssertEqual(visible.midY, view.bounds.midY, accuracy: 1)
          }
        }
      }
    }
  }

  func testLaunchTypeExists() {
    XCTAssertNotNil(PDFMathReaderApp.self)
  }

  func testAppleLanguageNamesAndCodesResolveToTheSameModels() {
    XCTAssertEqual(
      AppleTranslationLanguages(source: "English", target: "Simplified Chinese"),
      AppleTranslationLanguages(source: "en", target: "zh-Hans")
    )
    XCTAssertEqual(
      AppleTranslationLanguages(source: "", target: "zh-TW"),
      AppleTranslationLanguages(source: nil, target: "zh-Hant")
    )
    XCTAssertNotEqual(
      AppleTranslationLanguages(source: "en", target: "zh"),
      AppleTranslationLanguages(source: "en", target: "zh-TW")
    )
  }

  func testAppleSameLanguageDoesNotRequireDownloadedModels() async throws {
    guard #available(iOS 26.0, *) else { return }
    let provider = AppleTranslationProvider(sourceLanguage: "English", targetLanguage: "en")
    let response = try await provider.complete(
      TranslationProviderRequest(messages: [TranslationMessage(role: "user", content: "A scientific paragraph.")])
    )
    XCTAssertEqual(response.translationContent(), "A scientific paragraph.")
  }

  func testReaderThumbnailCacheCoalescesAndReusesDocument() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("thumbnail.pdf")
    try thumbnailPDF(pageCount: 2).write(to: url)
    let cache = ReaderThumbnailCache(imageByteBudget: 4 * 1024 * 1024, documentLimit: 2)
    let access = SecurityScopedAccess(url: url)

    async let first = cache.image(
      url: url, access: access, pageIndex: 0, fitting: CGSize(width: 140, height: 188)
    )
    async let duplicate = cache.image(
      url: url, access: access, pageIndex: 0, fitting: CGSize(width: 140, height: 188)
    )
    let firstImages = await first
    let duplicateImages = await duplicate
    XCTAssertNotNil(firstImages)
    XCTAssertNotNil(duplicateImages)

    let secondPageImages = await cache.image(
      url: url, access: access, pageIndex: 1, fitting: CGSize(width: 140, height: 188)
    )
    XCTAssertNotNil(secondPageImages)
    let statistics = await cache.statistics()
    XCTAssertEqual(statistics.documentOpenCount, 1)
    XCTAssertEqual(statistics.renderCount, 2)
    XCTAssertEqual(statistics.imageCount, 2)
    XCTAssertLessThanOrEqual(statistics.imageBytes, 4 * 1024 * 1024)
  }

  @MainActor
  func testThumbnailAppearanceSwitchReusesCachedImages() {
    let light = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { renderer in
      UIColor.white.setFill()
      renderer.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    let pair = ReaderThumbnailImagePair(light: light, dark: ReaderDarkPDF.inverted(light))
    let view = ReaderThumbnailImageView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    let window = UIWindow(frame: view.bounds)
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    window.isHidden = false
    defer { window.isHidden = true }
    view.traitOverrides.userInterfaceStyle = .light
    view.layoutIfNeeded()
    view.images = pair
    XCTAssertTrue(view.image === pair.light)
    view.traitOverrides.userInterfaceStyle = .dark
    view.layoutIfNeeded()
    XCTAssertEqual(view.traitCollection.userInterfaceStyle, .dark)
    XCTAssertTrue(view.image === pair.dark)
    view.traitOverrides.userInterfaceStyle = .light
    view.layoutIfNeeded()
    XCTAssertTrue(view.image === pair.light)
  }

  func testReaderThumbnailCacheInvalidatesChangedFileAndBoundsImages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("thumbnail.pdf")
    try thumbnailPDF(pageCount: 1).write(to: url)
    let cache = ReaderThumbnailCache(imageByteBudget: 1, documentLimit: 1)
    let access = SecurityScopedAccess(url: url)

    let firstImages = await cache.image(
      url: url, access: access, pageIndex: 0, fitting: CGSize(width: 140, height: 188)
    )
    XCTAssertNotNil(firstImages)
    let before = await cache.statistics()
    XCTAssertEqual(before.imageCount, 0)
    XCTAssertEqual(before.documentCount, 1)

    // Atomic replacement changes the file identity and size, so stale page
    // pixels cannot survive a companion or annotation rewrite.
    try thumbnailPDF(pageCount: 2).write(to: url, options: .atomic)
    let secondPageImages = await cache.image(
      url: url, access: access, pageIndex: 1, fitting: CGSize(width: 140, height: 188)
    )
    XCTAssertNotNil(secondPageImages)
    let after = await cache.statistics()
    XCTAssertEqual(after.documentOpenCount, 2)
    XCTAssertEqual(after.renderCount, 2)
    XCTAssertEqual(after.documentCount, 1)
    XCTAssertEqual(after.imageCount, 0)
    XCTAssertEqual(after.imageBytes, 0)
  }

  @MainActor
  func testRecentThumbnailPersistsAcrossLibraryReloadAfterOriginalPDFIsRemoved() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-RecentThumbnailTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let pdfURL = root.appendingPathComponent("paper.pdf")
    try thumbnailPDF(pageCount: 1).write(to: pdfURL)
    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    let library = LibraryModel(directory: libraryDirectory)
    let opened = await library.makeSession(for: pdfURL)
    let session = try XCTUnwrap(opened)

    let firstRecent = try XCTUnwrap(library.recents.first)
    let generatedThumbnail = await library.recentThumbnailURL(for: firstRecent)
    let firstThumbnail = try XCTUnwrap(generatedThumbnail)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstThumbnail.path))
    XCTAssertNotNil(UIImage(contentsOfFile: firstThumbnail.path))

    let reopenedLibrary = LibraryModel(directory: libraryDirectory)
    let reopenedRecent = try XCTUnwrap(reopenedLibrary.recents.first)
    XCTAssertEqual(reopenedRecent.id, session.id)
    try FileManager.default.removeItem(at: pdfURL)

    let persistedThumbnail = await reopenedLibrary.recentThumbnailURL(for: reopenedRecent)
    XCTAssertEqual(persistedThumbnail?.standardizedFileURL, firstThumbnail.standardizedFileURL)
    XCTAssertNotNil(persistedThumbnail.flatMap { UIImage(contentsOfFile: $0.path) })
  }

  @MainActor
  func testRecentThumbnailRegeneratesMissingAndCorruptPNGWithoutChangingLastOpened() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-RecentThumbnailTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let pdfURL = root.appendingPathComponent("paper.pdf")
    try thumbnailPDF(pageCount: 1).write(to: pdfURL)
    let library = LibraryModel(directory: root.appendingPathComponent("Library", isDirectory: true))
    let opened = await library.makeSession(for: pdfURL)
    _ = try XCTUnwrap(opened)
    let recent = try XCTUnwrap(library.recents.first)
    let originalLastOpened = try XCTUnwrap(library.recentsStore.document(id: recent.id)?.lastOpened)
    let thumbnailURL = library.recentsStore.thumbnailURL(for: recent.id)

    let missingResult = await library.recentThumbnailURL(for: recent)
    XCTAssertEqual(missingResult?.standardizedFileURL, thumbnailURL.standardizedFileURL)
    XCTAssertNotNil(UIImage(contentsOfFile: thumbnailURL.path))

    try Data("corrupt preview".utf8).write(to: thumbnailURL, options: [.atomic])
    XCTAssertNil(UIImage(contentsOfFile: thumbnailURL.path))
    let corruptResult = await library.recentThumbnailURL(for: recent)
    XCTAssertEqual(corruptResult?.standardizedFileURL, thumbnailURL.standardizedFileURL)
    XCTAssertNotNil(UIImage(contentsOfFile: thumbnailURL.path))

    let savedRecent = try XCTUnwrap(library.recentsStore.document(id: recent.id))
    XCTAssertEqual(savedRecent.lastOpened, originalLastOpened)
    XCTAssertEqual(try XCTUnwrap(library.recents.first).lastOpened, originalLastOpened)
  }

  @MainActor
  func testCancelledThumbnailCallerStillPersistsPreview() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-RecentThumbnailTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let pdfURL = root.appendingPathComponent("paper.pdf")
    try thumbnailPDF(pageCount: 1).write(to: pdfURL)
    let library = LibraryModel(directory: root.appendingPathComponent("Library", isDirectory: true))
    let opened = await library.makeSession(for: pdfURL)
    let session = try XCTUnwrap(opened)
    let thumbnailURL = library.recentsStore.thumbnailURL(for: session.id)

    let caller = Task { @MainActor in
      await library.prepareThumbnail(for: session)
    }
    caller.cancel()
    await caller.value

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertNotNil(UIImage(contentsOfFile: thumbnailURL.path))
  }

  private func thumbnailPDF(pageCount: Int) throws -> Data {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200 + index, height: 300), for: .mediaBox)
      document.insert(page, at: index)
    }
    return try XCTUnwrap(document.dataRepresentation())
  }

  @MainActor
  private func scrollOffset(for view: UIView) -> CGPoint {
    readerPDFScrollView(in: view)?.contentOffset ?? .zero
  }
}

@MainActor
private final class TranslationInteractionScrollView: UIScrollView {
  var simulatedDeceleration = false
  var simulatedZoom = false
  override var isDecelerating: Bool { simulatedDeceleration }
  override var isZooming: Bool { simulatedZoom }
}

final class TranslationInteractionTests: XCTestCase {
  @MainActor
  func testTranslationRenderingWaitsForDecelerationZoomAndQuietInterval() {
    let view = ReaderAnnotationPDFView()
    let scroll = TranslationInteractionScrollView()
    view.insertSubview(scroll, at: 0)
    XCTAssertFalse(readerPDFInteractionIsActive(view))
    scroll.simulatedDeceleration = true
    XCTAssertTrue(readerPDFInteractionIsActive(view))
    scroll.simulatedDeceleration = false
    scroll.simulatedZoom = true
    XCTAssertTrue(readerPDFInteractionIsActive(view))
    scroll.simulatedZoom = false
    view.translationRenderResumeTime = CACurrentMediaTime() + 0.2
    XCTAssertTrue(readerPDFInteractionIsActive(view), "Finger-up must not immediately permit tile replacement")
    view.translationRenderResumeTime = CACurrentMediaTime() - 1
    XCTAssertFalse(readerPDFInteractionIsActive(view))
  }
}
