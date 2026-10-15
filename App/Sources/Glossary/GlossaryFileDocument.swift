import Foundation
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

struct GlossaryFileDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  static let writableContentTypes: [UTType] = [.json]

  var data: Data

  init(data: Data = Data("[]".utf8)) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data("[]".utf8)
  }

  init(libraries: [GlossaryLibrary]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    data = (try? encoder.encode(libraries)) ?? Data("[]".utf8)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
