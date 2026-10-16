import Testing

@testable import ReaderCore

@Test func readerLocalizationPreservesEnglishDefaultsAndInterpolatesSafely() {
  ReaderLocalization.setResolver { $0 }
  defer { ReaderLocalization.setResolver { $0 } }

  #expect(ReaderLocalization.resolve("Default English") == "Default English")
  #expect(ReaderLocalization.string("Status {0}", "ready") == "Status ready")

  ReaderLocalization.setResolver { english in
    english == "Greeting {0} {1}" ? "Bonjour {1}, {0}" : english
  }
  #expect(
    ReaderLocalization.string("Greeting {0} {1}", "value {1}", "world")
      == "Bonjour world, value {1}"
  )
}
