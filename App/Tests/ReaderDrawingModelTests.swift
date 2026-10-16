import PDFKit
import PencilKit
import ReaderCore
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderDrawingModelTests: XCTestCase {
  func testAnnotatedPagesAreSortedAndExcludeEmptyDrawings() async throws {
    let fixture = try makeFixture(pageCount: 5)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ReaderDrawingModel(session: fixture.session, directory: fixture.directory)
    await model.prepare()

    let laterCanvas = model.canvas(for: 3, page: try XCTUnwrap(fixture.document.page(at: 3)))
    laterCanvas.drawing = sampleDrawing(offset: CGPoint(x: 15, y: 0))
    model.canvasViewDrawingDidChange(laterCanvas)

    let emptyCanvas = model.canvas(for: 2, page: try XCTUnwrap(fixture.document.page(at: 2)))
    model.canvasViewDrawingDidChange(emptyCanvas)

    let earlierCanvas = model.canvas(for: 0, page: try XCTUnwrap(fixture.document.page(at: 0)))
    earlierCanvas.drawing = sampleDrawing(offset: CGPoint(x: 30, y: 0))
    model.canvasViewDrawingDidChange(earlierCanvas)
    model.flush()

    XCTAssertEqual(model.annotatedPages, [0, 3])
    XCTAssertEqual(model.drawings[2]?.strokes.count, 0)
  }

  func testDeleteDrawingClearsLiveCanvasPersistsAndPreservesOtherPages() async throws {
    let fixture = try makeFixture(pageCount: 3)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ReaderDrawingModel(session: fixture.session, directory: fixture.directory)
    await model.prepare()

    let deletedCanvas = model.canvas(for: 1, page: try XCTUnwrap(fixture.document.page(at: 1)))
    deletedCanvas.drawing = sampleDrawing()
    model.canvasViewDrawingDidChange(deletedCanvas)

    let keptCanvas = model.canvas(for: 2, page: try XCTUnwrap(fixture.document.page(at: 2)))
    keptCanvas.drawing = sampleDrawing(offset: CGPoint(x: 40, y: 0))
    model.canvasViewDrawingDidChange(keptCanvas)
    model.flush()

    model.deleteDrawing(on: 1)

    XCTAssertTrue(deletedCanvas.drawing.strokes.isEmpty)
    XCTAssertTrue(model.drawings[1]?.strokes.isEmpty == true)
    XCTAssertEqual(model.annotatedPages, [2])
    XCTAssertEqual(keptCanvas.drawing.strokes.count, 1)

    let reopened = ReaderDrawingModel(session: fixture.session, directory: fixture.directory)
    await reopened.prepare()
    XCTAssertTrue(reopened.drawings[1]?.strokes.isEmpty == true)
    XCTAssertEqual(reopened.drawings[2]?.strokes.count, 1)
    XCTAssertEqual(reopened.annotatedPages, [2])
    let reopenedDeletedCanvas = reopened.canvas(
      for: 1,
      page: try XCTUnwrap(fixture.document.page(at: 1))
    )
    XCTAssertTrue(reopenedDeletedCanvas.drawing.strokes.isEmpty)
  }

  func testDrawingSurvivesReopenAndEraseDoesNotResurrectIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
    document.insert(page, at: 0)
    let source = root.appendingPathComponent("sample.pdf")
    try XCTUnwrap(document.dataRepresentation()).write(to: source)
    let session = DocumentSession(id: "drawing-test", title: "sample.pdf", url: source, access: SecurityScopedAccess(url: source))
    let directory = root.appendingPathComponent("drawings")
    let model = ReaderDrawingModel(session: session, directory: directory)
    await model.prepare()
    XCTAssertNil(model.lastError)
    let canvas = model.canvas(for: 0, page: page)
    XCTAssertFalse(canvas.acceptsDrawing)
    model.isDrawing = true
    XCTAssertTrue(canvas.acceptsDrawing)
    XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
    model.usesFinger = true
    XCTAssertEqual(canvas.drawingPolicy, .anyInput)
    canvas.drawing = sampleDrawing()
    model.canvasViewDrawingDidChange(canvas)
    model.flush()
    // A highlight save changes the content hash used for the next session.
    let editedSession = DocumentSession(id: "after-highlight", title: session.title, url: source, access: SecurityScopedAccess(url: source))
    let reopened = ReaderDrawingModel(session: editedSession, directory: directory)
    await reopened.prepare()
    XCTAssertEqual(reopened.drawings[0]?.strokes.count, 1)
    let restoredCanvas = reopened.canvas(for: 0, page: page)
    restoredCanvas.drawing = PKDrawing()
    reopened.canvasViewDrawingDidChange(restoredCanvas)
    reopened.release(restoredCanvas)
    let erased = ReaderDrawingModel(session: session, directory: directory)
    await erased.prepare()
    XCTAssertEqual(erased.drawings[0]?.strokes.count, 0)
    model.isDrawing = false
    XCTAssertFalse(canvas.acceptsDrawing)
  }

  func testUnreadableSidecarIsPreservedAndBlocksEditing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.pdf")
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    try XCTUnwrap(document.dataRepresentation()).write(to: source)
    let session = DocumentSession(id: "corrupt", title: "source", url: source, access: SecurityScopedAccess(url: source))
    let model = ReaderDrawingModel(session: session, directory: root)
    await model.prepare()
    let canvas = model.canvas(for: 0, page: try XCTUnwrap(document.page(at: 0)))
    canvas.drawing = sampleDrawing()
    model.canvasViewDrawingDidChange(canvas)
    model.flush()
    let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
    let corrupt = Data("not JSON".utf8)
    try corrupt.write(to: sidecar)
    let reopened = ReaderDrawingModel(session: session, directory: root)
    await reopened.prepare()
    XCTAssertNotNil(reopened.lastError)
    reopened.isDrawing = true
    XCTAssertFalse(reopened.canvas(for: 0, page: try XCTUnwrap(document.page(at: 0))).acceptsDrawing)
    XCTAssertThrowsError(try reopened.exportDrawings())
    reopened.flush()
    XCTAssertEqual(try Data(contentsOf: sidecar), corrupt)
  }

  func testPreparationRestoresEmbeddedDrawingWithoutEarlyOverlaySave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("embedded.pdf")
    let document = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
    document.insert(page, at: 0)
    let sourceData = try XCTUnwrap(document.dataRepresentation())
    let embeddedDrawing = sampleDrawing()
    let embeddedData = try ReaderDrawingPDF.embed([0: embeddedDrawing], in: sourceData)
    try embeddedData.write(to: source)

    let session = DocumentSession(
      id: "embedded-drawing-test",
      title: "embedded.pdf",
      url: source,
      access: SecurityScopedAccess(url: source)
    )
    let directory = root.appendingPathComponent("drawings")
    let model = ReaderDrawingModel(session: session, directory: directory)
    let displayedDocument = try XCTUnwrap(PDFDocument(data: embeddedData))
    let displayedPage = try XCTUnwrap(displayedDocument.page(at: 0))
    let canvas = model.canvas(for: 0, page: displayedPage)
    let marker = try XCTUnwrap(
      displayedPage.annotations.first {
        $0.value(forAnnotationKey: ReaderDrawingPDF.markerKey) != nil
      }
    )

    XCTAssertFalse(model.isPrepared)
    XCTAssertTrue(marker.shouldDisplay)
    canvas.drawing = sampleDrawing(offset: CGPoint(x: 40, y: 0))
    model.canvasViewDrawingDidChange(canvas)
    model.flush()
    XCTAssertTrue(model.drawings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

    await model.prepare()

    XCTAssertTrue(model.isPrepared)
    XCTAssertEqual(model.drawings[0]?.strokes.count, embeddedDrawing.strokes.count)
    XCTAssertEqual(canvas.drawing.strokes.count, embeddedDrawing.strokes.count)
    XCTAssertFalse(marker.shouldDisplay)
  }

  private func sampleDrawing() -> PKDrawing {
    sampleDrawing(offset: .zero)
  }

  private func sampleDrawing(offset: CGPoint) -> PKDrawing {
    let points = [
      CGPoint(x: 20 + offset.x, y: 30 + offset.y),
      CGPoint(x: 80 + offset.x, y: 100 + offset.y),
    ].enumerated().map { index, point in
      PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
  }

  private func makeFixture(pageCount: Int) throws -> (
    root: URL,
    document: PDFDocument,
    session: DocumentSession,
    directory: URL
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let document = PDFDocument()
    for index in 0..<pageCount {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
      document.insert(page, at: index)
    }
    let source = root.appendingPathComponent("sample.pdf")
    try XCTUnwrap(document.dataRepresentation()).write(to: source)
    let session = DocumentSession(
      id: "drawing-test-\(UUID().uuidString)",
      title: "sample.pdf",
      url: source,
      access: SecurityScopedAccess(url: source)
    )
    return (root, document, session, root.appendingPathComponent("drawings"))
  }
}
