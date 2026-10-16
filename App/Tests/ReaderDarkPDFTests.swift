import PDFKit
import UIKit
import XCTest

@testable import PDFMathReader

final class ReaderDarkPDFTests: XCTestCase {
  /// A blank page: white paper must come out as 0.75 - 0.5 = 0.25 gray.
  private func blankPage() throws -> PDFPage {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
      .pdfData { $0.beginPage() }
    return try XCTUnwrap(ReaderPDFDocument(data: data)?.page(at: 0))
  }

  private func centerGray(_ image: UIImage) throws -> CGFloat {
    let cgImage = try XCTUnwrap(image.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let x = cgImage.width / 2, y = cgImage.height / 2
    context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
    return CGFloat(pixel[0]) / 255
  }

  func testThumbnailInvertsPaper() throws {
    let page = try blankPage()
    let light = ReaderDarkPDF.thumbnail(of: page, fitting: CGSize(width: 140, height: 188), box: .cropBox, inverted: false)
    let dark = ReaderDarkPDF.thumbnail(of: page, fitting: CGSize(width: 140, height: 188), box: .cropBox, inverted: true)
    XCTAssertEqual(try centerGray(light), 1, accuracy: 0.02)
    XCTAssertEqual(try centerGray(dark), 0.25, accuracy: 0.03)
  }

  func testInvertedImageDimsWhite() throws {
    let white = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { renderer in
      UIColor.white.setFill()
      renderer.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    XCTAssertEqual(try centerGray(ReaderDarkPDF.inverted(white)), 0.25, accuracy: 0.03)
  }
}
