import SwiftUI

extension Notification.Name {
  static let readerNextPage = Notification.Name("PDFMathReader.readerNextPage")
  static let readerPreviousPage = Notification.Name("PDFMathReader.readerPreviousPage")
  static let readerZoomIn = Notification.Name("PDFMathReader.readerZoomIn")
  static let readerZoomOut = Notification.Name("PDFMathReader.readerZoomOut")
  static let readerToggleSidebar = Notification.Name("PDFMathReader.readerToggleSidebar")
  static let readerOpenSearch = Notification.Name("PDFMathReader.readerOpenSearch")
}

struct ReaderCommandMenu: Commands {
  var body: some Commands {
    CommandMenu("Reader") {
      Button("Next Page") {
        NotificationCenter.default.post(name: .readerNextPage, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut(.rightArrow, modifiers: [])

      Button("Previous Page") {
        NotificationCenter.default.post(name: .readerPreviousPage, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut(.leftArrow, modifiers: [])

      Divider()

      Button("Zoom In") {
        NotificationCenter.default.post(name: .readerZoomIn, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("=", modifiers: [.command])

      Button("Zoom Out") {
        NotificationCenter.default.post(name: .readerZoomOut, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("-", modifiers: [.command])

      Button("Toggle Thumbnails") {
        NotificationCenter.default.post(name: .readerToggleSidebar, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("b", modifiers: [.command])

      Button("Find in Document") {
        NotificationCenter.default.post(name: .readerOpenSearch, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("f", modifiers: [.command])
    }
  }
}

@MainActor
final class ReaderCommandRouter {
  static let shared = ReaderCommandRouter()
  weak var activeModel: ReaderViewModel?

  private init() {}

  func activate(_ model: ReaderViewModel) {
    activeModel = model
  }

  func deactivate(_ model: ReaderViewModel) {
    if activeModel === model { activeModel = nil }
  }
}
