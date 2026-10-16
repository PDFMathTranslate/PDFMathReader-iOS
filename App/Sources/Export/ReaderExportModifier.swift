import Foundation
import PDFKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ReaderExportKind {
  case airDrop
  case original
  case translated

  var title: String {
    switch self {
    case .airDrop: L10n.string("ios.airDropToComputer")
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
  let shareImmediately: Bool
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
  let sourceData: Data?
  let annotations: [ReaderAnnotation]
  let quickLinks: [ReaderQuickLink]
  let readingState: ReadingState
  let coordinator: ReaderTranslationCoordinator?
  let drawings: ReaderDrawingModel?
  /// Set by the reader's menu; consumed here.
  @Binding var request: ReaderExportKind?

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
    sourceData: Data? = nil,
    annotations: [ReaderAnnotation] = [],
    quickLinks: [ReaderQuickLink] = [],
    readingState: ReadingState = ReadingState(),
    coordinator: ReaderTranslationCoordinator? = nil,
    drawings: ReaderDrawingModel? = nil,
    request: Binding<ReaderExportKind?>
  ) {
    self.document = document
    self.originalName = originalName
    self.sourceData = sourceData
    self.annotations = annotations
    self.quickLinks = quickLinks
    self.readingState = readingState
    self.coordinator = coordinator
    self.drawings = drawings
    _request = request
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: request) { _, kind in
        guard let kind else { return }
        request = nil
        beginExport(kind)
      }
      .overlay(alignment: .top) {
        if isExporting {
          ProgressView(value: progress)
            .frame(width: 120)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .accessibilityLabel(L10n.string("ios.exportingPDF"))
        }
      }
      .sheet(item: $preparedExport) { export in
        if export.shareImmediately {
          ReaderSystemShareSheet(url: export.url)
        } else {
          PreparedReaderExportView(
            export: export,
            onSaveToFiles: {
              do {
                fileDocument = ExportPDFFileDocument(data: try Data(contentsOf: export.url))
                fileName = export.fileName
                isFileExporterPresented = true
              } catch {
                errorMessage = error.localizedDescription
              }
            }
          )
        }
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
        case .airDrop, .original:
          progress = 0.35
          data = try originalPDFData()
          outputName = Self.originalFileName(for: originalName)
        case .translated:
          progress = 0.25
          data = try translatedPDFData()
          progress = 0.82
          outputName = ShareableDocument.translatedFileName(for: originalName)
        }

        let annotatedData: Data
        if let drawings {
          annotatedData = try ReaderDrawingPDF.embed(drawings.exportDrawings(), in: data)
        } else {
          annotatedData = data
        }
        let url = try Self.writeTemporaryFile(data: annotatedData, fileName: outputName)
        progress = 1
        preparedExport = PreparedReaderExport(
          url: url,
          fileName: outputName,
          title: kind.title,
          shareImmediately: kind == .airDrop
        )
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func originalPDFData() throws -> Data {
    guard let data = sourceData ?? document.dataRepresentation(), !data.isEmpty else {
      throw ReaderExportError.invalidDocument
    }
    return try ReaderTransferPDF.export(
      sourceData: data,
      annotations: annotations,
      quickLinks: quickLinks,
      readingState: readingState
    )
  }

  private func translatedPDFData() throws -> Data {
    let sourceData = try originalPDFData()
    return try coordinator?.exportedPDFData(originalPDFData: sourceData) ?? sourceData
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
    sourceData: Data? = nil,
    annotations: [ReaderAnnotation] = [],
    quickLinks: [ReaderQuickLink] = [],
    readingState: ReadingState = ReadingState(),
    coordinator: ReaderTranslationCoordinator? = nil,
    drawings: ReaderDrawingModel? = nil,
    request: Binding<ReaderExportKind?>
  ) -> some View {
    modifier(
      ReaderExportModifier(
        document: document,
        originalName: originalName,
        sourceData: sourceData,
        annotations: annotations,
        quickLinks: quickLinks,
        readingState: readingState,
        coordinator: coordinator,
        drawings: drawings,
        request: request
      )
    )
  }
}

/// The system sheet owns AirDrop discovery, recipient selection, and transfer.
/// Sharing a file URL transfers the PDF bytes, never a sandbox-local path.
private struct ReaderSystemShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
