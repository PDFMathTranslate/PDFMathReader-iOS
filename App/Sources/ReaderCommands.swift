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
    CommandMenu(L10n.string("ios.reader")) {
      Button(L10n.string("menu.extra.messages.Next Page")) {
        NotificationCenter.default.post(name: .readerNextPage, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut(.rightArrow, modifiers: [])

      Button(L10n.string("menu.extra.messages.Previous Page")) {
        NotificationCenter.default.post(name: .readerPreviousPage, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut(.leftArrow, modifiers: [])

      Divider()

      Button(L10n.string("menu.extra.messages.Zoom In")) {
        NotificationCenter.default.post(name: .readerZoomIn, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("=", modifiers: [.command])

      Button(L10n.string("menu.extra.messages.Zoom Out")) {
        NotificationCenter.default.post(name: .readerZoomOut, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("-", modifiers: [.command])

      Button(L10n.string("toolbar.toggleThumbnails")) {
        NotificationCenter.default.post(name: .readerToggleSidebar, object: ReaderCommandRouter.shared.activeModel)
      }
      .keyboardShortcut("b", modifiers: [.command])

      Button(L10n.string("ios.findInDocument")) {
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
