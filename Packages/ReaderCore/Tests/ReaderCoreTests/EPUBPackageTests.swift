import Foundation
import Testing

@testable import ReaderCore

private struct ZIPFixtureEntry {
  let name: String
  let data: Data
  let method: UInt16
  let compressedData: Data
  let flags: UInt16
  let versionMadeBy: UInt16
  let externalAttributes: UInt32
  let crcOverride: UInt32?

  init(
    name: String,
    data: Data,
    method: UInt16 = 0,
    compressedData: Data? = nil,
    flags: UInt16 = 0,
    versionMadeBy: UInt16 = 20,
    externalAttributes: UInt32 = 0,
    crcOverride: UInt32? = nil
  ) {
    self.name = name
    self.data = data
    self.method = method
    self.compressedData = compressedData ?? data
    self.flags = flags
    self.versionMadeBy = versionMadeBy
    self.externalAttributes = externalAttributes
    self.crcOverride = crcOverride
  }
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func crc32(_ data: Data) -> UInt32 {
  var crc: UInt32 = 0xffff_ffff
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0)
    }
  }
  return ~crc
}

private func makeZIP(_ entries: [ZIPFixtureEntry]) -> Data {
  var local = Data()
  var central = Data()
  for entry in entries {
    let name = Data(entry.name.utf8)
    let compressed = entry.compressedData
    let checksum = entry.crcOverride ?? crc32(entry.data)
    let localOffset = UInt32(local.count)

    appendUInt32(0x0403_4b50, to: &local)
    appendUInt16(20, to: &local)
    appendUInt16(entry.flags, to: &local)
    appendUInt16(entry.method, to: &local)
    appendUInt16(0, to: &local)
    appendUInt16(0, to: &local)
    appendUInt32(checksum, to: &local)
    appendUInt32(UInt32(compressed.count), to: &local)
    appendUInt32(UInt32(entry.data.count), to: &local)
    appendUInt16(UInt16(name.count), to: &local)
    appendUInt16(0, to: &local)
    local.append(name)
    local.append(compressed)

    appendUInt32(0x0201_4b50, to: &central)
    appendUInt16(entry.versionMadeBy, to: &central)
    appendUInt16(20, to: &central)
    appendUInt16(entry.flags, to: &central)
    appendUInt16(entry.method, to: &central)
    appendUInt16(0, to: &central)
    appendUInt16(0, to: &central)
    appendUInt32(checksum, to: &central)
    appendUInt32(UInt32(compressed.count), to: &central)
    appendUInt32(UInt32(entry.data.count), to: &central)
    appendUInt16(UInt16(name.count), to: &central)
    appendUInt16(0, to: &central)
    appendUInt16(0, to: &central)
    appendUInt16(0, to: &central)
    appendUInt16(0, to: &central)
    appendUInt32(entry.externalAttributes, to: &central)
    appendUInt32(localOffset, to: &central)
    central.append(name)
  }

  var archive = local
  let centralOffset = UInt32(local.count)
  archive.append(central)
  appendUInt32(0x0605_4b50, to: &archive)
  appendUInt16(0, to: &archive)
  appendUInt16(0, to: &archive)
  appendUInt16(UInt16(entries.count), to: &archive)
  appendUInt16(UInt16(entries.count), to: &archive)
  appendUInt32(UInt32(central.count), to: &archive)
  appendUInt32(centralOffset, to: &archive)
  appendUInt16(0, to: &archive)
  return archive
}

private let rawDeflatedChapter = Data([
  37, 141, 65, 14, 131, 32, 16, 69, 175, 98, 56, 0, 83, 210, 21, 13,
  226, 162, 221, 120, 12, 149, 73, 49, 81, 198, 224, 88, 236, 237, 29, 195,
  246, 191, 247, 255, 119, 221, 185, 46, 205, 15, 243, 62, 83, 106, 149, 209,
  15, 213, 121, 23, 89, 66, 1, 105, 111, 85, 100, 222, 94, 0, 165, 20,
  93, 158, 154, 242, 23, 140, 181, 22, 206, 219, 81, 162, 226, 16, 188,
  227, 153, 23, 244, 239, 56, 108, 140, 185, 249, 208, 116, 172, 152, 216,
  65, 205, 29, 84, 107, 164, 240, 151, 134, 241, 125, 226, 76, 225, 152,
  88, 78, 5, 26, 49, 42, 131, 123, 213, 95,
])

private let containerXML = """
<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""

private let packageXML = """
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" version="3.0">
  <metadata><dc:title>Example Book</dc:title><dc:creator>Ada Author</dc:creator></metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="font" href="fontdata" media-type="font/woff2"/>
    <item id="omitted" href="omitted.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter"/><itemref idref="omitted" linear="no"/></spine>
</package>
"""

private let navXML = """
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <body><nav epub:type="toc"><ol>
    <li><a href="chapter.xhtml#intro">Introduction</a><ol>
      <li><a href="chapter.xhtml#part">Part One</a></li>
    </ol></li>
  </ol></nav></body>
</html>
"""

private let chapterXML = "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Chapter Document</title></head><body><h1>Introduction</h1></body></html>"

private func validFixture() -> Data {
  makeZIP([
    ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
    ZIPFixtureEntry(name: "META-INF/container.xml", data: Data(containerXML.utf8)),
    ZIPFixtureEntry(name: "OPS/package.opf", data: Data(packageXML.utf8)),
    ZIPFixtureEntry(name: "OPS/nav.xhtml", data: Data(navXML.utf8)),
    ZIPFixtureEntry(
      name: "OPS/chapter.xhtml",
      data: Data(chapterXML.utf8),
      method: 8,
      compressedData: rawDeflatedChapter
    ),
    ZIPFixtureEntry(name: "OPS/fontdata", data: Data([0, 1, 2, 3])),
    ZIPFixtureEntry(name: "OPS/omitted.xhtml", data: Data("<html/>".utf8)),
  ])
}

@Test func epubPackageParsesDeflateMetadataSpineAndNavigation() throws {
  let package = try EPUBPackage(data: validFixture())

  #expect(package.title == "Example Book")
  #expect(package.author == "Ada Author")
  #expect(package.files["OPS/chapter.xhtml"] == Data(chapterXML.utf8))
  #expect(package.mediaTypes["OPS/fontdata"] == "font/woff2")
  #expect(package.chapters == [EPUBPackage.Chapter(path: "OPS/chapter.xhtml", title: "Introduction")])
  #expect(package.navigation.count == 2)
  #expect(package.navigation[0] == EPUBPackage.NavigationEntry(path: "OPS/chapter.xhtml", title: "Introduction", fragment: "intro", depth: 0))
  #expect(package.navigation[1] == EPUBPackage.NavigationEntry(path: "OPS/chapter.xhtml", title: "Part One", fragment: "part", depth: 1))
}

@Test func epubPackageResolvesSafeRelativeReferences() {
  #expect(EPUBPackage.resolve(path: "chapter.xhtml#intro", relativeTo: "OPS/package.opf") == "OPS/chapter.xhtml")
  #expect(EPUBPackage.resolve(path: "../Text/chapter.xhtml", relativeTo: "OPS/sub/package.opf") == "OPS/Text/chapter.xhtml")
  #expect(EPUBPackage.resolve(path: "", relativeTo: "OPS/package.opf") == "OPS/package.opf")
  #expect(EPUBPackage.resolve(path: "/chapter.xhtml", relativeTo: "OPS/package.opf") == nil)
  #expect(EPUBPackage.resolve(path: "https://example.com/book.xhtml", relativeTo: "OPS/package.opf") == nil)
  #expect(EPUBPackage.resolve(path: "../../chapter.xhtml", relativeTo: "OPS/package.opf") == nil)
  #expect(EPUBPackage.resolve(path: "%2e%2e/chapter.xhtml", relativeTo: "OPS/package.opf") == "chapter.xhtml")
}

@Test func epubPackageRejectsBrokenAndUnsafeArchives() {
  do {
    _ = try EPUBPackage(data: Data("not a ZIP".utf8))
    #expect(Bool(false), "a non-ZIP input should be rejected")
  } catch let error as EPUBPackage.Error {
    #expect(error.localizedDescription.contains("archive"))
  } catch {
    #expect(Bool(false), "the parser should report EPUBPackage.Error")
  }

  let badCRC = makeZIP([
    ZIPFixtureEntry(name: "META-INF/container.xml", data: Data(containerXML.utf8), crcOverride: 0),
  ])
  #expect(throws: EPUBPackage.Error.self) { try EPUBPackage(data: badCRC) }

  let traversal = makeZIP([
    ZIPFixtureEntry(name: "../META-INF/container.xml", data: Data(containerXML.utf8)),
  ])
  #expect(throws: EPUBPackage.Error.self) { try EPUBPackage(data: traversal) }

  let duplicate = makeZIP([
    ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("one".utf8)),
    ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("two".utf8)),
  ])
  #expect(throws: EPUBPackage.Error.self) { try EPUBPackage(data: duplicate) }
}

@Test func epubPackageRejectsEncryptedAndSymlinkEntries() {
  let encrypted = makeZIP([
    ZIPFixtureEntry(name: "META-INF/container.xml", data: Data(containerXML.utf8), flags: 1),
  ])
  #expect(throws: EPUBPackage.Error.self) { try EPUBPackage(data: encrypted) }

  let symlink = makeZIP([
    ZIPFixtureEntry(
      name: "META-INF/container.xml",
      data: Data(containerXML.utf8),
      versionMadeBy: 0x0314,
      externalAttributes: 0xa000_0000
    ),
  ])
  #expect(throws: EPUBPackage.Error.self) { try EPUBPackage(data: symlink) }
}
