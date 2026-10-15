import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

@MainActor
final class ReaderAnnotationViewModel: ObservableObject {
  let session: DocumentSession
  let store: ReaderAnnotationStore

  @Published private(set) var annotations: [ReaderAnnotation] = []
  @Published var lastError: String?

  private var nativeRefs: [String] = []
  private var sourceData: Data?

  init(
    session: DocumentSession,
    store: ReaderAnnotationStore = ReaderAnnotationStore()
  ) {
    self.session = session
    self.store = store
    sourceData = try? Data(contentsOf: session.url, options: [.mappedIfSafe])
    if let sourceData,
      let state = try? store.loadOrImport(session.id, sourceData: sourceData)
    {
      annotations = state.annotations
      nativeRefs = state.nativeRefs
    } else if let state = try? store.load(session.id) {
      annotations = state.annotations
      nativeRefs = state.nativeRefs
    }
  }

  func loadIfNeeded(from pdfView: PDFView) {
    guard (try? store.hasMetadata(for: session.id)) != true,
      let data = pdfView.document?.dataRepresentation(),
      let imported = try? ReaderAnnotationPDF.importAnnotations(from: data)
    else { return }
    sourceData = data
    annotations = imported.annotations
    nativeRefs = imported.nativeRefs
  }

  func addSelection(
    _ selection: PDFSelection,
    in pdfView: PDFView,
    color: String,
    comment: String = ""
  ) {
    let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let pages = selection.pages
    let newAnnotations = pages.compactMap { page -> ReaderAnnotation? in
      let pageIndex = pdfView.document?.index(for: page) ?? NSNotFound
      guard pageIndex != NSNotFound else { return nil }
      let rects = ReaderAnnotationPDF.viewportRects(for: selection, on: page)
      guard !rects.isEmpty else { return nil }
      return ReaderAnnotation(
        id: UUID().uuidString,
        page: pageIndex + 1,
        kind: comment.isEmpty ? .highlight : .comment,
        origin: .source,
        text: text,
        comment: comment,
        color: color,
        rects: rects,
        createdAt: createdAt,
        sourceRect: rects.first
      )
    }
    guard !newAnnotations.isEmpty else { return }
    annotations.append(contentsOf: newAnnotations)
    commit(to: pdfView)
  }

  func delete(_ annotation: ReaderAnnotation, pdfView: PDFView?) {
    annotations.removeAll { $0.id == annotation.id }
    commit(to: pdfView)
  }

  func updateComment(
    for annotation: ReaderAnnotation,
    comment: String,
    pdfView: PDFView?
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
    annotations[index].comment = comment
    annotations[index].modifiedAt = ISO8601DateFormatter().string(from: Date())
    commit(to: pdfView)
  }

  private func commit(to pdfView: PDFView?) {
    do {
      let input = pdfView?.document?.dataRepresentation() ?? sourceData
      let output = try ReaderAnnotationPDF.embedAnnotations(
        annotations,
        in: input ?? Data(),
        nativeRefs: nativeRefs
      )
      sourceData = output
      pdfView?.document = PDFDocument(data: output)
      _ = try store.save(
        annotations,
        nativeRefs: nativeRefs,
        for: session.id,
        sourceURL: session.url,
        sourceData: output
      )
      lastError = nil
    } catch {
      lastError = "The annotation could not be saved."
    }
  }
}

@MainActor
final class ReaderAnnotationInteractionController: NSObject {
  weak var pdfView: PDFView?
  let model: ReaderAnnotationViewModel

  init(model: ReaderAnnotationViewModel, pdfView: PDFView) {
    self.model = model
    self.pdfView = pdfView
    super.init()
    model.loadIfNeeded(from: pdfView)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(selectionChanged(_:)),
      name: Notification.Name.PDFViewSelectionChanged,
      object: pdfView
    )
    updateMenu()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func canPerform(_ action: Selector) -> Bool {
    guard let selection = pdfView?.currentSelection,
      !(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    else { return false }
    if action == #selector(highlightYellow(_:)) ||
      action == #selector(highlightPink(_:)) ||
      action == #selector(highlightBlue(_:)) ||
      action == #selector(highlightGreen(_:)) ||
      action == #selector(addComment(_:))
    { return true }
    if action == #selector(copyEmail(_:)) {
      return email(in: selection.string ?? "") != nil
    }
    return false
  }

  @objc func highlightYellow(_ sender: Any?) { highlight(color: "#fff36a") }
  @objc func highlightPink(_ sender: Any?) { highlight(color: "#ffb6c1") }
  @objc func highlightBlue(_ sender: Any?) { highlight(color: "#9bd7ff") }
  @objc func highlightGreen(_ sender: Any?) { highlight(color: "#b8e986") }

  @objc func addComment(_ sender: Any?) {
    guard let view = pdfView, let selection = view.currentSelection else { return }
    let alert = UIAlertController(title: "Add Comment", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Comment"
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak view, weak alert] _ in
      guard let self, let view, let comment = alert?.textFields?.first?.text,
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      self.model.addSelection(selection, in: view, color: "#ffb347", comment: comment)
      view.clearSelection()
    })
    topViewController(for: view)?.present(alert, animated: true)
  }

  @objc func copyEmail(_ sender: Any?) {
    guard let selection = pdfView?.currentSelection,
      let value = email(in: selection.string ?? "")
    else { return }
    UIPasteboard.general.string = value
  }

  private func highlight(color: String) {
    guard let view = pdfView, let selection = view.currentSelection else { return }
    model.addSelection(selection, in: view, color: color)
    view.clearSelection()
  }

  @objc private func selectionChanged(_ notification: Notification) {
    updateMenu()
  }

  private func updateMenu() {
    guard let view = pdfView else { return }
    var items = [
      UIMenuItem(title: "Highlight Yellow", action: #selector(highlightYellow(_:))),
      UIMenuItem(title: "Highlight Pink", action: #selector(highlightPink(_:))),
      UIMenuItem(title: "Highlight Blue", action: #selector(highlightBlue(_:))),
      UIMenuItem(title: "Highlight Green", action: #selector(highlightGreen(_:))),
      UIMenuItem(title: "Add Comment", action: #selector(addComment(_:))),
    ]
    if canPerform(#selector(copyEmail(_:))) {
      items.append(UIMenuItem(title: "Copy Email", action: #selector(copyEmail(_:))))
    }
    UIMenuController.shared.menuItems = items
    if view.isFirstResponder { UIMenuController.shared.update() }
  }

  private func email(in text: String) -> String? {
    let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map {
      String(text[$0])
    }
  }

  private func topViewController(for view: UIView) -> UIViewController? {
    var responder: UIResponder? = view
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return view.window?.rootViewController
  }
}

@MainActor
final class ReaderAnnotationPDFView: PDFView {
  weak var annotationController: ReaderAnnotationInteractionController?

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if annotationController?.canPerform(action) == true { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
    if annotationController?.canPerform(action) == true { return annotationController }
    return super.target(forAction: action, withSender: sender)
  }
}
