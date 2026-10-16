import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderAnnotationInteractionTests: XCTestCase {
  func testRepeatedColorEditsReplaceVisibleHighlight() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for hex in ["#ffb6c1", "#9bd7ff", "#b8e986"] {
      fixture.model.updateColor(for: fixture.annotation, color: hex, pdfView: fixture.pdfView)
      XCTAssertNil(fixture.model.lastError)
      let page = try XCTUnwrap(fixture.pdfView.document?.page(at: 0))
      XCTAssertEqual(page.annotations.count, 1, "Recoloring must replace the old mark")
      let actual = try XCTUnwrap(page.annotations.last).color
      let expected = UIColor(hex: hex)
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
      XCTAssertTrue(actual.getRed(&r, green: &g, blue: &b, alpha: &a))
      XCTAssertTrue(expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea))
      XCTAssertEqual(r, er, accuracy: 0.001)
      XCTAssertEqual(g, eg, accuracy: 0.001)
      XCTAssertEqual(b, eb, accuracy: 0.001)
      XCTAssertEqual(a, ea, accuracy: 0.001)
      let exported = try XCTUnwrap(PDFDocument(data: XCTUnwrap(fixture.model.exportSourceData)))
      XCTAssertEqual(exported.page(at: 0)?.annotations.count, 1)
    }
    fixture.model.delete(fixture.annotation, pdfView: fixture.pdfView)
    XCTAssertEqual(fixture.pdfView.document?.page(at: 0)?.annotations.count, 0)
  }

  func testAddingCommentAndUpdatingColorPersistsAcrossReopen() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertEqual(fixture.model.annotations, [fixture.annotation])

    fixture.model.updateComment(
      for: fixture.annotation,
      comment: "A saved note",
      pdfView: fixture.pdfView
    )
    let commented = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertEqual(commented.kind, .comment)
    XCTAssertEqual(commented.comment, "A saved note")

    fixture.model.updateColor(
      for: commented,
      color: "#ffb6c1",
      pdfView: fixture.pdfView
    )
    let edited = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertEqual(edited.color, "#ffb6c1")
    XCTAssertNotNil(edited.modifiedAt)

    let reopened = ReaderAnnotationViewModel(
      session: fixture.session,
      store: fixture.store,
      quickLinkStore: fixture.quickLinkStore
    )
    await reopened.prepare()
    XCTAssertEqual(reopened.annotations, [edited])
    XCTAssertEqual(try fixture.store.load(fixture.session.id).annotations, [edited])
  }

  func testBlankCommentConvertsCommentBackToHighlightAndPersists() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    fixture.model.updateComment(
      for: fixture.annotation,
      comment: "Temporary note",
      pdfView: fixture.pdfView
    )
    let comment = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertEqual(comment.kind, .comment)

    fixture.model.updateComment(
      for: comment,
      comment: " \n\t",
      pdfView: fixture.pdfView
    )
    let highlight = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertEqual(highlight.kind, .highlight)
    XCTAssertEqual(highlight.comment, " \n\t")

    let reopened = ReaderAnnotationViewModel(
      session: fixture.session,
      store: fixture.store,
      quickLinkStore: fixture.quickLinkStore
    )
    await reopened.prepare()
    XCTAssertEqual(reopened.annotations.first?.kind, .highlight)
    XCTAssertEqual(reopened.annotations.first?.comment, " \n\t")
  }

  func testDeletingAnnotationPersistsEmptyStoreAcrossReopen() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    fixture.model.delete(fixture.annotation, pdfView: fixture.pdfView)

    XCTAssertTrue(fixture.model.annotations.isEmpty)
    XCTAssertTrue(try fixture.store.load(fixture.session.id).annotations.isEmpty)

    let reopened = ReaderAnnotationViewModel(
      session: fixture.session,
      store: fixture.store,
      quickLinkStore: fixture.quickLinkStore
    )
    await reopened.prepare()
    XCTAssertTrue(reopened.annotations.isEmpty)
  }

  func testHitTestingIgnoresHiddenAnnotationsAndMultilineGap() async throws {
    let multiline = ReaderAnnotation(
      id: "multiline-highlight",
      page: 1,
      kind: .highlight,
      text: "First line\nSecond line",
      comment: "",
      color: "#fff36a",
      rects: [
        ReaderAnnotationRect(x: 20, y: 40, width: 80, height: 14),
        ReaderAnnotationRect(x: 20, y: 80, width: 60, height: 14),
      ],
      createdAt: "2026-01-01T00:00:00Z",
      sourceRect: ReaderAnnotationRect(x: 20, y: 40, width: 80, height: 54)
    )
    let fixture = try makeFixture(annotation: multiline)
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let page = try XCTUnwrap(fixture.pdfView.document?.page(at: 0))

    let firstLine = viewportPoint(x: 40, y: 47, on: page, in: fixture.pdfView)
    let secondLine = viewportPoint(x: 35, y: 87, on: page, in: fixture.pdfView)
    let gap = viewportPoint(x: 40, y: 67, on: page, in: fixture.pdfView)

    XCTAssertEqual(
      fixture.model.annotation(at: firstLine, in: fixture.pdfView)?.id,
      multiline.id
    )
    XCTAssertEqual(
      fixture.model.annotation(at: secondLine, in: fixture.pdfView)?.id,
      multiline.id
    )
    XCTAssertNil(fixture.model.annotation(at: gap, in: fixture.pdfView))

    fixture.model.setShowsAnnotations(false, in: fixture.pdfView)
    XCTAssertNil(fixture.model.annotation(at: firstLine, in: fixture.pdfView))

    fixture.model.setShowsAnnotations(true, in: fixture.pdfView)
    XCTAssertEqual(
      fixture.model.annotation(at: firstLine, in: fixture.pdfView)?.id,
      multiline.id
    )
  }

  func testBackgroundPreparationOwnsEmbeddedAnnotationImport() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: try fixture.store.metadataURL(for: fixture.session.id))

    XCTAssertFalse(fixture.model.isPrepared)
    fixture.model.loadIfNeeded(from: fixture.pdfView)
    XCTAssertTrue(fixture.model.annotations.isEmpty)

    await fixture.model.prepare()

    XCTAssertTrue(fixture.model.isPrepared)
    XCTAssertEqual(fixture.model.annotations, [fixture.annotation])
    XCTAssertNotNil(fixture.model.exportSourceData)
  }

  private func makeFixture(annotation: ReaderAnnotation? = nil) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReaderAnnotationInteractionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("source.pdf")
    let document = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
    document.insert(page, at: 0)
    let sourceData = try XCTUnwrap(document.dataRepresentation())
    try sourceData.write(to: sourceURL)

    let session = DocumentSession(
      id: "annotation-interaction-test",
      title: "source.pdf",
      url: sourceURL,
      access: SecurityScopedAccess(url: sourceURL)
    )
    let store = ReaderAnnotationStore(directory: root.appendingPathComponent("Annotations"))
    let quickLinkStore = ReaderQuickLinkStore(directory: root.appendingPathComponent("Links"))
    let seeded = annotation ?? ReaderAnnotation(
      id: "highlight-1",
      page: 1,
      kind: .highlight,
      text: "Selected text",
      comment: "",
      color: "#fff36a",
      rects: [ReaderAnnotationRect(x: 20, y: 40, width: 80, height: 14)],
      createdAt: "2026-01-01T00:00:00Z",
      sourceRect: ReaderAnnotationRect(x: 20, y: 40, width: 80, height: 14)
    )
    try store.save([seeded], for: session.id, sourceURL: sourceURL, sourceData: sourceData)

    let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    pdfView.document = try XCTUnwrap(PDFDocument(data: sourceData))
    pdfView.displayMode = .singlePage
    pdfView.autoScales = true
    pdfView.layoutIfNeeded()
    if let page = pdfView.document?.page(at: 0) {
      pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 100, y: 150)))
      pdfView.layoutIfNeeded()
    }

    let model = ReaderAnnotationViewModel(
      session: session,
      store: store,
      quickLinkStore: quickLinkStore
    )
    return Fixture(
      root: root,
      session: session,
      store: store,
      quickLinkStore: quickLinkStore,
      pdfView: pdfView,
      model: model,
      annotation: seeded
    )
  }

  private func viewportPoint(
    x: CGFloat,
    y: CGFloat,
    on page: PDFPage,
    in pdfView: PDFView
  ) -> CGPoint {
    let pagePoint = ReaderAnnotationPDF.pdfPoint(
      for: ReaderQuickLinkBox(x: Double(x), y: Double(y), width: 1, height: 1),
      on: page
    )
    return pdfView.convert(pagePoint, from: page)
  }

  private struct Fixture {
    let root: URL
    let session: DocumentSession
    let store: ReaderAnnotationStore
    let quickLinkStore: ReaderQuickLinkStore
    let pdfView: PDFView
    let model: ReaderAnnotationViewModel
    let annotation: ReaderAnnotation
  }
}
