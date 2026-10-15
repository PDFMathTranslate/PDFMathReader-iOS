import Foundation

public enum ReaderAnnotationKind: String, Codable, Hashable, Sendable {
  case highlight
  case comment
}

public enum ReaderAnnotationOrigin: String, Codable, Hashable, Sendable {
  case source
  case translation
}

public enum ReaderTranslationEngine: String, Codable, Hashable, Sendable {
  case pdfInspector = "pdf_inspector"
  case pdfMathFast = "pdf_math_fast"
  case pdfMathPrecise = "pdf_math_precise"
}

public struct ReaderAnnotationTranslationVersion: Codable, Hashable, Sendable {
  public var engine: ReaderTranslationEngine
  public var language: String

  public init(engine: ReaderTranslationEngine, language: String) {
    self.engine = engine
    self.language = language
  }
}

public enum ReaderAnnotationBlockID: Codable, Hashable, Sendable {
  case string(String)
  case integer(Int)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      self = .integer(try container.decode(Int.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    }
  }
}

public struct ReaderAnnotationRect: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// The JSON-compatible annotation model shared with the desktop reader.
public struct ReaderAnnotation: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var page: Int
  public var kind: ReaderAnnotationKind
  public var origin: ReaderAnnotationOrigin
  public var text: String
  public var comment: String
  public var color: String
  public var rects: [ReaderAnnotationRect]
  public var createdAt: String
  public var blockID: ReaderAnnotationBlockID?
  public var nativeRef: String?
  public var dateUnknown: Bool?
  public var author: String?
  public var translationRect: ReaderAnnotationRect?
  public var sourceRect: ReaderAnnotationRect?
  public var modifiedAt: String?
  public var translationVersion: ReaderAnnotationTranslationVersion?

  public init(
    id: String,
    page: Int,
    kind: ReaderAnnotationKind,
    origin: ReaderAnnotationOrigin = .source,
    text: String,
    comment: String,
    color: String,
    rects: [ReaderAnnotationRect],
    createdAt: String,
    blockID: ReaderAnnotationBlockID? = nil,
    nativeRef: String? = nil,
    dateUnknown: Bool? = nil,
    author: String? = nil,
    translationRect: ReaderAnnotationRect? = nil,
    sourceRect: ReaderAnnotationRect? = nil,
    modifiedAt: String? = nil,
    translationVersion: ReaderAnnotationTranslationVersion? = nil
  ) {
    self.id = id
    self.page = page
    self.kind = kind
    self.origin = origin
    self.text = text
    self.comment = comment
    self.color = color
    self.rects = rects
    self.createdAt = createdAt
    self.blockID = blockID
    self.nativeRef = nativeRef
    self.dateUnknown = dateUnknown
    self.author = author
    self.translationRect = translationRect
    self.sourceRect = sourceRect
    self.modifiedAt = modifiedAt
    self.translationVersion = translationVersion
  }

  private enum CodingKeys: String, CodingKey {
    case id, page, kind, origin, text, comment, color, rects, createdAt
    case blockID = "blockId"
    case nativeRef, dateUnknown, author, translationRect, sourceRect, modifiedAt
    case translationVersion
  }
}

public struct ReaderAnnotationStoreRecord: Codable, Hashable, Sendable {
  public var version: Int
  public var key: String
  public var annotations: [ReaderAnnotation]
  public var nativeRefs: [String]
  public var updatedAt: String

  public init(
    version: Int = 1,
    key: String,
    annotations: [ReaderAnnotation],
    nativeRefs: [String] = [],
    updatedAt: String
  ) {
    self.version = version
    self.key = key
    self.annotations = annotations
    self.nativeRefs = nativeRefs
    self.updatedAt = updatedAt
  }
}

public struct ReaderAnnotationState: Hashable, Sendable {
  public var annotations: [ReaderAnnotation]
  public var nativeRefs: [String]

  public init(annotations: [ReaderAnnotation], nativeRefs: [String] = []) {
    self.annotations = annotations
    self.nativeRefs = nativeRefs
  }
}

public struct ReaderAnnotationImportResult: Hashable, Sendable {
  public var annotations: [ReaderAnnotation]
  public var nativeRefs: [String]

  public init(annotations: [ReaderAnnotation], nativeRefs: [String] = []) {
    self.annotations = annotations
    self.nativeRefs = nativeRefs
  }
}
