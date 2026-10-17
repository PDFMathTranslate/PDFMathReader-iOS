import ReaderCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
  @State private var isImporting = false
  @State private var isOpeningDocument = false
  @State private var isShowingComputerDocuments = false
  @State private var isShowingSettings = false
  @State private var isConfirmingClear = false
  @State private var cacheClearDocument: RecentDocument?

  let onOpenDocument: (DocumentSession) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 18, alignment: .topLeading)
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        Text(L10n.string("ios.library"))
          .font(.largeTitle.bold())
          .accessibilityAddTraits(.isHeader)
        header
        if library.recents.isEmpty {
          emptyState
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(library.recents) { recent in
              RecentDocumentCard(document: recent, isRemote: library.isRemoteDocument(recent)) {
                open(recent)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contextMenu {
                Button { open(recent) } label: {
                  Label(L10n.string("ios.recentOpen"), systemImage: "doc.text")
                }
                if supportsMultipleWindows {
                  Button { open(recent, inNewWindow: true) } label: {
                    Label(L10n.string("ios.recentOpenWindow"), systemImage: "macwindow.badge.plus")
                  }
                }
                Button { library.togglePinned(recent) } label: {
                  Label(L10n.string(recent.pinned ? "ios.recentUnpin" : "ios.recentPin"),
                        systemImage: recent.pinned ? "pin.slash" : "pin")
                }
                if !library.isRemoteDocument(recent), !recent.bookmarkData.isEmpty {
                  Button { library.copyLocation(for: recent) } label: {
                    Label(L10n.string("ios.recentCopyLocation"), systemImage: "doc.on.doc")
                  }
                }
                Divider()
                Button { cacheClearDocument = recent } label: {
                  Label(L10n.string("ios.clearTranslationCache"), systemImage: "arrow.trianglehead.2.clockwise")
                }
                Button(role: .destructive) { library.removeRecent(recent) } label: {
                  Label(L10n.string("ios.recentRemove"), systemImage: "clock.badge.xmark")
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: 1080, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      computerDocumentsSection
        .frame(maxWidth: 1080)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
    .disabled(isOpeningDocument)
    .overlay {
      if isOpeningDocument { ProgressView(L10n.string(library.epubConversionsInProgress > 0 ? "ios.preparingEPUB" : "status.openingPDF")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .task { await library.reconcileRecentDocuments() }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          isShowingSettings = true
        } label: {
          Label(L10n.string("settings.title"), systemImage: "gearshape")
        }
        .accessibilityIdentifier("library.settings")
        Button {
          isImporting = true
        } label: {
          Label(L10n.string("ios.importDocument"), systemImage: "plus")
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: [.pdf, .epub],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first, !isOpeningDocument else { return }
        isOpeningDocument = true
        Task {
          defer { isOpeningDocument = false }
          guard let session = await library.makeSession(for: url) else { return }
          onOpenDocument(session)
        }
      case .failure:
        library.lastError = L10n.string("ios.importDocumentFailed")
      }
    }
    .sheet(isPresented: $isShowingSettings) {
      SettingsView().environmentObject(library)
    }
    .sheet(isPresented: $isShowingComputerDocuments) {
      NavigationStack {
        CompanionDocumentsView(manager: library.computerDocuments) { session in
          isShowingComputerDocuments = false
          onOpenDocument(session)
        }
        .environmentObject(library)
      }
    }
    .confirmationDialog(
      L10n.string("ios.clearTranslationCache"),
      isPresented: Binding(
        get: { cacheClearDocument != nil },
        set: { if !$0 { cacheClearDocument = nil } }
      ),
      titleVisibility: .visible,
      presenting: cacheClearDocument
    ) { recent in
      Button(L10n.string("ios.clearTranslationCache"), role: .destructive) {
        Task { await library.clearTranslationCache(for: recent) }
      }
      Button(L10n.string("ios.cancel"), role: .cancel) {}
    } message: { _ in
      Text(L10n.string("ios.recentClearCacheMessage"))
    }
    .confirmationDialog(
      L10n.string("ios.clearRecentPDFsTitle"),
      isPresented: $isConfirmingClear,
      titleVisibility: .visible
    ) {
      Button(L10n.string("ios.clearHistory"), role: .destructive) { library.clearHistory() }
      Button(L10n.string("ios.cancel"), role: .cancel) {}
    } message: {
      Text(L10n.string("ios.clearHistoryMessage"))
    }
  }

  private func open(_ recent: RecentDocument, inNewWindow: Bool = false) {
    guard !isOpeningDocument else { return }
    isOpeningDocument = true
    Task {
      defer { isOpeningDocument = false }
      guard let session = await library.makeSession(for: recent) else { return }
      if inNewWindow {
        openWindow(value: library.windowValue(for: session))
      } else {
        onOpenDocument(session)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(L10n.string("startup.recentDocuments"))
          .font(.title2.weight(.semibold))
        Spacer()
        if !library.recents.isEmpty {
          Button(L10n.string("startup.clear"), role: .destructive) { isConfirmingClear = true }
            .font(.subheadline.weight(.medium))
        }
      }
      Text(L10n.string("ios.resumeReading"))
        .foregroundStyle(.secondary)
    }
  }

  private var computerDocumentsSection: some View {
    Button {
      isShowingComputerDocuments = true
    } label: {
      HStack(spacing: 14) {
        Image(systemName: "desktopcomputer")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 36, height: 36)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 3) {
          Text(L10n.string("companion.onYourComputer"))
            .font(.headline)
          Text(L10n.string("companion.onYourComputerDescription"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("library.computerDocuments")
    .accessibilityHint(L10n.string("companion.openDocumentsHint"))
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(L10n.string("menu.extra.messages.No Recent Documents"), systemImage: "doc.text.magnifyingglass")
    } description: {
      Text(L10n.string("ios.noRecentPDFsDescription"))
    } actions: {
      Button(L10n.string("ios.importDocument")) { isImporting = true }
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, minHeight: 340)
  }
}

private struct RecentDocumentCard: View {
  let document: RecentDocument
  let isRemote: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        RecentThumbnail(document: document)
          .frame(maxWidth: .infinity)
          .aspectRatio(0.72, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            if document.pinned {
              Image(systemName: "pin.fill")
                .foregroundStyle(.tint)
            }
            if isRemote {
              Image(systemName: "desktopcomputer")
                .foregroundStyle(.tint)
            }
            Text(document.title)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          .font(.headline)
          HStack(spacing: 5) {
            if let pageCount = document.pageCount {
              Text(L10n.string("ios.pagesCount", String(pageCount)))
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
    .accessibilityIdentifier("library.recent.\(document.id)")
    .accessibilityHint(L10n.string("ios.openPDF"))
  }
}

private struct RecentThumbnail: View {
  let document: RecentDocument
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        // Cached previews are drawn uninverted; dim them like open pages.
        Image(uiImage: colorScheme == .dark ? ReaderDarkPDF.inverted(image) : image)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "doc.richtext")
          .font(.system(size: 46, weight: .light))
          .foregroundStyle(.tint)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: document) {
      let url = await library.recentThumbnailURL(for: document)
      guard !Task.isCancelled else { return }
      image = url.flatMap { UIImage(contentsOfFile: $0.path) }
    }
  }
}
