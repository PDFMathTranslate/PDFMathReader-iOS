import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportPDFFileDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.pdf]
  static let writableContentTypes: [UTType] = [.pdf]

  var data: Data

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
