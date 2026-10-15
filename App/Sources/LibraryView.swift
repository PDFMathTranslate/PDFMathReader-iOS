import ReaderCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryView: View {
  @EnvironmentObject private var library: LibraryModel
  @State private var isImporting = false
  @State private var isShowingSettings = false
  @State private var isConfirmingClear = false

  let onOpenDocument: (DocumentSession) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 18, alignment: .top)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        header
        if library.recents.isEmpty {
          emptyState
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(library.recents) { recent in
              RecentDocumentCard(document: recent) {
                guard let session = library.makeSession(for: recent) else { return }
                onOpenDocument(session)
              }
            }
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
      .frame(maxWidth: 1120, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          isShowingSettings = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        Button {
          isImporting = true
        } label: {
          Label("Import PDF", systemImage: "plus")
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.pdf],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first, let session = library.makeSession(for: url) else { return }
        onOpenDocument(session)
      case .failure:
        library.lastError = "The PDF could not be imported."
      }
    }
    .sheet(isPresented: $isShowingSettings) {
      SettingsView().environmentObject(library)
    }
    .confirmationDialog(
      "Clear recent PDFs?",
      isPresented: $isConfirmingClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) { library.clearHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the recent list and cached thumbnails. Your original files stay untouched.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Recent PDFs")
          .font(.title2.weight(.semibold))
        Spacer()
        if !library.recents.isEmpty {
          Button("Clear", role: .destructive) { isConfirmingClear = true }
            .font(.subheadline.weight(.medium))
        }
      }
      Text("Pick up where you left off, or import a paper from Files.")
        .foregroundStyle(.secondary)
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No recent PDFs", systemImage: "doc.text.magnifyingglass")
    } description: {
      Text("Import a PDF to start reading. Your position and display settings will be restored next time.")
    } actions: {
      Button("Import PDF") { isImporting = true }
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, minHeight: 340)
  }
}

private struct RecentDocumentCard: View {
  let document: RecentDocument
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        RecentThumbnail(path: document.thumbnailCachePath)
          .frame(maxWidth: .infinity)
          .aspectRatio(0.72, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          Text(document.title)
            .font(.headline)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          HStack(spacing: 5) {
            if let pageCount = document.pageCount {
              Text("\(pageCount) pages")
            }
            Text("·")
            Text(document.lastOpened, style: .relative)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(10)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(document.title)
    .accessibilityHint("Open PDF")
  }
}

private struct RecentThumbnail: View {
  let path: String?

  var body: some View {
    Group {
      if let path, let image = UIImage(contentsOfFile: path) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .padding(6)
      } else {
        Image(systemName: "doc.richtext")
          .font(.system(size: 46, weight: .light))
          .foregroundStyle(.tint)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      LinearGradient(
        colors: [Color(uiColor: .secondarySystemBackground), Color(uiColor: .tertiarySystemBackground)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}
