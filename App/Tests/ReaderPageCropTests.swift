import CoreGraphics
import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderPageCropTests: XCTestCase {
  func testVirtualArtBoxUsesCropBoxAndSwapsAxesForRotatedPages() throws {
    let mediaBox = CGRect(x: 10, y: 20, width: 400, height: 600)
    let cropBox = CGRect(x: 30, y: 50, width: 300, height: 500)
    let storedArtBox = CGRect(x: 45, y: 70, width: 260, height: 460)
    let crop = PageCrop(x: 0.2, y: 0.1)

    for rotation in [0, 90, 180, 270] {
      let fixture = try makeDocument(
        mediaBox: mediaBox,
        cropBox: cropBox,
        artBox: storedArtBox,
        rotation: rotation
      )
      let document = fixture.document
      let page = try XCTUnwrap(document.page(at: 0) as? ReaderPDFPage)
      let baselinePage = try XCTUnwrap(fixture.baseline.page(at: 0))
      let baselineCropBox = baselinePage.bounds(for: .cropBox)

      document.pageCrop = crop
      let expected = baselineCropBox.insetBy(
        dx: baselineCropBox.width * CGFloat(rotation % 180 == 0 ? crop.x : crop.y) / 2,
        dy: baselineCropBox.height * CGFloat(rotation % 180 == 0 ? crop.y : crop.x) / 2
      )

      assertRect(page.bounds(for: .artBox), equals: expected)
      assertRect(page.bounds(for: .cropBox), equals: baselineCropBox)
      assertRect(page.bounds(for: .mediaBox), equals: baselinePage.bounds(for: .mediaBox))
    }
  }

  func testResettingPageCropRestoresCropBoxAsVirtualArtBox() throws {
    let cropBox = CGRect(x: 30, y: 50, width: 300, height: 500)
    let fixture = try makeDocument(
      mediaBox: CGRect(x: 10, y: 20, width: 400, height: 600),
      cropBox: cropBox,
      artBox: CGRect(x: 45, y: 70, width: 260, height: 460),
      rotation: 90
    )
    let document = fixture.document
    let page = try XCTUnwrap(document.page(at: 0) as? ReaderPDFPage)
    let baselineCropBox = try XCTUnwrap(fixture.baseline.page(at: 0)).bounds(for: .cropBox)

    document.pageCrop = PageCrop(x: 0.18, y: 0.24)
    XCTAssertNotEqual(page.bounds(for: .artBox), baselineCropBox)

    document.pageCrop = PageCrop()
    XCTAssertEqual(document.pageCrop, PageCrop())
    assertRect(page.bounds(for: .artBox), equals: baselineCropBox)
    assertRect(page.bounds(for: .cropBox), equals: baselineCropBox)
  }

  func testPageCropDoesNotChangeSerializationOrStoredBoxes() throws {
    let mediaBox = CGRect(x: 10, y: 20, width: 400, height: 600)
    let cropBox = CGRect(x: 30, y: 50, width: 300, height: 500)
    let storedArtBox = CGRect(x: 45, y: 70, width: 260, height: 460)
    let fixture = try makeDocument(
      mediaBox: mediaBox,
      cropBox: cropBox,
      artBox: storedArtBox,
      rotation: 270
    )
    let document = fixture.document
    let baselinePage = try XCTUnwrap(fixture.baseline.page(at: 0))
    let before = try XCTUnwrap(document.dataRepresentation())

    document.pageCrop = PageCrop(x: 0.25, y: 0.12)
    let after = try XCTUnwrap(document.dataRepresentation())

    let beforeDocument = try XCTUnwrap(PDFDocument(data: before))
    let beforePage = try XCTUnwrap(beforeDocument.page(at: 0))
    let reopened = try XCTUnwrap(PDFDocument(data: after))
    let page = try XCTUnwrap(reopened.page(at: 0))
    for box: PDFDisplayBox in [.mediaBox, .cropBox, .artBox] {
      assertRect(beforePage.bounds(for: box), equals: baselinePage.bounds(for: box))
      assertRect(page.bounds(for: box), equals: baselinePage.bounds(for: box))
    }
  }

  func testPDFViewArtBoxConversionUsesVirtualCropGeometry() throws {
    let cropBox = CGRect(x: 30, y: 50, width: 300, height: 500)
    let fixture = try makeDocument(
      mediaBox: CGRect(x: 10, y: 20, width: 400, height: 600),
      cropBox: cropBox,
      artBox: cropBox,
      rotation: 0
    )
    let document = fixture.document
    document.pageCrop = PageCrop(x: 0.2, y: 0.1)
    let page = try XCTUnwrap(document.page(at: 0))
    let artBox = page.bounds(for: .artBox)

    let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
    pdfView.displayBox = .artBox
    pdfView.autoScales = false
    pdfView.document = document
    pdfView.scaleFactor = 1
    pdfView.layoutIfNeeded()

    let convertedArt = pdfView.convert(artBox, from: page)
    let convertedCrop = pdfView.convert(cropBox, from: page)
    XCTAssertEqual(pdfView.displayBox, .artBox)
    XCTAssertGreaterThan(convertedCrop.width, convertedArt.width)
    XCTAssertGreaterThan(convertedCrop.height, convertedArt.height)
    XCTAssertEqual(
      convertedArt.width / convertedCrop.width,
      artBox.width / cropBox.width,
      accuracy: 0.02
    )
    XCTAssertEqual(
      convertedArt.height / convertedCrop.height,
      artBox.height / cropBox.height,
      accuracy: 0.02
    )
  }

  func testDrawingOverlayPreservesCropBoxCanvasCoordinates() {
    let canvas = ReaderPencilCanvas()
    let overlay = ReaderDrawingPageOverlay(
      canvas: canvas,
      pageSize: CGSize(width: 300, height: 500),
      visibleSize: CGSize(width: 240, height: 450),
      content: nil
    )
    overlay.frame = CGRect(x: 0, y: 0, width: 480, height: 900)
    overlay.layoutIfNeeded()

    assertRect(
      canvas.frame,
      equals: CGRect(x: -60, y: -50, width: 600, height: 1_000)
    )
    XCTAssertEqual(canvas.bounds.size, CGSize(width: 300, height: 500))
    XCTAssertEqual(canvas.contentSize, CGSize(width: 300, height: 500))
  }

  func testDefaultCropOnlyAppliesWithoutSavedDocumentCrop() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryModel(directory: directory)
    var preferences = library.preferences
    preferences.defaultPageCropEnabled = true
    preferences.defaultPageCropX = 0.2
    preferences.defaultPageCropY = 0.1
    library.savePreferences(preferences)
    let url = directory.appendingPathComponent("sample.pdf")
    let session = DocumentSession(id: "crop-test", title: "Sample", url: url, access: SecurityScopedAccess(url: url))
    let initial = ReaderViewModel(session: session, library: library)
    XCTAssertEqual(initial.readingState.pageCrop, PageCrop(x: 0.2, y: 0.1))
    initial.setPageCrop(PageCrop(x: 0.35, y: 0.15))
    XCTAssertEqual(ReaderViewModel(session: session, library: library).readingState.pageCrop,
                   PageCrop(x: 0.35, y: 0.15))
    initial.setPageCrop(PageCrop())
    XCTAssertEqual(ReaderViewModel(session: session, library: library).readingState.pageCrop, PageCrop(),
                   "A saved reset must take precedence over defaults")
  }

  private func makeDocument(
    mediaBox: CGRect,
    cropBox: CGRect,
    artBox: CGRect,
    rotation: Int
  ) throws -> (document: ReaderPDFDocument, baseline: PDFDocument) {
    let source = PDFDocument()
    let page = PDFPage()
    page.setBounds(mediaBox, for: .mediaBox)
    page.setBounds(cropBox, for: .cropBox)
    page.setBounds(artBox, for: .artBox)
    page.rotation = rotation
    source.insert(page, at: 0)
    let data = try XCTUnwrap(source.dataRepresentation())
    return (
      try XCTUnwrap(ReaderPDFDocument(data: data)),
      try XCTUnwrap(PDFDocument(data: data))
    )
  }

  private func compactionDocument() throws -> ReaderPDFDocument {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
      .pdfData { renderer in
        renderer.beginPage()
        let font = UIFont.systemFont(ofSize: 12)
        ("First paragraph" as NSString).draw(
          at: CGPoint(x: 30, y: 40),
          withAttributes: [.font: font]
        )
        ("Second paragraph" as NSString).draw(
          at: CGPoint(x: 30, y: 340),
          withAttributes: [.font: font]
        )
        renderer.cgContext.fill(CGRect(x: 30, y: 200, width: 100, height: 20))
      }
    return try XCTUnwrap(ReaderPDFDocument(data: data))
  }

  private func assertRect(
    _ actual: CGRect,
    equals expected: CGRect,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
  }
}
