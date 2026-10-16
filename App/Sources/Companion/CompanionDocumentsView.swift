import ReaderCore
import SwiftUI

/// Lists complete PDF snapshots that are currently available from the paired
/// computer. Opening a row acquires the computer's exclusive document session;
/// the workspace releases and syncs that session when the reader closes.
struct CompanionDocumentsView: View {
  @EnvironmentObject private var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var manager: CompanionDocumentManager

  let onOpenDocument: (DocumentSession) -> Void

  @State private var isOpeningDocument = false

  var body: some View {
    Group {
      if manager.documents.isEmpty {
        if manager.isLoading {
          loadingState
        } else {
          emptyState
        }
      } else {
        documentList
      }
    }
    .navigationTitle(L10n.string("companion.documentsTitle"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await refresh() }
        } label: {
          if manager.isLoading {
            ProgressView()
              .controlSize(.small)
          } else {
            Label(L10n.string("companion.refresh"), systemImage: "arrow.clockwise")
          }
        }
        .disabled(manager.isLoading || isOpeningDocument)
        .accessibilityLabel(L10n.string("companion.refresh"))
        .accessibilityIdentifier("companion.refresh")
      }
    }
    .disabled(isOpeningDocument)
    .overlay {
      if isOpeningDocument {
        ProgressView(L10n.string("status.openingPDF"))
          .padding()
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .task {
      await refresh()
    }
    .refreshable {
      await refresh()
    }
    .modifier(ComputerDocumentToast(manager: manager))
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(L10n.string("companion.loading"))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(L10n.string("companion.noDocuments"), systemImage: "doc.on.doc")
    } description: {
      Text(L10n.string("companion.noDocumentsDescription"))
    } actions: {
      Button {
        Task { await refresh() }
      } label: {
        Label(L10n.string("companion.retry"), systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderedProminent)
      .disabled(manager.isLoading)
      .accessibilityIdentifier("companion.retry")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var documentList: some View {
    List {
      Section {
        Text(L10n.string("companion.documentsDescription"))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
      }

      Section(L10n.string("companion.documentsListTitle")) {
        ForEach(manager.documents) { document in
          CompanionDocumentRow(
            document: document,
            isBusy: isOpeningDocument || manager.busyDocumentIDs.contains(document.id)
          ) {
            open(document)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .accessibilityIdentifier("companion.documents")
  }

  @MainActor
  private func refresh() async {
    await manager.refresh(preferences: library.preferences)
  }

  @MainActor
  private func open(_ document: CompanionRecentDocument) {
    guard !isOpeningDocument else { return }
    isOpeningDocument = true
    Task { @MainActor in
      defer { isOpeningDocument = false }
      guard let session = await manager.open(document, library: library) else { return }
      dismiss()
      onOpenDocument(session)
    }
  }
}

private struct CompanionDocumentRow: View {
  let document: CompanionRecentDocument
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: "doc.richtext")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 36, height: 36)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

        VStack(alignment: .leading, spacing: 3) {
          Text(document.title)
            .font(.headline)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(L10n.string("ios.pagesCount", String(document.pageCount)))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)
        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .accessibilityLabel(Text("\(document.title), \(L10n.string("ios.pagesCount", String(document.pageCount)))"))
    .accessibilityHint(L10n.string("ios.openPDF"))
    .accessibilityIdentifier("companion.document.\(document.id)")
  }
}
