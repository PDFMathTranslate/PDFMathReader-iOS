import PDFKit
import ReaderCore
import SwiftUI

struct ReaderAnnotationsSidebar: View {
  @ObservedObject var model: ReaderAnnotationViewModel
  @ObservedObject var pdfViewReference: PDFViewReference
  let onJump: (Int) -> Void
  @State private var editing: ReaderAnnotation?

  var body: some View {
    Group {
      if model.annotations.isEmpty {
        ContentUnavailableView(
          "No annotations",
          systemImage: "highlighter",
          description: Text("Select text to highlight it or add a comment.")
        )
      } else {
        List {
          ForEach(model.annotations) { annotation in
            Button {
              onJump(annotation.page)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Circle()
                    .fill(Color(uiColor: UIColor(hex: annotation.color)))
                    .frame(width: 9, height: 9)
                  Text(annotation.kind == .highlight ? "Highlight" : "Comment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Spacer(minLength: 4)
                  Text("p. \(annotation.page)")
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
              Button("Edit Comment", systemImage: "pencil") {
                editing = annotation
              }
              .disabled(annotation.kind != .comment)
              Button("Delete", systemImage: "trash", role: .destructive) {
                model.delete(annotation, pdfView: pdfViewReference.view)
              }
            }
          }
        }
        .listStyle(.plain)
      }
    }
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
      Button("OK") { model.lastError = nil }
    } message: {
      Text(model.lastError ?? "")
    }
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
        TextField("Comment", text: $comment, axis: .vertical)
          .lineLimit(4...8)
      }
      .navigationTitle("Edit Comment")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { onSave(comment) }
            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}

private extension UIColor {
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
