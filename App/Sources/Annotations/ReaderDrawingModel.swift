import Combine
import CryptoKit
import Foundation
import PDFKit
import PencilKit
import ReaderCore
import UIKit

private enum ReaderDrawingPreparationError: Error, LocalizedError {
  case invalidPDF
  case invalidDrawing(Int)
  case pdfTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidPDF:
      ReaderLocalization.resolve("The drawing PDF could not be opened.")
    case .invalidDrawing(let page):
      ReaderLocalization.string("The PencilKit drawing on PDF page {0} is invalid.", String(page))
    case .pdfTooLarge:
      ReaderLocalization.resolve("The drawing PDF exceeds the 200 MiB limit.")
    }
  }
}

/// PencilKit data stays separate from text markup so erasing a drawing never
/// rewrites highlights or invalidates an in-flight translation.
@MainActor
final class ReaderDrawingModel: NSObject, ObservableObject, PKCanvasViewDelegate {
  @Published var isDrawing = false { didSet { updateCanvases() } }
  @Published var usesFinger = false { didSet { updateCanvases() } }
  @Published var lastError: String?
  @Published private(set) var drawings: [Int: PKDrawing] = [:]
  @Published private(set) var isPrepared = false
  private let url: URL
  private let sourceURL: URL
  private let access: SecurityScopedAccess
  private let session: DocumentSession
  private let picker = PKToolPicker()
  private var canvases: [Int: ReaderPencilCanvas] = [:]
  private var pages: [Int: PDFPage] = [:]
  private weak var activeCanvas: ReaderPencilCanvas?
  private var pendingSave: Task<Void, Never>?
  private var preparationTask: Task<PreparedStartup, Never>?
  private var isApplyingPreparedDrawings = false
  private var isDirty = false
  private var canSave = false

  private struct PreparedStartup: Sendable {
    let records: [Int: [Data]]
    let errorDescription: String?
  }

  /// In Pencil-only drawing, a finger long-press means the Pencil is put away:
  /// it returns to reading mode and selects text there. iPadOS has no public
  /// signal for a Pencil being attached to the iPad, so this is the stand-in.
  var exitsOnFingerPress: Bool { isDrawing && !usesFinger }

  init(session: DocumentSession, directory: URL = LibraryDirectory.default.appendingPathComponent("drawings")) {
    self.session = session
    // Text annotation saves can rewrite the source bytes and change its content
    // hash. Bind the local drawing to the Files URL, which survives those edits.
    // Moving/sharing drawings is handled by the embedded PencilKit PDF data.
    sourceURL = session.url
    access = session.access
    let key = session.url.standardizedFileURL.absoluteString
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    url = directory.appendingPathComponent(digest).appendingPathExtension("json")
    super.init()
    // The palette docks over the reader toolbar on iPad, hiding its Pencil
    // toggle, so the palette carries its own way back to reading mode.
    let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
      self?.isDrawing = false
    })
    done.accessibilityIdentifier = "reader.exitPencilMode"
    picker.accessoryItem = done
  }

  /// Loads local drawings or embedded PencilKit records away from the main
  /// actor. The records are decoded into `PKDrawing` only after this method
  /// resumes on the main actor because PencilKit values are not Sendable.
  func prepare() async {
    guard !isPrepared else { return }

    let task: Task<PreparedStartup, Never>
    if let preparationTask {
      task = preparationTask
    } else {
      let sidecarURL = url
      let sourceURL = self.sourceURL
      let access = self.access
      task = Task.detached(priority: .utility) {
        withExtendedLifetime(access) {
          Self.prepareStartup(sidecarURL: sidecarURL, sourceURL: sourceURL)
        }
      }
      preparationTask = task
    }

    let prepared = await task.value
    guard !isPrepared else { return }
    preparationTask = nil

    if let errorDescription = prepared.errorDescription {
      // Preserve unreadable data instead of replacing it with an empty,
      // editable drawing. Embedded appearance annotations remain visible.
      canSave = false
      lastError = errorDescription
    } else {
      do {
        var loaded: [Int: PKDrawing] = [:]
        for (pageIndex, records) in prepared.records {
          var strokes: [PKStroke] = []
          for data in records {
            guard let drawing = try? PKDrawing(data: data) else {
              throw ReaderDrawingPreparationError.invalidDrawing(pageIndex)
            }
            strokes.append(contentsOf: drawing.strokes)
          }
          loaded[pageIndex] = PKDrawing(strokes: strokes)
        }
        drawings = loaded
        canSave = true
        lastError = nil
      } catch {
        canSave = false
        lastError = error.localizedDescription
      }
    }

    isPrepared = true
    applyPreparedDrawings()
  }

  private nonisolated static func prepareStartup(
    sidecarURL: URL,
    sourceURL: URL
  ) -> PreparedStartup {
    do {
      if FileManager.default.fileExists(atPath: sidecarURL.path) {
        let records = try JSONDecoder().decode(
          [Int: Data].self,
          from: Data(contentsOf: sidecarURL, options: [.mappedIfSafe])
        )
        return PreparedStartup(
          records: records.mapValues { [$0] },
          errorDescription: nil
        )
      }

      let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
      return PreparedStartup(
        records: try embeddedRecords(in: sourceData),
        errorDescription: nil
      )
    } catch {
      return PreparedStartup(records: [:], errorDescription: error.localizedDescription)
    }
  }

  private nonisolated static func embeddedRecords(in data: Data) throws -> [Int: [Data]] {
    guard data.count <= ReaderAnnotationLimits.maximumPDFBytes else {
      throw ReaderDrawingPreparationError.pdfTooLarge
    }
    guard let document = PDFDocument(data: data) else {
      throw ReaderDrawingPreparationError.invalidPDF
    }

    let markerKey = PDFAnnotationKey(rawValue: "PDFMathReaderPencilDrawing")
    var records: [Int: [Data]] = [:]
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        guard let value = annotation.value(forAnnotationKey: markerKey) else { continue }
        guard let encoded = value as? String, let data = Data(base64Encoded: encoded) else {
          throw ReaderDrawingPreparationError.invalidDrawing(pageIndex)
        }
        records[pageIndex, default: []].append(data)
      }
    }
    return records
  }

  func canvas(for index: Int, page: PDFPage) -> ReaderPencilCanvas {
    pages[index] = page
    // Imported appearance streams are represented by the editable overlay.
    if isPrepared { hideEmbeddedDrawings(on: page) }
    if let canvas = canvases[index] { return canvas }
    let canvas = ReaderPencilCanvas()
    canvas.pageIndex = index
    canvas.accessibilityIdentifier = "reader.drawingCanvas.\(index + 1)"
    canvas.accessibilityLabel = L10n.string("ios.drawingTools")
    canvas.drawing = drawings[index] ?? PKDrawing()
    canvas.delegate = self
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.overrideUserInterfaceStyle = .light
    canvas.isScrollEnabled = false
    canvas.minimumZoomScale = 1
    canvas.maximumZoomScale = 1
    canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
    canvas.onActivate = { [weak self] canvas in self?.activate(canvas) }
    canvas.onDetach = { [weak self] canvas in
      guard let self else { return }
      self.capture(canvas)
      self.flush()
    }
    canvases[index] = canvas
    configure(canvas)
    return canvas
  }

  private func hideEmbeddedDrawings(on page: PDFPage) {
    guard canSave else { return }
    let markerKey = PDFAnnotationKey(rawValue: "PDFMathReaderPencilDrawing")
    for annotation in page.annotations where annotation.value(forAnnotationKey: markerKey) != nil {
      annotation.shouldDisplay = false
    }
  }

  private func applyPreparedDrawings() {
    guard canSave else {
      for canvas in canvases.values { configure(canvas) }
      return
    }
    isApplyingPreparedDrawings = true
    defer { isApplyingPreparedDrawings = false }
    for (index, canvas) in canvases {
      canvas.drawing = drawings[index] ?? PKDrawing()
      canvas.undoManager?.removeAllActions()
      if let page = pages[index] { hideEmbeddedDrawings(on: page) }
      configure(canvas)
    }
  }

  func release(_ canvas: ReaderPencilCanvas) {
    capture(canvas)
    flush()
    picker.setVisible(false, forFirstResponder: canvas)
    picker.removeObserver(canvas)
    if canvases[canvas.pageIndex] === canvas {
      canvases[canvas.pageIndex] = nil
      pages[canvas.pageIndex] = nil
    }
  }

  /// A closed PDF view may not report every page that stopped displaying.
  /// Saves and drops canvases that left the window, with their page references.
  func releaseDetachedCanvases() {
    for canvas in canvases.values where canvas.window == nil { release(canvas) }
    pages = pages.filter { canvases[$0.key] != nil }
  }

  func activate(_ canvas: ReaderPencilCanvas) {
    guard isDrawing, canvas.window != nil else { return }
    activeCanvas = canvas
    canvas.tool = picker.selectedTool
    picker.addObserver(canvas)
    picker.setVisible(true, forFirstResponder: canvas)
    canvas.becomeFirstResponder()
  }

  func undo() { activeCanvas?.undoManager?.undo() }
  func redo() { activeCanvas?.undoManager?.redo() }

  /// One sidebar entry per page, including both Pencil and finger strokes.
  var annotatedPages: [Int] {
    drawings.keys.filter { drawings[$0]?.strokes.isEmpty == false }.sorted()
  }

  func deleteDrawing(on pageIndex: Int) {
    guard isPrepared, canSave else { return }
    if let canvas = canvases[pageIndex] {
      canvas.drawing = PKDrawing()
      canvas.undoManager?.removeAllActions()
    }
    drawings[pageIndex] = PKDrawing()
    isDirty = true
    flush()
  }

  func exportDrawings() throws -> [Int: PKDrawing] {
    guard isPrepared, canSave else { throw CocoaError(.fileReadCorruptFile) }
    for canvas in canvases.values { capture(canvas) }
    flush()
    return drawings
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard isPrepared, canSave else { return }
    guard let canvas = canvasView as? ReaderPencilCanvas else { return }
    capture(canvas)
    pendingSave?.cancel()
    pendingSave = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { flush() }

  private func capture(_ canvas: ReaderPencilCanvas) {
    guard isPrepared, canSave, !isApplyingPreparedDrawings else { return }
    drawings[canvas.pageIndex] = canvas.drawing
    isDirty = true
  }

  func flush() {
    pendingSave?.cancel()
    pendingSave = nil
    guard isPrepared, isDirty, canSave else { return }
    do {
      let data = try JSONEncoder().encode(drawings.mapValues { $0.dataRepresentation() })
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      isDirty = false
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func updateCanvases() {
    for canvas in canvases.values { configure(canvas) }
    if isDrawing {
      if let canvas = activeCanvas, canvas.window != nil { activate(canvas) }
      else if let canvas = canvases.values.first(where: { $0.window != nil }) { activate(canvas) }
    } else {
      flush()
    }
  }

  private func configure(_ canvas: ReaderPencilCanvas) {
    canvas.acceptsDrawing = isDrawing && canSave
    canvas.drawingPolicy = usesFinger ? .anyInput : .pencilOnly
    canvas.drawingGestureRecognizer.isEnabled = isDrawing && canSave
    if !isDrawing {
      picker.setVisible(false, forFirstResponder: canvas)
      canvas.resignFirstResponder()
    }
  }
}

@MainActor
final class ReaderPencilCanvas: PKCanvasView {
  var pageIndex = 0
  var acceptsDrawing = false
  var onActivate: ((ReaderPencilCanvas) -> Void)?
  var onDetach: ((ReaderPencilCanvas) -> Void)?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard acceptsDrawing else { return nil }
    // Touch types are unknown during hit-testing, so filtering on them here
    // dropped Pencil strokes. In Pencil-only mode the drawing recognizer
    // ignores fingers, and PDFKit's scroll and zoom recognizers on ancestor
    // views still receive them.
    return super.hitTest(point, with: event)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    onActivate?(self)
    super.touchesBegan(touches, with: event)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { onActivate?(self) }
    else { onDetach?(self) }
  }
}

/// PDFKit sizes and rotates this container with the page. The canvas keeps
/// coordinates in unrotated crop-box points across zoom and device rotation.
@MainActor
final class ReaderDrawingPageOverlay: UIView {
  let canvas: ReaderPencilCanvas
  private let pageSize: CGSize
  private let visibleSize: CGSize

  init(canvas: ReaderPencilCanvas, pageSize: CGSize, visibleSize: CGSize, content: UIView?) {
    self.canvas = canvas
    self.pageSize = pageSize
    self.visibleSize = visibleSize
    super.init(frame: .zero)
    backgroundColor = .clear
    clipsToBounds = true
    if let content { addSubview(content) }
    addSubview(canvas)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    for view in subviews where view !== canvas { view.frame = bounds }
    guard pageSize.width > 0, pageSize.height > 0, visibleSize.width > 0, visibleSize.height > 0 else { return }
    canvas.bounds = CGRect(origin: .zero, size: pageSize)
    canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    canvas.transform = CGAffineTransform(scaleX: bounds.width / visibleSize.width, y: bounds.height / visibleSize.height)
    canvas.contentSize = pageSize
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}
