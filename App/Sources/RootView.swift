import SwiftUI
import UIKit

/// The library's window scene, so closing a reader window can bring it forward.
@MainActor
enum LibraryScene {
  static weak var session: UISceneSession?
}

/// Reports the UIKit scene session of the window hosting this view.
struct SceneSessionReader: UIViewRepresentable {
  let onSession: (UISceneSession) -> Void

  func makeUIView(context: Context) -> HostView { HostView(onSession: onSession) }
  func updateUIView(_ uiView: HostView, context: Context) {}

  final class HostView: UIView {
    let onSession: (UISceneSession) -> Void
    init(onSession: @escaping (UISceneSession) -> Void) {
      self.onSession = onSession
      super.init(frame: .zero)
      isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let session = window?.windowScene?.session { onSession(session) }
    }
  }
}

struct RootView: View {
  var body: some View {
    ReaderWorkspace()
      .background(SceneSessionReader { LibraryScene.session = $0 })
  }
}

struct ReaderWindow: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  let value: ReaderWindowValue
  @State private var session: DocumentSession?
  @State private var failure: String?
  @State private var sceneSession: UISceneSession?

  var body: some View {
    Group {
      if let session {
        ReaderWorkspace(initialSession: session, onEmpty: closeDocument)
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
    .background(SceneSessionReader { sceneSession = $0 })
    .task {
      guard session == nil, failure == nil else { return }
      session = await library.session(
        for: value,
        fallbackURL: Self.relocatedIntoCurrentContainer(value.url)
      )
      if session == nil {
        failure = library.lastError ?? L10n.string("error.thisPDFUnavailable")
        library.lastError = nil
      }
    }
  }

  /// Brings the library forward (reopening it if its window was closed), then
  /// closes this reader window.
  private func closeDocument() {
    if let library = LibraryScene.session,
       UIApplication.shared.openSessions.contains(library) {
      UIApplication.shared.requestSceneSessionActivation(library, userActivity: nil, options: nil)
    } else {
      openWindow(id: PDFMathReaderApp.libraryWindowID)
    }
    // dismissWindow() leaves the reader scene alive once the library takes
    // the foreground, so destroy this scene through UIKit.
    if let sceneSession {
      let options = UIWindowSceneDestructionRequestOptions()
      options.windowDismissalAnimation = .standard
      UIApplication.shared.requestSceneSessionDestruction(sceneSession, options: options)
    } else {
      dismissWindow()
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
