import Foundation

/// The deterministic layout logic shared by the on-device reader and its fixtures.
public enum LayoutEngine {
  public static func paragraphs(items: [TextItem], pageHeight: Double) -> [LayoutParagraph] {
    let runs = items.enumerated()
      .filter { _, item in
        !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
          item.width > 0 &&
          item.height > 0 &&
          item.rotation == 0 &&
          !["Image", "Link", "FormField"].contains(item.itemType)
      }
      .map { index, item in
        PositionedRun(
          item: item,
          originalIndex: index,
          top: pageHeight - item.y - item.height
        )
      }
      .sorted {
        if $0.top != $1.top { return $0.top < $1.top }
        if $0.item.x != $1.item.x { return $0.item.x < $1.item.x }
        return $0.originalIndex < $1.originalIndex
      }

    var lines: [LayoutLine] = []
    for run in runs {
      let runFontSize = jsFontSize(for: run.item)
      if let lineIndex = lines.firstIndex(where: { line in
        abs(line.top - run.top) < min(line.fontSize, run.item.fontSize) * 0.4 &&
          run.item.x >= line.x - 2 &&
          run.item.x - line.right < max(12, run.item.fontSize * 1.2)
      }) {
        lines[lineIndex].text += " " + run.item.text
        lines[lineIndex].x = min(lines[lineIndex].x, run.item.x)
        lines[lineIndex].top = min(lines[lineIndex].top, run.top)
        lines[lineIndex].right = max(lines[lineIndex].right, run.item.x + run.item.width)
        lines[lineIndex].bottom = max(lines[lineIndex].bottom, run.top + run.item.height)
      } else {
        lines.append(
          LayoutLine(
            text: run.item.text,
            x: run.item.x,
            top: run.top,
            right: run.item.x + run.item.width,
            bottom: run.top + run.item.height,
            fontSize: runFontSize,
            isBold: run.item.isBold,
            order: lines.count
          )
        )
      }
    }

    lines.sort { lhs, rhs in
      if lhs.top != rhs.top { return lhs.top < rhs.top }
      if lhs.x != rhs.x { return lhs.x < rhs.x }
      return lhs.order < rhs.order
    }

    // Weight by UTF-16 characters so short superscripts and footnotes do not
    // outvote the page body, matching JavaScript's String.length.
    let sizes = runs
      .map { (jsFontSize(for: $0.item), $0.item.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) }
      .sorted { $0.0 < $1.0 }
    var bodySize = 12.0
    let totalCharacters = sizes.reduce(0) { $0 + $1.1 }
    if !sizes.isEmpty {
      let half = Double(totalCharacters) / 2
      var seen = 0
      for (size, count) in sizes {
        seen += count
        if Double(seen) >= half {
          bodySize = size
          break
        }
      }
    }

    // Learn normal leading from nearby lines of the same size independently
    // of columns.
    var gaps: [Int: [Double]] = [:]
    for index in lines.indices {
      let line = lines[index]
      let next = lines[(index + 1)...].first { candidate in
        candidate.top > line.top + line.fontSize * 0.5 &&
          abs(candidate.x - line.x) < line.fontSize * 1.5 &&
          abs(candidate.fontSize - line.fontSize) < 1.5
      }
      let gap = next.map { $0.top - line.bottom } ?? -1
      if gap >= 0 && gap < line.fontSize * 0.85 {
        gaps[Int(line.fontSize.rounded()) + 0, default: []].append(gap)
      }
    }
    var leading: [Int: Double] = [:]
    for (key, values) in gaps where values.count >= 3 {
      let sortedValues = values.sorted()
      leading[key] = sortedValues[Int(Double(sortedValues.count) * 0.25)]
    }

    var blocks: [LayoutBlock] = []
    for line in lines.sorted(by: {
      if $0.top != $1.top { return $0.top < $1.top }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.order < $1.order
    }) {
      let blockIndex = blocks.indices.reversed().first { index in
        let block = blocks[index]
        return line.top >= block.top &&
          line.top - block.bottom < line.fontSize * 0.85 &&
          line.top - block.bottom >= -2 &&
          (
            abs(line.x - block.x) < line.fontSize * 1.5 ||
              (block.count == 1 && block.x > line.x && block.x - line.x <= line.fontSize * 3) ||
              isCentered(block: block, line: line, bodySize: bodySize)
          ) &&
          abs(line.fontSize - block.fontSize) < 1.5 &&
          line.isBold == block.isBold
      }

      if let blockIndex,
        !isBoundary(
          block: blocks[blockIndex],
          line: line,
          leading: leading,
          bodySize: bodySize
        ) {
        if abs(line.x - blocks[blockIndex].x) >= line.fontSize * 1.5 &&
          isCentered(block: blocks[blockIndex], line: line, bodySize: bodySize) {
          blocks[blockIndex].textAlign = "center"
        }
        let hasHyphen = blocks[blockIndex].text.hasSuffix("-")
        blocks[blockIndex].text = String(blocks[blockIndex].text.dropLast(hasHyphen ? 1 : 0)) +
          (hasHyphen ? "" : " ") + line.text
        blocks[blockIndex].x = min(blocks[blockIndex].x, line.x)
        blocks[blockIndex].top = min(blocks[blockIndex].top, line.top)
        blocks[blockIndex].right = max(blocks[blockIndex].right, line.right)
        blocks[blockIndex].bottom = max(blocks[blockIndex].bottom, line.bottom)
        blocks[blockIndex].last = line
        blocks[blockIndex].count += 1
      } else {
        blocks.append(
          LayoutBlock(
            text: line.text,
            x: line.x,
            top: line.top,
            right: line.right,
            bottom: line.bottom,
            fontSize: line.fontSize,
            isBold: line.isBold,
            firstX: line.x,
            count: 1,
            last: line
          )
        )
      }
    }

    return blocks.enumerated().map { id, block in
      LayoutParagraph(
        id: id,
        text: block.text,
        x: block.x,
        y: block.top,
        width: block.right - block.x,
        height: block.bottom - block.top,
        fontSize: block.fontSize,
        bold: block.isBold,
        textAlign: block.textAlign
      )
    }
  }

  /// Merge and size-jitter-correct OCR word items using the desktop recovery path.
  public static func normalizeOcrItems(_ items: [TextItem]) -> [TextItem] {
    let sortedItems = items.enumerated()
      .sorted { lhs, rhs in
        if lhs.element.y != rhs.element.y { return lhs.element.y > rhs.element.y }
        return lhs.offset < rhs.offset
      }
      .map(\.element)

    var groups: [[TextItem]] = []
    for item in sortedItems {
      if let last = groups.indices.last,
        abs(groups[last][0].y - item.y) < min(groups[last][0].fontSize, item.fontSize) * 0.3 {
        groups[last].append(item)
      } else {
        groups.append([item])
      }
    }

    var runs: [TextItem] = []
    for group in groups {
      let sizeValues = group.map(\.fontSize).sorted()
      guard let size = sizeValues[safe: group.count >> 1] else { continue }
      var merged: [TextItem] = []
      for item in group.enumerated().sorted(by: { lhs, rhs in
        if lhs.element.x != rhs.element.x { return lhs.element.x < rhs.element.x }
        return lhs.offset < rhs.offset
      }).map(\.element) {
        if let lastIndex = merged.indices.last,
          item.x - (merged[lastIndex].x + merged[lastIndex].width) < size * 1.6 {
          merged[lastIndex].text += " " + item.text
          merged[lastIndex].width = max(
            merged[lastIndex].width,
            item.x + item.width - merged[lastIndex].x
          )
          merged[lastIndex].isBold = merged[lastIndex].isBold || item.isBold
        } else {
          var copy = item
          copy.y = group[0].y
          copy.fontSize = size
          copy.height = size
          merged.append(copy)
        }
      }
      runs.append(contentsOf: merged)
    }

    let bodyValues = runs.flatMap { run in
      Array(repeating: run.fontSize, count: run.text.utf16.count)
    }.sorted()
    guard let body = bodyValues[safe: bodyValues.count >> 1] else { return runs }
    return runs.map { run in
      var copy = run
      if copy.fontSize >= body * 0.8 && copy.fontSize <= body * 1.3 {
        copy.fontSize = body
        copy.height = body
      }
      return copy
    }
  }

  private static func isCentered(block: LayoutBlock, line: LayoutLine, bodySize: Double) -> Bool {
    (line.isBold || line.fontSize > bodySize * 1.2) &&
      abs((line.x + line.right - block.x - block.right) / 2) < line.fontSize * 0.5 &&
      min(line.right, block.right) - max(line.x, block.x) >
        min(line.right - line.x, block.right - block.x) * 0.6
  }

  private static func jsFontSize(for item: TextItem) -> Double {
    item.fontSize == 0 ? item.height : item.fontSize
  }

  private static func isBoundary(
    block: LayoutBlock,
    line: LayoutLine,
    leading: [Int: Double],
    bodySize: Double
  ) -> Bool {
    if isCentered(block: block, line: line, bodySize: bodySize) {
      return false
    }

    let last = block.last
    let terminal = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
      .range(of: #"[.!?。！？]["'”’）)]?$"#, options: .regularExpression) != nil
    let indent = line.x - block.x
    let normal = leading[Int(line.fontSize.rounded())]
    if let normal,
      line.top - last.bottom > normal + max(2, line.fontSize * 0.18) {
      return true
    }
    if line.text.range(
      of: #"^\s*(?:[•●▪◦]|\d+[.)、]\s|[（(]\d+[）)]\s)"#,
      options: .regularExpression
    ) != nil {
      return true
    }
    if indent > line.fontSize * 0.5 &&
      (terminal || (block.count >= 2 && block.firstX - block.x > line.fontSize * 0.5)) {
      return true
    }
    return terminal &&
      block.count >= 2 &&
      last.right < block.right - line.fontSize * 2 &&
      last.right - last.x < (block.right - block.x) * 0.85
  }

  private struct PositionedRun {
    let item: TextItem
    let originalIndex: Int
    let top: Double
  }

  private struct LayoutLine {
    var text: String
    var x: Double
    var top: Double
    var right: Double
    var bottom: Double
    let fontSize: Double
    let isBold: Bool
    let order: Int
  }

  private struct LayoutBlock {
    var text: String
    var x: Double
    var top: Double
    var right: Double
    var bottom: Double
    let fontSize: Double
    let isBold: Bool
    let firstX: Double
    var count: Int
    var last: LayoutLine
    var textAlign: String?
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
