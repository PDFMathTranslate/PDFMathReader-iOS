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
  @State private var selectedAnnotationID: String?

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
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }
      }

      Section(L10n.string("sidebar.annotations")) {
        if model.annotations.isEmpty && drawings.annotatedPages.isEmpty {
          Text(L10n.string("ios.annotationEmpty"))
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.annotations) { annotation in
            Button {
              selectedAnnotationID = annotation.id
              onJump(annotation.page)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                  Circle()
                    .fill(annotation.kind == .comment ? Color(uiColor: .systemGray) : Color(uiColor: UIColor(hex: annotation.color)))
                    .overlay { Circle().strokeBorder(.black.opacity(0.13), lineWidth: 0.5) }
                    .frame(width: 10, height: 10)
                  Text(verbatim: annotationMetadata(annotation))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                let excerpt = annotationExcerpt(annotation.text)
                if !excerpt.isEmpty {
                  Text(verbatim: excerpt)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !annotation.comment.isEmpty {
                  Text(verbatim: annotation.comment)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if excerpt.isEmpty && annotation.comment.isEmpty {
                  Text(L10n.string(annotation.kind == .comment ? "sidebar.comment" : "sidebar.highlight"))
                }
              }
              .font(.footnote)
              .padding(.vertical, 10)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(
              RoundedRectangle(cornerRadius: 14)
                .fill(.primary.opacity(selectedAnnotationID == annotation.id ? 0.1 : 0))
                .padding(.vertical, 2)
            )
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
              .padding(.vertical, 10)
              .frame(minHeight: 44)
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
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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

  private func annotationExcerpt(_ text: String) -> String {
    // Match desktop: join PDF line breaks, preserving literal bracket contents.
    text.components(separatedBy: CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}"))
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func annotationMetadata(_ annotation: ReaderAnnotation) -> String {
    let source = L10n.string(annotation.origin == .translation ? "sidebar.translation" : "sidebar.source")
    let page = L10n.string("sidebar.page", String(annotation.page))
    let timestamp = annotation.modifiedAt ?? (annotation.dateUnknown == true ? nil : annotation.createdAt)
    let date = timestamp.flatMap { value in
      ISO8601DateFormatter().date(from: value) ?? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
      }()
    }
    let dateLabel = date?.formatted(
      Date.FormatStyle().year().month(.twoDigits).day(.twoDigits).locale(L10n.locale)
    )
      ?? L10n.string("annotationBrowser.date.unknown")
    return "\(source) · \(page) · \(dateLabel)"
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
