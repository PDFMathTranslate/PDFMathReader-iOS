import UIKit

/// Resolve both installed family names and PostScript names, falling back
/// safely when a saved font is unavailable on this device.
enum ReaderTranslationFont {
  static func resolve(name: String, serif: Bool, size: CGFloat, bold: Bool = false) -> UIFont {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let system = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let fallback = serif
      ? UIFont(descriptor: system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor, size: size)
      : system
    guard !name.isEmpty else { return fallback }
    let family = UIFont.familyNames.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    let installed = family.map {
      UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: $0]), size: size)
    } ?? UIFont(name: name, size: size)
    guard let installed else { return fallback }
    var traits = installed.fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    guard let descriptor = installed.fontDescriptor.withSymbolicTraits(traits) else { return installed }
    return UIFont(descriptor: descriptor, size: size)
  }
}
