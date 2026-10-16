import ReaderCore

/// ReaderCore keeps English defaults for command-line/package consumers. The
/// app resolves those same templates through its selected interface language.
enum ReaderErrorLocalization {
  static func configure() {
    ReaderLocalization.setResolver { template in
      let key = "core.error.\(template)"
      let translated = L10n.string(key)
      return translated == key ? template : translated
    }
  }
}
