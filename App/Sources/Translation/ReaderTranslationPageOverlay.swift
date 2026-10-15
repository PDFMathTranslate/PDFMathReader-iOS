import PDFKit
import ReaderCore
import UIKit

@MainActor
final class ReaderTranslationLabel: UILabel {
  var textInsets = UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)

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
    for paragraph in state.paragraphs {
      guard let label = labels[paragraph.paragraph.id] else { continue }
      label.frame = overlayRect(for: paragraph.paragraph)
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
      label.backgroundColor = paperColor
      label.isOpaque = true
      label.layer.cornerRadius = 2
      label.layer.masksToBounds = true
      label.isUserInteractionEnabled = true
      label.textAlignment = textAlignment(for: item.paragraph.textAlign)
      label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleParagraph(_:))))
      addSubview(label)
      labels[item.paragraph.id] = label
      updateLabel(label, item: item)
    }
  }

  private func updateLabel(_ label: ReaderTranslationLabel, item: PageTranslationParagraph) {
    let useOriginal = originalOverrides.contains(item.paragraph.id)
    let text = useOriginal ? item.paragraph.text : (item.translation ?? "")
    label.text = text
    let baseSize = max(6, min(36, CGFloat(item.paragraph.fontSize)))
    let rect = overlayRect(for: item.paragraph)
    let font = fittingFont(
      text: text,
      baseSize: baseSize,
      rect: rect,
      bold: item.paragraph.bold
    )
    label.font = font
    label.attributedText = readingAidsAttributedString(
      text: text,
      font: font,
      configuration: readingAidsConfiguration,
      isOriginal: useOriginal
    )
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
    let pdfRect = CGRect(
      x: bounds.minX + CGFloat(paragraph.x),
      y: bounds.minY + bounds.height - CGFloat(paragraph.y) - CGFloat(paragraph.height),
      width: CGFloat(paragraph.width),
      height: CGFloat(paragraph.height)
    )
    let viewRect = pdfView.convert(pdfRect, from: page)
    return convert(viewRect, from: pdfView).standardized
  }

  private func fittingFont(text: String, baseSize: CGFloat, rect: CGRect, bold: Bool) -> UIFont {
    let padding = max(3, baseSize * 0.28)
    let available = CGSize(
      width: max(1, rect.width - padding * 2),
      height: max(1, rect.height - padding * 2)
    )
    var size = baseSize
    while size >= 6 {
      let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
      let measured = (text as NSString).boundingRect(
        with: available,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      if measured.height <= max(available.height, size * 1.1) {
        return font
      }
      size -= 0.5
    }
    return UIFont.systemFont(ofSize: 6, weight: bold ? .semibold : .regular)
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
        : UIColor(white: 0.98, alpha: 1)
    }
  }
}
