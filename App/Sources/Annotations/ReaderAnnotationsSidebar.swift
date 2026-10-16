import PDFKit
import PencilKit
import ReaderCore
import SwiftUI

struct ReaderAnnotationsSidebar: View {
  @ObservedObject var model: ReaderAnnotationViewModel
  @ObservedObject var drawings: ReaderDrawingModel
  @ObservedObject var pdfViewReference: PDFViewReference
  let onJump: (Int) -> Void
  @State private var editing: ReaderAnnotation?

  var body: some View {
    List {
      Section {
        Button {
          guard let view = pdfViewReference.view,
            let selection = view.currentSelection,
            let origin = model.quickLinkOrigin(from: selection, in: view)
          else {
            model.lastError = L10n.string("ios.selectTextQuickLink")
            return
          }
          presentReaderQuickLinkTargetPrompt(model: model, pdfView: view, origin: origin)
        } label: {
          Label(L10n.string("ios.createQuickLink"), systemImage: "link.badge.plus")
        }
      }

      Section(L10n.string("sidebar.annotations")) {
        if model.annotations.isEmpty && drawings.annotatedPages.isEmpty {
          Text(L10n.string("ios.annotationEmpty"))
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.annotations) { annotation in
            Button {
              onJump(annotation.page)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Circle()
                    .fill(Color(uiColor: UIColor(hex: annotation.color)))
                    .frame(width: 9, height: 9)
                  Text(
                    annotation.kind == .highlight
                      ? L10n.string("sidebar.highlight")
                      : L10n.string("sidebar.comment")
                  )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Spacer(minLength: 4)
                  Text(L10n.string("sidebar.page", String(annotation.page)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Text(annotation.kind == .comment ? annotation.comment : annotation.text)
                  .lineLimit(3)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button(
                L10n.string(annotation.kind == .comment ? "ios.editComment" : "ios.addComment"),
                systemImage: annotation.kind == .comment ? "pencil" : "text.bubble"
              ) {
                editing = annotation
              }
              Menu(L10n.string("annotationBrowser.color"), systemImage: "paintpalette") {
                Button(L10n.string("ios.highlightYellow")) {
                  model.updateColor(
                    for: annotation,
                    color: "#fff36a",
                    pdfView: pdfViewReference.view
                  )
                }
                Button(L10n.string("ios.highlightPink")) {
                  model.updateColor(
                    for: annotation,
                    color: "#ffb6c1",
                    pdfView: pdfViewReference.view
                  )
                }
                Button(L10n.string("ios.highlightBlue")) {
                  model.updateColor(
                    for: annotation,
                    color: "#9bd7ff",
                    pdfView: pdfViewReference.view
                  )
                }
                Button(L10n.string("ios.highlightGreen")) {
                  model.updateColor(
                    for: annotation,
                    color: "#b8e986",
                    pdfView: pdfViewReference.view
                  )
                }
              }
              let text = annotation.text.isEmpty ? annotation.comment : annotation.text
              if !text.isEmpty {
                Button(L10n.string("menu.extra.messages.Copy"), systemImage: "doc.on.doc") {
                  UIPasteboard.general.string = text
                }
              }
              Button(L10n.string("ios.delete"), systemImage: "trash", role: .destructive) {
                model.delete(annotation, pdfView: pdfViewReference.view)
              }
            }
          }
        }
        ForEach(drawings.annotatedPages, id: \.self) { pageIndex in
          if let drawing = drawings.drawings[pageIndex] {
            Button {
              onJump(pageIndex + 1)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Label(L10n.string("ios.drawing"), systemImage: "pencil.tip")
                  Spacer(minLength: 4)
                  Text(L10n.string("sidebar.page", String(pageIndex + 1)))
                    .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                DrawingAnnotationPreview(drawing: drawing)
              }
              .padding(.vertical, 3)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.drawingAnnotation.\(pageIndex + 1)")
            .contextMenu {
              Button(L10n.string("ios.delete"), systemImage: "trash", role: .destructive) {
                drawings.deleteDrawing(on: pageIndex)
              }
            }
          }
        }
      }

      Section(L10n.string("ios.quickLinks")) {
        if model.quickLinks.isEmpty {
          Text(L10n.string("ios.quickLinkEmpty"))
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.quickLinks) { link in
            HStack(spacing: 8) {
              Button {
                onJump(link.result.page)
                // The model maps the stored source box into the compacted
                // display page before applying the precise destination.
                model.followQuickLink(link, side: .origin, in: pdfViewReference.view)
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Label(
                    L10n.string("ios.fromPage", String(link.origin.page)),
                    systemImage: "arrow.up.right"
                  )
                  Text(quickLinkLocation(link.origin.box))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .buttonStyle(.plain)

              Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

              Button {
                onJump(link.origin.page)
                // The model maps the stored source box into the compacted
                // display page before applying the precise destination.
                model.followQuickLink(link, side: .result, in: pdfViewReference.view)
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Label(
                    L10n.string("ios.toPage", String(link.result.page)),
                    systemImage: "arrow.down.left"
                  )
                  Text(quickLinkLocation(link.result.box))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .buttonStyle(.plain)
            }
            .contextMenu {
              Button(L10n.string("ios.delete"), systemImage: "trash", role: .destructive) {
                model.deleteQuickLink(link)
              }
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .sheet(item: $editing) { annotation in
      AnnotationCommentEditor(
        annotation: annotation,
        onSave: { comment in
          model.updateComment(
            for: annotation,
            comment: comment,
            pdfView: pdfViewReference.view
          )
          editing = nil
        },
        onCancel: { editing = nil }
      )
      .presentationDetents([.height(220)])
    }
    .alert(
      "PDFMathReader",
      isPresented: Binding(
        get: { model.lastError != nil },
        set: { if !$0 { model.lastError = nil } }
      )
    ) {
      Button(L10n.string("ios.ok")) { model.lastError = nil }
    } message: {
      Text(model.lastError ?? "")
    }
  }

  private func quickLinkLocation(_ box: ReaderQuickLinkBox) -> String {
    L10n.string(
      "ios.quickLinkLocation",
      box.x.formatted(.number.precision(.fractionLength(0...1))),
      box.y.formatted(.number.precision(.fractionLength(0...1)))
    )
  }
}

private struct DrawingAnnotationPreview: View {
  let drawing: PKDrawing

  var body: some View {
    let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
    // Bound raster size even for large PDF pages, preserving the stroke colors.
    let scale = min(2, 480 / max(bounds.width, bounds.height, 1))
    Image(uiImage: drawing.image(from: bounds, scale: scale))
      .resizable()
      .scaledToFit()
      .frame(maxWidth: .infinity, maxHeight: 100, alignment: .leading)
      .padding(6)
      .background(.white, in: RoundedRectangle(cornerRadius: 6))
      .accessibilityHidden(true)
  }
}

private struct AnnotationCommentEditor: View {
  let annotation: ReaderAnnotation
  let onSave: (String) -> Void
  let onCancel: () -> Void
  @State private var comment: String

  init(annotation: ReaderAnnotation, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.annotation = annotation
    self.onSave = onSave
    self.onCancel = onCancel
    _comment = State(initialValue: annotation.comment)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(L10n.string("sidebar.comment"), text: $comment, axis: .vertical)
          .lineLimit(4...8)
      }
      .navigationTitle(
        L10n.string(annotation.kind == .comment ? "ios.editComment" : "ios.addComment")
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.string("ios.cancel"), action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.string("ios.save")) { onSave(comment) }
        }
      }
    }
  }
}

extension UIColor {
  convenience init(hex: String) {
    let digits = Array(hex.dropFirst().prefix(6))
    guard digits.count == 6,
      let red = UInt8(String(digits[0...1]), radix: 16),
      let green = UInt8(String(digits[2...3]), radix: 16),
      let blue = UInt8(String(digits[4...5]), radix: 16)
    else {
      self.init(red: 1, green: 0.95, blue: 0.42, alpha: 1)
      return
    }
    self.init(
      red: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    )
  }
}
