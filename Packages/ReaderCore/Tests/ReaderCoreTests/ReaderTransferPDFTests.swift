import CoreText
import Foundation
import PDFKit
import Testing

@testable import ReaderCore

@Suite(.serialized)
struct ReaderTransferPDFTests {
  @Test
  func roundTripsRichMetadataAndBidirectionalRotatedLinks() throws {
    let source = makeTransferPDF(rotations: [0, 90], foreignMarkup: true)
    let annotation = ReaderAnnotation(
      id: "rich-highlight",
      page: 1,
      kind: .highlight,
      origin: .translation,
      text: "translated text",
      comment: "comment with detail",
      color: "#66bbff",
      rects: [
        ReaderAnnotationRect(x: 20, y: 30, width: 60, height: 14),
        ReaderAnnotationRect(x: 20, y: 48, width: 42, height: 14),
      ],
      createdAt: "2026-10-16T01:02:03.000Z",
      blockID: .string("block-1"),
      dateUnknown: false,
      author: "Reader",
      translationRect: ReaderAnnotationRect(x: 100, y: 120, width: 32, height: 16),
      sourceRect: ReaderAnnotationRect(x: 18, y: 28, width: 64, height: 38),
      modifiedAt: "2026-10-16T02:03:04.000Z",
      translationVersion: ReaderAnnotationTranslationVersion(
        engine: .pdfMathPrecise,
        language: "zh-Hans"
      )
    )
    let link = ReaderQuickLink(
      id: "quick-link-1",
      origin: ReaderQuickLinkEndpoint(
        page: 1,
        box: ReaderQuickLinkBox(x: 20, y: 30, width: 60, height: 20),
        blockID: .integer(42),
        translationVersion: ReaderAnnotationTranslationVersion(
          engine: .pdfMathFast,
          language: "zh"
        )
      ),
      result: ReaderQuickLinkEndpoint(
        page: 2,
        box: ReaderQuickLinkBox(x: 40, y: 50, width: 80, height: 24),
        blockID: .string("result-block"),
        translationVersion: ReaderAnnotationTranslationVersion(
          engine: .pdfInspector,
          language: "en"
        )
      )
    )
    let state = ReadingState(
      page: 2,
      zoom: 1.35,
      scaleMode: .custom,
      displayMode: .twoPages,
      scrollDirection: .horizontal,
      sidebarVisible: false,
      lastUpdated: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let output = try ReaderTransferPDF.export(
      sourceData: source,
      annotations: [annotation],
      quickLinks: [link],
      readingState: state
    )
    let document = try #require(PDFDocument(data: output))
    let metadata = try #require(try ReaderTransferPDF.metadata(from: document))
    #expect(metadata.version == 1)
    #expect(metadata.documentID.flatMap(UUID.init(uuidString:)) != nil)
    #expect(metadata.annotations == [annotation])
    #expect(metadata.quickLinks == [link])
    #expect(metadata.readingState == state)

    let managedLinks = documentAnnotations(document).filter {
      ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderQuickLink")) as? String) != nil
    }
    #expect(managedLinks.count == 2)
    #expect(managedLinks.allSatisfy { ($0.border?.lineWidth ?? 0) > 0 })

    let originLink = try #require(managedLinks.first { $0.bounds == expectedPDFRect(link.origin.box, on: document.page(at: 0)!) })
    let originAction = try #require(originLink.action as? PDFActionGoTo)
    #expect(originAction.destination.page === document.page(at: 1))
    #expect(originAction.destination.point == ReaderAnnotationPDF.pdfPoint(for: link.result.box, on: document.page(at: 1)!))

    let resultLink = try #require(managedLinks.first { $0.bounds == expectedPDFRect(link.result.box, on: document.page(at: 1)!) })
    let resultAction = try #require(resultLink.action as? PDFActionGoTo)
    #expect(resultAction.destination.page === document.page(at: 0))
    #expect(resultAction.destination.point == ReaderAnnotationPDF.pdfPoint(for: link.origin.box, on: document.page(at: 0)!))

    let imported = try ReaderAnnotationPDF.importAnnotations(from: output)
    #expect(imported.annotations.contains(annotation))
    #expect(imported.annotations.contains { $0.comment == "Foreign comment" })
  }

  @Test
  func preservesForeignLinkOutlineAndCommentAndRemovesDeletedManagedState() throws {
    let source = makeTransferPDF(rotations: [0, 90], foreignMarkup: true)
    let annotation = ReaderAnnotation(
      id: "to-delete",
      page: 1,
      kind: .comment,
      text: "",
      comment: "managed comment",
      color: "#fff36a",
      rects: [ReaderAnnotationRect(x: 30, y: 80, width: 20, height: 20)],
      createdAt: "2026-10-16T01:02:03Z"
    )
    let link = ReaderQuickLink(
      id: "to-delete-link",
      origin: ReaderQuickLinkEndpoint(page: 1, box: ReaderQuickLinkBox(x: 30, y: 80, width: 20, height: 20)),
      result: ReaderQuickLinkEndpoint(page: 2, box: ReaderQuickLinkBox(x: 40, y: 50, width: 20, height: 20))
    )
    let state = ReadingState(page: 1, lastUpdated: Date(timeIntervalSince1970: 1_800_000_001))
    let first = try ReaderTransferPDF.export(
      sourceData: source,
      annotations: [annotation],
      quickLinks: [link],
      readingState: state
    )
    let deleted = try ReaderTransferPDF.export(
      sourceData: first,
      annotations: [],
      quickLinks: [],
      readingState: state
    )
    let document = try #require(PDFDocument(data: deleted))

    let firstDocument = try #require(PDFDocument(data: first))
    let firstMetadata = try #require(try ReaderTransferPDF.metadata(from: firstDocument))
    let deletedMetadata = try #require(try ReaderTransferPDF.metadata(from: document))
    #expect(deletedMetadata.documentID == firstMetadata.documentID)
    #expect(deletedMetadata.annotations.isEmpty)
    #expect(deletedMetadata.quickLinks.isEmpty)
    let imported = try ReaderAnnotationPDF.importAnnotations(from: deleted)
    #expect(imported.annotations.count == 1)
    #expect(imported.annotations[0].comment == "Foreign comment")
    #expect(documentAnnotations(document).filter {
      ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderQuickLink")) as? String) != nil
    }.isEmpty)
    let foreignLinkPreserved = documentAnnotations(document).contains { annotation in
      annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Link"
        && (annotation.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/foreign"
    }
    let foreignCommentPreserved = documentAnnotations(document).contains { annotation in
      annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Text"
        && annotation.contents == "Foreign comment"
    }
    #expect(foreignLinkPreserved)
    #expect(foreignCommentPreserved)
    #expect(document.outlineRoot?.child(at: 0)?.label == "Foreign outline")

    // Re-exporting the already-clean state must not accumulate hidden metadata
    // or managed link annotations.
    let repeated = try ReaderTransferPDF.export(
      sourceData: deleted,
      annotations: [],
      quickLinks: [],
      readingState: state
    )
    let repeatedDocument = try #require(PDFDocument(data: repeated))
    let repeatedMetadata = try #require(try ReaderTransferPDF.metadata(from: repeatedDocument))
    #expect(repeatedMetadata.documentID == firstMetadata.documentID)
    #expect(documentAnnotations(repeatedDocument).filter {
      ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderQuickLink")) as? String) != nil
    }.isEmpty)
    #expect(documentAnnotations(repeatedDocument).filter {
      ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderTransferMetadata")) as? String) != nil
    }.count == 1)
  }

  @Test
  func rejectsMissingPagesAndImpossibleBoxes() throws {
    let source = makeTransferPDF(rotations: [0, 90], foreignMarkup: false)
    let annotation = ReaderAnnotation(
      id: "missing-page",
      page: 3,
      kind: .highlight,
      text: "",
      comment: "",
      color: "#fff36a",
      rects: [ReaderAnnotationRect(x: 1, y: 1, width: 2, height: 2)],
      createdAt: "2026-10-16T01:02:03Z"
    )
    #expect(throws: ReaderTransferPDFError.self) {
      try ReaderTransferPDF.export(
        sourceData: source,
        annotations: [annotation],
        quickLinks: [],
        readingState: ReadingState()
      )
    }

    let impossible = ReaderQuickLink(
      id: "impossible",
      origin: ReaderQuickLinkEndpoint(
        page: 1,
        box: ReaderQuickLinkBox(x: 190, y: 290, width: 20, height: 20)
      ),
      result: ReaderQuickLinkEndpoint(
        page: 2,
        box: ReaderQuickLinkBox(x: 20, y: 20, width: 20, height: 20)
      )
    )
    #expect(throws: ReaderTransferPDFError.self) {
      try ReaderTransferPDF.export(
        sourceData: source,
        annotations: [],
        quickLinks: [impossible],
        readingState: ReadingState()
      )
    }
  }

  @Test
  func rejectsMalformedUnsupportedAndOversizedMetadata() throws {
    let source = makeTransferPDF(rotations: [0], foreignMarkup: false)
    let malformedDocument = try #require(PDFDocument(data: source))
    setTransferAttribute("{malformed", on: malformedDocument)
    #expect(throws: ReaderTransferPDFError.malformedMetadata) {
      try ReaderTransferPDF.metadata(from: malformedDocument)
    }

    let unsupportedDocument = try #require(PDFDocument(data: source))
    let unsupported = ReaderTransferMetadata(
      version: 2,
      annotations: [],
      quickLinks: [],
      readingState: ReadingState()
    )
    let unsupportedJSON = String(decoding: try JSONEncoder().encode(unsupported), as: UTF8.self)
    setTransferAttribute(unsupportedJSON, on: unsupportedDocument)
    #expect(throws: ReaderTransferPDFError.unsupportedMetadataVersion(2)) {
      try ReaderTransferPDF.metadata(from: unsupportedDocument)
    }

    let invalidIDDocument = try #require(PDFDocument(data: source))
    let invalidIDMetadata = ReaderTransferMetadata(
      annotations: [],
      quickLinks: [],
      readingState: ReadingState(),
      documentID: "not-a-uuid"
    )
    let invalidIDJSON = String(decoding: try JSONEncoder().encode(invalidIDMetadata), as: UTF8.self)
    setTransferAttribute(invalidIDJSON, on: invalidIDDocument)
    #expect(throws: ReaderTransferPDFError.malformedMetadata) {
      try ReaderTransferPDF.metadata(from: invalidIDDocument)
    }

    let oversizedDocument = try #require(PDFDocument(data: source))
    setTransferAttribute(String(repeating: "x", count: 4 * 1024 * 1024 + 1), on: oversizedDocument)
    #expect(throws: ReaderTransferPDFError.metadataTooLarge) {
      try ReaderTransferPDF.metadata(from: oversizedDocument)
    }

    let malformedFallbackDocument = try #require(PDFDocument(data: source))
    let marker = PDFAnnotation(
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      forType: .stamp,
      withProperties: nil
    )
    _ = marker.setValue(
      "PDFMathReaderTransferMetadata:v1",
      forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderTransferMetadata")
    )
    malformedFallbackDocument.page(at: 0)?.addAnnotation(marker)
    malformedFallbackDocument.documentAttributes = [:]
    #expect(throws: ReaderTransferPDFError.malformedMetadata) {
      try ReaderTransferPDF.metadata(from: malformedFallbackDocument)
    }
  }

  @Test
  func fallsBackToHiddenAnnotationWhenDocumentAttributeIsUnavailable() throws {
    let source = makeTransferPDF(rotations: [0], foreignMarkup: false)
    let state = ReadingState(page: 1, zoom: 1.2, lastUpdated: Date(timeIntervalSince1970: 1_800_000_010))
    let output = try ReaderTransferPDF.export(
      sourceData: source,
      annotations: [],
      quickLinks: [],
      readingState: state
    )
    let document = try #require(PDFDocument(data: output))
    let expected = try #require(try ReaderTransferPDF.metadata(from: document))
    document.documentAttributes = [:]
    #expect(try ReaderTransferPDF.metadata(from: document) == expected)
  }
}

private func makeTransferPDF(rotations: [Int], foreignMarkup: Bool) -> Data {
  let data = NSMutableData()
  let consumer = CGDataConsumer(data: data)!
  var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
  let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font
  ]

  for index in rotations.indices {
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "Transfer page \(index + 1)", attributes: attributes)
    )
    context.textPosition = CGPoint(x: 10, y: 200)
    CTLineDraw(line, context)
    context.endPDFPage()
  }
  context.closePDF()

  let sourceDocument = PDFDocument(data: data as Data)!
  let document = PDFDocument()
  document.documentAttributes = sourceDocument.documentAttributes
  for index in 0..<sourceDocument.pageCount {
    document.insert(sourceDocument.page(at: index)!.copy() as! PDFPage, at: index)
  }
  for (index, rotation) in rotations.enumerated() {
    document.page(at: index)!.rotation = rotation
  }
  if foreignMarkup, let page = document.page(at: 0) {
    let foreignLink = PDFAnnotation(
      bounds: CGRect(x: 10, y: 210, width: 40, height: 20),
      forType: .link,
      withProperties: nil
    )
    foreignLink.action = PDFActionURL(url: URL(string: "https://example.com/foreign")!)
    page.addAnnotation(foreignLink)

    let foreignComment = PDFAnnotation(
      bounds: CGRect(x: 80, y: 210, width: 20, height: 20),
      forType: .text,
      withProperties: nil
    )
    foreignComment.contents = "Foreign comment"
    page.addAnnotation(foreignComment)

    let root = PDFOutline()
    root.label = "Foreign root"
    let child = PDFOutline()
    child.label = "Foreign outline"
    child.destination = PDFDestination(page: page, at: CGPoint(x: 10, y: 10))
    root.insertChild(child, at: 0)
    document.outlineRoot = root
  }
  return document.dataRepresentation()!
}

private func documentAnnotations(_ document: PDFDocument) -> [PDFAnnotation] {
  (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
}

private func expectedPDFRect(_ box: ReaderQuickLinkBox, on page: PDFPage) -> CGRect {
  let first = ReaderAnnotationPDF.pdfPoint(for: box, on: page)
  let opposite = ReaderAnnotationPDF.pdfPoint(
    for: ReaderQuickLinkBox(x: box.x + box.width, y: box.y + box.height, width: 0, height: 0),
    on: page
  )
  return CGRect(
    x: min(first.x, opposite.x),
    y: min(first.y, opposite.y),
    width: abs(opposite.x - first.x),
    height: abs(opposite.y - first.y)
  )
}

private func setTransferAttribute(_ value: String, on document: PDFDocument) {
  var attributes = document.documentAttributes ?? [:]
  attributes[PDFDocumentAttribute(rawValue: "PDFMathReaderTransfer")] = value
  document.documentAttributes = attributes
}
