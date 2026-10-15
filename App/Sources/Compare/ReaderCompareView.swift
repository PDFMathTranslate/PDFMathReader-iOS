import PDFKit
import ReaderCore
import SwiftUI
import UIKit

struct ReaderCompareView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @ObservedObject var coordinator: ReaderTranslationCoordinator
  let document: PDFDocument
  @Binding var currentPage: Int
  private let onShowOverlay: (() -> Void)?

  init(
    document: PDFDocument,
    coordinator: ReaderTranslationCoordinator,
    currentPage: Binding<Int> = .constant(1),
    onShowOverlay: (() -> Void)? = nil
  ) {
    self.document = document
    self.coordinator = coordinator
    _currentPage = currentPage
    self.onShowOverlay = onShowOverlay
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        ReaderCompareRegularView(
          document: document,
          coordinator: coordinator,
          currentPage: $currentPage,
          snapshot: coordinator.exportSnapshot(),
          revision: coordinator.translationRevision
        )
      } else {
        compactFallback
      }
    }
    .navigationTitle("Compare translations")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var compactFallback: some View {
    ContentUnavailableView {
      Label("Compare is available on iPad", systemImage: "rectangle.split.2x1")
    } description: {
      Text("Use the translation overlay on this screen, or open the document on an iPad.")
    } actions: {
      Button("Show translation overlay") {
        if let onShowOverlay {
          onShowOverlay()
        } else {
          coordinator.toggleTranslations()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }
}

private struct ReaderCompareRegularView: View {
  let document: PDFDocument
  @ObservedObject var coordinator: ReaderTranslationCoordinator
  @Binding var currentPage: Int
  let snapshot: ReaderTranslationExportSnapshot
  let revision: Int

  @State private var lastDetectedPage = 0
  @State private var didScrollToInitialPage = false

  private let horizontalPadding: CGFloat = 24
  private let columnGap: CGFloat = 16
  private let rowGap: CGFloat = 18

  var body: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: rowGap) {
            ForEach(Array(0..<document.pageCount), id: \.self) { pageIndex in
              if let page = document.page(at: pageIndex) {
                let columnWidth = self.columnWidth(for: viewport.size.width)
                let pageHeight = pageHeight(for: page, width: columnWidth)
                HStack(alignment: .top, spacing: columnGap) {
                  ReaderComparePageSurface(
                    page: page,
                    blocks: blocks(at: pageIndex),
                    replacementData: replacementData(at: pageIndex),
                    width: columnWidth,
                    height: pageHeight
                  )
                  ReaderComparePageSurface(
                    page: page,
                    blocks: blocks(at: pageIndex),
                    replacementData: replacementData(at: pageIndex),
                    width: columnWidth,
                    height: pageHeight,
                    translated: true
                  )
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .id(pageIndex)
                .background {
                  GeometryReader { row in
                    Color.clear.preference(
                      key: ReaderComparePageOffsetKey.self,
                      value: [pageIndex: row.frame(in: .named("readerCompareScroll")).midY]
                    )
                  }
                }
                .overlay(alignment: .bottom) {
                  Text("Page \(pageIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 6)
                }
              }
            }
          }
          .padding(.horizontal, horizontalPadding)
          .padding(.vertical, horizontalPadding)
        }
        .coordinateSpace(name: "readerCompareScroll")
        .background(Color(uiColor: .secondarySystemBackground))
        .onAppear {
          guard !didScrollToInitialPage else { return }
          didScrollToInitialPage = true
          let target = max(0, min(document.pageCount - 1, currentPage - 1))
          proxy.scrollTo(target, anchor: .top)
        }
        .onChange(of: currentPage) { _, value in
          guard document.pageCount > 0 else { return }
          let target = max(0, min(document.pageCount - 1, value - 1))
          guard target != lastDetectedPage else { return }
          proxy.scrollTo(target, anchor: .top)
        }
        .onPreferenceChange(ReaderComparePageOffsetKey.self) { offsets in
          guard !offsets.isEmpty else { return }
          let center = viewport.size.height / 2
          guard let nearest = offsets.min(by: {
            abs($0.value - center) < abs($1.value - center)
          })?.key else { return }
          lastDetectedPage = nearest
          if currentPage != nearest + 1 {
            currentPage = nearest + 1
          }
        }
      }
    }
    .overlay(alignment: .top) {
      HStack(spacing: 0) {
        Text("Original")
        Spacer()
        Text("Translated")
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, 10)
      .background(.bar)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Original and translated pages")
  }

  private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
    max(120, min(920, (availableWidth - horizontalPadding * 2 - columnGap) / 2))
  }

  private func pageHeight(for page: PDFPage, width: CGFloat) -> CGFloat {
    let bounds = page.bounds(for: .cropBox)
    guard bounds.width > 0 else { return width * 1.4 }
    return width * bounds.height / bounds.width
  }

  private func blocks(at pageIndex: Int) -> [ExportParagraphBlock] {
    guard snapshot.paragraphsByPage.indices.contains(pageIndex) else { return [] }
    return snapshot.paragraphsByPage[pageIndex]
  }

  private func replacementData(at pageIndex: Int) -> Data? {
    guard snapshot.replacementPDFDataByPage.indices.contains(pageIndex) else { return nil }
    return snapshot.replacementPDFDataByPage[pageIndex]
  }
}

private struct ReaderComparePageSurface: View {
  let page: PDFPage
  let blocks: [ExportParagraphBlock]
  let replacementData: Data?
  let width: CGFloat
  let height: CGFloat
  var translated = false

  var body: some View {
    ZStack(alignment: .topLeading) {
      pageImage(page, size: CGSize(width: width, height: height))

      if translated, let replacementPage {
        pageImage(replacementPage, size: CGSize(width: width, height: height))
      } else if translated {
        paragraphOverlay
      }
    }
    .frame(width: width, height: height)
    .background(Color(uiColor: .systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
    .accessibilityLabel(translated ? "Translated page" : "Original page")
  }

  private var replacementPage: PDFPage? {
    guard let replacementData else { return nil }
    return PDFDocument(data: replacementData)?.page(at: 0)
  }

  @ViewBuilder
  private var paragraphOverlay: some View {
    let pageBounds = page.bounds(for: .cropBox)
    let scale = pageBounds.width > 0 ? width / pageBounds.width : 1
    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
      let blockWidth = max(1, CGFloat(block.width) * scale)
      let blockHeight = max(CGFloat(block.height), CGFloat(block.fontSize) * 1.1) * scale
      Text(block.translation)
        .font(.system(
          size: max(6, min(36, CGFloat(block.fontSize) * scale)),
          weight: block.bold ? .semibold : .regular
        ))
        .multilineTextAlignment(textAlignment(block.textAlign))
        .lineSpacing(1)
        .lineLimit(nil)
        .minimumScaleFactor(0.45)
        .allowsTightening(true)
        .padding(max(1.5, CGFloat(block.fontSize) * scale * 0.28))
        .frame(width: blockWidth, height: blockHeight, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground).opacity(0.98))
        .position(
          x: (CGFloat(block.x) + CGFloat(block.width) / 2) * scale,
          y: (CGFloat(block.y) + max(CGFloat(block.height), CGFloat(block.fontSize) * 1.1) / 2) * scale
        )
    }
  }

  private func pageImage(_ page: PDFPage, size: CGSize) -> some View {
    Image(uiImage: page.thumbnail(of: size, for: .cropBox))
      .resizable()
      .interpolation(.high)
      .scaledToFill()
      .frame(width: width, height: height)
  }

  private func textAlignment(_ value: String?) -> TextAlignment {
    switch value {
    case "center": .center
    case "right": .trailing
    default: .leading
    }
  }
}

private struct ReaderComparePageOffsetKey: PreferenceKey {
  static let defaultValue: [Int: CGFloat] = [:]

  static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}
