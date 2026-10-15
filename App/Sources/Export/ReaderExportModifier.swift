import Foundation
import PDFKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

private enum ReaderExportKind {
  case original
  case translated

  var title: String {
    switch self {
    case .original: L10n.string("ios.exportOriginalPDF")
    case .translated: L10n.string("ios.exportTranslatedPDF")
    }
  }
}

private struct PreparedReaderExport: Identifiable {
  let id = UUID()
  let url: URL
  let fileName: String
  let title: String
}

private enum ReaderExportError: Error, LocalizedError {
  case invalidDocument

  var errorDescription: String? {
    switch self {
    case .invalidDocument:
      L10n.string("ios.exportSerializationFailed")
    }
  }
}

@MainActor
struct ReaderExportModifier: ViewModifier {
  let document: PDFDocument
  let originalName: String
  let annotations: [ReaderAnnotation]
  let coordinator: ReaderTranslationCoordinator?

  @State private var isExporting = false
  @State private var progress = 0.0
  @State private var preparedExport: PreparedReaderExport?
  @State private var fileDocument = ExportPDFFileDocument()
  @State private var fileName = L10n.string("ios.documentFilename")
  @State private var isFileExporterPresented = false
  @State private var errorMessage: String?

  init(
    document: PDFDocument,
    originalName: String,
    annotations: [ReaderAnnotation] = [],
    coordinator: ReaderTranslationCoordinator? = nil
  ) {
    self.document = document
    self.originalName = originalName
    self.annotations = annotations
    self.coordinator = coordinator
  }

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if isExporting {
            ProgressView(value: progress)
              .frame(width: 76)
              .accessibilityLabel(L10n.string("ios.exportingPDF"))
          } else {
            Menu {
              Button(ReaderExportKind.original.title, systemImage: "doc") {
                beginExport(.original)
              }
              Button(ReaderExportKind.translated.title, systemImage: "character.book.closed") {
                beginExport(.translated)
              }
            } label: {
              Label(L10n.string("ios.export"), systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(L10n.string("ios.exportPDF"))
          }
        }
      }
      .sheet(item: $preparedExport) { export in
        PreparedReaderExportView(
          export: export,
          onSaveToFiles: {
            fileDocument = ExportPDFFileDocument(data: (try? Data(contentsOf: export.url)) ?? Data())
            fileName = export.fileName
            isFileExporterPresented = true
          }
        )
      }
      .fileExporter(
        isPresented: $isFileExporterPresented,
        document: fileDocument,
        contentType: .pdf,
        defaultFilename: fileName
      ) { result in
        if case .failure(let error) = result {
          errorMessage = error.localizedDescription
        }
      }
      .alert(L10n.string("ios.exportFailed"), isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button(L10n.string("ios.ok")) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
  }

  private func beginExport(_ kind: ReaderExportKind) {
    guard !isExporting else { return }
    isExporting = true
    progress = 0.08
    Task { @MainActor in
      defer {
        isExporting = false
        progress = 0
      }
      do {
        let data: Data
        let outputName: String
        switch kind {
        case .original:
          progress = 0.35
          data = try originalPDFData()
          outputName = Self.originalFileName(for: originalName)
        case .translated:
          progress = 0.25
          data = try translatedPDFData()
          progress = 0.82
          outputName = ShareableDocument.translatedFileName(for: originalName)
        }

        let url = try Self.writeTemporaryFile(data: data, fileName: outputName)
        progress = 1
        preparedExport = PreparedReaderExport(
          url: url,
          fileName: outputName,
          title: kind.title
        )
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func originalPDFData() throws -> Data {
    guard let data = document.dataRepresentation(), !data.isEmpty else {
      throw ReaderExportError.invalidDocument
    }
    guard !annotations.isEmpty else { return data }
    return try ReaderAnnotationPDF.embedAnnotations(annotations, in: data)
  }

  private func translatedPDFData() throws -> Data {
    let sourceData = try originalPDFData()
    let snapshot = coordinator?.exportSnapshot()
    return try TranslatedPDFExporter().export(
      originalPDFData: sourceData,
      paragraphsByPage: snapshot?.paragraphsByPage ?? [],
      replacementPDFDataByPage: snapshot?.replacementPDFDataByPage ?? []
    )
  }

  private static func writeTemporaryFile(data: Data, fileName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-Export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(fileName)
    try data.write(to: url, options: [.atomic])
    return url
  }

  private static func originalFileName(for name: String) -> String {
    let component = (name as NSString).lastPathComponent
    let stem = (component as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(stem.isEmpty ? L10n.string("ios.documentFilenameStem") : stem).pdf"
  }
}

private struct PreparedReaderExportView: View {
  let export: PreparedReaderExport
  let onSaveToFiles: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: "doc.richtext")
          .font(.system(size: 42, weight: .medium))
          .foregroundStyle(.tint)
        Text(export.fileName)
          .font(.headline)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)

        ShareLink(
          item: export.url,
          subject: Text(export.title),
          message: Text(export.fileName)
        ) {
          Label(L10n.string("ios.share"), systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button {
          onSaveToFiles()
          dismiss()
        } label: {
          Label(L10n.string("ios.saveToFiles"), systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
      .padding(28)
      .navigationTitle(export.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("search.done")) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
  }
}

extension View {
  func readerExport(
    document: PDFDocument,
    originalName: String,
    annotations: [ReaderAnnotation] = [],
    coordinator: ReaderTranslationCoordinator? = nil
  ) -> some View {
    modifier(
      ReaderExportModifier(
        document: document,
        originalName: originalName,
        annotations: annotations,
        coordinator: coordinator
      )
    )
  }
}
