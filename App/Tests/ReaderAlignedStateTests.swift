import CryptoKit
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderAlignedStateTests: XCTestCase {
  func testQuickLinkEndpointsAndDrawingSidecarScaleAndReuseDerivative() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("Mixed.pdf")
    let sourceData = try makeMixedPDF()
    try sourceData.write(to: sourceURL)
    let directory = root.appendingPathComponent("Library")
    let sourceID = "aligned-state-test"
    let contentHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()

    let quickLink = ReaderQuickLink(
      id: "quick-link",
      origin: ReaderQuickLinkEndpoint(
        page: 2,
        box: ReaderQuickLinkBox(x: 100, y: 40, width: 100, height: 80)
      ),
      result: ReaderQuickLinkEndpoint(
        page: 1,
        box: ReaderQuickLinkBox(x: 20, y: 30, width: 40, height: 50)
      )
    )
    let quickLinks = ReaderQuickLinkStore(
      directory: directory.appendingPathComponent("quick-links")
    )
    try quickLinks.save([quickLink], for: sourceID)

    let drawing = sampleDrawing()
    let drawingKey = sourceURL.standardizedFileURL.absoluteString
    let drawingDigest = SHA256.hash(data: Data(drawingKey.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let drawingURL = directory
      .appendingPathComponent("drawings", isDirectory: true)
      .appendingPathComponent(drawingDigest)
      .appendingPathExtension("json")
    try FileManager.default.createDirectory(
      at: drawingURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let drawingData = try XCTUnwrap(drawing.dataRepresentation())
    try JSONEncoder().encode([1: drawingData]).write(to: drawingURL)

    let firstResult = try await ReaderAlignedDocument.prepare(
      sourceData: sourceData,
      sourceURL: sourceURL,
      sourceID: sourceID,
      contentHash: contentHash,
      directory: directory,
      readingState: ReadingState(page: 2)
    )
    let firstURL = try XCTUnwrap(firstResult)
    let firstData = try Data(contentsOf: firstURL)
    let firstDocument = try XCTUnwrap(PDFDocument(data: firstData))
    let metadata = try XCTUnwrap(ReaderTransferPDF.metadata(from: firstDocument))
    let savedLink = try XCTUnwrap(metadata.quickLinks.first)

    XCTAssertEqual(savedLink.origin.box.x, 50, accuracy: 0.01)
    XCTAssertEqual(savedLink.origin.box.y, 20, accuracy: 0.01)
    XCTAssertEqual(savedLink.origin.box.width, 50, accuracy: 0.01)
    XCTAssertEqual(savedLink.origin.box.height, 40, accuracy: 0.01)
    XCTAssertEqual(savedLink.result.box, quickLink.result.box)
    XCTAssertNotNil(metadata.documentID.flatMap(UUID.init(uuidString:)))

    let transformed = try XCTUnwrap(try ReaderDrawingPDF.drawings(in: firstData)[1])
    let expected = drawing.transformed(using: CGAffineTransform(scaleX: 0.5, y: 0.5))
    XCTAssertEqual(transformed.bounds.origin.x, expected.bounds.origin.x, accuracy: 0.01)
    XCTAssertEqual(transformed.bounds.origin.y, expected.bounds.origin.y, accuracy: 0.01)
    XCTAssertEqual(transformed.bounds.width, expected.bounds.width, accuracy: 0.01)
    XCTAssertEqual(transformed.bounds.height, expected.bounds.height, accuracy: 0.01)

    let secondResult = try await ReaderAlignedDocument.prepare(
      sourceData: sourceData,
      sourceURL: sourceURL,
      sourceID: sourceID,
      contentHash: contentHash,
      directory: directory,
      readingState: ReadingState(page: 2)
    )
    let secondURL = try XCTUnwrap(secondResult)
    XCTAssertEqual(secondURL, firstURL)
    XCTAssertEqual(try Data(contentsOf: secondURL), firstData)
  }

  private func makeMixedPDF() throws -> Data {
    let document = PDFDocument()
    for (index, width) in [200.0, 400.0].enumerated() {
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: width, height: 300), for: .mediaBox)
      page.setBounds(CGRect(x: 0, y: 0, width: width, height: 300), for: .cropBox)
      document.insert(page, at: index)
    }
    return try XCTUnwrap(document.dataRepresentation())
  }

  private func sampleDrawing() -> PKDrawing {
    let points = [
      PKStrokePoint(
        location: CGPoint(x: 20, y: 30),
        timeOffset: 0,
        size: CGSize(width: 4, height: 4),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      ),
      PKStrokePoint(
        location: CGPoint(x: 80, y: 100),
        timeOffset: 0.1,
        size: CGSize(width: 4, height: 4),
        opacity: 1,
        force: 1,
        azimuth: 0,
        altitude: .pi / 2
      ),
    ]
    return PKDrawing(strokes: [
      PKStroke(
        ink: PKInk(.pen, color: .systemRed),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
      ),
    ])
  }
}
