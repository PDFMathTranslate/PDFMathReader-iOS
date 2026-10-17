import SwiftUI

private struct ReaderWorkspaceSnapshot: Codable {
  let tabs: [ReaderWindowValue]
  let selectedID: String?
}

@MainActor
private final class ReaderWorkspaceLaunchState {
  var resolved = false
  var explicitOpenReceived = false
}

private struct OpenReaderTabKey: EnvironmentKey {
  static let defaultValue: (@MainActor (DocumentSession) -> Void)? = nil
}

private struct ReaderTabStripKey: EnvironmentKey {
  static let defaultValue: (@MainActor () -> AnyView)? = nil
}

extension EnvironmentValues {
  var openReaderTab: (@MainActor (DocumentSession) -> Void)? {
    get { self[OpenReaderTabKey.self] }
    set { self[OpenReaderTabKey.self] = newValue }
  }

  var readerTabStrip: (@MainActor () -> AnyView)? {
    get { self[ReaderTabStripKey.self] }
    set { self[ReaderTabStripKey.self] = newValue }
  }
}

/// A window owns its tabs and retains each document's reader models while
/// another tab is visible. Only the selected PDF mounts a PDFKit view.
struct ReaderWorkspace: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @StateObject private var tabs = ReaderTabsModel()
  @State private var launchState = ReaderWorkspaceLaunchState()
  @State private var isRestoringWorkspace = false
  @SceneStorage("readerWorkspace.snapshot") private var storedWorkspaceData: Data?
  @State private var showingLibrary = false
  @State private var isClosingComputerDocument = false
  @State private var failedCloseID: String?
  @State private var closeToStartPage = false
  @Environment(\.scenePhase) private var scenePhase
  let initialSession: DocumentSession?
  let onEmpty: (() -> Void)?
  let restoreSavedWorkspace: Bool
  let restorationFallback: ReaderWindowValue?

  init(
    initialSession: DocumentSession? = nil,
    onEmpty: (() -> Void)? = nil,
    restoreSavedWorkspace: Bool = true,
    restorationFallback: ReaderWindowValue? = nil
  ) {
    self.initialSession = initialSession
    self.onEmpty = onEmpty
    self.restoreSavedWorkspace = restoreSavedWorkspace
    self.restorationFallback = restorationFallback
  }

  var body: some View {
    VStack(spacing: 0) {
      if let selected = tabs.selectedTab {
        reader(for: selected).id(selected.id)
          .modifier(ComputerSessionGuard(manager: library.computerDocuments,
            documentID: selected.id, retry: { close(selected.id) }))
      } else {
        NavigationStack {
          LibraryView { openExplicitly($0) }
        }
      }
    }
    .environment(\.openReaderTab, { session in openExplicitly(session) })
    .environment(\.readerTabStrip, {
      AnyView(Group {
        if tabs.tabs.count > 1 { tabStrip }
      })
    })
    .disabled(isClosingComputerDocument || library.epubConversionsInProgress > 0)
    .overlay {
      if library.epubConversionsInProgress > 0 {
        ProgressView(L10n.string("ios.preparingEPUB"))
          .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .modifier(ComputerDocumentToast(manager: library.computerDocuments))
    .overlay {
      if isClosingComputerDocument {
        ReaderCloseBackdrop(message: L10n.string("ios.computerSaving"), saving: true)
      } else if let id = failedCloseID {
        ReaderCloseBackdrop(message: L10n.string("ios.readerCloseSaveFailed"), retry: {
          close(id, showStartPage: closeToStartPage)
        })
      }
    }
    .task(id: scenePhase == .active) {
      // Leaving the active phase syncs once below; periodic sync is foreground-only.
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) } catch { break }
        for tab in tabs.tabs where library.computerDocuments.isManaged(tab.session) {
          _ = await library.computerDocuments.sync(tab, release: false)
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase != .active else { return }
      Task {
        let background = UIApplication.shared.beginBackgroundTask(withName: "Sync computer document")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        for tab in tabs.tabs where library.computerDocuments.isManaged(tab.session) {
          _ = await library.computerDocuments.sync(tab, release: false)
        }
      }
    }
    .preferredColorScheme(library.preferences.theme.colorScheme)
    .sheet(isPresented: $showingLibrary) {
      NavigationStack {
        LibraryView { session in
          openExplicitly(session)
          showingLibrary = false
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(L10n.string("ios.cancel")) { showingLibrary = false }
          }
        }
      }
    }
    .onOpenURL { url in
      launchState.explicitOpenReceived = true
      launchState.resolved = true
      Task {
        guard let session = await library.receiveExternalPDF(at: url) else { return }
        showingLibrary = false
        open(session)
      }
    }
    .task {
      await resolveLaunch()
    }
    .onChange(of: tabs.tabs.map(\.id)) { _, _ in persistWorkspace() }
    .onChange(of: tabs.selectedID) { _, _ in persistWorkspace() }
    .alert("PDFMathReader", isPresented: Binding(
      get: { library.lastError != nil },
      set: { if !$0 { library.lastError = nil } }
    )) {
      Button(L10n.string("ios.ok")) { library.lastError = nil }
    } message: {
      Text(library.lastError ?? "")
    }
  }

  @ViewBuilder
  private func reader(for tab: ReaderTab) -> some View {
    if horizontalSizeClass == .regular {
      ReaderView(tab: tab, onDragClose: { close(tab.id, showStartPage: true) }) { close(tab.id) }
    } else {
      NavigationStack {
        ReaderView(tab: tab, onDragClose: { close(tab.id, showStartPage: true) }) { close(tab.id) }
      }
    }
  }

  private var tabStrip: some View {
    HStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(tabs.tabs) { tab in
              HStack(spacing: 0) {
                Button {
                  tabs.select(tab.id)
                } label: {
                  Label(tab.session.title, systemImage:
                    library.computerDocuments.isManaged(tab.session) ? "desktopcomputer" : "doc.richtext")
                    .lineLimit(1)
                    .frame(minWidth: 80, maxWidth: 200, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.tab.\(tab.id)")
                .accessibilityAddTraits(tab.id == tabs.selectedID ? .isSelected : [])
                Button {
                  close(tab.id)
                } label: {
                  Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("\(L10n.string("menu.extra.messages.Close Document")): \(tab.session.title)"))
                .accessibilityIdentifier("reader.closeTab.\(tab.id)")
              }
              .buttonStyle(.plain)
              .font(.subheadline)
              .background(
                tab.id == tabs.selectedID ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
              )
              .overlay(alignment: .bottom) {
                if tab.id == tabs.selectedID {
                  Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 12)
                }
              }
              .id(tab.id)
            }
          }
          .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .onChange(of: tabs.selectedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      Button {
        showingLibrary = true
      } label: {
        Image(systemName: "plus").frame(width: 44, height: 44)
      }
      .accessibilityLabel(L10n.string("ios.importDocument"))
      .accessibilityIdentifier("reader.addTab")
    }
    .padding(.vertical, 4)
  }

  private func openExplicitly(_ session: DocumentSession) {
    launchState.explicitOpenReceived = true
    launchState.resolved = true
    open(session)
  }

  private func open(_ session: DocumentSession) {
    tabs.open(session, library: library)
    persistWorkspace()
  }

  private func close(_ id: String, showStartPage: Bool = false) {
    guard !isClosingComputerDocument else { return }
    guard let tab = tabs.tabs.first(where: { $0.id == id }) else { return }
    failedCloseID = nil
    if library.computerDocuments.isManaged(tab.session) {
      closeToStartPage = showStartPage
      isClosingComputerDocument = true
      Task {
        defer { isClosingComputerDocument = false }
        guard await library.computerDocuments.sync(tab, release: true) else {
          failedCloseID = id
          return
        }
        tabs.close(id, showStartPage: showStartPage)
        persistWorkspace()
        if tabs.tabs.isEmpty { onEmpty?() }
      }
    } else {
      tabs.close(id, showStartPage: showStartPage)
      persistWorkspace()
      if tabs.tabs.isEmpty { onEmpty?() }
    }
  }

  private func resolveLaunch() async {
    guard !launchState.resolved else { return }

    // A reader window's live handoff is an explicit open and must win over
    // scene restoration. It also remains available when restoration is off.
    if let initialSession, !restoreSavedWorkspace {
      launchState.resolved = true
      open(initialSession)
      return
    }

    // Give an open URL delivered during scene construction a chance to mark
    // this launch explicit before looking at saved workspace state.
    await Task.yield()
    guard !launchState.explicitOpenReceived else {
      launchState.resolved = true
      return
    }

    #if DEBUG
    let launchURLs = library.consumeLaunchArgumentPDFs()
    if !launchURLs.isEmpty {
      launchState.resolved = true
      for url in launchURLs {
        guard !launchState.explicitOpenReceived else { return }
        if let session = await library.makeSession(for: url) {
          guard !launchState.explicitOpenReceived else { return }
          open(session)
        }
      }
      return
    }
    #endif

    launchState.resolved = true
    guard library.preferences.restoreDocumentsOnLaunch,
          !launchState.explicitOpenReceived
    else { return }
    guard let data = storedWorkspaceData, !data.isEmpty else {
      await openFallbackSessionIfNeeded()
      return
    }

    let snapshot: ReaderWorkspaceSnapshot
    do {
      snapshot = try JSONDecoder().decode(ReaderWorkspaceSnapshot.self, from: data)
    } catch {
      storedWorkspaceData = nil
      await openFallbackSessionIfNeeded()
      return
    }
    guard !snapshot.tabs.isEmpty else {
      storedWorkspaceData = nil
      await openFallbackSessionIfNeeded()
      return
    }

    isRestoringWorkspace = true
    defer {
      isRestoringWorkspace = false
      if launchState.explicitOpenReceived { persistWorkspace() }
    }
    var sessions: [DocumentSession] = []
    for value in snapshot.tabs {
      guard !Task.isCancelled, !launchState.explicitOpenReceived else {
        isRestoringWorkspace = false
        return
      }
      let fallbackURL = ReaderWindow.relocatedIntoCurrentContainer(value.url)
      if let session = await library.session(for: value, fallbackURL: fallbackURL) {
        sessions.append(session)
      }
    }
    guard !Task.isCancelled, !launchState.explicitOpenReceived else {
      isRestoringWorkspace = false
      return
    }

    guard !sessions.isEmpty else {
      isRestoringWorkspace = false
      await openFallbackSessionIfNeeded()
      return
    }

    // A missing tab can leave the library's last error populated even though
    // the remaining tabs restored successfully. Keep that stale error from
    // presenting an alert over a usable workspace.
    library.lastError = nil
    for session in sessions {
      guard !launchState.explicitOpenReceived else {
        isRestoringWorkspace = false
        return
      }
      tabs.open(session, library: library)
    }
    if let selectedID = snapshot.selectedID,
       let selected = sessions.first(where: { $0.id == selectedID }) {
      tabs.select(selected.id)
    }
    isRestoringWorkspace = false
    persistWorkspace()
  }

  private func openFallbackSessionIfNeeded() async {
    guard !launchState.explicitOpenReceived else { return }
    if let initialSession {
      library.lastError = nil
      open(initialSession)
      return
    }
    guard let restorationFallback else { return }
    let fallbackURL = ReaderWindow.relocatedIntoCurrentContainer(restorationFallback.url)
    guard let session = await library.session(for: restorationFallback, fallbackURL: fallbackURL) else {
      return
    }
    guard !launchState.explicitOpenReceived else { return }
    open(session)
  }

  private func persistWorkspace() {
    guard !isRestoringWorkspace else { return }
    guard !tabs.tabs.isEmpty else {
      storedWorkspaceData = nil
      return
    }
    let snapshot = ReaderWorkspaceSnapshot(
      tabs: tabs.tabs.map { ReaderWindowValue(documentID: $0.session.id, url: $0.session.url) },
      selectedID: tabs.selectedID
    )
    storedWorkspaceData = try? JSONEncoder().encode(snapshot)
  }
}

/// An uncertain unlock acknowledgement freezes editing until the exact save
/// is acknowledged. The document may already be available on another device.
private struct ComputerSessionGuard: ViewModifier {
  @ObservedObject var manager: CompanionDocumentManager
  let documentID: String
  let retry: () -> Void

  func body(content: Content) -> some View {
    content
      .disabled(manager.uncertainSessions.contains(documentID))
      .overlay {
        if manager.uncertainSessions.contains(documentID) {
          VStack(spacing: 16) {
            Text(L10n.string("ios.computerReleasePending"))
              .multilineTextAlignment(.center)
            Button(L10n.string("companion.retry"), action: retry).buttonStyle(.borderedProminent)
          }
          .padding(24)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
          .padding()
        }
      }
  }
}
