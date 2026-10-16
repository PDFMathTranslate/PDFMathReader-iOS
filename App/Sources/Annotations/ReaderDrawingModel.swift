import Combine
import CryptoKit
import PDFKit
import PencilKit
import ReaderCore
import UIKit

/// PencilKit data stays separate from text markup so erasing a drawing never
/// rewrites highlights or invalidates an in-flight translation.
@MainActor
final class ReaderDrawingModel: NSObject, ObservableObject, PKCanvasViewDelegate {
  @Published var isDrawing = false { didSet { updateCanvases() } }
  @Published var usesFinger = false { didSet { updateCanvases() } }
  @Published var lastError: String?
  @Published private(set) var drawings: [Int: PKDrawing] = [:]
  private let url: URL
  private let picker = PKToolPicker()
  private var canvases: [Int: ReaderPencilCanvas] = [:]
  private weak var activeCanvas: ReaderPencilCanvas?
  private var pendingSave: Task<Void, Never>?
  private var isDirty = false
  private var canSave = true

  /// In Pencil-only drawing, a finger long-press means the Pencil is put away:
  /// it returns to reading mode and selects text there. iPadOS has no public
  /// signal for a Pencil being attached to the iPad, so this is the stand-in.
  var exitsOnFingerPress: Bool { isDrawing && !usesFinger }

  init(session: DocumentSession, directory: URL = LibraryDirectory.default.appendingPathComponent("drawings")) {
    // Text annotation saves can rewrite the source bytes and change its content
    // hash. Bind the local drawing to the Files URL, which survives those edits.
    // Moving/sharing drawings is handled by the embedded PencilKit PDF data.
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
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        let records = try JSONDecoder().decode([Int: Data].self, from: Data(contentsOf: url))
        drawings = try records.mapValues { try PKDrawing(data: $0) }
      } else {
        drawings = try ReaderDrawingPDF.drawings(in: Data(contentsOf: session.url))
      }
    } catch {
      // Preserve unreadable data instead of replacing it with an empty drawing.
      canSave = false
      lastError = error.localizedDescription
    }
  }

  func canvas(for index: Int, page: PDFPage) -> ReaderPencilCanvas {
    // Imported appearance streams are represented by the editable overlay.
    for annotation in page.annotations where canSave && annotation.value(
      forAnnotationKey: PDFAnnotationKey(rawValue: "PDFMathReaderPencilDrawing")
    ) != nil {
      annotation.shouldDisplay = false
    }
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

  func release(_ canvas: ReaderPencilCanvas) {
    capture(canvas)
    flush()
    picker.setVisible(false, forFirstResponder: canvas)
    picker.removeObserver(canvas)
    if canvases[canvas.pageIndex] === canvas { canvases[canvas.pageIndex] = nil }
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
    guard canSave else { return }
    if let canvas = canvases[pageIndex] {
      canvas.drawing = PKDrawing()
      canvas.undoManager?.removeAllActions()
    }
    drawings[pageIndex] = PKDrawing()
    isDirty = true
    flush()
  }

  func exportDrawings() throws -> [Int: PKDrawing] {
    guard canSave else { throw CocoaError(.fileReadCorruptFile) }
    for canvas in canvases.values { capture(canvas) }
    flush()
    return drawings
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
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
    drawings[canvas.pageIndex] = canvas.drawing
    isDirty = true
  }

  func flush() {
    pendingSave?.cancel()
    pendingSave = nil
    guard isDirty, canSave else { return }
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

  init(canvas: ReaderPencilCanvas, pageSize: CGSize, content: UIView?) {
    self.canvas = canvas
    self.pageSize = pageSize
    super.init(frame: .zero)
    backgroundColor = .clear
    if let content { addSubview(content) }
    addSubview(canvas)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    for view in subviews where view !== canvas { view.frame = bounds }
    guard pageSize.width > 0, pageSize.height > 0 else { return }
    canvas.bounds = CGRect(origin: .zero, size: pageSize)
    canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    canvas.transform = CGAffineTransform(scaleX: bounds.width / pageSize.width, y: bounds.height / pageSize.height)
    canvas.contentSize = pageSize
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}
