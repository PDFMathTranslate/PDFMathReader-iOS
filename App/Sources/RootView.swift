import SwiftUI

struct RootView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.openWindow) private var openWindow
  @State private var compactSession: DocumentSession?

  var body: some View {
    NavigationStack {
      LibraryView { session in
        open(session)
      }
      .navigationDestination(item: $compactSession) { session in
        ReaderView(session: session, library: library)
      }
    }
    .preferredColorScheme(library.preferences.theme.colorScheme)
    .onOpenURL { url in
      open(url: url)
    }
    .alert(
      "PDFMathReader",
      isPresented: Binding(
        get: { library.lastError != nil },
        set: { if !$0 { library.lastError = nil } }
      )
    ) {
      Button(L10n.string("ios.ok")) { library.lastError = nil }
    } message: {
      Text(library.lastError ?? "")
    }
  }

  private func open(url: URL) {
    guard let session = library.makeSession(for: url) else { return }
    open(session)
  }

  private func open(_ session: DocumentSession) {
    if horizontalSizeClass == .regular {
      openWindow(value: session.url)
    } else {
      compactSession = session
    }
  }
}

struct ReaderWindow: View {
  @EnvironmentObject private var library: LibraryModel
  let url: URL
  @State private var session: DocumentSession?

  var body: some View {
    Group {
      if let session {
        ReaderView(session: session, library: library)
      } else {
        ProgressView(L10n.string("status.openingPDF"))
      }
    }
    .task {
      if session == nil {
        session = library.makeSession(for: url)
      }
    }
  }
}
