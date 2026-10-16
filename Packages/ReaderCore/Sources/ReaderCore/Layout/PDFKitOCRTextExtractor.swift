import CoreGraphics
import Foundation
import PDFKit
import Vision

/// On-device recovery for scanned pages. Native text pages never pay the
/// rasterization/OCR cost, and the image size stays bounded on phones.
public enum PDFKitOCRTextExtractor {
  public static func extract(page: PDFPage, pageNumber: Int = 1) -> [TextItem] {
    guard !Task.isCancelled, let pageRef = page.pageRef else { return [] }
    let bounds = page.bounds(for: .cropBox)
    guard bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0 else { return [] }
    let scale = min(2, 1800 / max(bounds.width, bounds.height))
    let width = max(1, Int(ceil(bounds.width * scale)))
    let height = max(1, Int(ceil(bounds.height * scale)))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return [] }
    let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(imageRect)
    // Explicit scaling also enlarges small pages; getDrawingTransform may
    // center them at 1x instead, invalidating normalized OCR coordinates.
    context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    context.drawPDFPage(pageRef)
    guard !Task.isCancelled, let image = context.makeImage() else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    do {
      try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
      // Preserve the original page when OCR is unavailable or cannot read it.
      return []
    }
    guard !Task.isCancelled else { return [] }
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first,
        !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let rect = observation.boundingBox
      let lineHeight = rect.height * bounds.height
      return TextItem(
        page: pageNumber, text: candidate.string,
        x: rect.minX * bounds.width, y: rect.minY * bounds.height,
        width: rect.width * bounds.width, height: lineHeight,
        fontSize: lineHeight
      )
    }
  }
}
