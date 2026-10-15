import Combine
import Foundation
import PDFKit
import ReaderCore
import UIKit

@MainActor
final class ReaderAnnotationViewModel: ObservableObject {
  let session: DocumentSession
  let store: ReaderAnnotationStore
  let quickLinkStore: ReaderQuickLinkStore

  @Published private(set) var annotations: [ReaderAnnotation] = []
  @Published private(set) var quickLinks: [ReaderQuickLink] = []
  @Published var lastError: String?

  private var nativeRefs: [String] = []
  private var sourceData: Data?

  init(
    session: DocumentSession,
    store: ReaderAnnotationStore = ReaderAnnotationStore(),
    quickLinkStore: ReaderQuickLinkStore = ReaderQuickLinkStore()
  ) {
    self.session = session
    self.store = store
    self.quickLinkStore = quickLinkStore
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
    quickLinks = (try? quickLinkStore.load(session.id)) ?? []
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

  func quickLinkOrigin(
    from selection: PDFSelection,
    in pdfView: PDFView
  ) -> ReaderQuickLinkEndpoint? {
    guard let document = pdfView.document, let page = selection.pages.first else { return nil }
    let pageIndex = document.index(for: page)
    guard pageIndex != NSNotFound else { return nil }
    let rects = ReaderAnnotationPDF.viewportRects(for: selection, on: page)
    guard let first = rects.first else { return nil }
    let bounds = rects.dropFirst().reduce(
      CGRect(x: CGFloat(first.x), y: CGFloat(first.y), width: CGFloat(first.width), height: CGFloat(first.height))
    ) { result, rect in
      result.union(
        CGRect(
          x: CGFloat(rect.x),
          y: CGFloat(rect.y),
          width: CGFloat(rect.width),
          height: CGFloat(rect.height)
        )
      )
    }
    return ReaderQuickLinkEndpoint(
      page: pageIndex + 1,
      box: ReaderQuickLinkBox(
        x: Double(bounds.minX),
        y: Double(bounds.minY),
        width: Double(bounds.width),
        height: Double(bounds.height)
      )
    )
  }

  @discardableResult
  func createQuickLink(
    origin: ReaderQuickLinkEndpoint,
    result: ReaderQuickLinkEndpoint
  ) -> Bool {
    let link = ReaderQuickLink(id: UUID().uuidString, origin: origin, result: result)
    guard !quickLinks.contains(where: { $0.origin == origin && $0.result == result }) else {
      lastError = L10n.string("ios.quickLinkAlreadyExists")
      return false
    }
    let updated = quickLinks + [link]
    do {
      try quickLinkStore.save(updated, for: session.id)
      quickLinks = updated
      lastError = nil
      return true
    } catch {
      lastError = L10n.string("ios.quickLinkSaveFailed")
      return false
    }
  }

  func deleteQuickLink(_ link: ReaderQuickLink) {
    let updated = quickLinks.filter { $0.id != link.id }
    do {
      try quickLinkStore.save(updated, for: session.id)
      quickLinks = updated
      lastError = nil
    } catch {
      lastError = L10n.string("ios.quickLinkDeleteFailed")
    }
  }

  func followQuickLink(
    _ link: ReaderQuickLink,
    side: ReaderQuickLinkSide,
    in pdfView: PDFView?
  ) {
    let destination = side.destination(in: link)
    guard let document = pdfView?.document,
      let page = document.page(at: max(0, destination.page - 1))
    else { return }
    let point = ReaderAnnotationPDF.pdfPoint(for: destination.box, on: page)
    pdfView?.go(to: PDFDestination(page: page, at: point))
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
      lastError = L10n.string("ios.annotationSaveFailed")
    }
  }
}

enum ReaderQuickLinkSide {
  case origin
  case result

  func destination(in link: ReaderQuickLink) -> ReaderQuickLinkEndpoint {
    switch self {
    case .origin: link.result
    case .result: link.origin
    }
  }
}

@MainActor
func presentReaderQuickLinkTargetPrompt(
  model: ReaderAnnotationViewModel,
  pdfView: PDFView,
  origin: ReaderQuickLinkEndpoint
) {
  let document = pdfView.document
  let currentPage = pdfView.currentPage.flatMap { page in
    guard let document else { return nil }
    let index = document.index(for: page)
    return index == NSNotFound ? nil : index + 1
  } ?? origin.page
  let alert = UIAlertController(
    title: L10n.string("ios.createQuickLink"),
    message: L10n.string("ios.quickLinkDestinationMessage"),
    preferredStyle: .alert
  )
  alert.addTextField { field in
    field.placeholder = L10n.string("ios.page")
    field.text = "\(currentPage)"
    field.keyboardType = .numberPad
  }
  alert.addTextField { field in
    field.placeholder = L10n.string("ios.x")
    field.text = "0"
    field.keyboardType = .decimalPad
  }
  alert.addTextField { field in
    field.placeholder = L10n.string("ios.y")
    field.text = "0"
    field.keyboardType = .decimalPad
  }
  alert.addAction(UIAlertAction(title: L10n.string("ios.cancel"), style: .cancel))
  alert.addAction(UIAlertAction(title: L10n.string("ios.create"), style: .default) { [weak model, weak pdfView, weak alert] _ in
    guard let model, let pdfView, let fields = alert?.textFields,
      let page = Int(fields[0].text ?? ""),
      let x = Double(fields[1].text ?? ""),
      let y = Double(fields[2].text ?? ""),
      let pageCount = pdfView.document?.pageCount,
      page >= 1,
      page <= pageCount,
      x.isFinite, y.isFinite, x >= 0, y >= 0
    else {
      model?.lastError = L10n.string("ios.enterValidQuickLinkTarget")
      return
    }
    let result = ReaderQuickLinkEndpoint(
      page: page,
      box: ReaderQuickLinkBox(x: x, y: y, width: 1, height: 1)
    )
    if model.createQuickLink(origin: origin, result: result) {
      pdfView.clearSelection()
    }
  })
  readerTopViewController(for: pdfView)?.present(alert, animated: true)
}

@MainActor
private func readerTopViewController(for view: UIView) -> UIViewController? {
  var responder: UIResponder? = view
  while let current = responder {
    if let controller = current as? UIViewController { return controller }
    responder = current.next
  }
  return view.window?.rootViewController
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
    UIMenuSystem.main.setNeedsRebuild()
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
      action == #selector(addComment(_:)) ||
      action == #selector(createQuickLink(_:))
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

  @objc func createQuickLink(_ sender: Any?) {
    guard let view = pdfView,
      let selection = view.currentSelection,
      let origin = model.quickLinkOrigin(from: selection, in: view)
    else { return }
    presentReaderQuickLinkTargetPrompt(model: model, pdfView: view, origin: origin)
  }

  @objc func addComment(_ sender: Any?) {
    guard let view = pdfView, let selection = view.currentSelection else { return }
    let alert = UIAlertController(
      title: L10n.string("ios.addComment"),
      message: nil,
      preferredStyle: .alert
    )
    alert.addTextField { field in
      field.placeholder = L10n.string("sidebar.comment")
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: L10n.string("ios.cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L10n.string("ios.add"), style: .default) { [weak self, weak view, weak alert] _ in
      guard let self, let view, let comment = alert?.textFields?.first?.text,
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      self.model.addSelection(selection, in: view, color: "#ffb347", comment: comment)
      view.clearSelection()
    })
    readerTopViewController(for: view)?.present(alert, animated: true)
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
    UIMenuSystem.main.setNeedsRebuild()
  }

  func menuCommands() -> [UIMenuElement] {
    let actions: [(String, Selector)] = [
      (L10n.string("ios.highlightYellow"), #selector(highlightYellow(_:))),
      (L10n.string("ios.highlightPink"), #selector(highlightPink(_:))),
      (L10n.string("ios.highlightBlue"), #selector(highlightBlue(_:))),
      (L10n.string("ios.highlightGreen"), #selector(highlightGreen(_:))),
      (L10n.string("ios.addComment"), #selector(addComment(_:))),
      (L10n.string("ios.createQuickLink"), #selector(createQuickLink(_:))),
    ]
    var commands = actions.compactMap { title, action -> UIMenuElement? in
      canPerform(action) ? UICommand(title: title, action: action) : nil
    }
    if canPerform(#selector(copyEmail(_:))) {
      commands.append(
        UICommand(
          title: L10n.string("menu.extra.messages.Copy Email"),
          action: #selector(copyEmail(_:))
        )
      )
    }
    return commands
  }

  private func email(in text: String) -> String? {
    let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map {
      String(text[$0])
    }
  }

}

@MainActor
final class ReaderAnnotationPDFView: PDFView {
  weak var annotationController: ReaderAnnotationInteractionController?

  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    guard let commands = annotationController?.menuCommands(), !commands.isEmpty else { return }
    let menu = UIMenu(
      title: L10n.string("ios.annotate"),
      identifier: UIMenu.Identifier("com.pdfmathreader.annotate"),
      options: .displayInline,
      children: commands
    )
    builder.insertChild(menu, atStartOfMenu: .text)
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if annotationController?.canPerform(action) == true { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
    if annotationController?.canPerform(action) == true { return annotationController }
    return super.target(forAction: action, withSender: sender)
  }
}
