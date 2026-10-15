import Foundation
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

struct GlossaryEditorView: View {
  @Binding private var libraries: [GlossaryLibrary]
  private let store: GlossaryStore

  @State private var isImporting = false
  @State private var isExporting = false
  @State private var exportDocument = GlossaryFileDocument()
  @State private var errorMessage: String?

  init(
    libraries: Binding<[GlossaryLibrary]>,
    store: GlossaryStore = GlossaryStore()
  ) {
    _libraries = libraries
    self.store = store
  }

  var body: some View {
    List {
      Section {
        Text("Exact phrase matching is case sensitive. The longest match applies to new translations.")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button {
          addLibrary()
        } label: {
          Label("Add glossary", systemImage: "plus.circle.fill")
        }
      }

      if libraries.isEmpty {
        ContentUnavailableView(
          "No terminology libraries",
          systemImage: "text.book.closed",
          description: Text("Add a glossary to keep preferred translations for recurring terms.")
        )
        .listRowBackground(Color.clear)
      } else {
        ForEach(Array(libraries.indices), id: \.self) { libraryIndex in
          librarySection(at: libraryIndex)
        }
      }
    }
    .navigationTitle("Terminology glossary")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Button("Import glossary…", systemImage: "arrow.down.doc") {
            isImporting = true
          }
          Button("Export glossary…", systemImage: "arrow.up.doc") {
            exportDocument = GlossaryFileDocument(libraries: libraries)
            isExporting = true
          }
        } label: {
          Label("Glossary files", systemImage: "ellipsis.circle")
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.json],
      allowsMultipleSelection: false
    ) { result in
      importGlossary(result)
    }
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "glossaries.json"
    ) { result in
      if case .failure(let error) = result {
        errorMessage = error.localizedDescription
      }
    }
    .alert("Glossary error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .onAppear {
      if libraries.isEmpty {
        let saved = store.load()
        if !saved.isEmpty { libraries = saved }
      }
    }
    .onChange(of: libraries) { _, value in
      do {
        try store.save(value)
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private func librarySection(at libraryIndex: Int) -> some View {
    Section {
      TextField(
        "Library name",
        text: Binding(
          get: { libraries[libraryIndex].name },
          set: { libraries[libraryIndex].name = $0 }
        )
      )
      .textInputAutocapitalization(.sentences)

      Toggle(
        "Enabled",
        isOn: Binding(
          get: { libraries[libraryIndex].enabled },
          set: { libraries[libraryIndex].enabled = $0 }
        )
      )

      if libraries[libraryIndex].entries.isEmpty {
        Text("No terms yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(libraries[libraryIndex].entries.indices), id: \.self) { entryIndex in
          entryRow(libraryIndex: libraryIndex, entryIndex: entryIndex)
        }
      }

      Button {
        addEntry(to: libraryIndex)
      } label: {
        Label("Add term", systemImage: "plus")
      }

      Button(role: .destructive) {
        deleteLibrary(at: libraryIndex)
      } label: {
        Label("Remove glossary", systemImage: "trash")
      }
    } header: {
      Text(displayName(for: libraries[libraryIndex]))
    }
  }

  private func entryRow(libraryIndex: Int, entryIndex: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        "Source phrase",
        text: Binding(
          get: { libraries[libraryIndex].entries[entryIndex].source },
          set: { libraries[libraryIndex].entries[entryIndex].source = $0 }
        )
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()

      TextField(
        "Target phrase",
        text: Binding(
          get: { libraries[libraryIndex].entries[entryIndex].target },
          set: { libraries[libraryIndex].entries[entryIndex].target = $0 }
        )
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()

      Button(role: .destructive) {
        deleteEntry(libraryIndex: libraryIndex, entryIndex: entryIndex)
      } label: {
        Label("Remove term", systemImage: "minus.circle")
          .font(.footnote)
      }
    }
    .padding(.vertical, 4)
  }

  private func addLibrary() {
    libraries.append(
      GlossaryLibrary(
        id: "glossary-\(UUID().uuidString)",
        name: "New glossary",
        enabled: true,
        entries: [GlossaryEntry(source: "", target: "")]
      )
    )
  }

  private func deleteLibrary(at index: Int) {
    guard libraries.indices.contains(index) else { return }
    libraries.remove(at: index)
  }

  private func addEntry(to libraryIndex: Int) {
    guard libraries.indices.contains(libraryIndex) else { return }
    libraries[libraryIndex].entries.append(GlossaryEntry(source: "", target: ""))
  }

  private func deleteEntry(libraryIndex: Int, entryIndex: Int) {
    guard libraries.indices.contains(libraryIndex),
      libraries[libraryIndex].entries.indices.contains(entryIndex)
    else { return }
    libraries[libraryIndex].entries.remove(at: entryIndex)
  }

  private func displayName(for library: GlossaryLibrary) -> String {
    let value = library.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "Unnamed glossary" : value
  }

  private func importGlossary(_ result: Result<[URL], Error>) {
    do {
      let urls = try result.get()
      guard let url = urls.first else {
        throw CocoaError(.fileNoSuchFile)
      }
      let data = try Data(contentsOf: url)
      let imported = try JSONDecoder().decode([GlossaryLibrary].self, from: data)
      guard validGlossaries(imported) else {
        throw GlossaryStoreError.invalidGlossary
      }
      libraries = imported
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
