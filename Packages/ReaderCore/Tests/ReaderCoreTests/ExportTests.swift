import CoreText
import Foundation
import PDFKit
import Testing

@testable import ReaderCore

@Suite(.serialized)
struct TranslatedPDFExporterTests {
  @Test
  func exportsTranslatedPagesWithRotationsAndLeavesUntouchedPageIdentical() throws {
    let originalData = makeTextPDF(
      rotations: [0, 90, 180, 270, 0]
    )
    let original = try #require(PDFDocument(data: originalData))
    let blocks = (0..<4).map { _ in
      [
        ExportParagraphBlock(
          x: 10,
          y: 20,
          width: 100,
          height: 40,
          translation: "中文译文",
          fontSize: 10
        )
      ]
    } + [[]]

    let data = try TranslatedPDFExporter().export(
      originalPDFData: originalData,
      paragraphsByPage: blocks
    )
    let exported = try #require(PDFDocument(data: data))

    #expect(exported.pageCount == 5)
    #expect((0..<5).allSatisfy { exported.page(at: $0)?.rotation == [0, 90, 180, 270, 0][$0] })
    #expect((0..<4).allSatisfy { exported.page(at: $0)?.string?.contains("中文译文") == true })
    #expect(exported.page(at: 4)?.string == original.page(at: 4)?.string)
  }

  @Test
  func substitutesRemoteKernelPageAndPreservesPageOrder() throws {
    let originalData = makeTextPDF(rotations: [0, 90, 180, 270, 0])
    let replacementData = makeTextPDF(
      rotations: [0],
      textPrefix: "Kernel translated page"
    )
    var replacements = Array<Data?>(repeating: nil, count: 5)
    replacements[2] = replacementData

    let data = try TranslatedPDFExporter().export(
      originalPDFData: originalData,
      replacementPDFDataByPage: replacements
    )
    let output = try #require(PDFDocument(data: data))

    #expect(output.pageCount == 5)
    #expect(output.page(at: 0)?.string?.contains("Original vector text 1") == true)
    #expect(output.page(at: 1)?.string?.contains("Original vector text 2") == true)
    #expect(output.page(at: 2)?.string?.contains("Kernel translated page 1") == true)
    #expect(output.page(at: 2)?.string?.contains("Original vector text 3") == false)
    #expect(output.page(at: 3)?.string?.contains("Original vector text 4") == true)
    #expect(output.page(at: 4)?.string?.contains("Original vector text 5") == true)
  }

  @Test
  func emptyTranslationInputReturnsOriginalBytes() throws {
    let originalData = makeTextPDF(rotations: [0, 90, 180, 270, 0])

    let output = try TranslatedPDFExporter().export(
      originalPDFData: originalData,
      paragraphsByPage: Array(repeating: [], count: 5),
      replacementPDFDataByPage: Array(repeating: nil, count: 5)
    )

    #expect(output == originalData)
  }

  @Test
  func createsSensibleShareableTranslatedFile() throws {
    let shareable = try ShareableDocument(
      data: Data("pdf".utf8),
      originalName: "research paper.pdf"
    )
    defer { try? FileManager.default.removeItem(at: shareable.url.deletingLastPathComponent()) }

    #expect(shareable.url.lastPathComponent == "research paper (translated).pdf")
    #expect(try Data(contentsOf: shareable.url) == Data("pdf".utf8))
    #expect(ShareableDocument.translatedFileName(for: "") == "Document (translated).pdf")
  }
}

private func makeTextPDF(
  rotations: [Int],
  textPrefix: String = "Original vector text"
) -> Data {
  let data = NSMutableData()
  let consumer = CGDataConsumer(data: data)!
  var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
  let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font
  ]

  for (index, _) in rotations.enumerated() {
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: "\(textPrefix) \(index + 1)", attributes: attributes)
    )
    context.textPosition = CGPoint(x: 10, y: 200)
    CTLineDraw(line, context)
    context.endPDFPage()
  }
  context.closePDF()

  let document = PDFDocument(data: data as Data)!
  for (index, rotation) in rotations.enumerated() {
    document.page(at: index)!.rotation = rotation
  }
  return document.dataRepresentation()!
}
