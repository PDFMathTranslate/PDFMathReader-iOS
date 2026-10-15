import Foundation

public enum LibraryDirectory {
  public static var `default`: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("PDFMathReader", isDirectory: true)
  }
}

internal struct JSONFile<Value: Codable> {
  let url: URL
  let fileManager: FileManager

  init(url: URL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  func read() -> Value? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Value.self, from: data)
  }

  func write(_ value: Value) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: [.atomic])
  }
}

internal extension NSLock {
  func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}
