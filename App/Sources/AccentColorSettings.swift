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

  var body: some View {
    Picker(L10n.string("appearance.accentColor"), selection: $selection) {
      ForEach(ReaderAccentColor.options) { option in
        Label {
          Text(L10n.string(option.name))
        } icon: {
          if let color = option.color {
            Image(systemName: "circle.fill")
              .foregroundStyle(color)
          } else {
            Image(systemName: "circle.lefthalf.filled")
          }
        }
        .tag(option.id)
      }
      // Preserve a custom desktop-compatible value if one was imported.
      if !ReaderAccentColor.options.contains(where: { $0.id == selection }) {
        Text(L10n.string("appearance.custom")).tag(selection)
      }
    }
    .accessibilityIdentifier("settings.accentColor")
  }
}
