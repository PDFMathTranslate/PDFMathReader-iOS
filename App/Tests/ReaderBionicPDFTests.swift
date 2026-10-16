import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

final class ReaderBionicPDFTests: XCTestCase {
  @MainActor
  func testEmphasisSurvivesLowAndHighZoom() throws {
    let document = try makeDocument()
    let page = try XCTUnwrap(document.page(at: 0))
    for scale: CGFloat in [1, 2, 4, 8] {
      document.bionicOptions = BionicReadingOptions()
      let plain = render(page, scale: scale)
      document.bionicOptions = BionicReadingOptions(mode: .fixed, fixedLength: 3)
      let bold = render(page, scale: scale)
      let region = try XCTUnwrap(document.bionicRegions(on: page).first)
      let columns = bold.pixelColumns(for: region)
      XCTAssertGreaterThan(bold.darkness(in: columns), plain.darkness(in: columns),
        "Original glyphs must gain ink at scale \(scale)")
    }
  }

  @MainActor
  func testBionicRenderEmphasizesPrefixWithoutReplacingGlyphs() throws {
    let document = try makeDocument()
    let page = try XCTUnwrap(document.page(at: 0))
    let text = try XCTUnwrap(page.string)
    XCTAssertTrue(text.hasPrefix("Bionic"))

    let characterBoundsBefore = (0..<min(6, page.numberOfCharacters)).map { page.characterBounds(at: $0) }
    document.bionicOptions = BionicReadingOptions()
    let plain = render(page)

    document.bionicOptions = BionicReadingOptions(mode: .fixed, fixedLength: 3)
    let regions = document.bionicRegions(on: page)
    let prefixRegion = try XCTUnwrap(regions.first)
    let bionic = render(page)
    let prefixWindow = prefixRegion.insetBy(dx: -2, dy: -2)
    let prefixColumns = bionic.pixelColumns(for: prefixWindow)

    XCTAssertGreaterThan(
      bionic.darkness(in: prefixColumns), plain.darkness(in: prefixColumns),
      "The render-time bionic pass should increase ink in the selected prefix"
    )

    let plainSupport = try XCTUnwrap(plain.darkColumnBounds(in: prefixColumns))
    let bionicSupport = try XCTUnwrap(bionic.darkColumnBounds(in: prefixColumns))
    XCTAssertLessThanOrEqual(
      CGFloat(max(0, plainSupport.lowerBound - bionicSupport.lowerBound)) / bionic.scale,
      1.0,
      "Morphology may expand ink, but it must stay within one point"
    )
    XCTAssertLessThanOrEqual(
      CGFloat(max(0, bionicSupport.upperBound - plainSupport.upperBound)) / bionic.scale,
      1.0,
      "Morphology may expand ink, but it must stay within one point"
    )

    let suffixBounds = (3..<min(6, page.numberOfCharacters))
      .map { page.characterBounds(at: $0) }
      .filter { !$0.isNull && !$0.isEmpty }
      .reduce(CGRect.null) { $0.union($1) }
    // A pixel straddling the prefix boundary legitimately contains prefix
    // ink too. Compare the pixels wholly inside the unchanged suffix.
    let suffixRange = bionic.pixelColumns(for: suffixBounds)
    let suffixColumns = Int(ceil(suffixBounds.minX * bionic.scale))..<suffixRange.upperBound
    XCTAssertEqual(
      plain.maximumDifference(from: bionic, in: suffixColumns), 0,
      "Characters after the bionic prefix must retain their original pixels"
    )

    let characterBoundsAfter = (0..<min(6, page.numberOfCharacters)).map { page.characterBounds(at: $0) }
    XCTAssertEqual(characterBoundsBefore, characterBoundsAfter, "PDFKit glyph geometry must remain unchanged")
    XCTAssertEqual(page.string, text, "Bionic rendering must not replace the PDF text")
  }

  @MainActor
  func testBionicToggleRestoresTilesAndLeavesExportContentUntouched() throws {
    let document = try makeDocument()
    let page = try XCTUnwrap(document.page(at: 0))
    let sourceBefore = try XCTUnwrap(document.dataRepresentation())

    document.bionicOptions = BionicReadingOptions()
    let plain = render(page)
    document.bionicOptions = BionicReadingOptions(mode: .fixed, fixedLength: 3)
    let emphasized = render(page)
    XCTAssertNotEqual(plain.bytes, emphasized.bytes)

    // Serialize while the effect is enabled: it must never be baked into a PDF.
    let sourceAfter = try XCTUnwrap(document.dataRepresentation())
    let originalExport = try XCTUnwrap(PDFDocument(data: sourceBefore)?.page(at: 0))
    let bionicExport = try XCTUnwrap(PDFDocument(data: sourceAfter)?.page(at: 0))
    XCTAssertEqual(originalExport.string, bionicExport.string)
    XCTAssertEqual(render(originalExport).bytes, render(bionicExport).bytes,
      "Exported PDF content must stay unchanged (PDFKit may regenerate trailer IDs)")

    document.bionicOptions = BionicReadingOptions()
    let reverted = render(page)
    XCTAssertEqual(plain.bytes, reverted.bytes, "Turning bionic reading off must restore the source tile")
  }

  @MainActor
  func testBionicRenderWorksWithDarkAppearance() throws {
    let document = try makeDocument()
    let page = try XCTUnwrap(document.page(at: 0))
    document.bionicOptions = BionicReadingOptions(mode: .fixed, fixedLength: 3)
    document.invertsPages = true
    let darkEmphasized = render(page)
    let region = try XCTUnwrap(document.bionicRegions(on: page).first)
    let columns = darkEmphasized.pixelColumns(for: region.insetBy(dx: -2, dy: -2))

    XCTAssertEqual(darkEmphasized.cornerGray(), 0.25, accuracy: 0.05)
    let emphasizedLightness = darkEmphasized.lightness(in: columns)

    document.bionicOptions = BionicReadingOptions()
    let darkPlain = render(page)
    XCTAssertGreaterThan(
      emphasizedLightness, darkPlain.lightness(in: columns),
      "The dark appearance should preserve bionic emphasis after page inversion"
    )
  }

  @MainActor
  func testCoordinatorPropagatesBionicPreferencesAndRetainsLiveZoom() throws {
    let document = try makeDocument()
    let sourceData = try XCTUnwrap(document.dataRepresentation())
    var preferences = ReaderPreferences()
    preferences.bionicReading = .fixed
    preferences.bionicFixedLength = 2
    preferences.readingLinksEnabled = false
    let readingProvider = ReadingAidsOverlayProvider(
      document: document, preferences: preferences, sourceData: sourceData
    )
    let composite = ReaderPageOverlayCompositeProvider(providers: [readingProvider])
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    view.minScaleFactor = 0.25
    view.maxScaleFactor = 5
    let coordinator = PDFKitView.Coordinator(onStateChanged: { _ in }, annotationModel: nil)
    coordinator.attach(view, document: document, overlayProvider: composite)
    XCTAssertNil(readingProvider.overlayView(for: try XCTUnwrap(document.page(at: 0)), in: view),
      "Bionic reading alone must not create a text overlay")
    view.scaleFactor = 2.2
    let liveScale = view.scaleFactor

    XCTAssertEqual(document.bionicOptions, BionicReadingOptions(mode: .fixed, fixedLength: 2))

    preferences.bionicReading = .root
    readingProvider.updatePreferences(preferences)
    coordinator.updateOverlayProvider(composite)

    XCTAssertEqual(document.bionicOptions, BionicReadingOptions(mode: .root, fixedLength: 2))
    XCTAssertEqual(view.scaleFactor, liveScale, accuracy: 0.001)
  }

  private func makeDocument() throws -> ReaderPDFDocument {
    let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
    let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
      renderer.beginPage()
      let font = UIFont(name: "TimesNewRomanPSMT", size: 30) ?? UIFont(name: "Georgia", size: 30)!
      ("Bionic" as NSString).draw(
        at: CGPoint(x: 24, y: 58),
        withAttributes: [.font: font, .foregroundColor: UIColor.black]
      )
    }
    return try XCTUnwrap(ReaderPDFDocument(data: data))
  }

  private func render(_ page: PDFPage, scale: CGFloat = 4) -> RenderedPage {
    let pageBounds = page.bounds(for: .cropBox)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: pageBounds.size, format: format).image { renderer in
      let context = renderer.cgContext
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(CGRect(origin: .zero, size: pageBounds.size))
      context.saveGState()
      context.translateBy(x: 0, y: pageBounds.height)
      context.scaleBy(x: 1, y: -1)
      page.transform(context, for: .cropBox)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    let cgImage = image.cgImage!
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RenderedPage(bytes: bytes, width: width, height: height, pageBounds: pageBounds, scale: scale)
  }

  private struct RenderedPage {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let pageBounds: CGRect
    let scale: CGFloat

    func pixelColumns(for pageRect: CGRect) -> Range<Int> {
      let lower = max(0, Int(floor((pageRect.minX - pageBounds.minX) * scale)))
      let upper = min(width, Int(ceil((pageRect.maxX - pageBounds.minX) * scale)))
      return lower..<max(lower, upper)
    }

    func gray(x: Int, y: Int) -> Int {
      let index = (y * width + x) * 4
      return (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
    }

    func darkness(in columns: Range<Int>) -> Int {
      columns.reduce(into: 0) { result, x in
        for y in 0..<height { result += max(0, 255 - gray(x: x, y: y)) }
      }
    }

    func lightness(in columns: Range<Int>) -> Int {
      columns.reduce(into: 0) { result, x in
        for y in 0..<height { result += gray(x: x, y: y) }
      }
    }

    func darkColumnBounds(in columns: Range<Int>) -> ClosedRange<Int>? {
      let darkColumns = columns.filter { x in
        (0..<height).contains { gray(x: x, y: $0) < 244 }
      }
      guard let first = darkColumns.first, let last = darkColumns.last else { return nil }
      return first...last
    }

    func maximumDifference(from other: RenderedPage, in columns: Range<Int>) -> Int {
      guard width == other.width, height == other.height else { return Int.max }
      var maximum = 0
      for x in columns {
        for y in 0..<height {
          let offset = (y * width + x) * 4
          for component in 0..<4 {
            maximum = max(maximum, abs(Int(bytes[offset + component]) - Int(other.bytes[offset + component])))
          }
        }
      }
      return maximum
    }

    func cornerGray() -> CGFloat {
      let samples = [
        gray(x: 4, y: 4),
        gray(x: width - 5, y: 4),
        gray(x: 4, y: height - 5),
        gray(x: width - 5, y: height - 5),
      ]
      return CGFloat(samples.reduce(0, +)) / CGFloat(samples.count * 255)
    }
  }
}
