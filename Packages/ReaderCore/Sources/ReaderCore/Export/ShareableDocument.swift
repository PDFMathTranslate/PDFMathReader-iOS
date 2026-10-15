import Foundation

/// A translated PDF stored in a temporary location suitable for `ShareLink` or a share sheet.
public struct ShareableDocument: Sendable {
  public let url: URL

  public init(
    data: Data,
    originalName: String,
    fileManager: FileManager = .default
  ) throws {
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("PDFMathReader-Translated-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let fileURL = directory.appendingPathComponent(Self.translatedFileName(for: originalName))
    try data.write(to: fileURL, options: [.atomic])
    url = fileURL
  }

  public init(
    originalName: String,
    data: Data,
    fileManager: FileManager = .default
  ) throws {
    try self.init(data: data, originalName: originalName, fileManager: fileManager)
  }

  /// Writes a translated PDF and returns the resulting URL for direct use by `ShareLink`.
  public static func makeTemporaryFileURL(
    data: Data,
    originalName: String,
    fileManager: FileManager = .default
  ) throws -> URL {
    try Self(data: data, originalName: originalName, fileManager: fileManager).url
  }

  public static func translatedFileName(for originalName: String) -> String {
    // Avoid URL(fileURLWithPath:), which resolves "" to the working directory.
    let lastComponent = (originalName as NSString).lastPathComponent
    let basename = (lastComponent as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = basename.isEmpty ? "Document" : basename
    return "\(stem) (translated).pdf"
  }
}
