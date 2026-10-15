import Foundation

public enum L10n {
  public static func string(_ key: String, _ args: CVarArg...) -> String {
    let value = String(localized: String.LocalizationValue(key), table: "Localizable", bundle: .main)
    guard !args.isEmpty else { return value }
    return String(format: value, locale: Locale.current, arguments: args)
  }
}
