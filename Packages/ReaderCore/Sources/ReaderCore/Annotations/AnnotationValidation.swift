import Foundation

public enum ReaderAnnotationValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidDocumentKey
  case invalidAnnotations
  case invalidAnnotation(index: Int, field: String)
  case invalidNativeReference
  case pdfTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidDocumentKey: ReaderLocalization.resolve("Invalid annotation document key.")
    case .invalidAnnotations: ReaderLocalization.resolve("Invalid annotations.")
    case .invalidAnnotation(let index, let field): ReaderLocalization.string("Invalid annotation {0} {1}.", String(index), field)
    case .invalidNativeReference: ReaderLocalization.resolve("Invalid annotation native reference.")
    case .pdfTooLarge: ReaderLocalization.resolve("Annotation PDF exceeds the 200 MiB limit.")
    }
  }
}

public enum ReaderAnnotationLimits {
  public static let maximumKeyLength = 1_024
  public static let maximumAnnotations = 10_000
  public static let maximumTextLength = 100_000
  public static let maximumRectCount = 256
  public static let maximumCoordinate = 1_000_000.0
  public static let maximumPDFBytes = 200 * 1024 * 1024
  public static let managedPrefix = "PDFMathReader:"
}

public enum ReaderAnnotationValidator {
  public static func validateDocumentKey(_ key: String) throws -> String {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      key.utf16.count <= ReaderAnnotationLimits.maximumKeyLength,
      !containsControlCharacter(key)
    else { throw ReaderAnnotationValidationError.invalidDocumentKey }
    return key
  }

  public static func validateNativeReferences(_ references: [String]) throws -> [String] {
    guard references.count <= ReaderAnnotationLimits.maximumAnnotations,
      references.allSatisfy({ $0.range(of: #"^\d+ \d+ R$"#, options: .regularExpression) != nil })
    else { throw ReaderAnnotationValidationError.invalidNativeReference }
    return references
  }

  public static func validate(_ annotation: ReaderAnnotation, index: Int = 0) throws -> ReaderAnnotation {
    guard !annotation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      annotation.id.utf16.count <= 256,
      !containsControlCharacter(annotation.id)
    else { throw invalid(index, "id") }
    guard (1...1_000_000).contains(annotation.page) else { throw invalid(index, "page") }
    guard annotation.text.utf16.count <= ReaderAnnotationLimits.maximumTextLength else {
      throw invalid(index, "text")
    }
    guard annotation.comment.utf16.count <= ReaderAnnotationLimits.maximumTextLength else {
      throw invalid(index, "comment")
    }
    guard isHexColor(annotation.color) else { throw invalid(index, "color") }
    guard !annotation.rects.isEmpty,
      annotation.rects.count <= ReaderAnnotationLimits.maximumRectCount
    else { throw invalid(index, "rectangles") }
    for (rectIndex, rect) in annotation.rects.enumerated() {
      try validate(rect, field: "rectangle \(rectIndex)", index: index)
    }
    guard isValidTimestamp(annotation.createdAt) else { throw invalid(index, "created-at") }

    if let blockID = annotation.blockID {
      switch blockID {
      case .string(let value):
        guard !value.isEmpty, value.utf16.count <= 256 else { throw invalid(index, "block id") }
      case .integer(let value):
        guard value >= 0, Int64(value) <= 9_007_199_254_740_991 else {
          throw invalid(index, "block id")
        }
      }
    }
    if let nativeRef = annotation.nativeRef,
      nativeRef.range(of: #"^\d+ \d+ R$"#, options: .regularExpression) == nil
    { throw ReaderAnnotationValidationError.invalidNativeReference }
    if let author = annotation.author, author.utf16.count > 1_000 {
      throw invalid(index, "author")
    }
    if let translationRect = annotation.translationRect {
      try validate(translationRect, field: "translation rectangle", index: index)
    }
    if let sourceRect = annotation.sourceRect {
      try validate(sourceRect, field: "source rectangle", index: index)
    }
    if let modifiedAt = annotation.modifiedAt, !isValidTimestamp(modifiedAt) {
      throw invalid(index, "modified-at")
    }
    if let version = annotation.translationVersion,
      version.language.isEmpty || version.language.utf16.count > 100
    { throw invalid(index, "translation version") }
    return annotation
  }

  public static func validate(_ annotations: [ReaderAnnotation]) throws -> [ReaderAnnotation] {
    guard annotations.count <= ReaderAnnotationLimits.maximumAnnotations else {
      throw ReaderAnnotationValidationError.invalidAnnotations
    }
    return try annotations.enumerated().map { try validate($0.element, index: $0.offset) }
  }

  private static func validate(
    _ rect: ReaderAnnotationRect,
    field: String,
    index: Int
  ) throws {
    guard isFiniteCoordinate(rect.x), isFiniteCoordinate(rect.y),
      isFiniteCoordinate(rect.width), isFiniteCoordinate(rect.height),
      rect.width > 0, rect.height > 0
    else { throw invalid(index, field) }
  }

  private static func isFiniteCoordinate(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= ReaderAnnotationLimits.maximumCoordinate
  }

  private static func isHexColor(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count == 7 || scalars.count == 9, scalars.first == "#" else { return false }
    return scalars.dropFirst().allSatisfy { scalar in
      switch scalar.value {
      case 48...57, 65...70, 97...102: true
      default: false
      }
    }
  }

  private static func isValidTimestamp(_ value: String) -> Bool {
    guard value.utf16.count <= 128 else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    if formatter.date(from: value) != nil { return true }
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    fallback.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return fallback.date(from: value) != nil
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
  }

  private static func invalid(_ index: Int, _ field: String) -> ReaderAnnotationValidationError {
    .invalidAnnotation(index: index, field: field)
  }
}
