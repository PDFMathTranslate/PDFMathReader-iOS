import Foundation
import PDFKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Extracts PDFKit character geometry into the desktop pdf.js coordinate convention.
public struct PDFKitTextExtractor: Sendable {
  public init() {}

  public func extract(page: PDFPage, pageNumber: Int = 1) -> [TextItem] {
    Self.extract(page: page, pageNumber: pageNumber)
  }

  public static func extract(page: PDFPage, pageNumber: Int = 1) -> [TextItem] {
    let pageString = page.string as NSString? ?? ""
    let attributed = page.attributedString
    guard pageString.length > 0 else { return [] }

    var result: [TextItem] = []
    var run: [CharacterRun] = []
    var index = 0
    var styleRange = NSRange(location: 0, length: 0)
    var cachedStyle = CharacterStyle()
    // PDFKit can synthesize line breaks with no glyph slot. Keep string and
    // bounds indices separate, and stream runs without retaining a page-sized
    // second copy of all character geometry.
    var boundsShift = 0
    while index < pageString.length {
      let range = pageString.rangeOfComposedCharacterSequence(at: index)
      let text = pageString.substring(with: range)
      defer { index = NSMaxRange(range) }
      if isWhitespace(text) {
        appendRun(&result, run: run, pageNumber: pageNumber)
        run.removeAll(keepingCapacity: true)
        if isLineBreak(text), NSMaxRange(range) < pageString.length {
          boundsShift = resolvedBoundsShift(page: page, index: NSMaxRange(range), current: boundsShift)
        }
        continue
      }
      var bounds = CGRect.null
      for stringIndex in range.location..<NSMaxRange(range) {
        let slot = stringIndex + boundsShift
        guard slot >= 0, slot < pageString.length else { continue }
        let glyphBounds = page.characterBounds(at: slot)
        if glyphBounds.width > 0, glyphBounds.height > 0 {
          bounds = bounds.union(glyphBounds)
        }
      }
      if !NSLocationInRange(index, styleRange) {
        cachedStyle = style(at: index, in: attributed, effectiveRange: &styleRange)
      }
      let character = CharacterRun(
        index: index,
        text: text,
        bounds: bounds.isNull ? .zero : bounds,
        fontSize: cachedStyle.fontSize,
        isBold: cachedStyle.isBold,
        fontName: cachedStyle.fontName
      )
      // A synthesized glyph with no bounds still belongs to the current
      // word. Keep its text without treating the zero rectangle as a new line.
      if bounds.isNull, !run.isEmpty {
        run.append(character)
        continue
      }
      if let previous = run.last(where: { $0.bounds.width > 0 }), !sameLine(previous, character) {
        appendRun(&result, run: run, pageNumber: pageNumber)
        run.removeAll(keepingCapacity: true)
      }
      if let previous = run.last,
        previous.isBold != character.isBold || abs(previous.fontSize - character.fontSize) > 0.1 {
        appendRun(&result, run: run, pageNumber: pageNumber)
        run.removeAll(keepingCapacity: true)
      }
      run.append(character)
    }
    appendRun(&result, run: run, pageNumber: pageNumber)
    return snapToLines(result)
  }

  public static func items(for page: PDFPage, pageNumber: Int = 1) -> [TextItem] {
    extract(page: page, pageNumber: pageNumber)
  }

  /// Picks the bounds slot for `index` by checking it against the selection
  /// geometry, which stays aligned with the string. Only runs at line breaks.
  private static func resolvedBoundsShift(page: PDFPage, index: Int, current: Int) -> Int {
    guard let reference = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page),
      reference.width > 0
    else { return current }
    var best = current
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for candidate in [current, current - 1, current + 1] {
      let slot = index + candidate
      guard slot >= 0, slot < page.numberOfCharacters else { continue }
      let bounds = page.characterBounds(at: slot)
      guard bounds.width > 0, bounds.height > 0 else { continue }
      let distance = abs(bounds.midX - reference.midX) + abs(bounds.midY - reference.midY)
      if distance < bestDistance {
        best = candidate
        bestDistance = distance
      }
    }
    return best
  }

  private static func isLineBreak(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
  }

  private static func appendRun(
    _ result: inout [TextItem],
    run: [CharacterRun],
    pageNumber: Int
  ) {
    guard let first = run.first else { return }
    let valid = run.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
    guard !valid.isEmpty else { return }
    let minX = valid.map(\.bounds.minX).min() ?? 0
    let minY = valid.map(\.bounds.minY).min() ?? 0
    let maxX = valid.map(\.bounds.maxX).max() ?? 0
    let maxY = valid.map(\.bounds.maxY).max() ?? 0
    let fontSize = valid.map(\.fontSize).filter { $0 > 0 }.max() ?? Double(valid.map(\.bounds.height).max() ?? 0)
    let height = max(fontSize, maxY - minY)
    let width = maxX - minX
    guard width > 0 && height > 0 else { return }

    let rotation = rotation(for: valid)
    let text = run.map(\.text).joined()
    result.append(
      TextItem(
        page: pageNumber,
        text: text,
        x: Double(minX),
        // PDFKit reports these page character bounds in the same top-origin
        // y convention as the desktop pdf.js item.y values on iOS/macOS.
        y: Double(minY),
        width: Double(width),
        height: height,
        fontSize: fontSize,
        isBold: first.isBold,
        rotation: rotation,
        itemType: "Text"
      )
    )
  }

  private static func snapToLines(_ items: [TextItem]) -> [TextItem] {
    var lines: [LineGroup] = []
    for (index, item) in items.enumerated().sorted(by: { lhs, rhs in
      if lhs.element.y != rhs.element.y { return lhs.element.y < rhs.element.y }
      return lhs.offset < rhs.offset
    }) {
      let candidate = lines.indices.min { lhs, rhs in
        abs(lines[lhs].representativeY - item.y) < abs(lines[rhs].representativeY - item.y)
      }
      if let candidate,
        abs(lines[candidate].representativeY - item.y) < min(lines[candidate].fontSize, item.fontSize) * 0.28 {
        lines[candidate].indices.append(index)
        lines[candidate].ys.append(item.y)
      } else {
        lines.append(
          LineGroup(
            indices: [index],
            ys: [item.y],
            fontSize: item.fontSize
          )
        )
      }
    }

    var snapped = items
    for line in lines {
      let values = line.ys.sorted()
      let representativeY = values[values.count / 2]
      for index in line.indices {
        snapped[index].y = representativeY
      }
    }
    return snapped
  }

  private static func sameLine(_ lhs: CharacterRun, _ rhs: CharacterRun) -> Bool {
    let scale = max(lhs.fontSize, rhs.fontSize, lhs.bounds.height, rhs.bounds.height)
    guard scale > 0 else { return true }
    let verticalDistance = abs(lhs.bounds.midY - rhs.bounds.midY)
    if verticalDistance >= scale * 0.45 { return false }
    // A backwards x jump without a line break is normally a new text line or column.
    return rhs.bounds.minX >= lhs.bounds.minX - scale * 0.35
  }

  private static func rotation(for run: [CharacterRun]) -> Double {
    guard let first = run.first, let last = run.last else { return 0 }
    let dx = last.bounds.midX - first.bounds.midX
    let dy = last.bounds.midY - first.bounds.midY
    if abs(dx) < 0.001 && abs(dy) < 0.001 {
      return 0
    }
    if abs(dx) >= abs(dy) { return 0 }
    return atan2(dy, dx) * 180 / .pi
  }

  private static func isWhitespace(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
  }

  private static func style(
    at index: Int,
    in attributed: NSAttributedString?,
    effectiveRange: inout NSRange
  ) -> CharacterStyle {
    guard let attributed, index < attributed.length else {
      effectiveRange = NSRange(location: index, length: 1)
      return CharacterStyle()
    }
    let font = attributed.attribute(.font, at: index, effectiveRange: &effectiveRange)
    #if os(macOS)
    if let font = font as? NSFont {
      return CharacterStyle(
        fontSize: Double(font.pointSize),
        isBold: isBold(font.fontName),
        fontName: font.fontName
      )
    }
    #elseif os(iOS)
    if let font = font as? UIFont {
      return CharacterStyle(
        fontSize: Double(font.pointSize),
        isBold: isBold(font.fontName),
        fontName: font.fontName
      )
    }
    #endif
    return CharacterStyle()
  }

  private static func isBold(_ fontName: String) -> Bool {
    fontName.range(of: "bold|black|heavy", options: [.regularExpression, .caseInsensitive]) != nil
  }

  private struct CharacterStyle {
    let fontSize: Double
    let isBold: Bool
    let fontName: String

    init(fontSize: Double = 0, isBold: Bool = false, fontName: String = "") {
      self.fontSize = fontSize
      self.isBold = isBold
      self.fontName = fontName
    }
  }

  private struct CharacterRun {
    let index: Int
    let text: String
    let bounds: CGRect
    let fontSize: Double
    let isBold: Bool
    let fontName: String
  }

  private struct LineGroup {
    var indices: [Int]
    var ys: [Double]
    let fontSize: Double

    var representativeY: Double {
      let values = ys.sorted()
      return values[values.count / 2]
    }
  }
}
