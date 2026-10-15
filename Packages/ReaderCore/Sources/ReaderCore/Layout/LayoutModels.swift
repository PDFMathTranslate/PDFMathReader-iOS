import Foundation

/// A positioned text run in the coordinate system used by the desktop layout engine.
public struct TextItem: Codable, Equatable, Sendable {
  public var page: Int
  public var text: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var fontSize: Double
  public var isBold: Bool
  public var rotation: Double
  public var itemType: String

  public init(
    page: Int = 1,
    text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    fontSize: Double,
    isBold: Bool = false,
    rotation: Double = 0,
    itemType: String = "Text"
  ) {
    self.page = page
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.fontSize = fontSize
    self.isBold = isBold
    self.rotation = rotation
    self.itemType = itemType
  }
}

/// A paragraph block returned by `LayoutEngine.paragraphs`.
public struct LayoutParagraph: Codable, Equatable, Sendable {
  public var id: Int
  public var text: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var fontSize: Double
  public var bold: Bool
  public var textAlign: String?

  public init(
    id: Int,
    text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    fontSize: Double,
    bold: Bool,
    textAlign: String? = nil
  ) {
    self.id = id
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.fontSize = fontSize
    self.bold = bold
    self.textAlign = textAlign
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case text
    case x
    case y
    case width
    case height
    case fontSize
    case bold
    case textAlign
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    x = try container.decode(Double.self, forKey: .x)
    y = try container.decode(Double.self, forKey: .y)
    width = try container.decode(Double.self, forKey: .width)
    height = try container.decode(Double.self, forKey: .height)
    fontSize = try container.decode(Double.self, forKey: .fontSize)
    bold = try container.decode(Bool.self, forKey: .bold)
    textAlign = try container.decodeIfPresent(String.self, forKey: .textAlign)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encode(x, forKey: .x)
    try container.encode(y, forKey: .y)
    try container.encode(width, forKey: .width)
    try container.encode(height, forKey: .height)
    try container.encode(fontSize, forKey: .fontSize)
    try container.encode(bold, forKey: .bold)
    try container.encodeIfPresent(textAlign, forKey: .textAlign)
  }
}
