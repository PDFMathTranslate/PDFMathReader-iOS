import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

import zlib

/// A validated, in-memory EPUB package.
///
/// The package is deliberately a value type.  It does not resolve URLs or
/// fetch resources: every returned file comes from the ZIP archive supplied to
/// the initializer.
public struct EPUBPackage: Sendable {
  public struct Chapter: Sendable, Hashable {
    public let path: String
    public let title: String

    public init(path: String, title: String) {
      self.path = path
      self.title = title
    }
  }

  public struct NavigationEntry: Sendable, Hashable {
    public let path: String
    public let title: String
    public let fragment: String?
    public let depth: Int

    public init(path: String, title: String, fragment: String? = nil, depth: Int) {
      self.path = path
      self.title = title
      self.fragment = fragment
      self.depth = depth
    }
  }

  public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
    case archiveTooLarge
    case invalidArchive(String)
    case unsupportedArchive(String)
    case packageDocumentMissing
    case invalidPackage(String)
    case missingFile(String)
    case drmProtected

    public var errorDescription: String? {
      switch self {
      case .archiveTooLarge:
        return "The EPUB archive is larger than the supported compressed size limit."
      case .invalidArchive(let reason):
        return "The EPUB archive is invalid: \(reason)"
      case .unsupportedArchive(let reason):
        return "The EPUB archive uses an unsupported feature: \(reason)"
      case .packageDocumentMissing:
        return "The EPUB has no readable package document."
      case .invalidPackage(let reason):
        return "The EPUB package document is invalid: \(reason)"
      case .missingFile(let path):
        return "The EPUB references a missing file: \(path)"
      case .drmProtected:
        return "Encrypted or DRM-protected EPUB resources are not supported."
      }
    }
  }

  public let files: [String: Data]
  public let mediaTypes: [String: String]
  public let chapters: [Chapter]
  public let title: String
  public let author: String
  public let navigation: [NavigationEntry]

  public init(data: Data) throws {
    let archive = try ZIPArchive(data: data)
    guard archive.files["META-INF/container.xml"] != nil else {
      throw Error.packageDocumentMissing
    }

    if archive.files["META-INF/encryption.xml"] != nil {
      // Font obfuscation is valid EPUB packaging, but treating every
      // encryption manifest as protected keeps the reader from accidentally
      // presenting DRM content as ordinary bytes.
      throw Error.drmProtected
    }

    let container = try XMLTreeParser.parse(archive.files["META-INF/container.xml"]!)
    guard let rootfile = descendants(of: container, named: "rootfile").first(where: {
      (attribute("media-type", on: $0) ?? "").lowercased() == "application/oebps-package+xml"
    }) ?? descendants(of: container, named: "rootfile").first,
      let fullPath = attribute("full-path", on: rootfile),
      let packagePath = canonicalArchivePath(fullPath),
      let opfData = archive.files[packagePath]
    else {
      throw Error.packageDocumentMissing
    }

    let opf = try XMLTreeParser.parse(opfData)
    guard opf.localName == "package" else {
      throw Error.invalidPackage("the package document root is not <package>")
    }

    let itemNodes = descendants(of: opf, named: "item")
    var manifest: [String: ManifestItem] = [:]
    var resolvedMediaTypes: [String: String] = [:]
    for itemNode in itemNodes {
      guard let id = attribute("id", on: itemNode), !id.isEmpty,
        let href = attribute("href", on: itemNode), !href.isEmpty,
        let mediaType = attribute("media-type", on: itemNode), !mediaType.isEmpty
      else {
        throw Error.invalidPackage("a manifest item is missing id, href, or media-type")
      }
      guard let resolved = resolveReference(href, relativeTo: packagePath) else {
        throw Error.invalidPackage("manifest item \(id) has an unsafe href")
      }
      guard manifest[id] == nil else {
        throw Error.invalidPackage("the manifest contains duplicate id \(id)")
      }
      let normalizedMediaType = mediaType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mediaType
      manifest[id] = ManifestItem(
        id: id,
        path: resolved.path,
        mediaType: normalizedMediaType,
        properties: Set(
          (attribute("properties", on: itemNode) ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        )
      )
      resolvedMediaTypes[resolved.path] = normalizedMediaType
    }

    let spineNode = descendants(of: opf, named: "spine").first
    guard let spineNode else {
      throw Error.invalidPackage("the package document has no spine")
    }

    var spineItems: [ManifestItem] = []
    for itemRef in descendants(of: spineNode, named: "itemref") {
      if (attribute("linear", on: itemRef) ?? "").lowercased() == "no" { continue }
      guard let idref = attribute("idref", on: itemRef), let item = manifest[idref] else {
        throw Error.invalidPackage("the spine references a missing manifest item")
      }
      guard archive.files[item.path] != nil else {
        throw Error.missingFile(item.path)
      }
      if Self.renderableChapterTypes.contains(item.mediaType.lowercased()) {
        spineItems.append(item)
      }
    }
    guard !spineItems.isEmpty else {
      throw Error.invalidPackage("the spine has no readable chapters")
    }

    var parsedNavigation: [NavigationEntry] = []
    if let navigationItem = manifest.values.first(where: { $0.properties.contains("nav") }),
      let navigationData = archive.files[navigationItem.path]
    {
      let navigationDocument = try XMLTreeParser.parse(navigationData)
      parsedNavigation = parseEPUBNavigation(
        navigationDocument,
        relativeTo: navigationItem.path,
        files: archive.files
      )
    }

    if parsedNavigation.isEmpty {
      let ncxItem: ManifestItem?
      if let tocID = attribute("toc", on: spineNode) {
        ncxItem = manifest[tocID]
      } else {
        ncxItem = manifest.values.first(where: {
          $0.mediaType.lowercased() == "application/x-dtbncx+xml"
        })
      }
      if let ncxItem, let ncxData = archive.files[ncxItem.path] {
        let ncxDocument = try XMLTreeParser.parse(ncxData)
        parsedNavigation = parseNCXNavigation(
          ncxDocument,
          relativeTo: ncxItem.path,
          files: archive.files
        )
      }
    }

    let metadata = descendants(of: opf, named: "metadata").first
    let packageTitle = metadata.flatMap { firstText(in: $0, named: "title") } ?? ""
    let packageAuthor = metadata.flatMap { firstText(in: $0, named: "creator") } ?? ""

    var chapterTitles: [String: String] = [:]
    for entry in parsedNavigation where !entry.title.isEmpty && chapterTitles[entry.path] == nil {
      chapterTitles[entry.path] = entry.title
    }

    var parsedChapterTitles: [String: String] = [:]
    let chapterList = spineItems.map { item -> Chapter in
      let documentTitle: String
      if let knownTitle = parsedChapterTitles[item.path] {
        documentTitle = knownTitle
      } else if let chapterData = archive.files[item.path],
        let parsed = try? XMLTreeParser.parse(chapterData),
        let chapterTitle = firstText(in: parsed, named: "title"),
        !chapterTitle.isEmpty
      {
        parsedChapterTitles[item.path] = chapterTitle
        documentTitle = chapterTitle
      } else {
        documentTitle = ""
      }
      let chapterTitle = chapterTitles[item.path] ?? documentTitle
      return Chapter(path: item.path, title: chapterTitle.isEmpty ? basename(item.path) : chapterTitle)
    }

    self.files = archive.files
    self.mediaTypes = resolvedMediaTypes
    self.chapters = chapterList
    self.title = packageTitle
    self.author = packageAuthor
    self.navigation = parsedNavigation
  }

  /// Resolves an EPUB href against a package-relative path.
  ///
  /// Fragments are deliberately omitted from the returned path.  The method
  /// returns `nil` for external URLs, absolute paths, malformed percent
  /// escapes, or a reference that escapes the package root.
  public static func resolve(path: String, relativeTo: String) -> String? {
    resolveReference(path, relativeTo: relativeTo)?.path
  }

  private static let renderableChapterTypes: Set<String> = [
    "application/xhtml+xml",
    "text/html",
    "image/svg+xml",
  ]
}

public typealias EPUBPackageError = EPUBPackage.Error

private struct ManifestItem: Sendable {
  let id: String
  let path: String
  let mediaType: String
  let properties: Set<String>
}

private struct ResolvedReference {
  let path: String
  let fragment: String?
}

private struct XMLNode {
  let localName: String
  let attributes: [String: String]
  var text: String
  var children: [XMLNode]
}

private final class XMLTreeParser: NSObject, XMLParserDelegate {
  private static let maxXMLBytes = 8 * 1024 * 1024
  private static let maxDepth = 128
  private static let maxNodeCount = 100_000

  private var stack: [XMLNode] = []
  private(set) var root: XMLNode?
  private var parseError: Swift.Error?
  private var nodeCount = 0

  static func parse(_ data: Data) throws -> XMLNode {
    guard !data.isEmpty else {
      throw EPUBPackage.Error.invalidPackage("an XML document is empty")
    }
    guard data.count <= maxXMLBytes else {
      throw EPUBPackage.Error.invalidPackage("an XML document exceeds the 8 MB limit")
    }
    let parserDelegate = XMLTreeParser()
    let parser = XMLParser(data: data)
    parser.delegate = parserDelegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let root = parserDelegate.root else {
      if let parseError = parserDelegate.parseError {
        throw EPUBPackage.Error.invalidPackage("XML parsing failed: \(parseError.localizedDescription)")
      }
      throw EPUBPackage.Error.invalidPackage("XML parsing failed")
    }
    return root
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard stack.count < Self.maxDepth, nodeCount < Self.maxNodeCount else {
      parseError = EPUBPackage.Error.invalidPackage("the XML document is too deeply nested or has too many nodes")
      parser.abortParsing()
      return
    }
    nodeCount += 1
    let qualifiedName = qName ?? elementName
    let localName = qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
    var attributes: [String: String] = [:]
    for (key, value) in attributeDict {
      let lowercased = key.lowercased()
      attributes[lowercased] = value
      if let colon = lowercased.lastIndex(of: ":") {
        attributes[String(lowercased[lowercased.index(after: colon)...])] = value
      }
    }
    stack.append(XMLNode(localName: localName.lowercased(), attributes: attributes, text: "", children: []))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text.append(string)
  }

  func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespace: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text.append(whitespace)
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
    stack[stack.count - 1].text.append(string)
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    guard let node = stack.popLast() else { return }
    if stack.isEmpty {
      root = node
    } else {
      stack[stack.count - 1].children.append(node)
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Swift.Error) {
    self.parseError = parseError
  }
}

private struct ZIPArchive {
  private struct Entry {
    let name: String
    let isDirectory: Bool
    let flags: UInt16
    let method: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let dataStart: Int
  }

  let files: [String: Data]

  init(data: Data) throws {
    let maxCompressedArchiveSize = 128 * 1024 * 1024
    let maxExpandedArchiveSize = 256 * 1024 * 1024
    let maxEntrySize = 32 * 1024 * 1024
    let maxEntryCount = 10_000

    guard data.count <= maxCompressedArchiveSize else {
      throw EPUBPackage.Error.archiveTooLarge
    }
    let bytes = [UInt8](data)
    guard let endOfCentralDirectory = findEndOfCentralDirectory(in: bytes) else {
      throw EPUBPackage.Error.invalidArchive("the end-of-central-directory record is missing")
    }

    let commentLength = Int(readUInt16(bytes, at: endOfCentralDirectory + 20))
    guard endOfCentralDirectory + 22 + commentLength == bytes.count else {
      throw EPUBPackage.Error.invalidArchive("the end-of-central-directory comment is truncated")
    }

    let diskNumber = readUInt16(bytes, at: endOfCentralDirectory + 4)
    let centralDirectoryDisk = readUInt16(bytes, at: endOfCentralDirectory + 6)
    let entriesOnDisk = readUInt16(bytes, at: endOfCentralDirectory + 8)
    let entryCount = readUInt16(bytes, at: endOfCentralDirectory + 10)
    let centralDirectorySize = readUInt32(bytes, at: endOfCentralDirectory + 12)
    let centralDirectoryOffset = readUInt32(bytes, at: endOfCentralDirectory + 16)

    guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
      throw EPUBPackage.Error.unsupportedArchive("multi-disk ZIP archives are not supported")
    }
    guard entryCount != 0xffff, centralDirectorySize != 0xffff_ffff,
      centralDirectoryOffset != 0xffff_ffff
    else {
      throw EPUBPackage.Error.unsupportedArchive("ZIP64 archives are not supported")
    }

    let centralStart = Int(centralDirectoryOffset)
    let centralSize = Int(centralDirectorySize)
    guard centralStart >= 0, centralSize >= 0,
      centralStart <= bytes.count,
      centralSize <= bytes.count - centralStart,
      centralStart + centralSize == endOfCentralDirectory
    else {
      throw EPUBPackage.Error.invalidArchive("the central directory bounds are invalid")
    }
    guard Int(entryCount) <= maxEntryCount else {
      throw EPUBPackage.Error.invalidArchive("the archive contains too many files")
    }

    var entries: [Entry] = []
    entries.reserveCapacity(Int(entryCount))
    var names = Set<String>()
    var compressedTotal = 0
    var expandedTotal = 0
    var cursor = centralStart
    var dataRanges: [Range<Int>] = []

    for _ in 0..<Int(entryCount) {
      guard cursor <= centralStart + centralSize - 46,
        readUInt32(bytes, at: cursor) == 0x0201_4b50
      else {
        throw EPUBPackage.Error.invalidArchive("a central-directory entry is truncated")
      }

      let versionMadeBy = readUInt16(bytes, at: cursor + 4)
      let flags = readUInt16(bytes, at: cursor + 8)
      let method = readUInt16(bytes, at: cursor + 10)
      let expectedCRC = readUInt32(bytes, at: cursor + 16)
      let compressedSize32 = readUInt32(bytes, at: cursor + 20)
      let uncompressedSize32 = readUInt32(bytes, at: cursor + 24)
      let nameLength = Int(readUInt16(bytes, at: cursor + 28))
      let extraLength = Int(readUInt16(bytes, at: cursor + 30))
      let commentLength = Int(readUInt16(bytes, at: cursor + 32))
      let diskStart = readUInt16(bytes, at: cursor + 34)
      let externalAttributes = readUInt32(bytes, at: cursor + 38)
      let localHeaderOffset32 = readUInt32(bytes, at: cursor + 42)
      let recordLength = 46 + nameLength + extraLength + commentLength

      guard recordLength <= centralStart + centralSize - cursor else {
        throw EPUBPackage.Error.invalidArchive("a central-directory entry exceeds the directory")
      }
      guard diskStart == 0 else {
        throw EPUBPackage.Error.unsupportedArchive("multi-disk ZIP archives are not supported")
      }
      guard flags & 0x0001 == 0 else {
        throw EPUBPackage.Error.unsupportedArchive("encrypted ZIP entries are not supported")
      }
      guard method == 0 || method == 8 else {
        throw EPUBPackage.Error.unsupportedArchive("compression method \(method) is not supported")
      }
      guard compressedSize32 != 0xffff_ffff, uncompressedSize32 != 0xffff_ffff,
        localHeaderOffset32 != 0xffff_ffff
      else {
        throw EPUBPackage.Error.unsupportedArchive("ZIP64 entries are not supported")
      }

      let nameStart = cursor + 46
      let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
      guard let rawName = String(bytes: nameBytes, encoding: .utf8) else {
        throw EPUBPackage.Error.invalidArchive("a file name is not valid UTF-8")
      }
      let isDirectory = rawName.hasSuffix("/")
      guard let name = canonicalArchivePath(rawName, allowTrailingSlash: isDirectory) else {
        throw EPUBPackage.Error.invalidArchive("unsafe file name \(rawName)")
      }
      guard names.insert(name).inserted else {
        throw EPUBPackage.Error.invalidArchive("duplicate file name \(name)")
      }
      guard !hasZIP64Extra(bytes, start: nameStart + nameLength, length: extraLength) else {
        throw EPUBPackage.Error.unsupportedArchive("ZIP64 entries are not supported")
      }

      let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
      let creatorOS = UInt8(versionMadeBy >> 8)
      guard !(unixMode & 0xf000 == 0xa000 && creatorOS == 3) else {
        throw EPUBPackage.Error.unsupportedArchive("symbolic-link entries are not supported")
      }

      let compressedSize = Int(compressedSize32)
      let uncompressedSize = Int(uncompressedSize32)
      guard uncompressedSize <= maxEntrySize else {
        throw EPUBPackage.Error.invalidArchive("file \(name) expands beyond 32 MB")
      }
      guard compressedSize <= bytes.count else {
        throw EPUBPackage.Error.invalidArchive("file \(name) has an invalid compressed size")
      }
      guard compressedTotal <= maxCompressedArchiveSize - compressedSize else {
        throw EPUBPackage.Error.invalidArchive("compressed file data exceeds 128 MB")
      }
      guard expandedTotal <= maxExpandedArchiveSize - uncompressedSize else {
        throw EPUBPackage.Error.invalidArchive("expanded file data exceeds 256 MB")
      }
      compressedTotal += compressedSize
      expandedTotal += uncompressedSize

      let localHeaderOffset = Int(localHeaderOffset32)
      guard localHeaderOffset >= 0,
        localHeaderOffset <= centralStart - 30,
        readUInt32(bytes, at: localHeaderOffset) == 0x0403_4b50
      else {
        throw EPUBPackage.Error.invalidArchive("the local header for \(name) is invalid")
      }

      let localFlags = readUInt16(bytes, at: localHeaderOffset + 6)
      let localMethod = readUInt16(bytes, at: localHeaderOffset + 8)
      let localCRC = readUInt32(bytes, at: localHeaderOffset + 14)
      let localCompressedSize = readUInt32(bytes, at: localHeaderOffset + 18)
      let localUncompressedSize = readUInt32(bytes, at: localHeaderOffset + 22)
      let localNameLength = Int(readUInt16(bytes, at: localHeaderOffset + 26))
      let localExtraLength = Int(readUInt16(bytes, at: localHeaderOffset + 28))
      let localRecordLength = 30 + localNameLength + localExtraLength
      guard localFlags & 0x0001 == 0,
        localFlags == flags,
        localMethod == method,
        localRecordLength <= centralStart - localHeaderOffset
      else {
        throw EPUBPackage.Error.invalidArchive("the local header for \(name) does not match the central directory")
      }
      let localNameStart = localHeaderOffset + 30
      let localNameBytes = Array(bytes[localNameStart..<(localNameStart + localNameLength)])
      guard localNameBytes == nameBytes else {
        throw EPUBPackage.Error.invalidArchive("the local and central file names differ for \(name)")
      }
      guard !hasZIP64Extra(bytes, start: localNameStart + localNameLength, length: localExtraLength) else {
        throw EPUBPackage.Error.unsupportedArchive("ZIP64 entries are not supported")
      }
      if flags & 0x0008 == 0 {
        guard localCRC == expectedCRC,
          localCompressedSize == compressedSize32,
          localUncompressedSize == uncompressedSize32
        else {
          throw EPUBPackage.Error.invalidArchive("the local and central sizes differ for \(name)")
        }
      } else {
        guard (localCRC == 0 || localCRC == expectedCRC),
          (localCompressedSize == 0 || localCompressedSize == compressedSize32),
          (localUncompressedSize == 0 || localUncompressedSize == uncompressedSize32)
        else {
          throw EPUBPackage.Error.invalidArchive("the data descriptor for \(name) is inconsistent")
        }
      }

      let dataStart = localHeaderOffset + localRecordLength
      guard dataStart <= centralStart, compressedSize <= centralStart - dataStart else {
        throw EPUBPackage.Error.invalidArchive("the compressed data for \(name) is truncated")
      }
      if compressedSize > 0 { dataRanges.append(dataStart..<(dataStart + compressedSize)) }
      entries.append(
        Entry(
          name: name,
          isDirectory: isDirectory,
          flags: flags,
          method: method,
          crc32: expectedCRC,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          dataStart: dataStart
        )
      )
      cursor += recordLength
    }

    guard cursor == centralStart + centralSize else {
      throw EPUBPackage.Error.invalidArchive("the central directory entry count is inconsistent")
    }
    let orderedRanges = dataRanges.sorted { $0.lowerBound < $1.lowerBound }
    for index in 1..<orderedRanges.count {
      guard orderedRanges[index - 1].upperBound <= orderedRanges[index].lowerBound else {
        throw EPUBPackage.Error.invalidArchive("file data entries overlap")
      }
    }

    var extracted: [String: Data] = [:]
    extracted.reserveCapacity(entries.count)
    for entry in entries where !entry.isDirectory {
      let compressed = Data(bytes[entry.dataStart..<(entry.dataStart + entry.compressedSize)])
      let decoded: Data
      switch entry.method {
      case 0:
        guard compressed.count == entry.uncompressedSize else {
          throw EPUBPackage.Error.invalidArchive("stored file \(entry.name) has an invalid size")
        }
        decoded = compressed
      case 8:
        decoded = try inflateRaw(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
      default:
        throw EPUBPackage.Error.unsupportedArchive("compression method \(entry.method) is not supported")
      }
      guard decoded.count == entry.uncompressedSize else {
        throw EPUBPackage.Error.invalidArchive("file \(entry.name) has an invalid expanded size")
      }
      guard crc32(of: decoded) == entry.crc32 else {
        throw EPUBPackage.Error.invalidArchive("file \(entry.name) failed CRC validation")
      }
      extracted[entry.name] = decoded
    }
    self.files = extracted
  }
}

private func findEndOfCentralDirectory(in bytes: [UInt8]) -> Int? {
  guard bytes.count >= 22 else { return nil }
  let first = max(0, bytes.count - 22 - 0xffff)
  for offset in stride(from: bytes.count - 22, through: first, by: -1) {
    guard readUInt32(bytes, at: offset) == 0x0605_4b50 else { continue }
    let commentLength = Int(readUInt16(bytes, at: offset + 20))
    if offset + 22 + commentLength == bytes.count { return offset }
  }
  return nil
}

private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
  UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset]) |
    (UInt32(bytes[offset + 1]) << 8) |
    (UInt32(bytes[offset + 2]) << 16) |
    (UInt32(bytes[offset + 3]) << 24)
}

private func hasZIP64Extra(_ bytes: [UInt8], start: Int, length: Int) -> Bool {
  guard start >= 0, length >= 0, start <= bytes.count - length else { return true }
  var cursor = start
  let end = start + length
  while cursor < end {
    guard cursor + 4 <= end else { return true }
    let identifier = readUInt16(bytes, at: cursor)
    let size = Int(readUInt16(bytes, at: cursor + 2))
    cursor += 4
    guard size <= end - cursor else { return true }
    if identifier == 0x0001 { return true }
    cursor += size
  }
  return false
}

private func canonicalArchivePath(_ rawPath: String, allowTrailingSlash: Bool = false) -> String? {
  guard !rawPath.isEmpty,
    !rawPath.contains("\\"),
    !rawPath.contains("\0"),
    !rawPath.hasPrefix("/"),
    !rawPath.hasPrefix("//"),
    rawPath.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
  else { return nil }

  let hasTrailingSlash = rawPath.hasSuffix("/")
  guard !hasTrailingSlash || allowTrailingSlash else { return nil }
  var components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  if hasTrailingSlash { _ = components.popLast() }
  guard !components.isEmpty else { return nil }
  guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
  return components.joined(separator: "/")
}

private func resolveReference(_ href: String, relativeTo basePath: String) -> ResolvedReference? {
  let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty || !basePath.isEmpty else { return nil }
  guard trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil,
    !trimmed.hasPrefix("/"),
    !trimmed.contains("\\"),
    !trimmed.contains("\0")
  else { return nil }

  let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
  let rawPath = String(pieces.first ?? "")
  let fragment = pieces.count > 1 ? String(pieces[1]) : nil
  guard let decodedPath = rawPath.removingPercentEncoding else { return nil }
  guard !decodedPath.hasPrefix("/"),
    !decodedPath.contains("\\"),
    !decodedPath.contains("\0"),
    decodedPath.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
  else { return nil }
  guard let canonicalBase = basePath.isEmpty ? "" : canonicalArchivePath(basePath) else { return nil }
  if decodedPath.isEmpty {
    guard !canonicalBase.isEmpty else { return nil }
    return ResolvedReference(path: canonicalBase, fragment: fragment)
  }

  var components = canonicalBase.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  if !components.isEmpty { _ = components.popLast() }
  for component in decodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
    if component.isEmpty || component == "." { continue }
    if component == ".." {
      guard !components.isEmpty else { return nil }
      _ = components.popLast()
    } else {
      guard component != "\\", !component.contains("\0") else { return nil }
      components.append(component)
    }
  }
  guard !components.isEmpty else { return nil }
  return ResolvedReference(path: components.joined(separator: "/"), fragment: fragment)
}

private func inflateRaw(_ compressed: Data, expectedSize: Int, name: String) throws -> Data {
  var stream = z_stream()
  let initialization = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
  guard initialization == Z_OK else {
    throw EPUBPackage.Error.unsupportedArchive("raw DEFLATE could not be initialized for \(name)")
  }
  defer { inflateEnd(&stream) }

  var output = Data(count: expectedSize)
  var scratch = [UInt8](repeating: 0, count: max(1, expectedSize == 0 ? 1 : 0))
  var result: Int32 = Z_OK

  compressed.withUnsafeBytes { sourceRawBuffer in
    output.withUnsafeMutableBytes { destinationRawBuffer in
      let source = sourceRawBuffer.bindMemory(to: Bytef.self)
      stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
      stream.avail_in = uInt(compressed.count)

      if expectedSize == 0 {
        scratch.withUnsafeMutableBytes { scratchRawBuffer in
          stream.next_out = scratchRawBuffer.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = 1
          result = inflate(&stream, Z_FINISH)
        }
      } else {
        stream.next_out = destinationRawBuffer.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(expectedSize)
        repeat {
          result = inflate(&stream, Z_FINISH)
          if result == Z_OK && stream.avail_out == 0 { break }
        } while result == Z_OK
      }
    }
  }

  guard result == Z_STREAM_END,
    stream.avail_in == 0,
    Int(stream.total_out) == expectedSize
  else {
    throw EPUBPackage.Error.invalidArchive("file \(name) contains invalid DEFLATE data")
  }
  return output
}

private func crc32(of data: Data) -> UInt32 {
  var checksum: uLong = 0
  data.withUnsafeBytes { rawBuffer in
    let bytes = rawBuffer.bindMemory(to: Bytef.self)
    checksum = zlib.crc32(checksum, bytes.baseAddress, uInt(data.count))
  }
  return UInt32(truncatingIfNeeded: checksum)
}

private func attribute(_ name: String, on node: XMLNode) -> String? {
  node.attributes[name.lowercased()]
}

private func descendants(of node: XMLNode, named name: String) -> [XMLNode] {
  var result: [XMLNode] = []
  for child in node.children {
    if child.localName == name.lowercased() { result.append(child) }
    result.append(contentsOf: descendants(of: child, named: name))
  }
  return result
}

private func firstText(in node: XMLNode, named name: String) -> String? {
  guard let match = descendants(of: node, named: name).first else { return nil }
  let value = normalizedText(match)
  return value.isEmpty ? nil : value
}

private func normalizedText(_ node: XMLNode) -> String {
  let value = node.text + node.children.map(normalizedText).joined()
  return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseEPUBNavigation(
  _ document: XMLNode,
  relativeTo basePath: String,
  files: [String: Data]
) -> [EPUBPackage.NavigationEntry] {
  let navs = descendants(of: document, named: "nav")
  let nav = navs.first(where: {
    (attribute("type", on: $0) ?? "")
      .split(whereSeparator: { $0.isWhitespace })
      .contains { $0.lowercased() == "toc" }
  }) ?? navs.first
  guard let nav else { return [] }

  var entries: [EPUBPackage.NavigationEntry] = []
  func appendAnchor(_ anchor: XMLNode, depth: Int) {
    guard let href = attribute("href", on: anchor),
      let reference = resolveReference(href, relativeTo: basePath),
      files[reference.path] != nil
    else { return }
    let title = normalizedText(anchor)
    guard !title.isEmpty else { return }
    entries.append(
      EPUBPackage.NavigationEntry(
        path: reference.path,
        title: title,
        fragment: reference.fragment,
        depth: max(0, depth)
      )
    )
  }
  func walkList(_ list: XMLNode, depth: Int) {
    for child in list.children {
      if child.localName == "li" {
        if let anchor = child.children.first(where: { $0.localName == "a" }) {
          appendAnchor(anchor, depth: depth)
        }
        for nested in child.children where nested.localName == "ol" {
          walkList(nested, depth: depth + 1)
        }
      } else if child.localName == "ol" {
        walkList(child, depth: depth)
      }
    }
  }

  if let list = descendants(of: nav, named: "ol").first {
    walkList(list, depth: 0)
  } else {
    for anchor in descendants(of: nav, named: "a") {
      appendAnchor(anchor, depth: 0)
    }
  }
  return entries
}

private func parseNCXNavigation(
  _ document: XMLNode,
  relativeTo basePath: String,
  files: [String: Data]
) -> [EPUBPackage.NavigationEntry] {
  let navMap = descendants(of: document, named: "navmap").first
  guard let navMap else { return [] }
  var entries: [EPUBPackage.NavigationEntry] = []
  func walk(_ point: XMLNode, depth: Int) {
    let label = descendants(of: point, named: "text").first.map(normalizedText) ?? ""
    if let content = descendants(of: point, named: "content").first,
      let src = attribute("src", on: content),
      let reference = resolveReference(src, relativeTo: basePath),
      files[reference.path] != nil,
      !label.isEmpty
    {
      entries.append(
        EPUBPackage.NavigationEntry(
          path: reference.path,
          title: label,
          fragment: reference.fragment,
          depth: max(0, depth)
        )
      )
    }
    for child in point.children where child.localName == "navpoint" {
      walk(child, depth: depth + 1)
    }
  }
  for point in navMap.children where point.localName == "navpoint" {
    walk(point, depth: 0)
  }
  return entries
}

private func basename(_ path: String) -> String {
  let name = path.split(separator: "/").last.map(String.init) ?? path
  if let dot = name.lastIndex(of: "."), dot != name.startIndex {
    return String(name[..<dot])
  }
  return name
}
