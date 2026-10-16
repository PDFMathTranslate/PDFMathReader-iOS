import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// Embeds PencilKit drawings in a PDF without reducing them to PDF ink paths.
///
/// The embedded annotation has both a PDF appearance stream and the original
/// PencilKit bytes. The appearance stream makes the exported PDF portable,
/// while the private marker lets the reader recover an editable `PKDrawing`.
@MainActor
enum ReaderDrawingPDF {
  static let markerKey = PDFAnnotationKey(rawValue: "PDFMathReaderPencilDrawing")

  enum Error: Swift.Error, Equatable, LocalizedError {
    case invalidPDF
    case missingPage(Int)
    case invalidDrawing(Int)
    case couldNotRenderDrawing(Int)
    case couldNotSerialize
    case pdfTooLarge

    var errorDescription: String? {
      switch self {
      case .invalidPDF:
        ReaderLocalization.resolve("The drawing PDF could not be opened.")
      case .missingPage(let page):
        ReaderLocalization.string("The drawing references missing PDF page {0}.", String(page))
      case .invalidDrawing(let page):
        ReaderLocalization.string("The PencilKit drawing on PDF page {0} is invalid.", String(page))
      case .couldNotRenderDrawing(let page):
        ReaderLocalization.string("The PencilKit drawing on PDF page {0} could not be rendered.", String(page))
      case .couldNotSerialize:
        ReaderLocalization.resolve("The drawing PDF could not be serialized.")
      case .pdfTooLarge:
        ReaderLocalization.resolve("The drawing PDF exceeds the 200 MiB limit.")
      }
    }
  }

  /// Embeds one drawing per zero-based PDF page index.
  ///
  /// Existing annotations written by this helper are replaced. Other PDF
  /// content and annotations remain owned by PDFKit and are left in place.
  static func embed(_ drawings: [Int: PKDrawing], in data: Data) throws -> Data {
    guard data.count <= ReaderAnnotationLimits.maximumPDFBytes else {
      throw Error.pdfTooLarge
    }
    guard let document = PDFDocument(data: data) else {
      throw Error.invalidPDF
    }

    for pageIndex in drawings.keys where pageIndex < 0 || pageIndex >= document.pageCount {
      throw Error.missingPage(pageIndex)
    }

    var changed = false
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where isManaged(annotation) {
        page.removeAnnotation(annotation)
        changed = true
      }
    }

    for pageIndex in drawings.keys.sorted() {
      guard let drawing = drawings[pageIndex], !drawing.strokes.isEmpty else { continue }
      guard let page = document.page(at: pageIndex) else {
        throw Error.missingPage(pageIndex)
      }
      let mapping = try mapping(for: drawing, on: page, pageIndex: pageIndex)
      let image = drawing.image(from: mapping.sourceRect, scale: imageScale)
      guard let cgImage = image.cgImage else {
        throw Error.couldNotRenderDrawing(pageIndex)
      }
      let annotation = ReaderDrawingAnnotation(
        bounds: mapping.annotationBounds,
        image: cgImage,
        transform: mapping.transform,
        imageSize: mapping.sourceRect.size
      )
      let encoded = drawing.dataRepresentation().base64EncodedString()
      guard annotation.setValue(encoded, forAnnotationKey: markerKey) else {
        throw Error.couldNotSerialize
      }
      page.addAnnotation(annotation)
      changed = true
    }

    // Keeping untouched input bytes avoids needlessly rewriting PDFs when a
    // caller has no drawings to add and no managed stamps to remove.
    guard changed else { return data }
    guard let output = document.dataRepresentation() else {
      throw Error.couldNotSerialize
    }
    guard output.count <= ReaderAnnotationLimits.maximumPDFBytes else {
      throw Error.pdfTooLarge
    }
    return output
  }

  /// Recovers the original PencilKit drawing bytes stored by `embed`.
  static func drawings(in data: Data) throws -> [Int: PKDrawing] {
    guard data.count <= ReaderAnnotationLimits.maximumPDFBytes else {
      throw Error.pdfTooLarge
    }
    guard let document = PDFDocument(data: data) else {
      throw Error.invalidPDF
    }

    var drawings: [Int: PKDrawing] = [:]
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        guard let encoded = annotation.value(forAnnotationKey: markerKey) as? String,
          let encodedData = Data(base64Encoded: encoded),
          let drawing = try? PKDrawing(data: encodedData)
        else {
          if annotation.value(forAnnotationKey: markerKey) != nil {
            throw Error.invalidDrawing(pageIndex)
          }
          continue
        }
        if let existing = drawings[pageIndex] {
          drawings[pageIndex] = PKDrawing(strokes: existing.strokes + drawing.strokes)
        } else {
          drawings[pageIndex] = drawing
        }
      }
    }
    return drawings
  }

  private static let imageScale: CGFloat = 2

  private struct PageMapping {
    let sourceRect: CGRect
    let annotationBounds: CGRect
    /// Maps local top-left image coordinates into PDF page coordinates.
    let transform: CGAffineTransform
  }

  private static func mapping(
    for drawing: PKDrawing,
    on page: PDFPage,
    pageIndex: Int
  ) throws -> PageMapping {
    let crop = page.bounds(for: .cropBox)
    // PDFKit rotates the page overlay after laying out the unrotated crop box.
    // PencilKit therefore keeps the crop box's width and height as its canvas
    // coordinates even when the PDF page has a 90 or 270 degree rotation.
    let canvasSize = crop.size
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      throw Error.invalidDrawing(pageIndex)
    }

    let sourceRect = drawing.bounds.standardized
    guard sourceRect.width > 0, sourceRect.height > 0,
      sourceRect.minX.isFinite, sourceRect.minY.isFinite,
      sourceRect.maxX.isFinite, sourceRect.maxY.isFinite
    else {
      throw Error.invalidDrawing(pageIndex)
    }

    let topLeft = pdfPoint(x: sourceRect.minX, y: sourceRect.minY, on: page)
    let topRight = pdfPoint(x: sourceRect.maxX, y: sourceRect.minY, on: page)
    let bottomLeft = pdfPoint(x: sourceRect.minX, y: sourceRect.maxY, on: page)
    let bottomRight = pdfPoint(x: sourceRect.maxX, y: sourceRect.maxY, on: page)
    let transform = CGAffineTransform(
      a: (topRight.x - topLeft.x) / sourceRect.width,
      b: (topRight.y - topLeft.y) / sourceRect.width,
      c: (bottomLeft.x - topLeft.x) / sourceRect.height,
      d: (bottomLeft.y - topLeft.y) / sourceRect.height,
      tx: topLeft.x,
      ty: topLeft.y
    )
    let xValues = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
    let yValues = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
    let minX = xValues.min() ?? topLeft.x
    let maxX = xValues.max() ?? topLeft.x
    let minY = yValues.min() ?? topLeft.y
    let maxY = yValues.max() ?? topLeft.y
    let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    return PageMapping(sourceRect: sourceRect, annotationBounds: bounds, transform: transform)
  }

  private static func pdfPoint(x: CGFloat, y: CGFloat, on page: PDFPage) -> CGPoint {
    let crop = page.bounds(for: .cropBox)
    return CGPoint(x: crop.minX + x, y: crop.maxY - y)
  }

  private static func isManaged(_ annotation: PDFAnnotation) -> Bool {
    annotation.value(forAnnotationKey: markerKey) != nil
  }
}

private final class ReaderDrawingAnnotation: PDFAnnotation {
  private let image: CGImage
  private let transform: CGAffineTransform
  private let imageSize: CGSize

  init(bounds: CGRect, image: CGImage, transform: CGAffineTransform, imageSize: CGSize) {
    self.image = image
    self.transform = transform
    self.imageSize = imageSize
    super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    shouldDisplay = true
    shouldPrint = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    context.saveGState()
    context.concatenate(transform)
    // PKDrawing.image uses UIKit's top-left coordinate convention. Flip the
    // image once while drawing into PDFKit's bottom-left coordinate system.
    context.translateBy(x: 0, y: imageSize.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: imageSize))
    context.restoreGState()
  }
}
