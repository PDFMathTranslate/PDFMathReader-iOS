import PDFKit
import PencilKit
import ReaderCore
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderDrawingModelTests: XCTestCase {
  func testDrawingSurvivesReopenAndEraseDoesNotResurrectIt() throws {
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
    XCTAssertEqual(reopened.drawings[0]?.strokes.count, 1)
    let restoredCanvas = reopened.canvas(for: 0, page: page)
    restoredCanvas.drawing = PKDrawing()
    reopened.canvasViewDrawingDidChange(restoredCanvas)
    reopened.release(restoredCanvas)
    let erased = ReaderDrawingModel(session: session, directory: directory)
    XCTAssertEqual(erased.drawings[0]?.strokes.count, 0)
    model.isDrawing = false
    XCTAssertFalse(canvas.acceptsDrawing)
  }

  func testUnreadableSidecarIsPreservedAndBlocksEditing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.pdf")
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    try XCTUnwrap(document.dataRepresentation()).write(to: source)
    let session = DocumentSession(id: "corrupt", title: "source", url: source, access: SecurityScopedAccess(url: source))
    let model = ReaderDrawingModel(session: session, directory: root)
    let canvas = model.canvas(for: 0, page: try XCTUnwrap(document.page(at: 0)))
    canvas.drawing = sampleDrawing()
    model.canvasViewDrawingDidChange(canvas)
    model.flush()
    let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
    let corrupt = Data("not JSON".utf8)
    try corrupt.write(to: sidecar)
    let reopened = ReaderDrawingModel(session: session, directory: root)
    XCTAssertNotNil(reopened.lastError)
    reopened.isDrawing = true
    XCTAssertFalse(reopened.canvas(for: 0, page: try XCTUnwrap(document.page(at: 0))).acceptsDrawing)
    XCTAssertThrowsError(try reopened.exportDrawings())
    reopened.flush()
    XCTAssertEqual(try Data(contentsOf: sidecar), corrupt)
  }

  private func sampleDrawing() -> PKDrawing {
    let points = [CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 100)].enumerated().map { index, point in
      PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
  }
}
