import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import ReaderCore

@Test(arguments: [0, 90, 180, 270])
func onDeviceOCRRecoversImageOnlyPageInLayoutCoordinates(rotation: Int) throws {
  let bitmap = try #require(CGContext(
    data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
  ))
  bitmap.setFillColor(gray: 1, alpha: 1)
  bitmap.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
  let line = CTLineCreateWithAttributedString(NSAttributedString(
    string: "Scientific research improves knowledge.",
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
  ))
  bitmap.textPosition = CGPoint(x: 60, y: 450)
  CTLineDraw(line, bitmap)
  let image = try #require(bitmap.makeImage())
  let bytes = NSMutableData()
  let consumer = try #require(CGDataConsumer(data: bytes))
  var box = CGRect(x: 0, y: 0, width: 500, height: 300)
  let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
  pdf.beginPDFPage(nil)
  pdf.draw(image, in: box)
  pdf.endPDFPage()
  pdf.closePDF()
  let page = try #require(PDFDocument(data: bytes as Data)?.page(at: 0))
  page.rotation = rotation
  #expect(PDFKitTextExtractor.extract(page: page).isEmpty)
  let items = PDFKitOCRTextExtractor.extract(page: page, pageNumber: 3)
  #expect(items.map(\.text).joined(separator: " ").contains("Scientific research improves knowledge"))
  #expect(items.allSatisfy { $0.page == 3 && $0.width > 0 && $0.height > 0 })
  let paragraphs = LayoutEngine.paragraphs(items: LayoutEngine.normalizeOcrItems(items), pageHeight: 300)
  let paragraph = try #require(paragraphs.first)
  #expect(paragraph.x >= 25 && paragraph.x < 40)
  #expect(paragraph.y > 40 && paragraph.y < 85)
}

@Test
func onDeviceOCRLeavesBlankPageUntouched() throws {
  let page = PDFPage()
  page.setBounds(CGRect(x: 0, y: 0, width: 500, height: 300), for: .mediaBox)
  #expect(PDFKitOCRTextExtractor.extract(page: page).isEmpty)
}
