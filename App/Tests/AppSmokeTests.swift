import XCTest
import PDFKit
import ReaderCore

@testable import PDFMathReader

final class AppSmokeTests: XCTestCase {
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

  private func thumbnailPDF(pageCount: Int) throws -> Data {
    let document = PDFDocument()
    for index in 0..<pageCount {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200 + index, height: 300), for: .mediaBox)
      document.insert(page, at: index)
    }
    return try XCTUnwrap(document.dataRepresentation())
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
