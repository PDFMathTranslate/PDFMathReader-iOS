import Foundation

/// A page crop expressed as the fraction removed from each opposite edge.
/// Horizontal values apply equally to left and right; vertical values to top and bottom.
/// Values are bounded to `0...0.4`, leaving at least one fifth of either axis visible.
public struct PageCrop: Codable, Hashable, Sendable {
  public static let maximumFraction = 0.4
  public static let adjustmentStep = 0.05

  private var storedX: Double
  private var storedY: Double

  public var x: Double {
    get { storedX }
    set { storedX = Self.clamped(newValue) }
  }

  public var y: Double {
    get { storedY }
    set { storedY = Self.clamped(newValue) }
  }

  public var isActive: Bool {
    x > 0 || y > 0
  }

  public init(x: Double = 0, y: Double = 0) {
    storedX = Self.clamped(x)
    storedY = Self.clamped(y)
  }

  private enum CodingKeys: String, CodingKey {
    case x
    case y
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      x: try container.decode(Double.self, forKey: .x),
      y: try container.decode(Double.self, forKey: .y)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(x, forKey: .x)
    try container.encode(y, forKey: .y)
  }

  private static func clamped(_ value: Double) -> Double {
    guard !value.isNaN else { return 0 }
    let bounded = min(max(value, 0), maximumFraction)
    return (bounded * 100).rounded() / 100
  }
}
