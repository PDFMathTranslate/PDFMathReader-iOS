import Foundation

public struct CompactCut: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

/// The PDF.js transform shape used by `typicalLineHeight`.
public struct CompactionTextItem: Codable, Equatable, Sendable {
  public var text: String
  public var transform: [Double]

  public init(text: String, transform: [Double]) {
    self.text = text
    self.transform = transform
  }
}

public func compactBands(
  _ occupied: [Bool],
  rowScale: Double,
  pageHeight: Double,
  lineHeight: Double
) -> [CompactCut] {
  guard rowScale > 0, pageHeight >= 0, lineHeight >= 0 else { return [] }
  guard let first = occupied.firstIndex(of: true),
    let last = occupied.lastIndex(of: true), first < last else { return [] }
  let target = 1.5 * lineHeight
  var cuts: [CompactCut] = []
  var row = first
  while row < last {
    if occupied[row] {
      row += 1
      continue
    }
    let start = row
    while row < last, !occupied[row] { row += 1 }
    let gap = Double(row - start) / rowScale
    if gap > target + 2 {
      cuts.append(CompactCut(
        start: Double(start) / rowScale + target,
        end: Double(row) / rowScale
      ))
    }
  }
  return cuts.filter { $0.start >= 0 && $0.end <= pageHeight && $0.end > $0.start }
}

public func trailingCut(
  source: [Bool],
  occupied: [Bool],
  rowScale: Double,
  lineHeight: Double
) -> CompactCut? {
  guard rowScale > 0 else { return nil }
  guard let sourceLast = source.lastIndex(of: true),
    let last = occupied.lastIndex(of: true), sourceLast > last else { return nil }
  let start = Double(last + 1) / rowScale + lineHeight
  let end = Double(sourceLast + 1) / rowScale
  return end > start + 2 ? CompactCut(start: start, end: end) : nil
}

public func mapCompactY(_ y: Double, cuts: [CompactCut], inverse: Bool = false) -> Double {
  var removed = 0.0
  for cut in cuts {
    let edge = inverse ? cut.start - removed : cut.start
    if y <= edge { break }
    if inverse {
      removed += cut.end - cut.start
    } else {
      removed += min(y, cut.end) - cut.start
    }
  }
  return y + (inverse ? removed : -removed)
}

public func mapCompactRect(
  _ rect: ReadingRectangle?,
  cuts: [CompactCut],
  inverse: Bool = false
) -> ReadingRectangle? {
  guard let rect, rect.y.isFinite else { return rect }
  let y = mapCompactY(rect.y, cuts: cuts, inverse: inverse)
  return ReadingRectangle(
    x: rect.x,
    y: y,
    width: rect.width,
    height: rect.height.isFinite ? mapCompactY(rect.y + rect.height, cuts: cuts, inverse: inverse) - y : rect.height
  )
}

public func typicalLineHeight(_ items: [CompactionTextItem]) -> Double? {
  let runs = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.transform.count >= 6 }
  let sizes = runs.map { hypot($0.transform[2], $0.transform[3]) }
    .filter { $0 > 4 && $0 < 60 }
    .sorted()
  guard !sizes.isEmpty else { return nil }
  let font = sizes[sizes.count / 2]
  let ys = runs.map { $0.transform[5] }.sorted()
  let advances = zip(ys.dropFirst(), ys).map { $0 - $1 }
    .filter { $0 >= font * 0.8 && $0 <= font * 2 }
    .sorted()
  return advances.isEmpty ? font * 1.2 : advances[advances.count / 2]
}

public func typicalLineHeight(_ items: [ReadingTextRun]) -> Double? {
  let runs = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  let sizes = runs.map { hypot($0.height, $0.height) / sqrt(2) }
    .filter { $0 > 4 && $0 < 60 }
    .sorted()
  guard !sizes.isEmpty else { return nil }
  let font = sizes[sizes.count / 2]
  let ys = runs.map(\.y).sorted()
  let advances = zip(ys.dropFirst(), ys).map { $0 - $1 }
    .filter { $0 >= font * 0.8 && $0 <= font * 2 }
    .sorted()
  return advances.isEmpty ? font * 1.2 : advances[advances.count / 2]
}
