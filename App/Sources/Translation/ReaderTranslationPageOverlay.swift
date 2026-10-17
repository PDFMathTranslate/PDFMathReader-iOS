import PDFKit
import CoreImage.CIFilterBuiltins
import ReaderCore
import UIKit

/// Immutable raster data that is safe to hand to the detached refocus worker.
/// UIKit images stay on the main actor; only their Core Graphics backing image
/// and scalar display scale cross the actor boundary.
private struct ReaderRefocusImage: Sendable {
  let cgImage: CGImage
  let scale: CGFloat
}

private struct ReaderRefocusSnapshot: Sendable {
  let rect: CGRect
  let image: ReaderRefocusImage
}

private struct ReaderRefocusPreparedImages: Sendable {
  let incoming: ReaderRefocusImage
  let soft: ReaderRefocusImage
  let blurred: ReaderRefocusImage
  let outgoing: ReaderRefocusImage
}

private func readerRefocusImage(
  _ image: ReaderRefocusImage,
  blur: Double,
  contrast: Float,
  context: CIContext
) -> ReaderRefocusImage {
  let input = CIImage(cgImage: image.cgImage)
  let color = CIFilter.colorControls()
  color.inputImage = input.clampedToExtent()
  color.contrast = contrast
  let filter = CIFilter.gaussianBlur()
  filter.inputImage = color.outputImage
  filter.radius = Float(blur * image.scale)
  guard let output = filter.outputImage,
        let rendered = context.createCGImage(output, from: input.extent) else {
    return image
  }
  return ReaderRefocusImage(cgImage: rendered, scale: image.scale)
}

/// Matches the desktop page-top strip, including its loading and queued states.
@MainActor
private final class ReaderPageProgressView: UIView {
  enum Mode: Equatable {
    case queued
    case loading
    case measured(Double)
  }

  private let fill = CALayer()
  private var mode: Mode = .queued

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    backgroundColor = UIColor(red: 229 / 255, green: 229 / 255, blue: 234 / 255, alpha: 1)
    layer.addSublayer(fill)
  }

  required init?(coder: NSCoder) { nil }

  func update(_ mode: Mode, visible: Bool) {
    self.mode = mode
    isHidden = !visible
    setNeedsLayout()
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let loading = mode == .loading
    let width: CGFloat
    switch mode {
    case .queued: width = bounds.width * 0.12
    case .loading: width = bounds.width * 0.35
    case .measured(let fraction): width = bounds.width * min(1, max(0, fraction))
    }
    let oldWidth = fill.presentation()?.bounds.width ?? fill.bounds.width
    let oldBarWidth = fill.bounds.width
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.backgroundColor = (mode == .queued || loading ? UIColor.systemGray : tintColor ?? .systemBlue)
      .resolvedColor(with: traitCollection).cgColor
    fill.opacity = mode == .queued ? 0.55 : 1
    fill.anchorPoint = .zero
    fill.position = .zero
    fill.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    CATransaction.commit()

    if loading && !isHidden && !UIAccessibility.isReduceMotionEnabled {
      // Do not restart the sweep for every pipeline update.
      if fill.animation(forKey: "loading") == nil || oldBarWidth != width {
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -width
        sweep.toValue = width * 3.86
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(sweep, forKey: "loading")
      }
    } else {
      fill.removeAnimation(forKey: "loading")
      fill.transform = CATransform3DMakeTranslation(loading ? width * 0.9 : 0, 0, 0)
    }
    if case .measured = mode, !isHidden, !UIAccessibility.isReduceMotionEnabled, oldWidth != width {
      let change = CABasicAnimation(keyPath: "bounds.size.width")
      change.fromValue = oldWidth
      change.toValue = width
      change.duration = 0.2
      change.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      fill.add(change, forKey: "progress")
    } else {
      fill.removeAnimation(forKey: "progress")
    }
  }
}

@MainActor
final class ReaderTranslationLabel: UILabel {
  var textInsets = UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
  /// Label size and text the current font was fitted for.
  var fittedSize: CGSize = .zero
  var fittedText = ""
  /// Painted on the layer, not via `backgroundColor`: an opaque UILabel
  /// background makes its text bitmap opaque, and the partly covered last
  /// pixel column of that bitmap shows as a dark seam on the scaled page.
  var coverColor: UIColor = .white {
    didSet { applyCoverColor() }
  }
  /// Highlights under this cover, in label coordinates. Painted behind the
  /// text so the translation stays readable.
  var marks: [ReaderTranslationMarkupView.Highlight] = [] {
    didSet { if marks != oldValue { setNeedsDisplay() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (label: Self, _) in
      label.applyCoverColor()
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func applyCoverColor() {
    layer.backgroundColor = coverColor.resolvedColor(with: traitCollection).cgColor
  }

  /// PDFKit scales overlays in page coordinates. UIKit otherwise stretches a
  /// screen-scale text bitmap when the page is magnified.
  func updateRenderingScale(in view: UIView) {
    guard !bounds.isEmpty else { return }
    let origin = convert(CGPoint.zero, to: view)
    let x = convert(CGPoint(x: 1, y: 0), to: view)
    let y = convert(CGPoint(x: 0, y: 1), to: view)
    let zoom = max(hypot(x.x - origin.x, x.y - origin.y), hypot(y.x - origin.x, y.y - origin.y))
    let desired = ceil(zoom * max(1, view.traitCollection.displayScale))
    // Bound backing-store memory for unusually large paragraph covers.
    let budgetScale = sqrt(4_000_000 / max(1, bounds.width * bounds.height))
    let scale = max(1, min(8, desired, budgetScale))
    guard abs(contentScaleFactor - scale) > 0.01 else { return }
    contentScaleFactor = scale
    setNeedsDisplay()
  }

  override func drawText(in rect: CGRect) {
    if !marks.isEmpty, let context = UIGraphicsGetCurrentContext() {
      // Match PDFKit's highlights on the dimmed page in dark appearance.
      let dark = traitCollection.userInterfaceStyle == .dark
      for mark in marks {
        let color = dark ? ReaderDarkPDF.markOnDimmedPaper(mark.color) : mark.color.withAlphaComponent(0.5)
        context.setFillColor(color.cgColor)
        context.fill(mark.rect)
      }
    }
    super.drawText(in: rect.inset(by: textInsets))
  }
}

/// Redraws markup that sits under a translation cover: PDFKit paints
/// annotations on the page, below overlay views. Its live text selection is
/// drawn above overlays, so it is not repeated here. Label covers paint their
/// own highlights; this view handles the remote page image and comment icons.
/// Drawing is clipped to the covers so uncovered markup is not drawn twice.
@MainActor
final class ReaderTranslationMarkupView: UIView {
  struct Highlight: Equatable {
    let rect: CGRect
    let color: UIColor
  }

  var covers: [CGRect] = [] { didSet { setNeedsDisplay() } }
  var highlights: [Highlight] = [] { didSet { setNeedsDisplay() } }
  var comments: [PDFAnnotation] = [] { didSet { setNeedsDisplay() } }
  /// Maps page space (crop box) into this view, for PDFKit-drawn comment icons.
  var pageTransform: CGAffineTransform = .identity { didSet { setNeedsDisplay() } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    contentMode = .redraw
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext(), !covers.isEmpty else { return }
    context.saveGState()
    context.addRects(covers)
    context.clip()
    let dark = traitCollection.userInterfaceStyle == .dark
    for highlight in highlights {
      // This view sits above the translated image, so stay translucent.
      let color = dark
        ? ReaderDarkPDF.markOnDimmedPaper(highlight.color).withAlphaComponent(0.6)
        : highlight.color.withAlphaComponent(0.35)
      context.setFillColor(color.cgColor)
      context.fill(highlight.rect)
    }
    if !comments.isEmpty {
      context.concatenate(pageTransform)
      comments.forEach { $0.draw(with: .cropBox, in: context) }
    }
    context.restoreGState()
  }
}

/// A page-local overlay. PDFKit positions this view in page coordinates; the
/// conversion through PDFView below also handles crop boxes and page rotation.
@MainActor
final class ReaderTranslationPageOverlay: UIView {
  let pageIndex: Int
  private weak var pdfView: PDFView?
  private weak var page: PDFPage?
  private var state = PageTranslationState(pageIndex: 0)
  private var showTranslations = true
  private var interactionMode: ReaderInteractionMode = .reading
  private var readingAidsConfiguration = ReadingAidsConfiguration()
  private var translationFontName = ""
  private var translationSerif = false
  private var translationLanguage = ""
  private var originalOverrides = Set<Int>()
  private var labels: [Int: ReaderTranslationLabel] = [:]
  private var remotePageData: Data?
  private var remotePDFView: ReaderTiledPDFView?
  private var remoteFontRenderer: ReaderRemoteTranslationFont?
  private struct RemoteFontRequest: Equatable {
    let name: String
    let serif: Bool
    let language: String
  }
  private var cachedRemoteFontPDF: (request: RemoteFontRequest, data: Data)?
  private struct RemoteSourceGeometry: Equatable {
    let bounds: CGRect
    let rotation: Int
    let cuts: [CompactCut]
  }

  private func remoteSourceGeometry(_ page: PDFPage?) -> RemoteSourceGeometry? {
    guard let page else { return nil }
    return RemoteSourceGeometry(
      bounds: page.bounds(for: .cropBox), rotation: page.rotation,
      cuts: (page as? ReaderPDFPage)?.compaction?.cuts ?? []
    )
  }
  private let progressView = ReaderPageProgressView()
  private var remoteProgress: Double?
  private let markupView = ReaderTranslationMarkupView()
  private var isUpdatingRendering = false
  private var refocusView: UIView?
  private var refocusBounds: CGRect = .zero
  private var refocusTask: Task<Void, Never>?
  private var refocusPendingBounds: CGRect?
  private var refocusGeneration: UInt = 0
  private static let refocusPixelBudget: CGFloat = 2_000_000

  init(pageIndex: Int, page: PDFPage, pdfView: PDFView) {
    self.pageIndex = pageIndex
    self.page = page
    self.pdfView = pdfView
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    progressView.isHidden = true
    addSubview(progressView)
    addSubview(markupView)
    isAccessibilityElement = false
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (overlay: Self, _) in
      overlay.cancelRefocus()
      overlay.remotePDFView?.setInverted(overlay.traitCollection.userInterfaceStyle == .dark)
      overlay.setNeedsLayout()
    }
    // Applying a highlight clears the selection; refresh the covered marks then.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(selectionChanged(_:)),
      name: Notification.Name.PDFViewSelectionChanged,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(selectionChanged(_:)),
      name: .readerAnnotationVisibilityChanged,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scaleChanged(_:)),
      name: .PDFViewScaleChanged,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(
    state: PageTranslationState,
    showTranslations: Bool
  ) {
    let stateChanged = self.state != state
    let visibilityChanged = self.showTranslations != showTranslations
    guard stateChanged || visibilityChanged else { return }
    cancelRefocus()
    let previous = self.state
    self.state = state
    self.showTranslations = showTranslations
    if remotePageData == nil {
      if stateChanged {
        rebuildLabels(previousParagraphs: previous.paragraphs)
      } else {
        // Keep fitted labels alive across a visibility-only toggle. Hiding
        // their views avoids repeating text measurement when the user flips
        // translations while the page is otherwise unchanged.
        labels.values.forEach { $0.isHidden = !showTranslations }
      }
    } else {
      remotePDFView?.isHidden = !showTranslations
    }
    updateProgress()
    setNeedsLayout()
  }

  #if DEBUG
  var debugDisplayedText: [String] {
    guard window != nil, !isHidden, showTranslations else { return [] }
    return labels.sorted { $0.key < $1.key }
      .filter { $0.value.window != nil && !$0.value.isHidden }
      .map(\.value.fittedText)
  }
  #endif

  /// Annotation edits replace the PDFDocument; PDFKit then asks for this
  /// page's overlay with the new document's page object.
  func rebind(page: PDFPage, pdfView: PDFView) {
    guard page !== self.page || pdfView !== self.pdfView else { return }
    cancelRefocus()
    if remoteSourceGeometry(page) != remoteSourceGeometry(self.page) {
      remoteFontRenderer = nil
      cachedRemoteFontPDF = nil
    }
    self.page = page
    self.pdfView = pdfView
    if remotePageData != nil { updateRemotePDF() }
    setNeedsLayout()
  }

  func setTranslationFont(name: String, serif: Bool, language: String = "") {
    guard name != translationFontName
      || serif != translationSerif
      || language != translationLanguage
    else { return }
    translationFontName = name
    translationSerif = serif
    translationLanguage = language
    if remotePageData != nil {
      updateRemotePDF()
      setNeedsLayout()
      return
    }
    for item in state.paragraphs {
      if let label = labels[item.paragraph.id] { updateLabel(label, item: item) }
    }
  }

  func setInteractionMode(_ mode: ReaderInteractionMode) {
    guard mode != interactionMode else { return }
    interactionMode = mode
    let restore = !originalOverrides.isEmpty
    originalOverrides.removeAll()
    for item in state.paragraphs {
      guard let label = labels[item.paragraph.id] else { continue }
      label.isUserInteractionEnabled = mode == .comparison
      if restore { updateLabel(label, item: item) }
    }
  }

  /// Capture once around the complete render transaction. Updating state or
  /// replacing a remote PDF must not cancel the visibility transition midway.
  func performRenderingUpdate(showTranslations visible: Bool, updates: () -> Void) {
    let previous = visible != showTranslations ? refocusSnapshot(in: bounds) : nil
    isUpdatingRendering = true
    UIView.performWithoutAnimation {
      if visible != showTranslations { update(state: state, showTranslations: visible) }
      updates()
    }
    isUpdatingRendering = false
    layoutIfNeeded()
    if let previous { refocus(from: previous) }
  }

  /// Applies visibility with the last known state, even if the coordinator
  /// has no state for this page right now (e.g. during a pipeline restart).
  func setTranslationsVisible(_ visible: Bool) {
    guard visible != showTranslations else { return }
    let previous = refocusSnapshot(in: bounds)
    update(state: state, showTranslations: visible)
    layoutIfNeeded()
    refocus(from: previous)
  }

  // Reading mode: nothing here takes touches, so a long press on a
  // translation reaches PDFKit, which selects the source text beneath it and
  // shows the annotation menu. Comparison mode: labels take taps to toggle.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard interactionMode == .comparison else { return nil }
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }

  func updateReadingAids(_ configuration: ReadingAidsConfiguration) {
    guard configuration != readingAidsConfiguration else { return }
    readingAidsConfiguration = configuration
    guard remotePageData == nil else { return }
    for item in state.paragraphs {
      guard let label = labels[item.paragraph.id] else { continue }
      updateLabel(label, item: item)
    }
    setNeedsLayout()
  }

  func setRemotePageData(_ data: Data) {
    guard data != remotePageData else { return }
    cancelRefocus()
    remotePageData = data
    cachedRemoteFontPDF = nil
    labels.values.forEach { $0.removeFromSuperview() }
    labels.removeAll()
    remotePDFView?.removeFromSuperview()
    remotePDFView = nil
    remoteFontRenderer = nil
    if let provider = CGDataProvider(data: data as CFData),
       CGPDFDocument(provider)?.page(at: 1) != nil {
      let pdfContent = ReaderTiledPDFView(frame: bounds)
      pdfContent.backgroundColor = paperColor
      pdfContent.isHidden = !showTranslations
      addSubview(pdfContent)
      remotePDFView = pdfContent
      updateRemotePDF()
    }
    remoteProgress = nil
    updateProgress()
    setNeedsLayout()
  }

  func clearRemotePageData() {
    guard remotePageData != nil || remoteProgress != nil else { return }
    cancelRefocus()
    remotePageData = nil
    cachedRemoteFontPDF = nil
    remoteProgress = nil
    remoteFontRenderer = nil
    remotePDFView?.removeFromSuperview()
    remotePDFView = nil
    rebuildLabels()
    updateProgress()
    setNeedsLayout()
  }

  func setRemoteProgress(_ progress: Double) {
    remoteProgress = min(1, max(0, progress))
    updateProgress()
  }

  func beginRemoteTranslation() {
    cancelRefocus()
    remotePageData = nil
    cachedRemoteFontPDF = nil
    remoteFontRenderer = nil
    remotePDFView?.removeFromSuperview()
    remotePDFView = nil
    remoteProgress = 0
    updateProgress()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if (refocusView != nil && refocusBounds != bounds)
      || (refocusTask != nil && refocusPendingBounds != bounds) {
      cancelRefocus()
    }
    if let pdfView, readerPDFInteractionIsActive(pdfView), refocusView != nil {
      cancelRefocus()
    }
    progressView.frame = CGRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: 4
    )
    // Kernel PDFs still contain the complete source page. Position them in
    // page space so cropping clips margins instead of squeezing the content.
    if let page, let pdfView {
      remotePDFView?.frame = viewRect(page.bounds(for: .cropBox), page: page, pdfView: pdfView)
    } else {
      remotePDFView?.frame = bounds
    }
    markupView.frame = bounds
    bringSubviewToFront(markupView)
    bringSubviewToFront(progressView)
    if let refocusView { bringSubviewToFront(refocusView) }
    guard remotePageData == nil else {
      updateMarkup()
      return
    }
    for item in state.paragraphs {
      guard let label = labels[item.paragraph.id] else { continue }
      layoutLabel(label, item: item, forceFit: false)
    }
    updateMarkup()
  }

  @objc private func selectionChanged(_ notification: Notification) {
    guard let pdfView, notification.object as? PDFView === pdfView else { return }
    updateMarkup()
  }

  @objc private func scaleChanged(_ notification: Notification) {
    guard let pdfView, notification.object as? PDFView === pdfView else { return }
    cancelRefocus()
    labels.values.forEach { $0.updateRenderingScale(in: pdfView) }
  }

  private func updateMarkup() {
    let covers: [CGRect]
    var labelCovers = false
    if !showTranslations {
      covers = []
    } else if let remotePDFView, !remotePDFView.isHidden {
      covers = [remotePDFView.frame]
    } else {
      covers = labels.values.filter { !$0.isHidden }.map(\.frame)
      labelCovers = true
    }
    markupView.covers = covers
    guard !covers.isEmpty, let pdfView, let page else {
      markupView.highlights = []
      markupView.comments = []
      labels.values.forEach { $0.marks = [] }
      return
    }
    var highlights: [ReaderTranslationMarkupView.Highlight] = []
    var comments: [PDFAnnotation] = []
    for annotation in page.annotations {
      guard annotation.shouldDisplay else { continue }
      switch annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
      case "Highlight":
        let color = annotation.color.withAlphaComponent(1)
        for rect in markupRects(annotation) {
          highlights.append(.init(rect: viewRect(rect, page: page, pdfView: pdfView), color: color))
        }
      case "Text":
        comments.append(annotation)
      default:
        break
      }
    }
    // Labels paint highlights behind their own text; a separate layer on top
    // cannot blend with the label below it and would hide the translation.
    for label in labels.values {
      let frame = label.frame
      label.marks = labelCovers ? highlights.compactMap { highlight in
        let rect = highlight.rect.intersection(frame)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return .init(rect: rect.offsetBy(dx: -frame.minX, dy: -frame.minY), color: highlight.color)
      } : []
    }
    markupView.highlights = labelCovers ? [] : highlights
    markupView.comments = comments
    markupView.pageTransform = pageTransform(page: page, pdfView: pdfView)
  }

  /// Quad points are relative to the annotation origin; fall back to bounds.
  private func markupRects(_ annotation: PDFAnnotation) -> [CGRect] {
    let points = (annotation.quadrilateralPoints ?? []).map(\.cgPointValue)
    guard points.count >= 4 else { return [annotation.bounds] }
    let origin = annotation.bounds.origin
    return stride(from: 0, to: points.count - 3, by: 4).map { start in
      let quad = points[start..<start + 4].map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
      let xs = quad.map(\.x)
      let ys = quad.map(\.y)
      return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
  }

  private func viewRect(_ pageRect: CGRect, page: PDFPage, pdfView: PDFView) -> CGRect {
    convert(pdfView.convert(pageRect, from: page), from: pdfView).standardized
  }

  private func pageTransform(page: PDFPage, pdfView: PDFView) -> CGAffineTransform {
    let bounds = page.bounds(for: .cropBox)
    let view = viewRect(bounds, page: page, pdfView: pdfView)
    guard bounds.width > 0, bounds.height > 0 else { return .identity }
    return CGAffineTransform(translationX: view.minX, y: view.maxY)
      .scaledBy(x: view.width / bounds.width, y: -view.height / bounds.height)
      .translatedBy(x: -bounds.minX, y: -bounds.minY)
  }

  private func rebuildLabels(previousParagraphs: [PageTranslationParagraph] = []) {
    let translatedIDs = Set(state.paragraphs.filter {
      $0.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }.map { $0.paragraph.id })
    for id in Array(labels.keys) where !translatedIDs.contains(id) {
      labels.removeValue(forKey: id)?.removeFromSuperview()
    }
    let previous = Dictionary(previousParagraphs.map { ($0.paragraph.id, $0) }, uniquingKeysWith: { _, new in new })
    for item in state.paragraphs {
      guard translatedIDs.contains(item.paragraph.id) else { continue }
      if let label = labels[item.paragraph.id] {
        if previous[item.paragraph.id] != item {
          label.textAlignment = textAlignment(for: item.paragraph.textAlign)
          updateLabel(label, item: item)
        }
        continue
      }
      let label = ReaderTranslationLabel()
      label.tag = item.paragraph.id
      label.numberOfLines = 0
      label.lineBreakMode = .byWordWrapping
      label.textColor = ReaderDarkPDF.pageColor(.black)
      // Square cover, like the desktop box-shadow.
      label.coverColor = paperColor
      label.isUserInteractionEnabled = interactionMode == .comparison
      label.textAlignment = textAlignment(for: item.paragraph.textAlign)
      label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleParagraph(_:))))
      addSubview(label)
      labels[item.paragraph.id] = label
      updateLabel(label, item: item)
    }
    labels.values.forEach { $0.isHidden = !showTranslations }
  }

  private func updateLabel(_ label: ReaderTranslationLabel, item: PageTranslationParagraph) {
    layoutLabel(label, item: item, forceFit: true)
  }

  /// Desktop parity: the box is at least 1.1 x the font size tall, and a
  /// paper-colored margin of max(3, 0.28 x font size) around it hides the
  /// source ascenders and descenders. Sizes scale with the current zoom.
  private func layoutLabel(_ label: ReaderTranslationLabel, item: PageTranslationParagraph, forceFit: Bool) {
    let paragraph = item.paragraph
    let box = overlayRect(for: paragraph)
    let pdfArea = CGFloat(paragraph.width) * boxHeight(for: paragraph)
    let scale = pdfArea > 0 ? sqrt(max(0, box.width * box.height) / pdfArea) : 1
    let cover = max(3, CGFloat(paragraph.fontSize) * 0.28) * scale
    label.frame = pixelAligned(box.insetBy(dx: -cover, dy: -cover))
    if let pdfView { label.updateRenderingScale(in: pdfView) }
    // Let lines use half of the vertical cover so text keeps its source size.
    label.textInsets = UIEdgeInsets(top: cover / 2, left: cover, bottom: cover / 2, right: cover)

    let useOriginal = originalOverrides.contains(paragraph.id)
    let text = useOriginal ? paragraph.text : (item.translation ?? "")
    // Window pixel alignment shifts as the page scrolls. Fit against stable
    // page geometry so subpixel movement does not repeatedly measure the text.
    let size = box.insetBy(dx: -cover, dy: -cover).size
    guard forceFit ||
      text != label.fittedText ||
      abs(size.width - label.fittedSize.width) > 0.5 ||
      abs(size.height - label.fittedSize.height) > 0.5
    else { return }
    label.fittedSize = size
    label.fittedText = text
    let font = fittingFont(
      text: text,
      baseSize: max(6, min(36, CGFloat(paragraph.fontSize))) * scale,
      minimumSize: 6 * scale,
      available: CGSize(width: box.width, height: box.height + cover),
      bold: paragraph.bold,
      useOriginal: useOriginal
    )
    label.font = font
    label.attributedText = readingAidsAttributedString(
      text: text,
      font: font,
      configuration: readingAidsConfiguration,
      isOriginal: useOriginal
    )
  }

  /// Fractional edges leave a dark antialiased seam against the page.
  private func pixelAligned(_ rect: CGRect) -> CGRect {
    guard let window, rect.width > 0, rect.height > 0 else { return rect }
    let scale = max(1, traitCollection.displayScale)
    let inWindow = convert(rect, to: window)
    let minX = (inWindow.minX * scale).rounded(.down) / scale
    let minY = (inWindow.minY * scale).rounded(.down) / scale
    let maxX = (inWindow.maxX * scale).rounded(.up) / scale
    let maxY = (inWindow.maxY * scale).rounded(.up) / scale
    return convert(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), from: window)
  }

  private func boxHeight(for paragraph: LayoutParagraph) -> CGFloat {
    max(CGFloat(paragraph.height), CGFloat(paragraph.fontSize) * 1.1)
  }

  @objc private func toggleParagraph(_ recognizer: UITapGestureRecognizer) {
    guard interactionMode == .comparison, let label = recognizer.view as? ReaderTranslationLabel else { return }
    let previous = refocusSnapshot(in: label.frame)
    if originalOverrides.contains(label.tag) {
      originalOverrides.remove(label.tag)
    } else {
      originalOverrides.insert(label.tag)
    }
    guard let item = state.paragraphs.first(where: { $0.paragraph.id == label.tag }) else { return }
    updateLabel(label, item: item)
    refocus(from: previous)
  }

  /// Use public Core Image filters on a temporary, visible-region snapshot.
  /// UIKit's live text and PDFKit selection stay intact beneath the effect.
  private func cancelRefocus() {
    refocusGeneration &+= 1
    refocusTask?.cancel()
    refocusTask = nil
    refocusPendingBounds = nil
    guard !isUpdatingRendering else { return }
    refocusView?.removeFromSuperview()
    refocusView = nil
  }

  private func refocusSnapshot(in region: CGRect) -> ReaderRefocusSnapshot? {
    guard !UIAccessibility.isReduceMotionEnabled, let window, let pdfView else { return nil }
    guard !readerPDFInteractionIsActive(pdfView) else {
      cancelRefocus()
      return nil
    }
    layoutIfNeeded()
    let visible = convert(pdfView.bounds, from: pdfView)
      .intersection(convert(window.bounds, from: window))
    let rect = region.intersection(bounds).intersection(visible).integral
    guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
    // Map the view's basis vectors rather than an axis-aligned rectangle,
    // preserving PDFKit's zoom and rotated-page transforms.
    let origin = convert(CGPoint.zero, from: pdfView)
    let x = convert(CGPoint(x: 1, y: 0), from: pdfView)
    let y = convert(CGPoint(x: 0, y: 1), from: pdfView)
    let transform = CGAffineTransform(
      a: x.x - origin.x, b: x.y - origin.y,
      c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y
    )
    let format = UIGraphicsImageRendererFormat()
    let preferredScale = min(2, max(1, traitCollection.displayScale))
    let budgetScale = sqrt(Self.refocusPixelBudget / max(1, rect.width * rect.height))
    format.scale = min(preferredScale, budgetScale)
    var captured = false
    let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
      context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
      context.cgContext.concatenate(transform)
      // Reuse the currently visible PDF tiles. Asking for fresh screen
      // updates here can synchronously rasterize a destination page while a
      // visibility change is trying to start its transition.
      captured = pdfView.drawHierarchy(in: pdfView.bounds, afterScreenUpdates: false)
    }
    // Capture the visible intermediate state before removing an interrupted
    // effect, so a quick reverse toggle starts from what the reader saw.
    cancelRefocus()
    guard captured, let cgImage = image.cgImage else { return nil }
    return ReaderRefocusSnapshot(
      rect: rect,
      image: ReaderRefocusImage(cgImage: cgImage, scale: format.scale)
    )
  }

  private func refocus(from previous: ReaderRefocusSnapshot?) {
    guard let previous, let current = refocusSnapshot(in: previous.rect) else { return }
    guard let expectedWindow = window, let expectedPDFView = pdfView else { return }
    let generation = refocusGeneration &+ 1
    refocusGeneration = generation
    let expectedBounds = bounds
    refocusPendingBounds = expectedBounds

    // Keep the last presented frame visible while the utility worker prepares
    // the transition, avoiding a flash of new content followed by the old one.
    let holding = UIImageView(image: UIImage(
      cgImage: previous.image.cgImage, scale: previous.image.scale, orientation: .up
    ))
    holding.frame = previous.rect
    holding.isUserInteractionEnabled = false
    holding.accessibilityElementsHidden = true
    addSubview(holding)
    refocusView = holding
    refocusBounds = expectedBounds

    let preparation = Task.detached(priority: .utility) {
      () -> ReaderRefocusPreparedImages? in
      guard !Task.isCancelled else { return nil }
      let context = CIContext()
      let soft = readerRefocusImage(current.image, blur: 3, contrast: 1.06, context: context)
      guard !Task.isCancelled else { return nil }
      let blurred = readerRefocusImage(current.image, blur: 7, contrast: 1.12, context: context)
      guard !Task.isCancelled else { return nil }
      let outgoing = readerRefocusImage(previous.image, blur: 9, contrast: 1, context: context)
      guard !Task.isCancelled else { return nil }
      return ReaderRefocusPreparedImages(
        incoming: current.image, soft: soft, blurred: blurred, outgoing: outgoing
      )
    }

    refocusTask = Task { @MainActor [weak self] in
      defer {
        if let self, self.refocusGeneration == generation {
          self.refocusTask = nil
          self.refocusPendingBounds = nil
          if self.refocusView === holding {
            holding.removeFromSuperview()
            self.refocusView = nil
          }
        }
      }
      let prepared = await withTaskCancellationHandler(operation: {
        await preparation.value
      }, onCancel: {
        preparation.cancel()
      })
      guard !Task.isCancelled, let prepared, let self,
            self.refocusGeneration == generation,
            self.bounds == expectedBounds,
            self.window === expectedWindow,
            self.pdfView === expectedPDFView,
            !UIAccessibility.isReduceMotionEnabled,
            !readerPDFInteractionIsActive(expectedPDFView) else { return }
      self.installRefocus(prepared, previous: previous.image, rect: current.rect)
    }
  }

  @MainActor
  private func installRefocus(
    _ prepared: ReaderRefocusPreparedImages,
    previous: ReaderRefocusImage,
    rect: CGRect
  ) {
    let effect = UIView(frame: rect)
    effect.accessibilityIdentifier = "reader.translationRefocus"
    effect.isUserInteractionEnabled = false
    effect.accessibilityElementsHidden = true
    effect.clipsToBounds = true
    effect.backgroundColor = paperColor

    func imageView(_ image: ReaderRefocusImage, in container: UIView) -> UIImageView {
      let uiImage = UIImage(cgImage: image.cgImage, scale: image.scale, orientation: .up)
      let view = UIImageView(image: uiImage)
      view.frame = container.bounds
      container.addSubview(view)
      return view
    }
    func opacity(_ view: UIView, values: [Double], times: [Double], duration: Double, outgoing: Bool = false) {
      let animation = CAKeyframeAnimation(keyPath: "opacity")
      animation.values = values
      animation.keyTimes = times.map { NSNumber(value: $0) }
      animation.duration = duration
      animation.timingFunctions = (1..<values.count).map { _ in
        outgoing ? CAMediaTimingFunction(name: .easeOut)
          : CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.2, 1)
      }
      view.layer.opacity = Float(values.last ?? 1)
      view.layer.add(animation, forKey: "digitalRefocus")
    }

    let incoming = UIView(frame: effect.bounds)
    effect.addSubview(incoming)
    _ = imageView(prepared.incoming, in: incoming)
    let soft = imageView(prepared.soft, in: incoming)
    let blurred = imageView(prepared.blurred, in: incoming)
    let outgoing = imageView(prepared.outgoing, in: effect)
    let sharpOutgoing = imageView(previous, in: outgoing)
    refocusView?.removeFromSuperview()
    addSubview(effect)
    refocusView = effect
    refocusBounds = bounds

    // Desktop: incoming blur 7 → 3 → 0 and opacity .45 → .85 → 1
    // over 520 ms; the previous text blurs away over 260 ms.
    opacity(incoming, values: [0.45, 0.85, 1], times: [0, 0.4, 1], duration: 0.52)
    opacity(blurred, values: [1, 0, 0], times: [0, 0.4, 1], duration: 0.52)
    opacity(soft, values: [1, 1, 0], times: [0, 0.4, 1], duration: 0.52)
    opacity(outgoing, values: [1, 0], times: [0, 1], duration: 0.26, outgoing: true)
    opacity(sharpOutgoing, values: [1, 0], times: [0, 1], duration: 0.26, outgoing: true)
    Task { @MainActor [weak self, weak effect] in
      try? await Task.sleep(for: .milliseconds(520))
      effect?.removeFromSuperview()
      if self?.refocusView === effect { self?.refocusView = nil }
    }
  }

  private func overlayRect(for paragraph: LayoutParagraph) -> CGRect {
    guard let pdfView, let page else { return .zero }
    let bounds = page.bounds(for: .cropBox)
    let height = boxHeight(for: paragraph)
    let compact = (page as? ReaderPDFPage)?.compaction
    let sourceRect = ReadingRectangle(x: paragraph.x, y: paragraph.y,
                                      width: paragraph.width, height: Double(height))
    let mapped = compact?.displayRect(sourceRect) ?? sourceRect
    let pdfRect = CGRect(
      x: bounds.minX + CGFloat(mapped.x),
      y: bounds.maxY - CGFloat(mapped.y) - CGFloat(mapped.height),
      width: CGFloat(mapped.width),
      height: CGFloat(mapped.height)
    )
    let viewRect = pdfView.convert(pdfRect, from: page)
    return convert(viewRect, from: pdfView).standardized
  }

  private func fittingFont(
    text: String,
    baseSize: CGFloat,
    minimumSize: CGFloat,
    available: CGSize,
    bold: Bool,
    useOriginal: Bool
  ) -> UIFont {
    let selectedFont = ReaderTranslationFont.resolve(
      name: useOriginal ? "" : translationFontName,
      serif: !useOriginal && translationSerif,
      size: baseSize,
      bold: bold,
      language: useOriginal ? "" : translationLanguage
    )
    let available = CGSize(width: max(1, available.width), height: max(1, available.height))
    let step = max(0.25, baseSize / 40)
    var size = baseSize
    while size > minimumSize {
      let font = selectedFont.withSize(size)
      let measured = (text as NSString).boundingRect(
        with: CGSize(width: available.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      if measured.height <= available.height {
        return font
      }
      size -= step
    }
    return selectedFont.withSize(max(1, minimumSize))
  }

  private func textAlignment(for value: String?) -> NSTextAlignment {
    switch value {
    case "center": .center
    case "right": .right
    default: .left
    }
  }

  private func updateProgress() {
    if let remoteProgress {
      progressView.update(.measured(remoteProgress), visible: showTranslations && remoteProgress < 1)
      return
    }
    let active = state.status == .queued || state.status == .extracting || state.status == .translating
    let mode: ReaderPageProgressView.Mode = state.status == .queued ? .queued
      : state.status == .extracting || state.paragraphs.isEmpty ? .loading : .measured(state.progress)
    progressView.update(mode, visible: active && showTranslations && remotePageData == nil)
  }

  /// Covers match the page under them, which dark appearance inverts.
  private var paperColor: UIColor {
    ReaderDarkPDF.pageColor(.white)
  }

  private func updateRemotePDF() {
    guard let remotePageData, let remotePDFView else { return }
    // Font changes regenerate vectors once; zooming only requests new tiles.
    let customFont = !translationFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translationSerif
    if customFont, remoteFontRenderer == nil,
       let document = PDFDocument(data: remotePageData), let translated = document.page(at: 0) {
      remoteFontRenderer = ReaderRemoteTranslationFont(page: translated, original: page)
    }
    let request = RemoteFontRequest(
      name: translationFontName, serif: translationSerif, language: translationLanguage
    )
    let data: Data
    if !customFont {
      data = remotePageData
    } else if let cached = cachedRemoteFontPDF, cached.request == request {
      data = cached.data
    } else if let rendered = try? remoteFontRenderer?.pdfData(
      name: request.name, serif: request.serif, language: request.language
    ) {
      // Annotation edits rebind the source page. The remote text/font output
      // remains identical; retain only the most recent generated variant.
      cachedRemoteFontPDF = (request, rendered)
      data = rendered
    } else {
      data = remotePageData
    }
    var displayData = data
    if let compact = (page as? ReaderPDFPage)?.compaction,
       let translatedDocument = PDFDocument(data: data), let translated = translatedDocument.page(at: 0),
       let compactData = compact.pdfData(for: translated) {
      displayData = compactData
    }
    remotePDFView.setPDFData(displayData)
    remotePDFView.setInverted(traitCollection.userInterfaceStyle == .dark)
  }
}
