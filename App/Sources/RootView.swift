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
    #if DEBUG
    .task { openLaunchArgumentPDF() }
    #endif
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

  #if DEBUG
  /// UI tests pass `-PMROpenPDF <name-or-path>`; a bare name resolves against Documents.
  private func openLaunchArgumentPDF() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let flag = arguments.firstIndex(of: "-PMROpenPDF"), flag + 1 < arguments.count else { return }
    let value = arguments[flag + 1]
    let url = value.hasPrefix("/")
      ? URL(fileURLWithPath: value)
      : URL.documentsDirectory.appendingPathComponent(value)
    open(url: url)
  }
  #endif

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
  @Environment(\.dismissWindow) private var dismissWindow
  let url: URL
  @State private var session: DocumentSession?
  @State private var failure: String?

  var body: some View {
    Group {
      if let session {
        ReaderView(session: session, library: library)
      } else if let failure {
        // The library window's alert may be hidden; report the failure here
        // instead of spinning forever.
        ContentUnavailableView {
          Label(L10n.string("ios.pdfUnavailable"), systemImage: "doc.questionmark")
        } description: {
          Text(failure)
        } actions: {
          Button(L10n.string("menu.extra.messages.Close Window")) { dismissWindow() }
        }
      } else {
        ProgressView(L10n.string("status.openingPDF"))
      }
    }
    .task {
      guard session == nil, failure == nil else { return }
      session = library.makeSession(for: Self.relocatedIntoCurrentContainer(url))
      if session == nil {
        failure = library.lastError ?? L10n.string("error.thisPDFUnavailable")
        library.lastError = nil
      }
    }
  }

  /// Restored windows keep an absolute URL, but iOS may move the app's data
  /// container between installs. Re-root a missing in-container file under
  /// the current Documents directory.
  static func relocatedIntoCurrentContainer(_ url: URL) -> URL {
    let path = url.path
    guard url.isFileURL,
          !FileManager.default.fileExists(atPath: path),
          path.contains("/Containers/Data/Application/"),
          let documents = path.range(of: "/Documents/")
    else { return url }
    let candidate = URL.documentsDirectory.appendingPathComponent(String(path[documents.upperBound...]))
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
  }
}
