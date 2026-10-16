import Combine

@MainActor
final class ReaderTab: Identifiable {
  let session: DocumentSession
  nonisolated let id: String

  private let library: LibraryModel
  private var modelInitialized = false

  lazy var model: ReaderViewModel = {
    modelInitialized = true
    return ReaderViewModel(session: session, library: library)
  }()

  lazy var annotations: ReaderAnnotationViewModel = ReaderAnnotationViewModel(session: session)
  lazy var drawings: ReaderDrawingModel = ReaderDrawingModel(session: session)

  init(session: DocumentSession, library: LibraryModel) {
    self.id = session.id
    self.session = session
    self.library = library
  }

  func persistModelIfInitialized() {
    guard modelInitialized else { return }
    model.persistReadingState()
  }
}

@MainActor
final class ReaderTabsModel: ObservableObject {
  @Published private(set) var tabs: [ReaderTab] = []
  @Published private(set) var selectedID: String?

  var selectedTab: ReaderTab? {
    guard let selectedID else { return nil }
    return tabs.first { $0.id == selectedID }
  }

  func open(_ session: DocumentSession, library: LibraryModel) {
    if let existing = tabs.first(where: { $0.id == session.id }) {
      select(existing.id)
      return
    }

    let tab = ReaderTab(session: session, library: library)
    tabs.append(tab)
    select(tab.id)
  }

  func select(_ id: String) {
    guard let tab = tabs.first(where: { $0.id == id }), selectedID != id else { return }
    selectedTab?.persistModelIfInitialized()
    // Loading a reader updates library metadata. Do that in the action,
    // before SwiftUI evaluates the selected reader's body.
    _ = tab.model
    _ = tab.annotations
    _ = tab.drawings
    selectedID = id
  }

  func close(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let wasSelected = selectedID == id
    tabs[index].persistModelIfInitialized()

    tabs.remove(at: index)
    guard wasSelected else { return }
    selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
  }
}
