import Foundation

/// Resolves user-facing ReaderCore messages without coupling the package to an app
/// localization implementation.
public enum ReaderLocalization {
  public typealias Resolver = @Sendable (String) -> String

  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var resolver: Resolver = { $0 }
  }

  private static let storage = Storage()

  /// Installs the app's resolver. The default resolver returns the English input unchanged.
  public static func setResolver(_ resolver: @escaping Resolver) {
    storage.lock.lock()
    storage.resolver = resolver
    storage.lock.unlock()
  }

  /// Resolves an English message through the currently configured app resolver.
  public static func resolve(_ english: String) -> String {
    storage.lock.lock()
    let resolver = storage.resolver
    storage.lock.unlock()
    return resolver(english)
  }

  /// Resolves a template and substitutes positional values such as `{0}` and `{1}`.
  public static func string(_ template: String, _ args: String...) -> String {
    var value = resolve(template)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = (try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#))?.matches(in: value, range: range) ?? []
    for match in matches.reversed() {
      guard let indexRange = Range(match.range(at: 1), in: value),
        let index = Int(value[indexRange]),
        index < args.count,
        let replacementRange = Range(match.range, in: value)
      else { continue }
      value.replaceSubrange(replacementRange, with: args[index])
    }
    return value
  }
}
