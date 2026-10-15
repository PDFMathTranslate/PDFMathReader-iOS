import SwiftUI

@main
struct PDFMathReaderApp: App {
  @StateObject private var library = LibraryModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(library)
    }

    WindowGroup(for: URL.self) { $url in
      if let url {
        ReaderWindow(url: url)
          .environmentObject(library)
      } else {
        ContentUnavailableView(L10n.string("ios.noPDFSelected"), systemImage: "doc")
      }
    }
    .commands { ReaderCommandMenu() }
  }
}
