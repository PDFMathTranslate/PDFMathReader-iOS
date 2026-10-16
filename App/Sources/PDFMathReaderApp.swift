import SwiftUI

@main
struct PDFMathReaderApp: App {
  @StateObject private var library = LibraryModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(library)
    }

    WindowGroup(for: ReaderWindowValue.self) { $value in
      if let value {
        ReaderWindow(value: value)
          .environmentObject(library)
      } else {
        ContentUnavailableView(L10n.string("ios.noPDFSelected"), systemImage: "doc")
      }
    }
    .commands { ReaderCommandMenu() }
  }
}
