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
  @Published private(set) var isPrepared = false
  @Published var lastError: String?
  /// Per window, like the desktop: every opened document starts visible.
  @Published private(set) var showsAnnotations = true

  private var nativeRefs: [String] = []
  private var sourceData: Data?

  /// Source bytes stay immutable; exports embed the current annotation snapshot.
  var exportSourceData: Data? { sourceData }
  var exportNativeRefs: [String] { nativeRefs }

  private var saveTask: Task<Void, Never>?
  private var editRevision = 0

  /// Waits for the latest edit, including edits coalesced during a running save.
  func flushPendingSaves() async {
    await saveTask?.value
  }

  private struct PreparedStartup: Sendable {
    let sourceData: Data?
    let annotationState: ReaderAnnotationState
    let quickLinks: [ReaderQuickLink]
    let errorDescription: String?
  }

  private var preparationTask: Task<PreparedStartup, Never>?

  init(
    session: DocumentSession,
    store: ReaderAnnotationStore = ReaderAnnotationStore(),
    quickLinkStore: ReaderQuickLinkStore = ReaderQuickLinkStore()
  ) {
    self.session = session
    self.store = store
    self.quickLinkStore = quickLinkStore
  }

  /// Loads annotation sidecars and embedded transfer state away from the main
  /// actor. The display PDF can therefore render while this independent PDF
  /// document is being parsed.
  func prepare() async {
    if isPrepared { return }

    let task: Task<PreparedStartup, Never>
    if let preparationTask {
      task = preparationTask
    } else {
      let documentID = session.id
      let sourceURL = session.url
      let access = session.access
      let annotationStore = store
      let linkStore = quickLinkStore
      task = Task.detached(priority: .utility) {
        withExtendedLifetime(access) {
          Self.prepareStartup(
            documentID: documentID,
            sourceURL: sourceURL,
            annotationStore: annotationStore,
            linkStore: linkStore
          )
        }
      }
      preparationTask = task
    }

    let prepared = await task.value
    guard !isPrepared else { return }
    preparationTask = nil
    sourceData = prepared.sourceData
    annotations = prepared.annotationState.annotations
    nativeRefs = prepared.annotationState.nativeRefs
    quickLinks = prepared.quickLinks
    if let errorDescription = prepared.errorDescription {
      lastError = errorDescription
    }
    isPrepared = true
  }

  private nonisolated static func prepareStartup(
    documentID: String,
    sourceURL: URL,
    annotationStore: ReaderAnnotationStore,
    linkStore: ReaderQuickLinkStore
  ) -> PreparedStartup {
    let sourceData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    let annotationState: ReaderAnnotationState
    if let sourceData,
      let imported = try? annotationStore.loadOrImport(documentID, sourceData: sourceData)
    {
      annotationState = imported
    } else {
      annotationState = (try? annotationStore.load(documentID))
        ?? ReaderAnnotationState(annotations: [])
    }

    var quickLinks: [ReaderQuickLink] = []
    var errorDescription: String?
    do {
      // Local sidecars are authoritative after the recipient edits the PDF,
      // including an intentionally empty list after deleting every link.
      let localURL = try linkStore.url(for: documentID)
      if FileManager.default.fileExists(atPath: localURL.path) {
        quickLinks = try linkStore.load(documentID)
      } else if let sourceData,
        let document = PDFDocument(data: sourceData),
        let transferred = try ReaderTransferPDF.metadata(from: document)
      {
        quickLinks = transferred.quickLinks
        try linkStore.save(quickLinks, for: documentID)
      }
    } catch {
      errorDescription = error.localizedDescription
    }

    return PreparedStartup(
      sourceData: sourceData,
      annotationState: annotationState,
      quickLinks: quickLinks,
      errorDescription: errorDescription
    )
  }

  /// The interaction controller is installed before SwiftUI starts
  /// `prepare()`. Importing from PDFView here would reintroduce a synchronous
  /// full-PDF read and could race the background result, so preparation owns
  /// all startup imports.
  func loadIfNeeded(from _: PDFView) {
    // Kept as a compatibility hook for the controller's installation path.
  }

  func addSelection(
    _ selection: PDFSelection,
    in pdfView: PDFView,
    color: String,
    comment: String = ""
  ) {
    guard isPrepared else { return }
    let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let createdAt = ISO8601DateFormatter().string(from: Date())
    let pages = selection.pages
    let newAnnotations = pages.compactMap { page -> ReaderAnnotation? in
      let pageIndex = pdfView.document?.index(for: page) ?? NSNotFound
      guard pageIndex != NSNotFound else { return nil }
      let rects = ReaderAnnotationPDF.viewportRects(for: selection, on: page)
        .map { sourceRect($0, on: page) }
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
    // A new highlight must not vanish into a hidden layer.
    let wasHidden = !showsAnnotations
    showsAnnotations = true
    commit(to: pdfView, pages: Set(newAnnotations.map(\.page)))
    if wasHidden { applyVisibility(in: pdfView) }
  }

  func setShowsAnnotations(_ visible: Bool, in pdfView: PDFView?) {
    showsAnnotations = visible
    applyVisibility(in: pdfView)
  }

  /// Hides highlights, comments, and other markup; links and form fields stay.
  private func applyVisibility(in pdfView: PDFView?) {
    guard let pdfView, let document = pdfView.document else { return }
    for index in 0..<document.pageCount {
      for annotation in document.page(at: index)?.annotations ?? [] {
        switch annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "Link", "Widget": continue
        default: annotation.shouldDisplay = showsAnnotations
        }
      }
    }
    NotificationCenter.default.post(name: .readerAnnotationVisibilityChanged, object: pdfView)
  }

  func delete(_ annotation: ReaderAnnotation, pdfView: PDFView?) {
    guard isPrepared else { return }
    annotations.removeAll { $0.id == annotation.id }
    commit(to: pdfView, pages: [annotation.page])
  }

  func updateComment(
    for annotation: ReaderAnnotation,
    comment: String,
    pdfView: PDFView?
  ) {
    guard isPrepared else { return }
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
    annotations[index].comment = comment
    annotations[index].kind = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .highlight : .comment
    annotations[index].modifiedAt = ISO8601DateFormatter().string(from: Date())
    commit(to: pdfView, pages: [annotation.page])
  }

  func updateColor(for annotation: ReaderAnnotation, color: String, pdfView: PDFView?) {
    guard isPrepared else { return }
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
    annotations[index].color = color
    annotations[index].modifiedAt = ISO8601DateFormatter().string(from: Date())
    commit(to: pdfView, pages: [annotation.page])
  }

  /// Hit-test the individual lines, rather than the enclosing multiline box.
  func annotation(at point: CGPoint, in pdfView: PDFView) -> ReaderAnnotation? {
    guard showsAnnotations, !pdfView.isInMarkupMode,
      let document = pdfView.document,
      let page = pdfView.page(for: point, nearest: false)
    else { return nil }
    let pageIndex = document.index(for: page)
    guard pageIndex != NSNotFound else { return nil }
    let pagePoint = pdfView.convert(point, to: page)
    let hit = ReaderAnnotationPDF.viewportRect(
      for: CGRect(origin: pagePoint, size: CGSize(width: 1, height: 1)), on: page
    )
    let sourceHit = sourceRect(hit, on: page)
    return annotations.reversed().first { annotation in
      annotation.page == pageIndex + 1 && annotation.rects.contains { rect in
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
          .insetBy(dx: -2, dy: -2).contains(CGPoint(x: sourceHit.x, y: sourceHit.y))
      }
    }
  }

  func quickLinkOrigin(
    from selection: PDFSelection,
    in pdfView: PDFView
  ) -> ReaderQuickLinkEndpoint? {
    guard let document = pdfView.document, let page = selection.pages.first else { return nil }
    let pageIndex = document.index(for: page)
    guard pageIndex != NSNotFound else { return nil }
    let rects = ReaderAnnotationPDF.viewportRects(for: selection, on: page)
      .map { sourceRect($0, on: page) }
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
    guard isPrepared else { return false }
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
    guard isPrepared else { return }
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
    let point = ReaderAnnotationPDF.pdfPoint(
      for: displayBox(destination.box, on: page), on: page
    )
    if let view = pdfView as? ReaderAnnotationPDFView {
      view.navigate(to: PDFDestination(page: page, at: point))
    } else {
      pdfView?.go(to: PDFDestination(page: page, at: point))
    }
  }

  private func commit(to pdfView: PDFView?, pages: Set<Int>) {
    do {
      // Touch only edited pages. Keeping the document and page instances also
      // preserves PDFKit tiles, selection, zoom, overlays and reading position.
      for number in pages {
        guard let page = pdfView?.document?.page(at: number - 1) else { continue }
        let pageAnnotations = annotations.filter { $0.page == number }
        if let compaction = (page as? ReaderPDFPage)?.compaction {
          try ReaderAnnotationPDF.replacePageAnnotations(pageAnnotations, on: compaction.sourcePage)
        }
        let displayed = pageAnnotations.map { annotation in
          var mapped = annotation
          mapped.rects = annotation.rects.map { displayRect($0, on: page) }
          mapped.sourceRect = annotation.sourceRect.map { displayRect($0, on: page) }
          return mapped
        }
        try ReaderAnnotationPDF.replacePageAnnotations(displayed, on: page)
        for mark in page.annotations {
          switch mark.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
          case "Highlight", "Text": mark.shouldDisplay = showsAnnotations
          default: continue
          }
        }
      }
      if let pdfView {
        NotificationCenter.default.post(name: .readerAnnotationVisibilityChanged, object: pdfView)
      }
      editRevision += 1
      scheduleSave()
    } catch {
      lastError = L10n.string("ios.annotationSaveFailed")
    }
  }

  private func scheduleSave() {
    guard saveTask == nil else { return }
    // A single writer coalesces rapid edits. Never pass the displayed PDFKit
    // objects to the worker; it owns an independent document from source bytes.
    saveTask = Task { [self] in
      let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save annotations")
      defer {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
      }
      while true {
        let revision = editRevision
        let snapshot = annotations
        let references = nativeRefs
        let input = sourceData
        let annotationStore = store
        let documentID = session.id
        let sourceURL = session.url
        let access = session.access
        let succeeded = await Task.detached(priority: .utility) {
          withExtendedLifetime(access) {
            do {
              _ = try annotationStore.save(
                snapshot, nativeRefs: references, for: documentID,
                sourceURL: sourceURL, sourceData: input
              )
              return true
            } catch {
              return false
            }
          }
        }.value
        if revision == editRevision {
          lastError = succeeded ? nil : L10n.string("ios.annotationSaveFailed")
          break
        }
      }
      saveTask = nil
    }
  }

  private func sourceRect(_ rect: ReaderAnnotationRect, on page: PDFPage) -> ReaderAnnotationRect {
    guard let compaction = (page as? ReaderPDFPage)?.compaction else { return rect }
    let mapped = compaction.sourceRect(
      ReadingRectangle(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    )
    return ReaderAnnotationRect(
      x: mapped.x, y: mapped.y, width: mapped.width, height: mapped.height
    )
  }

  private func displayRect(_ rect: ReaderAnnotationRect, on page: PDFPage) -> ReaderAnnotationRect {
    guard let compaction = (page as? ReaderPDFPage)?.compaction else { return rect }
    let mapped = compaction.displayRect(
      ReadingRectangle(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    )
    return ReaderAnnotationRect(
      x: mapped.x, y: mapped.y, width: mapped.width, height: mapped.height
    )
  }

  private func displayBox(_ box: ReaderQuickLinkBox, on page: PDFPage) -> ReaderQuickLinkBox {
    let mapped = displayRect(
      ReaderAnnotationRect(x: box.x, y: box.y, width: box.width, height: box.height),
      on: page
    )
    return ReaderQuickLinkBox(
      x: mapped.x, y: mapped.y, width: mapped.width, height: mapped.height
    )
  }
}

extension Notification.Name {
  static let readerSearchSelectedText = Notification.Name("PDFMathReader.readerSearchSelectedText")
  /// Object: the PDFView whose markup annotations were shown or hidden.
  static let readerAnnotationVisibilityChanged = Notification.Name(
    "PDFMathReader.readerAnnotationVisibilityChanged"
  )
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
final class ReaderAnnotationInteractionController: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate,
  UIContextMenuInteractionDelegate {
  weak var pdfView: PDFView?
  let model: ReaderAnnotationViewModel
  private var activeAnnotation: ReaderAnnotation?
  private lazy var annotationMenu = UIEditMenuInteraction(delegate: self)

  init(model: ReaderAnnotationViewModel, pdfView: PDFView) {
    self.model = model
    self.pdfView = pdfView
    super.init()
    let tap = UITapGestureRecognizer(target: self, action: #selector(annotationTapped(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    pdfView.addGestureRecognizer(tap)
    pdfView.addInteraction(annotationMenu)
    pdfView.addInteraction(UIContextMenuInteraction(delegate: self))
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

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let view = pdfView, view.currentSelection == nil else { return false }
    return model.annotation(at: gestureRecognizer.location(in: view), in: view) != nil
  }

  @objc private func annotationTapped(_ gesture: UITapGestureRecognizer) {
    guard let view = pdfView else { return }
    let point = gesture.location(in: view)
    guard let annotation = model.annotation(at: point, in: view) else { return }
    activeAnnotation = annotation
    annotationMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: annotation.id as NSString, sourcePoint: point))
  }

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    activeAnnotation.map { menu(for: $0) }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let view = pdfView, view.currentSelection == nil,
      let annotation = model.annotation(at: location, in: view)
    else { return nil }
    return UIContextMenuConfiguration(identifier: annotation.id as NSString, previewProvider: nil) { [weak self] _ in
      self?.menu(for: annotation)
    }
  }

  private func menu(for annotation: ReaderAnnotation) -> UIMenu {
    let colors = [("ios.highlightYellow", "#fff36a"), ("ios.highlightPink", "#ffb6c1"),
                  ("ios.highlightBlue", "#9bd7ff"), ("ios.highlightGreen", "#b8e986")]
    let colorActions = colors.map { key, hex in
      UIAction(title: L10n.string(key), image: Self.swatch(hex: hex),
               state: annotation.color.lowercased() == hex ? .on : .off) { [weak self] _ in
        guard let self else { return }
        self.model.updateColor(for: annotation, color: hex, pdfView: self.pdfView)
      }
    }
    var actions: [UIMenuElement] = [
      UIAction(title: L10n.string(annotation.kind == .comment ? "ios.editComment" : "ios.addComment"),
               image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
        self?.editComment(for: annotation)
      },
      UIMenu(title: L10n.string("annotationBrowser.color"), children: colorActions),
    ]
    let text = annotation.text.isEmpty ? annotation.comment : annotation.text
    if !text.isEmpty {
      actions.append(UIAction(title: L10n.string("menu.extra.messages.Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
        UIPasteboard.general.string = text
      })
      actions += textActions(for: text)
    }
    actions.append(UIAction(title: L10n.string("ios.delete"), image: UIImage(systemName: "trash"),
                            attributes: .destructive) { [weak self] _ in
      guard let self else { return }
      self.model.delete(annotation, pdfView: self.pdfView)
    })
    return UIMenu(children: actions)
  }

  private func textActions(for text: String) -> [UIMenuElement] {
    [
      UIAction(title: L10n.string("ios.share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        guard let view = self?.pdfView else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(
          x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1
        )
        readerTopViewController(for: view)?.present(sheet, animated: true)
      },
      UIAction(title: L10n.string("menu.extra.messages.Search in Document"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
        guard let view = self?.pdfView else { return }
        NotificationCenter.default.post(name: .readerSearchSelectedText, object: view, userInfo: ["text": text])
      },
    ]
  }

  private func editComment(for annotation: ReaderAnnotation) {
    guard let view = pdfView else { return }
    let alert = UIAlertController(
      title: L10n.string(annotation.kind == .comment ? "ios.editComment" : "ios.addComment"),
      message: annotation.text.isEmpty ? nil : annotation.text, preferredStyle: .alert
    )
    alert.addTextField { field in
      field.text = annotation.comment
      field.placeholder = L10n.string("sidebar.comment")
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: L10n.string("ios.cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L10n.string("ios.save"), style: .default) { [weak self, weak alert] _ in
      guard let self, let comment = alert?.textFields?.first?.text else { return }
      self.model.updateComment(for: annotation, comment: comment, pdfView: self.pdfView)
    })
    readerTopViewController(for: view)?.present(alert, animated: true)
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
    // Highlight colors show as swatches. The edit menu prints a title whenever
    // one is set, so these commands have none; the swatch carries the name
    // as its accessibility label for VoiceOver.
    let swatches: [(String, String, Selector)] = [
      (L10n.string("ios.highlightYellow"), "#fff36a", #selector(highlightYellow(_:))),
      (L10n.string("ios.highlightPink"), "#ffb6c1", #selector(highlightPink(_:))),
      (L10n.string("ios.highlightBlue"), "#9bd7ff", #selector(highlightBlue(_:))),
      (L10n.string("ios.highlightGreen"), "#b8e986", #selector(highlightGreen(_:))),
    ]
    var commands = swatches.compactMap { title, hex, action -> UIMenuElement? in
      guard canPerform(action) else { return nil }
      let image = Self.swatch(hex: hex)
      image.accessibilityLabel = title
      return UICommand(title: "", image: image, action: action)
    }
    let actions: [(String, Selector)] = [
      (L10n.string("ios.addComment"), #selector(addComment(_:))),
      (L10n.string("ios.createQuickLink"), #selector(createQuickLink(_:))),
    ]
    commands += actions.compactMap { title, action -> UIMenuElement? in
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
    if let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      commands += textActions(for: text)
    }
    return commands
  }

  /// A filled color circle with a faint rim so pale colors stay visible on the menu.
  private static func swatch(hex: String) -> UIImage {
    let side: CGFloat = 22
    let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
      UIColor(hex: hex).setFill()
      circle.fill()
      UIColor.black.withAlphaComponent(0.18).setStroke()
      circle.lineWidth = 1
      circle.stroke()
    }
    return image.withRenderingMode(.alwaysOriginal)
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
  var onViewportLayout: (() -> Void)?
  private var lastViewportSize: CGSize = .zero
  private var viewportLayoutScheduled = false

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != lastViewportSize, !viewportLayoutScheduled else { return }
    viewportLayoutScheduled = true
    // PDFKit must finish updating its internal document/scroll geometry first.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.viewportLayoutScheduled = false
      guard self.bounds.size != self.lastViewportSize else { return }
      self.lastViewportSize = self.bounds.size
      self.onViewportLayout?()
    }
  }

  var navigationAnimator: UIViewPropertyAnimator?
  var navigationCover: UIView?
  // Updated by the PDFKit gesture/offset observer, without publishing view state.
  var translationRenderResumeTime: TimeInterval = 0
  var isUpdatingPageGeometry = false
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
    // The selection edit menu (context system) has no `.text` menu; that one only
    // exists in the main menu bar, so inserting there is silently dropped.
    if builder.system == .context {
      if builder.menu(for: .standardEdit) != nil {
        builder.insertSibling(menu, afterMenu: .standardEdit)
      } else {
        builder.insertChild(menu, atStartOfMenu: .root)
      }
    } else if builder.menu(for: .text) != nil {
      builder.insertChild(menu, atStartOfMenu: .text)
    }
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
