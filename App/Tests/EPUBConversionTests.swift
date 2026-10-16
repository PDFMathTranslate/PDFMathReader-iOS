import Foundation
import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class EPUBConversionTests: XCTestCase {
  func testConversionProducesMultipagePDFMetadataOutlineAndReusableCache() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("EPUB PDFs", isDirectory: true)
    let source = try fixtureEPUB()

    let firstURL = try await EPUBConverter.convert(data: source, directory: cache)
    let first = try XCTUnwrap(PDFDocument(url: firstURL))
    XCTAssertGreaterThan(first.pageCount, 2)
    XCTAssertEqual(first.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Fixture Book")
    XCTAssertEqual(first.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "PDFMathReader Tests")
    let renderedText = try XCTUnwrap(first.string)
    XCTAssertTrue(renderedText.contains("This is selectable EPUB text used by the conversion test."))
    XCTAssertTrue(renderedText.contains("Second chapter text remains selectable after conversion."))
    XCTAssertFalse(renderedText.lowercased().contains("parsererror"))
    if let firstChapter = renderedText.range(of: "Chapter One"),
       let secondChapter = renderedText.range(of: "Chapter Two") {
      XCTAssertLessThan(firstChapter.lowerBound, secondChapter.lowerBound)
    } else {
      XCTFail("The converted text should contain both chapter headings")
    }

    let rootOutline = try XCTUnwrap(first.outlineRoot)
    XCTAssertEqual(rootOutline.numberOfChildren, 2)
    XCTAssertEqual(rootOutline.child(at: 0)?.label, "Chapter One")
    XCTAssertEqual(rootOutline.child(at: 1)?.label, "Chapter Two")
    XCTAssertNotNil(rootOutline.child(at: 0)?.destination)

    // The converted PDF is the annotation store. A later conversion must
    // reuse it instead of replacing the user's edits.
    let page = try XCTUnwrap(first.page(at: 0))
    let annotation = PDFAnnotation(
      bounds: CGRect(x: 40, y: 40, width: 90, height: 20),
      forType: .highlight,
      withProperties: nil
    )
    annotation.color = .yellow
    page.addAnnotation(annotation)
    try XCTUnwrap(first.dataRepresentation()).write(to: firstURL, options: [.atomic])

    let secondURL = try await EPUBConverter.convert(data: source, directory: cache)
    XCTAssertEqual(secondURL.standardizedFileURL, firstURL.standardizedFileURL)
    let second = try XCTUnwrap(PDFDocument(url: secondURL))
    XCTAssertEqual(second.pageCount, first.pageCount)
    XCTAssertEqual(second.page(at: 0)?.annotations.count, 1)
  }

  func testInvalidEPUBIsRejected() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await EPUBConverter.convert(
        data: Data("this is not an EPUB".utf8),
        directory: root.appendingPathComponent("cache", isDirectory: true)
      )
      XCTFail("Invalid EPUB bytes must be rejected")
    } catch {
      let conversionError = try XCTUnwrap(error as? EPUBConversionError)
      XCTAssertFalse(conversionError.localizedDescription.isEmpty)
    }
  }

  func testPercentLiteralAssetNamesRemainDistinctAndHonorManifestMIME() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let pdfURL = try await EPUBConverter.convert(
      data: try percentPathFixtureEPUB(),
      directory: root.appendingPathComponent("cache", isDirectory: true)
    )
    let document = try XCTUnwrap(PDFDocument(url: pdfURL))
    let text = try XCTUnwrap(document.string)
    XCTAssertTrue(text.contains("Percent path chapter"))
    XCTAssertFalse(text.contains("LITERAL_MARKER"))
    XCTAssertFalse(text.contains("SPACE_MARKER"))
  }

  func testLibraryEPUBImportSurvivesSourceDeletionAndRestoresReadingState() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("fixture-book.epub")
    try fixtureEPUB().write(to: sourceURL)

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    let library = LibraryModel(directory: libraryDirectory)
    let imported = await library.receiveExternalPDF(at: sourceURL)
    let session = try XCTUnwrap(imported)
    XCTAssertEqual(session.title, "fixture-book.epub")
    XCTAssertTrue(session.url.pathExtension == "pdf")
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.url.path))

    let savedState = ReadingState(page: 2, zoom: 1.25, scaleMode: .fitWidth)
    try library.readingStateStore.save(savedState, for: session.id)
    let annotated = try XCTUnwrap(PDFDocument(url: session.url))
    let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 90, height: 20), forType: .highlight, withProperties: nil)
    annotated.page(at: 0)?.addAnnotation(annotation)
    try XCTUnwrap(annotated.dataRepresentation()).write(to: session.url, options: [.atomic])
    let reimportedOptional = await library.receiveExternalPDF(at: sourceURL)
    let reimported = try XCTUnwrap(reimportedOptional)
    XCTAssertEqual(reimported.id, session.id)
    XCTAssertEqual(reimported.url.standardizedFileURL, session.url.standardizedFileURL)
    XCTAssertEqual(library.readingStateStore.state(for: reimported.id).page, savedState.page)
    let stableURL = session.url.standardizedFileURL
    try FileManager.default.removeItem(at: sourceURL)

    let reopenedLibrary = LibraryModel(directory: libraryDirectory)
    let recent = try XCTUnwrap(reopenedLibrary.recents.first)
    let reopenedOptional = await reopenedLibrary.makeSession(for: recent)
    let reopened = try XCTUnwrap(reopenedOptional)
    XCTAssertEqual(reopened.url.standardizedFileURL, stableURL)
    XCTAssertEqual(reopened.title, "fixture-book.epub")
    XCTAssertEqual(reopened.id, session.id)
    XCTAssertEqual(reopenedLibrary.recents.count, 1)
    XCTAssertEqual(reopenedLibrary.readingStateStore.state(for: reopened.id).page, 2)
    XCTAssertNil(reopenedLibrary.lastError)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-EPUBTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func fixtureEPUB() throws -> Data {
    let chapterText = String(
      repeating: "This is selectable EPUB text used by the conversion test. ",
      count: 240
    )
    let chapterOne = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter One</title><link rel="stylesheet" href="styles/book.css" /></head><body><h1>Chapter One</h1><p>\(chapterText)</p><img src="images/mark.svg" alt="fixture image" /></body></html>
    """
    let chapterTwo = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter Two</title><link rel="stylesheet" href="styles/book.css" /></head><body><h1>Chapter Two</h1><p>\(chapterText)</p><p>Second chapter text remains selectable after conversion.</p></body></html>
    """
    let nav = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Chapter One</a></li><li><a href="chapter2.xhtml">Chapter Two</a></li></ol></nav></body></html>
    """
    let opf = """
    <?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">fixture-book</dc:identifier><dc:title>Fixture Book</dc:title><dc:creator>PDFMathReader Tests</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="styles/book.css" media-type="text/css"/><item id="one" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter2.xhtml" media-type="application/xhtml+xml"/><item id="image" href="images/mark.svg" media-type="image/svg+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>
    """
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head></head><docTitle><text>Fixture Book</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="chapter1.xhtml"/></navPoint><navPoint id="two" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="chapter2.xhtml"/></navPoint></navMap></ncx>
    """
    let container = """
    <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let css = "body { font-family: -apple-system, sans-serif; line-height: 1.45; } img { width: 80px; }"
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\" fill=\"#4f7cff\"/><text x=\"4\" y=\"25\" fill=\"white\">EPUB</text></svg>"
    let files: [String: Data] = [
      "mimetype": Data("application/epub+zip".utf8),
      "META-INF/container.xml": Data(container.utf8),
      "OEBPS/content.opf": Data(opf.utf8),
      "OEBPS/nav.xhtml": Data(nav.utf8),
      "OEBPS/chapter1.xhtml": Data(chapterOne.utf8),
      "OEBPS/chapter2.xhtml": Data(chapterTwo.utf8),
      "OEBPS/toc.ncx": Data(ncx.utf8),
      "OEBPS/styles/book.css": Data(css.utf8),
      "OEBPS/images/mark.svg": Data(svg.utf8),
    ]
    return makeStoredZip(files)
  }

  private func percentPathFixtureEPUB() throws -> Data {
    let chapter = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Percent Path Chapter</title><link rel="stylesheet" type="text/css" href="styles/theme%2520asset.bin" /><link rel="stylesheet" type="text/css" href="styles/theme%20asset.bin" /></head><body><h1>Percent path chapter</h1><p id="literal-marker">LITERAL_MARKER</p><p id="space-marker">SPACE_MARKER</p><p>Both marker paragraphs are hidden by their distinct manifest resources.</p></body></html>
    """
    let literalStyles = "#literal-marker { display: none !important; }"
    let spaceStyles = "#space-marker { display: none !important; }"
    let nav = """
    <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Percent Path Chapter</a></li></ol></nav></body></html>
    """
    let opf = """
    <?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">percent-path-book</dc:identifier><dc:title>Percent Path Book</dc:title><dc:creator>PDFMathReader Tests</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="literal-css" href="styles/theme%2520asset.bin" media-type="text/css"/><item id="space-css" href="styles/theme%20asset.bin" media-type="text/css"/></manifest><spine><itemref idref="chapter"/></spine></package>
    """
    let container = """
    <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let files: [String: Data] = [
      "mimetype": Data("application/epub+zip".utf8),
      "META-INF/container.xml": Data(container.utf8),
      "OEBPS/content.opf": Data(opf.utf8),
      "OEBPS/nav.xhtml": Data(nav.utf8),
      "OEBPS/chapter.xhtml": Data(chapter.utf8),
      "OEBPS/styles/theme%20asset.bin": Data(literalStyles.utf8),
      "OEBPS/styles/theme asset.bin": Data(spaceStyles.utf8),
    ]
    return makeStoredZip(files)
  }

  private func makeStoredZip(_ files: [String: Data]) -> Data {
    var local = Data()
    var central = Data()
    let orderedFiles: [(String, Data)] = files
      .filter { $0.key != "mimetype" }
      .sorted(by: { $0.key < $1.key })
      .map { ($0.key, $0.value) }
    let entries: [(String, Data)] = files["mimetype"].map { [("mimetype", $0)] + orderedFiles } ?? orderedFiles
    for (name, value) in entries {
      let nameData = Data(name.utf8)
      let offset = UInt32(local.count)
      appendLittleEndian(UInt32(0x04034b50), to: &local)
      appendLittleEndian(UInt16(20), to: &local)
      appendLittleEndian(UInt16(0), to: &local)
      appendLittleEndian(UInt16(0), to: &local)
      appendLittleEndian(UInt16(0), to: &local)
      appendLittleEndian(UInt16(0), to: &local)
      appendLittleEndian(crc32(value), to: &local)
      appendLittleEndian(UInt32(value.count), to: &local)
      appendLittleEndian(UInt32(value.count), to: &local)
      appendLittleEndian(UInt16(nameData.count), to: &local)
      appendLittleEndian(UInt16(0), to: &local)
      local.append(nameData)
      local.append(value)

      appendLittleEndian(UInt32(0x02014b50), to: &central)
      appendLittleEndian(UInt16(20), to: &central)
      appendLittleEndian(UInt16(20), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(crc32(value), to: &central)
      appendLittleEndian(UInt32(value.count), to: &central)
      appendLittleEndian(UInt32(value.count), to: &central)
      appendLittleEndian(UInt16(nameData.count), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt16(0), to: &central)
      appendLittleEndian(UInt32(0), to: &central)
      appendLittleEndian(offset, to: &central)
      central.append(nameData)
    }

    var archive = local
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    appendLittleEndian(UInt32(0x06054b50), to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    appendLittleEndian(UInt16(files.count), to: &archive)
    appendLittleEndian(UInt16(files.count), to: &archive)
    appendLittleEndian(UInt32(central.count), to: &archive)
    appendLittleEndian(centralOffset, to: &archive)
    appendLittleEndian(UInt16(0), to: &archive)
    return archive
  }

  private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        let mask = UInt32(0) &- (crc & 1)
        crc = (crc >> 1) ^ (0xedb8_8320 & mask)
      }
    }
    return ~crc
  }
}
