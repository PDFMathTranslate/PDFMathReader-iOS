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
      let exported = try exportedData(for: fixture)
      let imported = try ReaderAnnotationPDF.importAnnotations(from: exported)
      XCTAssertEqual(imported.annotations, fixture.model.annotations)
    }
    fixture.model.delete(fixture.annotation, pdfView: fixture.pdfView)
    XCTAssertEqual(fixture.pdfView.document?.page(at: 0)?.annotations.count, 0)
    await fixture.model.flushPendingSaves()
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

    await fixture.model.flushPendingSaves()
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

    await fixture.model.flushPendingSaves()
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
    await fixture.model.flushPendingSaves()
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

  func testRapidEditsKeepDocumentAndPageIdentityAndPreserveLinkAndInk() async throws {
    let fixture = try makeFixture(pageCount: 2, includeLinkAndInk: true)
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let document = try XCTUnwrap(fixture.pdfView.document)
    let editedPage = try XCTUnwrap(document.page(at: 0))
    let untouchedPage = try XCTUnwrap(document.page(at: 1))
    let editedLink = try XCTUnwrap(editedPage.annotations.first(where: { subtype(of: $0) == "Link" }))
    let editedInk = try XCTUnwrap(editedPage.annotations.first(where: { subtype(of: $0) == "Ink" }))
    let untouchedLink = try XCTUnwrap(untouchedPage.annotations.first(where: { subtype(of: $0) == "Link" }))

    for (index, hex) in ["#ffb6c1", "#9bd7ff", "#b8e986"].enumerated() {
      fixture.model.updateColor(for: fixture.annotation, color: hex, pdfView: fixture.pdfView)
      let edited = try XCTUnwrap(fixture.model.annotations.first)
      fixture.model.updateComment(
        for: edited,
        comment: "rapid edit \(index)",
        pdfView: fixture.pdfView
      )
    }
    fixture.model.delete(fixture.annotation, pdfView: fixture.pdfView)

    XCTAssertTrue(fixture.pdfView.document === document)
    XCTAssertTrue(document.page(at: 0) === editedPage)
    XCTAssertTrue(document.page(at: 1) === untouchedPage)
    XCTAssertTrue(editedPage.annotations.contains { $0 === editedLink })
    XCTAssertTrue(editedPage.annotations.contains { $0 === editedInk })
    XCTAssertTrue(untouchedPage.annotations.contains { $0 === untouchedLink })
    XCTAssertTrue(editedPage.annotations.allSatisfy { subtype(of: $0) == "Link" || subtype(of: $0) == "Ink" })

    await fixture.model.flushPendingSaves()
  }

  func testPendingSaveExportContainsLatestAnnotationSnapshot() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    fixture.model.updateColor(
      for: fixture.annotation,
      color: "#9bd7ff",
      pdfView: fixture.pdfView
    )
    let latest = try XCTUnwrap(fixture.model.annotations.first)

    // Export while the sidecar writer is still allowed to be pending. The
    // export must combine immutable source bytes with the live model snapshot.
    let exported = try exportedData(for: fixture)
    let imported = try ReaderAnnotationPDF.importAnnotations(from: exported)
    XCTAssertEqual(imported.annotations, [latest])
    let metadata = try ReaderTransferPDF.metadata(from: XCTUnwrap(PDFDocument(data: exported)))
    XCTAssertEqual(metadata?.annotations, [latest])

    await fixture.model.flushPendingSaves()
  }

  func testRapidEditsPersistTheLatestSnapshotAfterFlush() async throws {
    let fixture = try makeFixture()
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for (index, hex) in ["#ffb6c1", "#9bd7ff", "#b8e986"].enumerated() {
      fixture.model.updateColor(for: fixture.annotation, color: hex, pdfView: fixture.pdfView)
      if index == 0 { await Task.yield() }
      let edited = try XCTUnwrap(fixture.model.annotations.first)
      fixture.model.updateComment(
        for: edited,
        comment: "latest edit \(index)",
        pdfView: fixture.pdfView
      )
    }
    let latest = try XCTUnwrap(fixture.model.annotations.first)

    await fixture.model.flushPendingSaves()

    XCTAssertEqual(try fixture.store.load(fixture.session.id).annotations, [latest])
    let savedPDF = try Data(contentsOf: fixture.session.url)
    XCTAssertEqual(
      try ReaderAnnotationPDF.importAnnotations(from: savedPDF).annotations,
      [latest]
    )
  }

  func testPendingDeletionRemovesImportedNativeMarkupFromExportAndDisk() async throws {
    let fixture = try makeFixture(seedAnnotation: false, includeNativeHighlight: true)
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let imported = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertNotNil(imported.nativeRef)
    XCTAssertFalse(fixture.model.exportNativeRefs.isEmpty)

    fixture.model.delete(imported, pdfView: fixture.pdfView)

    let exported = try exportedData(for: fixture)
    XCTAssertTrue(try ReaderAnnotationPDF.importAnnotations(from: exported).annotations.isEmpty)

    await fixture.model.flushPendingSaves()

    XCTAssertTrue(try fixture.store.load(fixture.session.id).annotations.isEmpty)
    let savedPDF = try Data(contentsOf: fixture.session.url)
    XCTAssertTrue(try ReaderAnnotationPDF.importAnnotations(from: savedPDF).annotations.isEmpty)
  }

  func testAddSelectionKeepsPageIdentityAndPersistsSelectedText() async throws {
    let text = "Selectable annotation text"
    let fixture = try makeFixture(
      providedSourceData: selectableTextPDFData(text: text),
      seedAnnotation: false
    )
    await fixture.model.prepare()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let document = try XCTUnwrap(fixture.pdfView.document)
    let page = try XCTUnwrap(document.page(at: 0))
    let pageText = try XCTUnwrap(page.attributedString?.string)
    let range = (pageText as NSString).range(of: text)
    XCTAssertNotEqual(range.location, NSNotFound)
    let selection = try XCTUnwrap(page.selection(for: range))
    XCTAssertEqual(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), text)

    fixture.model.addSelection(
      selection,
      in: fixture.pdfView,
      color: "#9bd7ff",
      comment: "Saved selection"
    )

    let added = try XCTUnwrap(fixture.model.annotations.first)
    XCTAssertEqual(added.kind, .comment)
    XCTAssertEqual(added.text, text)
    XCTAssertEqual(added.comment, "Saved selection")
    XCTAssertTrue(fixture.pdfView.document === document)
    XCTAssertTrue(document.page(at: 0) === page)

    let exported = try exportedData(for: fixture)
    XCTAssertEqual(
      try ReaderAnnotationPDF.importAnnotations(from: exported).annotations,
      [added]
    )

    await fixture.model.flushPendingSaves()
    XCTAssertEqual(try fixture.store.load(fixture.session.id).annotations, [added])
    let savedPDF = try Data(contentsOf: fixture.session.url)
    XCTAssertEqual(
      try ReaderAnnotationPDF.importAnnotations(from: savedPDF).annotations,
      [added]
    )
  }

  private func makeFixture(
    annotation: ReaderAnnotation? = nil,
    providedSourceData: Data? = nil,
    pageCount: Int = 1,
    seedAnnotation: Bool = true,
    includeLinkAndInk: Bool = false,
    includeNativeHighlight: Bool = false
  ) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReaderAnnotationInteractionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("source.pdf")
    let sourceData: Data
    if let providedSourceData = providedSourceData {
      sourceData = providedSourceData
    } else {
      let document = PDFDocument()
      for index in 0..<pageCount {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
        if includeLinkAndInk {
          let link = PDFAnnotation(
            bounds: CGRect(x: 20, y: 200, width: 40, height: 20),
            forType: .link,
            withProperties: nil
          )
          let ink = PDFAnnotation(
            bounds: CGRect(x: 80, y: 200, width: 40, height: 20),
            forType: .ink,
            withProperties: nil
          )
          page.addAnnotation(link)
          page.addAnnotation(ink)
        }
        if includeNativeHighlight && index == 0 {
          let native = PDFAnnotation(
            bounds: CGRect(x: 20, y: 40, width: 80, height: 14),
            forType: .highlight,
            withProperties: nil
          )
          native.color = .yellow
          native.contents = "Imported native highlight"
          native.quadrilateralPoints = [
            NSValue(cgPoint: CGPoint(x: 20, y: 54)),
            NSValue(cgPoint: CGPoint(x: 100, y: 54)),
            NSValue(cgPoint: CGPoint(x: 20, y: 40)),
            NSValue(cgPoint: CGPoint(x: 100, y: 40)),
          ]
          page.addAnnotation(native)
        }
        document.insert(page, at: index)
      }
      sourceData = try XCTUnwrap(document.dataRepresentation())
    }
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
    if seedAnnotation {
      try store.save([seeded], for: session.id, sourceURL: sourceURL, sourceData: sourceData)
    }

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

  private func exportedData(for fixture: Fixture) throws -> Data {
    try ReaderTransferPDF.export(
      sourceData: try XCTUnwrap(fixture.model.exportSourceData),
      annotations: fixture.model.annotations,
      quickLinks: [],
      readingState: ReadingState(),
      nativeRefs: fixture.model.exportNativeRefs
    )
  }

  private func selectableTextPDFData(text: String) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { renderer in
      renderer.beginPage()
      (text as NSString).draw(
        at: CGPoint(x: 30, y: 40),
        withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
      )
    }
  }

  private func subtype(of annotation: PDFAnnotation) -> String {
    annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
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
