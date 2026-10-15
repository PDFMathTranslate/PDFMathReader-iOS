import Foundation
import PDFKit
import Testing

@testable import ReaderCore

@Suite(.serialized)
struct ReaderAnnotationsTests {
  @Test
  func importsDesktopManagedFixture() throws {
    let data = try fixtureData("desktop-written.pdf")
    let imported = try ReaderAnnotationPDF.importAnnotations(from: data)

    #expect(imported.nativeRefs.isEmpty)
    #expect(imported.annotations.map(\.id) == ["desktop-highlight-1", "desktop-comment-1"])
    #expect(imported.annotations[0].rects.count == 2)
    #expect(imported.annotations[0].text == "A desktop-written highlight")
    #expect(imported.annotations[1].comment == "A desktop-written comment")
    #expect(imported.annotations[1].sourceRect?.x == 300)
  }

  @Test
  func embedsAndReloadsManagedAnnotationsWithDesktopMarker() throws {
    let source = try fixtureData("desktop-written.pdf")
    let highlight = ReaderAnnotation(
      id: "swift-highlight-1",
      page: 1,
      kind: .highlight,
      text: "Written by Swift",
      comment: "",
      color: "#66bbff",
      rects: [
        ReaderAnnotationRect(x: 120, y: 240, width: 80, height: 12),
        ReaderAnnotationRect(x: 120, y: 256, width: 60, height: 12),
      ],
      createdAt: "2026-02-03T04:05:06.000Z"
    )
    let annotation = ReaderAnnotation(
      id: "swift-comment-1",
      page: 1,
      kind: .comment,
      text: "",
      comment: "Written by Swift",
      color: "#66bbff",
      rects: [ReaderAnnotationRect(x: 120, y: 240, width: 18, height: 18)],
      createdAt: "2026-02-03T04:05:06.000Z",
      sourceRect: ReaderAnnotationRect(x: 120, y: 240, width: 18, height: 18)
    )

    let output = try ReaderAnnotationPDF.embedAnnotations([highlight, annotation], in: source)
    let imported = try ReaderAnnotationPDF.importAnnotations(from: output)
    #expect(imported.annotations == [highlight, annotation])

    let raw = String(decoding: output, as: UTF8.self)
    #expect(raw.contains("/PDFMathReader"))
    #expect(raw.contains("/NM (PDFMathReader:swift-comment-1)"))
  }

  @Test
  func importsForeignMarkupWithIndirectReferenceAndRemovesItOnSave() throws {
    let source = try fixtureData("desktop-written.pdf")
    let document = try #require(PDFDocument(data: source))
    let page = try #require(document.page(at: 0))
    let foreign = PDFAnnotation(
      bounds: CGRect(x: 150, y: 400, width: 80, height: 18),
      forType: .highlight,
      withProperties: nil
    )
    foreign.contents = "Foreign highlight"
    #if os(iOS)
    foreign.quadrilateralPoints = [
      NSValue(cgPoint: CGPoint(x: 0, y: 18)),
      NSValue(cgPoint: CGPoint(x: 80, y: 18)),
      NSValue(cgPoint: CGPoint(x: 0, y: 0)),
      NSValue(cgPoint: CGPoint(x: 80, y: 0)),
    ]
    #else
    foreign.quadrilateralPoints = [
      NSValue(point: CGPoint(x: 0, y: 18)),
      NSValue(point: CGPoint(x: 80, y: 18)),
      NSValue(point: CGPoint(x: 0, y: 0)),
      NSValue(point: CGPoint(x: 80, y: 0)),
    ]
    #endif
    page.addAnnotation(foreign)
    let annotated = try #require(document.dataRepresentation())

    let imported = try ReaderAnnotationPDF.importAnnotations(from: annotated)
    let foreignAnnotation = try #require(imported.annotations.first { $0.nativeRef != nil })
    let nativeRef = try #require(foreignAnnotation.nativeRef)
    #expect(foreignAnnotation.id == "native:" + nativeRef)
    #expect(imported.nativeRefs.contains(nativeRef))

    let stripped = try ReaderAnnotationPDF.embedAnnotations([], in: annotated, nativeRefs: imported.nativeRefs)
    let reloaded = try ReaderAnnotationPDF.importAnnotations(from: stripped)
    #expect(reloaded.annotations.isEmpty)
  }

  @Test
  func importsForeignMarkupWhenPageAnnotationsUseCompressedObjectStreams() throws {
    let source = try fixtureData("compressed-object-stream.pdf")
    let imported = try ReaderAnnotationPDF.importAnnotations(from: source)

    #expect(imported.annotations.count == 1)
    let foreign = try #require(imported.annotations.first)
    #expect(foreign.nativeRef == "7 0 R")
    #expect(imported.nativeRefs == ["7 0 R"])

    let stripped = try ReaderAnnotationPDF.embedAnnotations([], in: source, nativeRefs: imported.nativeRefs)
    let reloaded = try ReaderAnnotationPDF.importAnnotations(from: stripped)
    #expect(reloaded.annotations.isEmpty)
  }

  @Test
  func annotationStoreUsesDesktopHashAndCacheSemantics() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReaderAnnotationStore(directory: root)
    let source = try fixtureData("desktop-written.pdf")
    let annotation = ReaderAnnotation(
      id: "stored-highlight",
      page: 1,
      kind: .highlight,
      text: "Stored",
      comment: "",
      color: "#fff36a",
      rects: [ReaderAnnotationRect(x: 80, y: 300, width: 80, height: 12)],
      createdAt: "2026-02-03T04:05:06.000Z"
    )

    let output = try store.save([annotation], for: "document-key", sourceData: source)
    #expect(output != nil)
    #expect(FileManager.default.fileExists(atPath: try store.metadataURL(for: "document-key").path))
    #expect(FileManager.default.fileExists(atPath: try store.cacheURL(for: "document-key").path))
    #expect(try store.load("document-key").annotations == [annotation])
    let imported = try ReaderAnnotationPDF.importAnnotations(from: try #require(output))
    #expect(imported.annotations == [annotation])
  }

  @Test
  func quickLinksRoundTripInSeparateDesktopSidecarDirectory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReaderQuickLinkStore(directory: root)
    let box = ReaderQuickLinkBox(x: 1, y: 2, width: 30, height: 40)
    let link = ReaderQuickLink(
      id: "link-1",
      origin: ReaderQuickLinkEndpoint(page: 1, box: box),
      result: ReaderQuickLinkEndpoint(page: 2, box: box)
    )

    try store.save([link], for: "document-key")
    #expect(try store.load("document-key") == [link])
    #expect(FileManager.default.fileExists(atPath: try store.url(for: "document-key").path))
  }

  @Test
  func validationMatchesDesktopLimits() throws {
    let annotation = ReaderAnnotation(
      id: "id",
      page: 1,
      kind: .highlight,
      text: "",
      comment: "",
      color: "#abc123",
      rects: [ReaderAnnotationRect(x: 0, y: 0, width: 1, height: 1)],
      createdAt: "2026-02-03T04:05:06.000Z",
      translationVersion: ReaderAnnotationTranslationVersion(engine: .pdfMathFast, language: "zh")
    )
    #expect(try ReaderAnnotationValidator.validate(annotation) == annotation)

    let badColor = ReaderAnnotation(
      id: "id",
      page: 1,
      kind: .highlight,
      text: "",
      comment: "",
      color: "#abcd",
      rects: annotation.rects,
      createdAt: annotation.createdAt
    )
    #expect(throws: ReaderAnnotationValidationError.self) {
      try ReaderAnnotationValidator.validate(badColor)
    }
  }
}

private func fixtureData(_ name: String) throws -> Data {
  guard let url = Bundle.module.url(forResource: "Fixtures/annotations/\(name)", withExtension: nil) else {
    throw FixtureError.missing(name)
  }
  return try Data(contentsOf: url)
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("PDFMathReader-AnnotationTests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private enum FixtureError: Error {
  case missing(String)
}
