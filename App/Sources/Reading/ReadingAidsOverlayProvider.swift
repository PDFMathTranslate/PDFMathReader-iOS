import Combine
import Foundation
import PDFKit
import ReaderCore
import SwiftUI
import UIKit

@MainActor
public protocol ReadingAidsConfigurationProviding: AnyObject {
  var readingAidsConfiguration: ReadingAidsConfiguration { get }
}

private struct ReadingAidsGlyph: Equatable, Sendable {
  var index: Int
  var text: String
  var bounds: CGRect
}

private struct ReadingAidsPageData: Equatable, Sendable {
  var text: String
  var glyphs: [ReadingAidsGlyph]
  var paragraphs: [LayoutParagraph]
}

private struct ReadingAidsLink: Equatable, Sendable {
  var url: URL
  var label: String
  var range: ReadingRange
}

private struct ReadingAidsPageAnalysis: Equatable, Sendable {
  var informationRanges: [InformationRange]
  var topicRanges: [ReadingRange]
  var tfidfRanges: [TfidfRange]
  var links: [ReadingAidsLink]
}

private struct ReadingAidsAnalysisSource: Sendable {
  var url: URL?
  var data: Data?
}

private struct ReadingAidsAnalysisResult: Sendable {
  var data: ReadingAidsPageData
  var analysis: ReadingAidsPageAnalysis
}

private extension ReadingAidsPageData {
  static let empty = ReadingAidsPageData(text: "", glyphs: [], paragraphs: [])
}

private extension ReadingAidsPageAnalysis {
  static let empty = ReadingAidsPageAnalysis(
    informationRanges: [],
    topicRanges: [],
    tfidfRanges: [],
    links: []
  )
}

/// Supplies cached, page-local drawing and interaction layers for reading aids.
@MainActor
public final class ReadingAidsOverlayProvider: ObservableObject, ReaderPageOverlayProviding, ReadingAidsConfigurationProviding {
  public let document: PDFDocument
  public let documentID: String
  public private(set) var readingAidsConfiguration: ReadingAidsConfiguration

  private let analysisSource: ReadingAidsAnalysisSource
  private var pageData: [Int: ReadingAidsPageData] = [:]
  private var overlays: [Int: ReadingAidsPageOverlay] = [:]
  private var analyses: [Int: ReadingAidsPageAnalysis] = [:]
  private var analysisGeneration = 0
  private var pendingAnalysisTasks: [Int: Task<Void, Never>] = [:]
  private var configurationObservers: [UUID: (ReadingAidsConfiguration) -> Void] = [:]
  // PDFKit can keep one overlay per page alive after it scrolls off screen.
  // Converted glyph rectangles are display-state geometry, so retain it only
  // for the most recently requested pages.
  private var geometryAccessOrder: [Int] = []
  private let maximumCachedGeometryPages = 8

  public init(
    document: PDFDocument,
    preferences: ReaderPreferences,
    documentID: String = "",
    sourceData: Data? = nil
  ) {
    self.document = document
    self.documentID = documentID
    let sourceURL = document.documentURL
    let suppliedSourceData = sourceData?.isEmpty == false ? sourceData : nil
    self.analysisSource = ReadingAidsAnalysisSource(
      url: sourceURL,
      data: suppliedSourceData ?? (sourceURL == nil ? document.dataRepresentation() : nil)
    )
    self.readingAidsConfiguration = ReadingAidsConfiguration(preferences: preferences)
  }

  isolated deinit {
    pendingAnalysisTasks.values.forEach { $0.cancel() }
  }

  public func updatePreferences(_ preferences: ReaderPreferences) {
    let next = ReadingAidsConfiguration(preferences: preferences)
    guard next != readingAidsConfiguration else { return }
    objectWillChange.send()
    readingAidsConfiguration = next
    analysisGeneration &+= 1
    pendingAnalysisTasks.values.forEach { $0.cancel() }
    pendingAnalysisTasks.removeAll(keepingCapacity: true)
    analyses.removeAll(keepingCapacity: true)
    for (pageIndex, overlay) in overlays {
      overlay.update(accentColor: next.emphasisColor)
      overlay.update(analysis: .empty)
      if next.hasOriginalOverlay {
        requestAnalysis(for: pageIndex)
      }
    }
    configurationObservers.values.forEach { $0(next) }
  }

  func addConfigurationObserver(
    _ observer: @escaping (ReadingAidsConfiguration) -> Void
  ) -> UUID {
    let token = UUID()
    configurationObservers[token] = observer
    observer(readingAidsConfiguration)
    return token
  }

  func removeConfigurationObserver(_ token: UUID) {
    configurationObservers.removeValue(forKey: token)
  }

  public func overlayView(for page: PDFPage, in pdfView: PDFView) -> UIView? {
    // Annotation edits swap in a new PDFDocument; see ReaderTranslationCoordinator.
    let pageIndex = pdfView.document?.index(for: page) ?? document.index(for: page)
    guard pageIndex != NSNotFound, pageIndex < document.pageCount,
      readingAidsConfiguration.hasOriginalOverlay
    else { return nil }

    let overlay: ReadingAidsPageOverlay
    if let existing = overlays[pageIndex] {
      overlay = existing
      overlay.rebind(page: page, pdfView: pdfView)
    } else {
      overlay = ReadingAidsPageOverlay(page: page, pdfView: pdfView, data: pageData[pageIndex] ?? .empty)
      overlays[pageIndex] = overlay
    }
    touchGeometry(for: pageIndex)
    overlay.update(accentColor: readingAidsConfiguration.emphasisColor)
    overlay.update(data: pageData[pageIndex] ?? .empty)
    overlay.update(analysis: analyses[pageIndex] ?? .empty)
    if pageData[pageIndex] == nil {
      requestAnalysis(for: pageIndex)
    }
    return overlay
  }

  public func didEndDisplayingOverlay(_ root: UIView, for page: PDFPage, in pdfView: PDFView) {
    let retired = overlays.compactMap { index, overlay in
      overlay === root || overlay.isDescendant(of: root) ? index : nil
    }
    for index in retired { overlays.removeValue(forKey: index) }
    geometryAccessOrder.removeAll { retired.contains($0) }
  }

  private func touchGeometry(for pageIndex: Int) {
    geometryAccessOrder.removeAll { $0 == pageIndex }
    geometryAccessOrder.append(pageIndex)
    guard geometryAccessOrder.count > maximumCachedGeometryPages else { return }
    let evictedPage = geometryAccessOrder.removeFirst()
    if overlays[evictedPage]?.superview == nil {
      overlays.removeValue(forKey: evictedPage)
    } else {
      overlays[evictedPage]?.discardGeometryCache()
    }
  }

  private func requestAnalysis(for pageIndex: Int) {
    guard pendingAnalysisTasks[pageIndex] == nil else { return }
    let source = analysisSource
    let configuration = readingAidsConfiguration
    let generation = analysisGeneration
    let task = Task { @MainActor [weak self, source, configuration, generation] in
      let result = await Task.detached(priority: .utility) {
        ReadingAidsOverlayProvider.makePageAnalysis(
          source: source,
          pageIndex: pageIndex,
          configuration: configuration
        )
      }.value
      guard !Task.isCancelled, let self else { return }
      guard self.analysisGeneration == generation,
        self.readingAidsConfiguration == configuration
      else { return }
      self.pendingAnalysisTasks[pageIndex] = nil
      guard let result else { return }
      self.pageData[pageIndex] = result.data
      self.analyses[pageIndex] = result.analysis
      guard let overlay = self.overlays[pageIndex] else { return }
      overlay.update(data: result.data)
      overlay.update(analysis: result.analysis)
    }
    pendingAnalysisTasks[pageIndex] = task
  }

  nonisolated private static func makePageAnalysis(
    source: ReadingAidsAnalysisSource,
    pageIndex: Int,
    configuration: ReadingAidsConfiguration
  ) -> ReadingAidsAnalysisResult? {
    guard let document = makeIndependentDocument(from: source),
      pageIndex >= 0, pageIndex < document.pageCount,
      let page = document.page(at: pageIndex)
    else { return nil }

    let data = makePageData(page: page, pageIndex: pageIndex)
    var corpus: TermCorpus?
    if configuration.tfidfWeightingEnabled {
      let prepared = TermCorpus()
      let pages = sampleTfidfPageNumbers(
        count: document.pageCount,
        size: tfidfSamplePages,
        random: { 0.5 }
      )
      for pageNumber in pages {
        guard let corpusPage = document.page(at: pageNumber - 1) else { continue }
        let text = corpusPage.string ?? ""
        _ = try? prepared.add(
          corpusID(pageNumber - 1),
          terms: tfidfTermSet([text])
        )
      }
      corpus = prepared
    }

    return ReadingAidsAnalysisResult(
      data: data,
      analysis: makeAnalysis(
        for: data,
        pageIndex: pageIndex,
        configuration: configuration,
        corpus: corpus
      )
    )
  }

  nonisolated private static func makeIndependentDocument(
    from source: ReadingAidsAnalysisSource
  ) -> PDFDocument? {
    if let data = source.data, !data.isEmpty,
      let document = PDFDocument(data: data)
    {
      return document
    }
    guard let url = source.url else { return nil }
    return PDFDocument(url: url)
  }

  nonisolated private static func makePageData(page: PDFPage, pageIndex: Int) -> ReadingAidsPageData {
    let text = page.string ?? ""
    let pageString = text as NSString
    var glyphs: [ReadingAidsGlyph] = []
    glyphs.reserveCapacity(pageString.length)
    for index in 0..<pageString.length {
      let bounds = page.characterBounds(at: index)
      guard bounds.width > 0, bounds.height > 0,
        bounds.minX.isFinite, bounds.minY.isFinite,
        bounds.width.isFinite, bounds.height.isFinite
      else { continue }
      glyphs.append(
        ReadingAidsGlyph(
          index: index,
          text: pageString.substring(with: NSRange(location: index, length: 1)),
          bounds: bounds
        )
      )
    }

    let items = PDFKitTextExtractor.extract(page: page, pageNumber: pageIndex + 1)
    let pageHeight = Double(page.bounds(for: .cropBox).height)
    return ReadingAidsPageData(
      text: text,
      glyphs: glyphs,
      paragraphs: LayoutEngine.paragraphs(items: items, pageHeight: pageHeight)
    )
  }

  nonisolated private static func makeAnalysis(
    for data: ReadingAidsPageData,
    pageIndex: Int,
    configuration: ReadingAidsConfiguration,
    corpus: TermCorpus?
  ) -> ReadingAidsPageAnalysis {
    let information = configuration.emphasizeInformation
      ? importantInformationRanges(data.text, categories: configuration.informationCategories)
      : []
    let topic = configuration.emphasizeTopicSentences
      ? topicRanges(in: data.text, paragraphs: data.paragraphs)
      : []

    var tfidf: [TfidfRange] = []
    if configuration.tfidfWeightingEnabled,
      let corpus,
      corpus.documentCount() >= tfidfMinimumDocuments
    {
      let terms = tfidfTermSet([data.text])
      if let values = try? corpus.frequencies(excluding: corpusID(pageIndex), terms: terms) {
        let frequencyByTerm = Dictionary(uniqueKeysWithValues: zip(terms, values.frequencies))
        tfidf = tfidfRanges(
          data.text,
          documents: values.documents,
          frequency: { frequencyByTerm[$0, default: 0] }
        )
      }
    }

    let links = configuration.readingLinksEnabled
      ? detectedLinks(in: data.text)
      : []
    return ReadingAidsPageAnalysis(
      informationRanges: information,
      topicRanges: topic,
      tfidfRanges: tfidf,
      links: links
    )
  }

  nonisolated private static func corpusID(_ pageIndex: Int) -> String {
    String(format: "%064x", max(0, pageIndex))
  }

  nonisolated private static func topicRanges(
    in text: String,
    paragraphs: [LayoutParagraph]
  ) -> [ReadingRange] {
    var result: [ReadingRange] = []
    var searchStart = 0
    for paragraph in paragraphs {
      let length = topicSentenceLength(paragraph.text)
      guard length > 0,
        let target = utf16Prefix(paragraph.text, length: length),
        let match = findWhitespaceTolerant(target, in: text, from: searchStart)
      else { continue }
      result.append(ReadingRange(start: match.location, end: match.location + match.length))
      searchStart = match.location + match.length
    }
    return result
  }

  nonisolated private static func detectedLinks(in text: String) -> [ReadingAidsLink] {
    var values: [String] = []
    values.append(contentsOf: detectLinks(text))
    values.append(contentsOf: detectEmails(text).map { "mailto:\($0)" })
    var result: [ReadingAidsLink] = []
    var searchStart = 0
    for value in values where result.count < maxDetectedLinks {
      guard let url = URL(string: value),
        let range = findLinkRange(value, in: text, from: searchStart)
      else { continue }
      result.append(
        ReadingAidsLink(
          url: url,
          label: value.hasPrefix("mailto:") ? String(value.dropFirst(7)) : linkLabel(value),
          range: ReadingRange(start: range.location, end: range.location + range.length)
        )
      )
      searchStart = range.location + range.length
    }
    return result
  }
}

@MainActor
public final class ReaderPageOverlayCompositeProvider: ReaderPageOverlayProviding, ReadingAidsConfigurationProviding {
  public var readingAidsConfiguration: ReadingAidsConfiguration {
    readingProvider?.readingAidsConfiguration ?? ReadingAidsConfiguration()
  }

  private let providers: [any ReaderPageOverlayProviding]
  private var composites: [Int: ReadingAidsCompositePageOverlay] = [:]
  private weak var readingProvider: ReadingAidsOverlayProvider?
  private var configurationObserverToken: UUID?

  public init(providers: [any ReaderPageOverlayProviding]) {
    self.providers = providers
    readingProvider = providers
      .compactMap { $0 as? ReadingAidsOverlayProvider }
      .first
    if let readingProvider {
      configurationObserverToken = readingProvider.addConfigurationObserver { [weak self] configuration in
        self?.updateTranslationOverlays(configuration)
      }
    }
  }

  isolated deinit {
    if let readingProvider, let configurationObserverToken {
      readingProvider.removeConfigurationObserver(configurationObserverToken)
    }
  }

  public func overlayView(for page: PDFPage, in pdfView: PDFView) -> UIView? {
    let views = providers.compactMap { provider -> UIView? in
      let view = provider.overlayView(for: page, in: pdfView)
      configureTranslationOverlay(view)
      return view
    }
    guard !views.isEmpty else { return nil }
    guard views.count > 1 else { return views[0] }

    let pageIndex = pdfView.document?.index(for: page) ?? NSNotFound
    guard pageIndex != NSNotFound else { return views[0] }
    if composites[pageIndex] == nil, composites.count >= 8 {
      let detached = composites.filter { $0.value.superview == nil }
      for (index, composite) in detached {
        guard composites.count >= 8 else { break }
        let retiredPage = pdfView.document?.page(at: index) ?? page
        didEndDisplayingOverlay(composite, for: retiredPage, in: pdfView)
      }
    }
    let composite = composites[pageIndex] ?? {
      let value = ReadingAidsCompositePageOverlay()
      composites[pageIndex] = value
      return value
    }()
    composite.replace(views: views)
    return composite
  }

  public func didEndDisplayingOverlay(_ root: UIView, for page: PDFPage, in pdfView: PDFView) {
    providers.forEach { $0.didEndDisplayingOverlay(root, for: page, in: pdfView) }
    let retired = composites.compactMap { index, composite in
      composite === root || composite.isDescendant(of: root) ? index : nil
    }
    for index in retired { composites.removeValue(forKey: index) }
  }

  private func configureTranslationOverlay(_ view: UIView?) {
    guard let view, let configuration = readingProvider?.readingAidsConfiguration else { return }
    (view as? ReaderTranslationPageOverlay)?.updateReadingAids(configuration)
  }

  private func updateTranslationOverlays(_ configuration: ReadingAidsConfiguration) {
    composites.values
      .flatMap(\.subviews)
      .compactMap { $0 as? ReaderTranslationPageOverlay }
      .forEach { $0.updateReadingAids(configuration) }
  }
}

@MainActor
private final class ReadingAidsCompositePageOverlay: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
  }

  required init?(coder: NSCoder) {
    nil
  }

  func replace(views: [UIView]) {
    subviews.forEach { $0.removeFromSuperview() }
    views.forEach { addSubview($0) }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    subviews.forEach { $0.frame = bounds }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

@MainActor
private final class ReadingAidsLinkButton: UIButton {
  let url: URL

  init(url: URL, label: String) {
    self.url = url
    super.init(frame: .zero)
    accessibilityLabel = label
    accessibilityTraits = .link
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    nil
  }
}

private struct ReadingAidsOverlayGeometryKey: Equatable {
  let pageID: ObjectIdentifier
  let pageBounds: CGRect
  let overlayBounds: CGRect
  let pageToOverlayOrigin: CGPoint
  let pageToOverlayXAxis: CGPoint
  let pageToOverlayYAxis: CGPoint
  let pageRotation: Int
  let scaleFactor: CGFloat
  let displayBox: PDFDisplayBox
}

private struct ReadingAidsOverlayGeometry {
  let key: ReadingAidsOverlayGeometryKey
  let glyphRects: [CGRect]
  let topicRects: [[CGRect]]
  let informationRects: [[CGRect]]
  let linkFrames: [CGRect]
}

@MainActor
private final class ReadingAidsPageOverlay: UIView {
  private weak var pdfView: PDFView?
  private weak var page: PDFPage?
  private var data: ReadingAidsPageData
  private var analysis = ReadingAidsPageAnalysis(
    informationRanges: [],
    topicRanges: [],
    tfidfRanges: [],
    links: []
  )
  private var linkButtons: [ReadingAidsLinkButton] = []
  private var emphasisColor: UIColor = .systemBlue
  private var geometry: ReadingAidsOverlayGeometry?
  private var glyphBoldStrengths: [Double] = []
  private var glyphBoldStrengthsDirty = true
  private var linkFramesDirty = true

  init(page: PDFPage, pdfView: PDFView, data: ReadingAidsPageData) {
    self.page = page
    self.pdfView = pdfView
    self.data = data
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) {
    nil
  }

  func rebind(page: PDFPage, pdfView: PDFView) {
    guard page !== self.page || pdfView !== self.pdfView else { return }
    self.page = page
    self.pdfView = pdfView
    discardGeometryCache()
    setNeedsLayout()
    setNeedsDisplay()
  }

  func discardGeometryCache() {
    geometry = nil
    linkFramesDirty = true
  }

  func update(accentColor: UIColor) {
    guard accentColor != emphasisColor else { return }
    emphasisColor = accentColor
    setNeedsDisplay()
  }

  func update(data: ReadingAidsPageData) {
    guard data != self.data else { return }
    self.data = data
    discardGeometryCache()
    glyphBoldStrengthsDirty = true
    setNeedsDisplay()
    setNeedsLayout()
  }

  func update(analysis: ReadingAidsPageAnalysis) {
    guard analysis != self.analysis else { return }
    self.analysis = analysis
    discardGeometryCache()
    glyphBoldStrengthsDirty = true
    linkButtons.forEach { $0.removeFromSuperview() }
    linkButtons = analysis.links.map { link in
      let button = ReadingAidsLinkButton(url: link.url, label: link.label)
      button.addTarget(self, action: #selector(openLink(_:)), for: .touchUpInside)
      addSubview(button)
      return button
    }
    isUserInteractionEnabled = !linkButtons.isEmpty
    setNeedsDisplay()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let geometryChanged = rebuildGeometryIfNeeded()
    if geometryChanged || linkFramesDirty {
      updateLinkButtonFrames()
    }
    if geometryChanged { setNeedsDisplay() }
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let context = UIGraphicsGetCurrentContext() else { return }
    let geometryChanged = rebuildGeometryIfNeeded()
    if geometryChanged || linkFramesDirty {
      updateLinkButtonFrames()
    }
    guard let geometry else { return }

    for rects in geometry.topicRects {
      context.setFillColor(emphasisColor.withAlphaComponent(0.13).cgColor)
      for glyphRect in rects {
        context.fill(glyphRect.insetBy(dx: -0.3, dy: 0))
      }
    }

    context.setFillColor(emphasisColor.withAlphaComponent(0.9).cgColor)
    for rects in geometry.informationRects {
      for glyphRect in rects {
        let thickness = max(1, glyphRect.height * 0.07)
        let line = CGRect(
          x: glyphRect.minX,
          y: glyphRect.maxY - thickness,
          width: glyphRect.width,
          height: thickness
        )
        context.fill(line)
      }
    }

    ensureGlyphBoldStrengths()
    for index in data.glyphs.indices {
      let glyph = data.glyphs[index]
      let strength = glyphBoldStrengths[index]
      let glyphRect = geometry.glyphRects[index]
      guard strength > 0,
        !glyph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !glyphRect.isNull, !glyphRect.isEmpty
      else { continue }
      let size = max(6, min(36, glyphRect.height * 0.88))
      let weight: UIFont.Weight = strength >= 0.9 ? .bold : strength >= 0.6 ? .semibold : .medium
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: UIColor.label.withAlphaComponent(0.92),
      ]
      (glyph.text as NSString).draw(in: glyphRect, withAttributes: attributes)
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    for button in linkButtons.reversed() {
      let buttonPoint = button.convert(point, from: self)
      if let hit = button.hitTest(buttonPoint, with: event) { return hit }
    }
    return nil
  }

  @objc private func openLink(_ sender: ReadingAidsLinkButton) {
    UIApplication.shared.open(sender.url, options: [:], completionHandler: nil)
  }

  private func rebuildGeometryIfNeeded() -> Bool {
    guard let page, let pdfView else {
      let changed = geometry != nil
      geometry = nil
      return changed
    }
    let pageBounds = page.bounds(for: .cropBox)
    let pageOrigin = CGPoint(x: pageBounds.minX, y: pageBounds.minY)
    let pageXAxis = CGPoint(x: pageBounds.minX + 1, y: pageBounds.minY)
    let pageYAxis = CGPoint(x: pageBounds.minX, y: pageBounds.minY + 1)
    let key = ReadingAidsOverlayGeometryKey(
      pageID: ObjectIdentifier(page),
      pageBounds: pageBounds,
      overlayBounds: bounds,
      pageToOverlayOrigin: pagePointInOverlay(pageOrigin, page: page, pdfView: pdfView),
      pageToOverlayXAxis: pagePointInOverlay(pageXAxis, page: page, pdfView: pdfView),
      pageToOverlayYAxis: pagePointInOverlay(pageYAxis, page: page, pdfView: pdfView),
      pageRotation: page.rotation,
      scaleFactor: pdfView.scaleFactor,
      displayBox: pdfView.displayBox
    )
    guard geometry?.key != key else { return false }

    let glyphRects = data.glyphs.map { convertedRect($0.bounds) ?? .null }
    let topicRects = analysis.topicRanges.map {
      convertedRects(for: $0, glyphRects: glyphRects)
    }
    let informationRects = analysis.informationRanges.map {
      convertedRects(
        for: ReadingRange(start: $0.start, end: $0.end),
        glyphRects: glyphRects
      )
    }
    let linkFrames = analysis.links.map {
      let rects = convertedRects(for: $0.range, glyphRects: glyphRects)
      let frame = rects.reduce(into: CGRect.null) { $0 = $0.union($1) }
      return frame.isNull ? .zero : frame.standardized
    }
    geometry = ReadingAidsOverlayGeometry(
      key: key,
      glyphRects: glyphRects,
      topicRects: topicRects,
      informationRects: informationRects,
      linkFrames: linkFrames
    )
    return true
  }

  private func pagePointInOverlay(_ point: CGPoint, page: PDFPage, pdfView: PDFView) -> CGPoint {
    convert(pdfView.convert(point, from: page), from: pdfView)
  }

  private func updateLinkButtonFrames() {
    guard let geometry else {
      linkButtons.forEach { $0.frame = .zero }
      linkFramesDirty = false
      return
    }
    for (button, frame) in zip(linkButtons, geometry.linkFrames) where button.frame != frame {
      button.frame = frame
    }
    linkFramesDirty = false
  }

  private func ensureGlyphBoldStrengths() {
    guard glyphBoldStrengthsDirty else { return }
    glyphBoldStrengths = Array(repeating: 0, count: data.glyphs.count)
    for range in analysis.tfidfRanges {
      applyBoldStrength(max(0, range.strength), for: ReadingRange(start: range.start, end: range.end))
    }
    glyphBoldStrengthsDirty = false
  }

  private func applyBoldStrength(_ strength: Double, for range: ReadingRange) {
    let start = lowerBound(for: range.start)
    let end = lowerBound(for: range.end)
    guard start < end else { return }
    for index in start..<end {
      glyphBoldStrengths[index] = max(glyphBoldStrengths[index], strength)
    }
  }

  private func convertedRects(for range: ReadingRange, glyphRects: [CGRect]) -> [CGRect] {
    let start = lowerBound(for: range.start)
    let end = lowerBound(for: range.end)
    guard start < end else { return [] }
    var rects: [CGRect] = []
    rects.reserveCapacity(end - start)
    for index in start..<end {
      let rect = glyphRects[index]
      if !rect.isNull, !rect.isEmpty {
        rects.append(rect)
      }
    }
    return mergeRects(rects)
  }

  private func lowerBound(for index: Int) -> Int {
    var lower = 0
    var upper = data.glyphs.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if data.glyphs[middle].index < index {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func convertedRect(_ pageRect: CGRect) -> CGRect? {
    guard let pdfView, let page, bounds.width > 0, bounds.height > 0 else { return nil }
    var displayRect = pageRect
    if let compact = (page as? ReaderPDFPage)?.compaction {
      let source = compact.sourcePage.bounds(for: .cropBox)
      let mapped = compact.displayRect(ReadingRectangle(
        x: pageRect.minX - source.minX, y: source.maxY - pageRect.maxY,
        width: pageRect.width, height: pageRect.height
      ))
      let bounds = page.bounds(for: .cropBox)
      displayRect = CGRect(x: bounds.minX + mapped.x, y: bounds.maxY - mapped.y - mapped.height,
                           width: mapped.width, height: mapped.height)
    }
    let viewRect = pdfView.convert(displayRect, from: page)
    let rect = convert(viewRect, from: pdfView).standardized
    return rect.width > 0 && rect.height > 0 ? rect : nil
  }
}

private func mergeRects(_ rects: [CGRect]) -> [CGRect] {
  var merged: [CGRect] = []
  for rect in rects.sorted(by: { lhs, rhs in
    lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
  }) {
    guard let index = merged.indices.last else {
      merged.append(rect)
      continue
    }
    let previous = merged[index]
    let sameLine = rect.minY <= previous.maxY + max(1, previous.height * 0.35)
    let adjacent = rect.minX <= previous.maxX + max(2, previous.height * 0.35)
    if sameLine && adjacent {
      merged[index] = previous.union(rect)
    } else {
      merged.append(rect)
    }
  }
  return merged
}

private func utf16Prefix(_ text: String, length: Int) -> String? {
  guard length >= 0, length <= text.utf16.count else { return nil }
  return String(decoding: text.utf16.prefix(length), as: UTF16.self)
}

private func findWhitespaceTolerant(
  _ target: String,
  in text: String,
  from offset: Int
) -> NSRange? {
  let tokens = target
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .map { NSRegularExpression.escapedPattern(for: $0) }
  guard !tokens.isEmpty else { return nil }
  let pattern = tokens.joined(separator: "\\s+")
  guard let expression = try? NSRegularExpression(pattern: pattern),
    offset >= 0, offset <= (text as NSString).length
  else { return nil }
  let range = NSRange(location: offset, length: (text as NSString).length - offset)
  return expression.firstMatch(in: text, range: range)?.range
}

private func findLinkRange(
  _ value: String,
  in text: String,
  from offset: Int
) -> NSRange? {
  let source = text as NSString
  let candidates: [String]
  if value.hasPrefix("mailto:") {
    candidates = [String(value.dropFirst(7))]
  } else {
    var values = [value]
    if value.hasPrefix("https://") { values.append(String(value.dropFirst(8))) }
    if value.hasPrefix("https://doi.org/") {
      let suffix = String(value.dropFirst("https://doi.org/".count))
      values.append("doi:\(suffix)")
      values.append(suffix)
    }
    candidates = values
  }
  for candidate in candidates {
    let range = source.range(
      of: candidate,
      options: [],
      range: NSRange(location: offset, length: source.length - offset)
    )
    if range.location != NSNotFound { return range }
  }
  return nil
}

public struct ReadingAidsViewModifier: ViewModifier {
  private let document: PDFDocument
  private let preferences: ReaderPreferences
  private let documentID: String
  @StateObject private var provider: ReadingAidsOverlayProvider

  public init(
    document: PDFDocument,
    preferences: ReaderPreferences,
    documentID: String = ""
  ) {
    self.document = document
    self.preferences = preferences
    self.documentID = documentID
    _provider = StateObject(
      wrappedValue: ReadingAidsOverlayProvider(
        document: document,
        preferences: preferences,
        documentID: documentID
      )
    )
  }

  public func body(content: Content) -> some View {
    content
      .environment(\.readerPageOverlayProvider, provider)
      .onChange(of: preferences) { _, value in
        provider.updatePreferences(value)
      }
  }
}

public extension View {
  func readerReadingAids(
    document: PDFDocument,
    preferences: ReaderPreferences,
    documentID: String = ""
  ) -> some View {
    modifier(
      ReadingAidsViewModifier(
        document: document,
        preferences: preferences,
        documentID: documentID
      )
    )
  }
}
