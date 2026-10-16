import PDFKit
import ReaderCore
import UIKit
import XCTest
@testable import PDFMathReader

final class TranslationFontTests: XCTestCase {
  @MainActor
  func testSavedFontUpdatesCompletedTranslationWithoutReopeningReader() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
      .pdfData { $0.beginPage() }
    let url = root.appendingPathComponent("font-test.pdf")
    try data.write(to: url)
    let library = LibraryModel(directory: root)
    var preferences = library.preferences
    preferences.engine = .ultraFast
    preferences.translationService = .openAICompatible
    preferences.translationFont = ""
    preferences.translationSerif = false
    preferences.showTranslations = true
    library.savePreferences(preferences)
    let session = DocumentSession(
      id: "font-test", title: "font-test.pdf", url: url, access: SecurityScopedAccess(url: url)
    )
    let model = ReaderViewModel(session: session, library: library)
    await model.loadDocument()
    let document = try XCTUnwrap(model.document)
    let coordinator = try XCTUnwrap(model.translationCoordinator)
    let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    pdfView.document = document
    let overlay = try XCTUnwrap(coordinator.overlayView(for: XCTUnwrap(document.page(at: 0)), in: pdfView)
      as? ReaderTranslationPageOverlay)
    overlay.update(state: PageTranslationState(pageIndex: 0, status: .ready, paragraphs: [
      PageTranslationParagraph(
        paragraph: LayoutParagraph(id: 0, text: "Source text", x: 20, y: 20,
                                   width: 240, height: 60, fontSize: 18, bold: true),
        translation: "Translated text", status: .ready
      )
    ]), showTranslations: true)
    let label = try XCTUnwrap(overlay.subviews.compactMap { $0 as? ReaderTranslationLabel }.first)
    let revision = coordinator.translationRevision

    for name in ["Georgia", "Courier New", ""] {
      preferences.translationFont = name
      library.savePreferences(preferences)
      XCTAssertEqual(label.font.familyName,
                     ReaderTranslationFont.resolve(name: name, serif: false, size: 18, bold: true).familyName)
      let attributedFont = try XCTUnwrap(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
      XCTAssertEqual(attributedFont.familyName, label.font.familyName)
      XCTAssertEqual(label.fittedText, "Translated text")
      XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitBold))
      XCTAssertEqual(coordinator.translationRevision, revision, "Font changes must not restart translation")
    }
    preferences.translationSerif = true
    library.savePreferences(preferences)
    XCTAssertEqual(label.font.familyName,
                   ReaderTranslationFont.resolve(name: "", serif: true, size: 18, bold: true).familyName)
  }

  @MainActor
  func testCoordinatorExportUsesCurrentFontForNativeTranslation() async throws {
    let fixture = try makeCoordinatorExportFixture()
    let documentID = "font-export-\(UUID().uuidString)"
    let preferences = ReaderPreferences(
      targetLanguage: "zh",
      engine: .ultraFast,
      translationService: .siliconFlowFree,
      showTranslations: true,
      translationSerif: false,
      translationFont: ""
    )
    let cacheDirectory = LibraryDirectory.default
      .appendingPathComponent("translation-cache", isDirectory: true)
      .appendingPathComponent("documents", isDirectory: true)
      .appendingPathComponent(documentID, isDirectory: true)
      .appendingPathComponent("paragraphs", isDirectory: true)
      .appendingPathComponent("paragraphs", isDirectory: true)
    let cleanupURLs = try seedNativeTranslationCache(
      paragraphs: fixture.paragraphs,
      documentID: documentID,
      targetLanguage: preferences.targetLanguage,
      cacheDirectory: cacheDirectory
    )
    defer { cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

    let coordinator = ReaderTranslationCoordinator(
      document: fixture.document,
      documentID: documentID,
      preferences: preferences,
      sourceData: fixture.data
    )
    let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 360, height: 450))
    pdfView.document = fixture.document
    _ = try XCTUnwrap(
      coordinator.overlayView(for: XCTUnwrap(fixture.document.page(at: 0)), in: pdfView)
    )
    _ = await coordinator.scheduleFullDocumentTranslation(excluding: [])
    let state = try await waitForReadyState(of: coordinator, pageIndex: 0)
    XCTAssertEqual(state.translatedCount, fixture.paragraphs.count)
    XCTAssertTrue(state.paragraphs.contains { $0.translation == "Native translation 0" })

    var selected = preferences
    selected.translationFont = "Georgia"
    coordinator.updatePreferences(selected)
    let exportedData = try coordinator.exportedPDFData(originalPDFData: fixture.data)
    let exported = try XCTUnwrap(PDFDocument(data: exportedData))
    let page = try XCTUnwrap(exported.page(at: 0))
    let translatedText = try XCTUnwrap(page.string)
    XCTAssertTrue(translatedText.contains("Native translation"))
    XCTAssertTrue(
      fonts(for: "Native", in: page).contains { $0.familyName == "Georgia" },
      "Coordinator export must use the font selected after translation completed"
    )
  }

  func testInstalledFontIsUsedAndBoldIsPreserved() {
    let font = ReaderTranslationFont.resolve(name: "Georgia", serif: false, size: 18, bold: true)
    XCTAssertEqual(font.familyName, "Georgia")
    XCTAssertEqual(font.pointSize, 18)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
  }

  func testUnavailableFontUsesChosenDefault() {
    for serif in [false, true] {
      let fallback = ReaderTranslationFont.resolve(name: "", serif: serif, size: 16)
      let missing = ReaderTranslationFont.resolve(name: "Missing-PMR-Font", serif: serif, size: 16)
      XCTAssertEqual(missing.fontName, fallback.fontName)
      XCTAssertEqual(missing.pointSize, 16)
    }
  }

  @MainActor
  func testBionicEmphasisKeepsSelectedFontFamily() {
    let font = ReaderTranslationFont.resolve(name: "Georgia", serif: false, size: 18)
    let text = readingAidsAttributedString(
      text: "Reading", font: font,
      configuration: ReadingAidsConfiguration(
        bionicOptions: .init(mode: .fixed, fixedLength: 2), bionicOriginalOnly: false
      ),
      isOriginal: false
    )
    let emphasized = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    XCTAssertEqual(emphasized?.familyName, font.familyName)
    XCTAssertTrue(emphasized?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
  }

  @MainActor
  func testRemoteFontSelectsTranslatedWordsButLeavesSharedEquationAndGraphicAlone() throws {
    let pages = try makeRemoteFontPages()
    let renderer = RemoteFontFixture(page: pages.translated, original: pages.source)

    XCTAssertTrue(renderer.runs.contains { $0.text == "Translated" })
    XCTAssertTrue(renderer.runs.contains { $0.text == "prose" })
    XCTAssertFalse(renderer.runs.contains { $0.text == "Source" })
    XCTAssertFalse(renderer.runs.contains { ["shared", "x", "y", "z"].contains($0.text) })

    let size = CGSize(width: 360, height: 450)
    let original = pages.translated.thumbnail(of: size, for: .cropBox)
    let defaultImage = renderer.image(size: size, name: "", serif: false)
    let styledImage = renderer.image(size: size, name: "Georgia", serif: false)
    let serifImage = renderer.image(size: size, name: "", serif: true)
    let restoredImage = renderer.image(size: size, name: "", serif: false)

    XCTAssertLessThan(try pixelDifference(defaultImage, original), 0.00001)
    XCTAssertGreaterThan(try pixelDifference(defaultImage, styledImage), 0.0001)
    XCTAssertGreaterThan(try pixelDifference(defaultImage, serifImage), 0.0001)
    XCTAssertLessThan(try pixelDifference(defaultImage, restoredImage), 0.00001)

    let graphic = try XCTUnwrap(redPixelBounds(in: defaultImage))
    XCTAssertGreaterThan(graphic.width, 10)
    XCTAssertGreaterThan(graphic.height, 10)
    XCTAssertLessThan(
      try pixelDifference(defaultImage, styledImage, in: graphic.insetBy(dx: 4, dy: 4)),
      0.00001
    )

    // Keep these artifacts available when the simulator run is being inspected.
    try? defaultImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-remote-font-default.png"))
    try? styledImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-remote-font-styled.png"))
  }

  @MainActor
  func testRemoteFontHandlesRotatedPageWithNonZeroCropBox() throws {
    let cropBox = CGRect(x: 20, y: 25, width: 320, height: 400)
    let pages = try makeRemoteFontPages(rotation: 90, cropBox: cropBox)
    let renderer = RemoteFontFixture(page: pages.translated, original: pages.source)

    XCTAssertTrue(renderer.runs.contains { $0.text == "Translated" })
    let size = CGSize(width: 420, height: 320)
    let original = renderer.image(size: size, name: "", serif: false)
    let styled = renderer.image(size: size, name: "Georgia", serif: false)
    XCTAssertGreaterThan(try pixelDifference(original, styled), 0.0001)
    let graphic = try XCTUnwrap(redPixelBounds(in: original))
    XCTAssertGreaterThan(graphic.width, 10)
    XCTAssertGreaterThan(graphic.height, 10)
    XCTAssertLessThan(
      try pixelDifference(original, styled, in: graphic.insetBy(dx: 4, dy: 4)),
      0.00001
    )

    // At 90 degrees, the translated line maps near x 35...90 and y 10...230.
    // Leave a margin so antialiasing at the line's edges is still included.
    let translatedRegion = CGRect(x: 20, y: 0, width: 110, height: 245)
    XCTAssertLessThan(
      try pixelDifferenceOutside(original, styled, excluding: translatedRegion),
      0.00001
    )
    try? styled.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-remote-font-rotated.png"))
  }

  @MainActor
  func testRemoteOverlayRefreshesPDFWhenFontChangesAndTogglesVisibility() throws {
    let pages = try makeRemoteFontPages()
    let sourceDocument = pages.sourceDocument
    let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
    let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 360, height: 450))
    pdfView.document = sourceDocument
    let overlay = ReaderTranslationPageOverlay(pageIndex: 0, page: sourcePage, pdfView: pdfView)
    overlay.frame = pdfView.bounds

    overlay.setRemotePageData(pages.translatedData)
    overlay.layoutIfNeeded()
    let imageView = try XCTUnwrap(overlay.subviews.compactMap { $0 as? ReaderTiledPDFView }.first)
    func rendered() -> UIImage {
      UIGraphicsImageRenderer(size: imageView.bounds.size).image { renderer in
        imageView.layer.draw(in: renderer.cgContext)
      }
    }
    let defaultImage = rendered()

    overlay.setTranslationFont(name: "Georgia", serif: false)
    overlay.layoutIfNeeded()
    let styledImage = rendered()
    XCTAssertGreaterThan(try pixelDifference(defaultImage, styledImage), 0.0001)

    overlay.setTranslationFont(name: "", serif: false)
    overlay.layoutIfNeeded()
    let restoredImage = rendered()
    XCTAssertLessThan(try pixelDifference(defaultImage, restoredImage), 0.00001)

    overlay.setTranslationsVisible(false)
    XCTAssertTrue(imageView.isHidden)
    overlay.setTranslationsVisible(true)
    XCTAssertFalse(imageView.isHidden)
  }

  @MainActor
  func testRemoteFontPreservesTintedPageBackgroundWhenRestyling() throws {
    let pages = try makeRemoteFontPages(
      background: UIColor(red: 0.82, green: 0.88, blue: 0.94, alpha: 1)
    )
    let renderer = RemoteFontFixture(page: pages.translated, original: pages.source)
    let size = CGSize(width: 360, height: 450)
    let original = renderer.image(size: size, name: "", serif: false)
    let styled = renderer.image(size: size, name: "Georgia", serif: false)
    let translatedRun = try XCTUnwrap(renderer.runs.first { $0.text == "Translated" })

    XCTAssertGreaterThan(try pixelDifference(original, styled), 0.0001)
    let imageSize = styled.size
    let pixels = try XCTUnwrap(styled.cgImage)
    let scaleX = CGFloat(pixels.width) / imageSize.width
    let scaleY = CGFloat(pixels.height) / imageSize.height
    let runRect = CGRect(
      x: translatedRun.rect.minX * scaleX,
      y: (imageSize.height - translatedRun.rect.maxY) * scaleY,
      width: translatedRun.rect.width * scaleX,
      height: translatedRun.rect.height * scaleY
    )
    XCTAssertGreaterThan(runRect.width, 4)
    XCTAssertGreaterThan(runRect.height, 4)
    XCTAssertGreaterThanOrEqual(runRect.minX, 0)
    XCTAssertGreaterThanOrEqual(runRect.minY, 0)
    XCTAssertLessThanOrEqual(runRect.maxX, CGFloat(pixels.width))
    XCTAssertLessThanOrEqual(runRect.maxY, CGFloat(pixels.height))
    XCTAssertLessThan(try pureWhiteFraction(in: styled, region: runRect), 0.05)
  }

  @MainActor
  func testRemoteFontPDFDataReopensWithSelectableGeorgiaTranslatedText() throws {
    let pages = try makeRemoteFontPages()
    let renderer = RemoteFontFixture(page: pages.translated, original: pages.source)
    let data = try renderer.pdfData(name: "Georgia", serif: false)
    let document = try XCTUnwrap(PDFDocument(data: data))
    let page = try XCTUnwrap(document.page(at: 0))
    let attributed = try XCTUnwrap(page.attributedString)

    XCTAssertTrue(attributed.string.contains("Translated"))
    XCTAssertTrue(attributed.string.contains("prose"))
    XCTAssertTrue(
      fonts(for: "Translated", in: page).contains { $0.familyName == "Georgia" },
      "The exported translated word must remain selectable and carry the selected font"
    )
    XCTAssertTrue(
      fonts(for: "prose", in: page).contains { $0.familyName == "Georgia" },
      "The exported translated word must remain selectable and carry the selected font"
    )

    // Shared source text and the equation are retained by the kernel page and
    // must not acquire the selected translation font.
    let sharedFonts = fonts(for: "shared", in: page)
    XCTAssertFalse(sharedFonts.isEmpty)
    XCTAssertFalse(sharedFonts.contains { $0.familyName == "Georgia" })
    for equationWord in ["x", "y", "z"] {
      let equationFonts = fonts(for: equationWord, in: page)
      XCTAssertFalse(equationFonts.isEmpty)
      XCTAssertFalse(
        equationFonts.contains { $0.familyName == "Georgia" },
        "Equation word \(equationWord) must retain its source font"
      )
    }

    let expected = pages.translated.thumbnail(of: CGSize(width: 360, height: 450), for: .cropBox)
    let exported = page.thumbnail(of: CGSize(width: 360, height: 450), for: .cropBox)
    XCTAssertGreaterThan(try pixelDifference(expected, exported), 0.0001)

    let expectedGraphic = try XCTUnwrap(redPixelBounds(in: expected))
    let exportedGraphic = try XCTUnwrap(redPixelBounds(in: exported))
    XCTAssertEqual(exportedGraphic, expectedGraphic, "Exporting must preserve the graphic geometry")
    XCTAssertLessThan(
      try pixelDifference(expected, exported, in: expectedGraphic.insetBy(dx: 4, dy: 4)),
      0.00001
    )

    let translatedRegion = translatedImageRegion(
      runs: renderer.runs, page: pages.translated, image: exported
    )
    let baselineToStyledOutside = try pixelDifferenceOutside(expected, exported, excluding: translatedRegion)
    XCTAssertLessThan(
      baselineToStyledOutside,
      0.00001,
      "Restyling must remain confined to translated runs"
    )


    try? expected.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-export-font-source.png"))
    try? exported.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-export-font-styled.png"))
  }

  @MainActor
  func testRemoteFontPDFDataPreservesRotatedCropBoundsAndTranslatedPosition() throws {
    let cropBox = CGRect(x: 20, y: 25, width: 320, height: 400)
    let pages = try makeRemoteFontPages(rotation: 90, cropBox: cropBox)
    let renderer = RemoteFontFixture(page: pages.translated, original: pages.source)
    let data = try renderer.pdfData(name: "Georgia", serif: false)
    let document = try XCTUnwrap(PDFDocument(data: data))
    let page = try XCTUnwrap(document.page(at: 0))

    XCTAssertEqual(page.rotation, 90)
    for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
      XCTAssertEqual(page.bounds(for: box), pages.translated.bounds(for: box), "Mismatched \(box) bounds")
    }

    let size = CGSize(width: 420, height: 320)
    let expected = pages.translated.thumbnail(of: size, for: .cropBox)
    let exported = page.thumbnail(of: size, for: .cropBox)
    XCTAssertGreaterThan(try pixelDifference(expected, exported), 0.0001)

    let expectedGraphic = try XCTUnwrap(redPixelBounds(in: expected))
    let exportedGraphic = try XCTUnwrap(redPixelBounds(in: exported))
    XCTAssertEqual(exportedGraphic, expectedGraphic, "Rotated graphic geometry must be preserved")
    XCTAssertLessThan(
      try pixelDifference(expected, exported, in: expectedGraphic.insetBy(dx: 4, dy: 4)),
      0.00001
    )

    let translatedRegion = translatedImageRegion(
      runs: renderer.runs, page: pages.translated, image: exported
    )
    XCTAssertGreaterThan(
      try pixelDifference(expected, exported, in: translatedRegion),
      0.0001,
      "The translated run should be visibly restyled"
    )
    let baselineToStyledOutside = try pixelDifferenceOutside(expected, exported, excluding: translatedRegion)
    XCTAssertLessThan(
      baselineToStyledOutside,
      0.00001,
      "Rotated restyling must remain confined to the translated region"
    )


    try? expected.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-export-font-rotated-source.png"))
    try? exported.pngData()?.write(to: URL(fileURLWithPath: "/tmp/pmr-export-font-rotated-styled.png"))
  }

  @MainActor
  private struct RemoteFontFixture {
    private let renderer: ReaderRemoteTranslationFont

    init(page: PDFPage, original: PDFPage?) {
      renderer = ReaderRemoteTranslationFont(page: page, original: original)
    }

    var runs: [ReaderRemoteTranslationFont.Run] { renderer.runs }

    func image(size: CGSize, name: String, serif: Bool) -> UIImage {
      renderer.image(size: size, name: name, serif: serif)
    }

    func pdfData(name: String, serif: Bool) throws -> Data {
      try renderer.pdfData(name: name, serif: serif)
    }
  }

  private struct RemoteFontPages {
    let sourceData: Data
    let translatedData: Data
    let sourceDocument: PDFDocument
    let translatedDocument: PDFDocument
    let source: PDFPage
    let translated: PDFPage
  }

  private struct CoordinatorExportFixture {
    let data: Data
    let document: PDFDocument
    let paragraphs: [LayoutParagraph]
  }

  @MainActor
  private func makeCoordinatorExportFixture() throws -> CoordinatorExportFixture {
    let bounds = CGRect(x: 0, y: 0, width: 360, height: 450)
    let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
      context.beginPage()
      let font = UIFont(name: "Helvetica", size: 20)!
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.black,
      ]
      ("Source paragraph for coordinator export" as NSString)
        .draw(at: CGPoint(x: 32, y: 280), withAttributes: attributes)
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let page = try XCTUnwrap(document.page(at: 0))
    let items = PDFKitTextExtractor.extract(page: page, pageNumber: 1)
    let paragraphs = LayoutEngine.paragraphs(
      items: items,
      pageHeight: Double(page.bounds(for: .cropBox).height)
    )
    XCTAssertFalse(paragraphs.isEmpty, "The export fixture must contain native text")
    return CoordinatorExportFixture(data: data, document: document, paragraphs: paragraphs)
  }

  private func seedNativeTranslationCache(
    paragraphs: [LayoutParagraph],
    documentID: String,
    targetLanguage: String,
    cacheDirectory: URL
  ) throws -> [URL] {
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    var cleanupURLs: [URL] = []
    let scope = "\(documentID):paragraphs"
    for (index, paragraph) in paragraphs.enumerated() {
      let key = try TranslationCacheKey.paragraph(
        text: paragraph.text,
        language: targetLanguage,
        sourceLanguage: nil,
        model: "siliconflow-free",
        serviceIdentity: nil,
        glossary: [],
        cacheScope: scope
      )
      let cacheURL = cacheDirectory.appendingPathComponent(key).appendingPathExtension("json")
      let value: [String: String] = [
        "translation": "Native translation \(index)",
        "key": key,
        "model": "siliconflow-free",
      ]
      let data = try JSONEncoder().encode(value)
      try data.write(to: cacheURL, options: [.atomic])
      cleanupURLs.append(cacheURL)

      let compatibleKey = try TranslationCacheKey.compatibleParagraph(
        text: paragraph.text,
        language: targetLanguage,
        sourceLanguage: nil,
        glossary: [],
        cacheScope: scope
      )
      cleanupURLs.append(
        cacheDirectory.appendingPathComponent(compatibleKey).appendingPathExtension("translation.json")
      )
    }
    return cleanupURLs
  }

  @MainActor
  private func waitForReadyState(
    of coordinator: ReaderTranslationCoordinator,
    pageIndex: Int
  ) async throws -> PageTranslationState {
    for _ in 0..<300 {
      let states = coordinator.exportSnapshot().statesByPage
      if pageIndex >= 0, pageIndex < states.count, let state = states[pageIndex],
        state.status == .ready {
        return state
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the native translation pipeline")
    throw CancellationError()
  }

  @MainActor
  private func makeRemoteFontPages(
    rotation: Int = 0,
    cropBox: CGRect? = nil,
    background: UIColor = .white
  ) throws -> RemoteFontPages {
    let mediaBox = CGRect(x: 0, y: 0, width: 360, height: 450)
    let sourceData = remoteFontPDFData(mediaBox: mediaBox, translated: false, background: background)
    let translatedData = remoteFontPDFData(mediaBox: mediaBox, translated: true, background: background)
    let sourceDocument = try XCTUnwrap(PDFDocument(data: sourceData))
    let translatedDocument = try XCTUnwrap(PDFDocument(data: translatedData))
    let source = try XCTUnwrap(sourceDocument.page(at: 0))
    let translated = try XCTUnwrap(translatedDocument.page(at: 0))
    if let cropBox {
      source.setBounds(cropBox, for: .cropBox)
      translated.setBounds(cropBox, for: .cropBox)
    }
    source.rotation = rotation
    translated.rotation = rotation
    return RemoteFontPages(
      sourceData: try XCTUnwrap(sourceDocument.dataRepresentation()),
      translatedData: try XCTUnwrap(translatedDocument.dataRepresentation()),
      sourceDocument: sourceDocument,
      translatedDocument: translatedDocument,
      source: source,
      translated: translated
    )
  }

  @MainActor
  private func remoteFontPDFData(
    mediaBox: CGRect,
    translated: Bool,
    background: UIColor = .white
  ) -> Data {
    UIGraphicsPDFRenderer(bounds: mediaBox).pdfData { context in
      context.beginPage()
      background.setFill()
      context.cgContext.fill(mediaBox)

      let proseFont = UIFont(name: "Helvetica", size: 24)!
      let equationFont = UIFont(name: "Courier New", size: 22)!
      let proseAttributes: [NSAttributedString.Key: Any] = [
        .font: proseFont,
        .foregroundColor: UIColor.black,
      ]
      let equationAttributes: [NSAttributedString.Key: Any] = [
        .font: equationFont,
        .foregroundColor: UIColor.black,
      ]
      ((translated ? "Translated prose" : "Source text") as NSString)
        .draw(at: CGPoint(x: 40, y: 350), withAttributes: proseAttributes)
      ("shared" as NSString).draw(at: CGPoint(x: 40, y: 300), withAttributes: proseAttributes)
      ("x + y = z" as NSString).draw(at: CGPoint(x: 40, y: 240), withAttributes: equationAttributes)

      UIColor.red.setFill()
      context.cgContext.fill(CGRect(x: 235, y: 300, width: 75, height: 55))
    }
  }

  private func fonts(for word: String, in page: PDFPage) -> [UIFont] {
    guard let text = page.attributedString else { return [] }
    let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: word) + "(?!\\w)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(location: 0, length: text.length)
    return expression.matches(in: text.string, range: range).compactMap { match in
      text.attribute(.font, at: match.range.location, effectiveRange: nil) as? UIFont
    }
  }

  @MainActor
  private func translatedImageRegion(
    runs: [ReaderRemoteTranslationFont.Run], page: PDFPage, image: UIImage
  ) -> CGRect {
    let crop = page.bounds(for: .cropBox)
    guard crop.width > 0, crop.height > 0, !runs.isEmpty else { return .zero }
    let rotation = ((page.rotation % 360) + 360) % 360
    let rotated = rotation == 90 || rotation == 270
    let sx = image.size.width / (rotated ? crop.height : crop.width)
    let sy = image.size.height / (rotated ? crop.width : crop.height)
    let transform: CGAffineTransform
    switch rotation {
    case 90:
      transform = CGAffineTransform(
        a: 0, b: sy, c: sx, d: 0, tx: -crop.minY * sx, ty: -crop.minX * sy
      )
    case 180:
      transform = CGAffineTransform(
        a: -sx, b: 0, c: 0, d: sy, tx: crop.maxX * sx, ty: -crop.minY * sy
      )
    case 270:
      transform = CGAffineTransform(
        a: 0, b: -sy, c: -sx, d: 0, tx: crop.maxY * sx, ty: crop.maxX * sy
      )
    default:
      transform = CGAffineTransform(
        a: sx, b: 0, c: 0, d: -sy, tx: -crop.minX * sx, ty: crop.maxY * sy
      )
    }
    let pointRegion = runs.reduce(into: CGRect.null) { result, run in
      result = result.union(run.rect.applying(transform).standardized.insetBy(dx: -4, dy: -4))
    }
    guard let cgImage = image.cgImage, !pointRegion.isNull else { return pointRegion }
    let pixelScaleX = CGFloat(cgImage.width) / image.size.width
    let pixelScaleY = CGFloat(cgImage.height) / image.size.height
    return CGRect(
      x: pointRegion.minX * pixelScaleX,
      y: pointRegion.minY * pixelScaleY,
      width: pointRegion.width * pixelScaleX,
      height: pointRegion.height * pixelScaleY
    )
  }

  private struct PixelBuffer {
    let pixels: [UInt8]
    let width: Int
    let height: Int
  }

  private func pixelBuffer(for image: UIImage) throws -> PixelBuffer {
    let cgImage = try XCTUnwrap(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try XCTUnwrap(CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return PixelBuffer(pixels: pixels, width: width, height: height)
  }

  private func pixelDifference(
    _ lhs: UIImage,
    _ rhs: UIImage,
    in region: CGRect? = nil
  ) throws -> CGFloat {
    let a = try pixelBuffer(for: lhs)
    let b = try pixelBuffer(for: rhs)
    guard a.width == b.width, a.height == b.height else {
      XCTFail("Images must have matching pixel dimensions")
      return 0
    }
    let requested = region ?? CGRect(x: 0, y: 0, width: a.width, height: a.height)
    let minX = max(0, Int(floor(requested.minX)))
    let minY = max(0, Int(floor(requested.minY)))
    let maxX = min(a.width, Int(ceil(requested.maxX)))
    let maxY = min(a.height, Int(ceil(requested.maxY)))
    guard minX < maxX, minY < maxY else { return 0 }
    var difference = 0
    var count = 0
    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * a.width + x) * 4
        for channel in 0..<4 {
          difference += abs(Int(a.pixels[offset + channel]) - Int(b.pixels[offset + channel]))
        }
        count += 4
      }
    }
    return CGFloat(difference) / CGFloat(count * 255)
  }

  private func pixelDifferenceOutside(
    _ lhs: UIImage,
    _ rhs: UIImage,
    excluding region: CGRect
  ) throws -> CGFloat {
    let a = try pixelBuffer(for: lhs)
    let b = try pixelBuffer(for: rhs)
    guard a.width == b.width, a.height == b.height else {
      XCTFail("Images must have matching pixel dimensions")
      return 0
    }
    var difference = 0
    var count = 0
    for y in 0..<a.height {
      for x in 0..<a.width {
        guard !region.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) else { continue }
        let offset = (y * a.width + x) * 4
        for channel in 0..<4 {
          difference += abs(Int(a.pixels[offset + channel]) - Int(b.pixels[offset + channel]))
        }
        count += 4
      }
    }
    return count == 0 ? 0 : CGFloat(difference) / CGFloat(count * 255)
  }

  private func redPixelBounds(in image: UIImage) throws -> CGRect? {
    let buffer = try pixelBuffer(for: image)
    var minX = buffer.width
    var minY = buffer.height
    var maxX = -1
    var maxY = -1
    for y in 0..<buffer.height {
      for x in 0..<buffer.width {
        let offset = (y * buffer.width + x) * 4
        let red = Int(buffer.pixels[offset])
        let green = Int(buffer.pixels[offset + 1])
        let blue = Int(buffer.pixels[offset + 2])
        let alpha = Int(buffer.pixels[offset + 3])
        guard alpha > 200, red > 220, green < 60, blue < 60 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(
      x: minX,
      y: minY,
      width: maxX - minX + 1,
      height: maxY - minY + 1
    )
  }

  private func pureWhiteFraction(in image: UIImage, region: CGRect) throws -> CGFloat {
    let buffer = try pixelBuffer(for: image)
    let minX = max(0, Int(floor(region.minX)))
    let minY = max(0, Int(floor(region.minY)))
    let maxX = min(buffer.width, Int(ceil(region.maxX)))
    let maxY = min(buffer.height, Int(ceil(region.maxY)))
    guard minX < maxX, minY < maxY else { return 0 }
    var white = 0
    var count = 0
    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * buffer.width + x) * 4
        let isWhite = buffer.pixels[offset] > 245
          && buffer.pixels[offset + 1] > 245
          && buffer.pixels[offset + 2] > 245
          && buffer.pixels[offset + 3] > 245
        if isWhite { white += 1 }
        count += 1
      }
    }
    return CGFloat(white) / CGFloat(count)
  }
}
