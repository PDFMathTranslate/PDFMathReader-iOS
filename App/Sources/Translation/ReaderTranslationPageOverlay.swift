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
    super.drawText(in: rect.inset(by: textInsets))
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
  private var readingAidsConfiguration = ReadingAidsConfiguration()
  private var originalOverrides = Set<Int>()
  private var labels: [Int: ReaderTranslationLabel] = [:]
  private var remotePageData: Data?
  private var remoteImageView: UIImageView?
  private let progressView = UIProgressView(progressViewStyle: .bar)

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
    isAccessibilityElement = false
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
      imageView.image = translated.thumbnail(of: bounds.size, for: .cropBox)
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
      remoteImageView?.image = translated.thumbnail(of: bounds.size, for: .cropBox)
    }
    bringSubviewToFront(progressView)
    guard remotePageData == nil else { return }
    for item in state.paragraphs {
      guard let label = labels[item.paragraph.id] else { continue }
      layoutLabel(label, item: item, forceFit: false)
    }
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
      label.textColor = .label
      // Square cover, like the desktop box-shadow.
      label.coverColor = paperColor
      label.isUserInteractionEnabled = true
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
      bold: paragraph.bold
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
    guard let label = recognizer.view as? ReaderTranslationLabel else { return }
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
    bold: Bool
  ) -> UIFont {
    let weight: UIFont.Weight = bold ? .semibold : .regular
    let available = CGSize(width: max(1, available.width), height: max(1, available.height))
    let step = max(0.25, baseSize / 40)
    var size = baseSize
    while size > minimumSize {
      let font = UIFont.systemFont(ofSize: size, weight: weight)
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
    return UIFont.systemFont(ofSize: max(1, minimumSize), weight: weight)
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

  private var paperColor: UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(white: 0.14, alpha: 1)
        : .white
    }
  }
}
