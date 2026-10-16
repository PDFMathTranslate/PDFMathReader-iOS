import ReaderCore
import SwiftUI
import UIKit

/// Matches the desktop palette. System deliberately supplies no override so
/// SwiftUI and UIKit retain the platform's native tint behavior.
struct ReaderAccentColor: Identifiable {
  let name: String
  let id: String

  var color: Color? {
    id == "system" ? nil : Color(uiColor: UIColor(hex: id))
  }

  static let options: [ReaderAccentColor] = [
    .init(name: "appearance.system", id: "system"),
    .init(name: "appearance.blue", id: "#007aff"),
    .init(name: "appearance.purple", id: "#af52de"),
    .init(name: "appearance.pink", id: "#ff2d55"),
    .init(name: "appearance.red", id: "#ff3b30"),
    .init(name: "appearance.orange", id: "#ff9500"),
    .init(name: "appearance.yellow", id: "#ffcc00"),
    .init(name: "appearance.green", id: "#34c759"),
    .init(name: "appearance.gray", id: "#8e8e93"),
    .init(name: "appearance.slateBlue", id: "#3d647a"),
  ]

  static func color(for value: String) -> Color? {
    let normalized = ReaderPreferences.normalizedAccentColor(value)
    return normalized == "system" ? nil : Color(uiColor: UIColor(hex: normalized))
  }
}

extension View {
  func readerAccentColor(_ value: String) -> some View {
    let color = ReaderAccentColor.color(for: value)
    // tint styles controls; accentColor also reaches existing custom selection
    // indicators that resolve Color.accentColor from the environment.
    return self.tint(color).accentColor(color)
  }
}

struct AccentColorSettingsRow: View {
  @Binding var selection: String

  // Native picker menus tint template symbols uniformly. Bake each swatch's
  // color into an original image so the menu preserves the palette.
  private static func swatch(for value: String) -> UIImage {
    let side: CGFloat = 22
    let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
      UIColor(hex: value).setFill()
      circle.fill()
      UIColor.black.withAlphaComponent(0.18).setStroke()
      circle.lineWidth = 1
      circle.stroke()
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  var body: some View {
    Picker(L10n.string("appearance.accentColor"), selection: $selection) {
      ForEach(ReaderAccentColor.options) { option in
        Label {
          Text(L10n.string(option.name))
        } icon: {
          if option.id != "system" {
            Image(uiImage: Self.swatch(for: option.id))
              .renderingMode(.original)
          } else {
            Image(systemName: "circle.lefthalf.filled")
          }
        }
        .tag(option.id)
      }
      // Preserve a custom desktop-compatible value if one was imported.
      if !ReaderAccentColor.options.contains(where: { $0.id == selection }) {
        Label {
          Text(L10n.string("appearance.custom"))
        } icon: {
          Image(uiImage: Self.swatch(for: selection))
            .renderingMode(.original)
        }
        .tag(selection)
      }
    }
    .accessibilityIdentifier("settings.accentColor")
  }
}
