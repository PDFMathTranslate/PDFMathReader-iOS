import SwiftUI

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
  @State private var showingLibrary = false
  let initialSession: DocumentSession?
  let onEmpty: (() -> Void)?

  init(initialSession: DocumentSession? = nil, onEmpty: (() -> Void)? = nil) {
    self.initialSession = initialSession
    self.onEmpty = onEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      if let selected = tabs.selectedTab {
        reader(for: selected).id(selected.id)
      } else {
        NavigationStack {
          LibraryView { open($0) }
        }
      }
    }
    .environment(\.openReaderTab, { session in open(session) })
    .environment(\.readerTabStrip, { AnyView(tabStrip) })
    .preferredColorScheme(library.preferences.theme.colorScheme)
    .sheet(isPresented: $showingLibrary) {
      NavigationStack {
        LibraryView { session in
          open(session)
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
      guard let session = library.receiveExternalPDF(at: url) else { return }
      showingLibrary = false
      open(session)
    }
    .task {
      if tabs.tabs.isEmpty, let initialSession { open(initialSession) }
      #if DEBUG
      if let url = library.consumeLaunchArgumentPDF(), let session = library.makeSession(for: url) {
        open(session)
      }
      let arguments = ProcessInfo.processInfo.arguments
      if let flag = arguments.firstIndex(of: "-PMRTabPDFs") {
        for path in arguments.dropFirst(flag + 1).prefix(while: { !$0.hasPrefix("-") }) {
          let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL.documentsDirectory.appendingPathComponent(path)
          if let session = library.makeSession(for: url) { open(session) }
        }
      }
      #endif
    }
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
      ReaderView(tab: tab) { close(tab.id) }
    } else {
      NavigationStack {
        ReaderView(tab: tab) { close(tab.id) }
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
                  Label(tab.session.title, systemImage: "doc.richtext")
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
      .accessibilityLabel(L10n.string("ios.importPDF"))
      .accessibilityIdentifier("reader.addTab")
    }
    .padding(.vertical, 4)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func open(_ session: DocumentSession) {
    tabs.open(session, library: library)
  }

  private func close(_ id: String) {
    tabs.close(id)
    if tabs.tabs.isEmpty { onEmpty?() }
  }
}
