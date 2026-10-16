import PDFKit
import ReaderCore
import UIKit

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
  private var originalOverrides = Set<Int>()
  private var labels: [Int: ReaderTranslationLabel] = [:]
  private var remotePageData: Data?
  private var remoteImageView: UIImageView?
  private let progressView = UIProgressView(progressViewStyle: .bar)
  private let markupView = ReaderTranslationMarkupView()

  init(pageIndex: Int, page: PDFPage, pdfView: PDFView) {
    self.pageIndex = pageIndex
    self.page = page
    self.pdfView = pdfView
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    progressView.trackTintColor = UIColor.secondaryLabel.withAlphaComponent(0.15)
    progressView.progressTintColor = UIColor.secondaryLabel.withAlphaComponent(0.65)
    progressView.alpha = 0
    addSubview(progressView)
    addSubview(markupView)
    isAccessibilityElement = false
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (overlay: Self, _) in
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
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(
    state: PageTranslationState,
    showTranslations: Bool
  ) {
    self.state = state
    self.showTranslations = showTranslations
    if remotePageData == nil {
      rebuildLabels()
    } else {
      remoteImageView?.isHidden = !showTranslations
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
    self.page = page
    self.pdfView = pdfView
    setNeedsLayout()
  }

  func setTranslationFont(name: String, serif: Bool) {
    guard name != translationFontName || serif != translationSerif else { return }
    translationFontName = name
    translationSerif = serif
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

  /// Applies visibility with the last known state, even if the coordinator
  /// has no state for this page right now (e.g. during a pipeline restart).
  func setTranslationsVisible(_ visible: Bool) {
    update(state: state, showTranslations: visible)
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
    readingAidsConfiguration = configuration
    guard remotePageData == nil else { return }
    for item in state.paragraphs {
      guard let label = labels[item.paragraph.id] else { continue }
      updateLabel(label, item: item)
    }
    setNeedsLayout()
  }

  func setRemotePageData(_ data: Data) {
    remotePageData = data
    labels.values.forEach { $0.removeFromSuperview() }
    labels.removeAll()
    remoteImageView?.removeFromSuperview()
    remoteImageView = nil
    if let translated = PDFDocument(data: data)?.page(at: 0) {
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      imageView.backgroundColor = paperColor
      imageView.isOpaque = true
      imageView.image = remoteImage(for: translated)
      imageView.isHidden = !showTranslations
      addSubview(imageView)
      remoteImageView = imageView
    }
    progressView.progress = 1
    progressView.alpha = 0
    setNeedsLayout()
  }

  func clearRemotePageData() {
    remotePageData = nil
    remoteImageView?.removeFromSuperview()
    remoteImageView = nil
    rebuildLabels()
    updateProgress()
    setNeedsLayout()
  }

  func setRemoteProgress(_ progress: Double) {
    progressView.progress = Float(min(1, max(0, progress)))
    progressView.alpha = showTranslations && progress < 1 ? 1 : 0
  }

  func beginRemoteTranslation() {
    remotePageData = nil
    progressView.progress = 0
    progressView.alpha = showTranslations ? 1 : 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    progressView.frame = CGRect(
      x: 8,
      y: 4,
      width: max(1, min(120, bounds.width - 16)),
      height: 2
    )
    remoteImageView?.frame = bounds
    if let remotePageData,
       bounds.width > 0,
       bounds.height > 0,
       let translated = PDFDocument(data: remotePageData)?.page(at: 0) {
      remoteImageView?.image = remoteImage(for: translated)
    }
    markupView.frame = bounds
    bringSubviewToFront(markupView)
    bringSubviewToFront(progressView)
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

  private func updateMarkup() {
    let covers: [CGRect]
    var labelCovers = false
    if !showTranslations {
      covers = []
    } else if let remoteImageView, !remoteImageView.isHidden {
      covers = [remoteImageView.frame]
    } else {
      covers = labels.values.map(\.frame)
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

  private func rebuildLabels() {
    labels.values.forEach { $0.removeFromSuperview() }
    labels.removeAll()
    guard showTranslations else { return }
    for item in state.paragraphs {
      guard item.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
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
    // Let lines use half of the vertical cover so text keeps its source size.
    label.textInsets = UIEdgeInsets(top: cover / 2, left: cover, bottom: cover / 2, right: cover)

    let useOriginal = originalOverrides.contains(paragraph.id)
    let text = useOriginal ? paragraph.text : (item.translation ?? "")
    let size = label.bounds.size
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
    if originalOverrides.contains(label.tag) {
      originalOverrides.remove(label.tag)
    } else {
      originalOverrides.insert(label.tag)
    }
    guard let item = state.paragraphs.first(where: { $0.paragraph.id == label.tag }) else { return }
    updateLabel(label, item: item)
  }

  private func overlayRect(for paragraph: LayoutParagraph) -> CGRect {
    guard let pdfView, let page else { return .zero }
    let bounds = page.bounds(for: .cropBox)
    let height = boxHeight(for: paragraph)
    let pdfRect = CGRect(
      x: bounds.minX + CGFloat(paragraph.x),
      y: bounds.minY + bounds.height - CGFloat(paragraph.y) - height,
      width: CGFloat(paragraph.width),
      height: height
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
      size: baseSize, bold: bold
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
    progressView.progress = Float(state.progress)
    let active = state.status == .queued || state.status == .extracting || state.status == .translating
    progressView.alpha = active && showTranslations ? 1 : 0
  }

  /// Covers match the page under them, which dark appearance inverts.
  private var paperColor: UIColor {
    ReaderDarkPDF.pageColor(.white)
  }

  private func remoteImage(for page: PDFPage) -> UIImage {
    let image = page.thumbnail(of: bounds.size, for: .cropBox)
    return traitCollection.userInterfaceStyle == .dark ? ReaderDarkPDF.inverted(image) : image
  }
}
