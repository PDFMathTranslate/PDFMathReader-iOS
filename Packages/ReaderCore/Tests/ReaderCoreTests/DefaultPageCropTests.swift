import Foundation
import Testing

@testable import ReaderCore

@Test func defaultPageCropPreferencesDefaultSafely() throws {
  let defaults = ReaderPreferences()
  #expect(!defaults.defaultPageCropEnabled)
  #expect(defaults.defaultPageCropX == 0)
  #expect(defaults.defaultPageCropY == 0)

  let decoded = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data("{}".utf8)
  )
  #expect(!decoded.defaultPageCropEnabled)
  #expect(decoded.defaultPageCropX == 0)
  #expect(decoded.defaultPageCropY == 0)
}

@Test func defaultPageCropPreferencesClampConstructionAndDecoding() throws {
  let constructed = ReaderPreferences(
    defaultPageCropEnabled: true,
    defaultPageCropX: -0.25,
    defaultPageCropY: 0.75
  )
  #expect(constructed.defaultPageCropEnabled)
  #expect(constructed.defaultPageCropX == 0)
  #expect(constructed.defaultPageCropY == 0.5)

  let nonFinite = ReaderPreferences(
    defaultPageCropX: .nan,
    defaultPageCropY: .infinity
  )
  #expect(nonFinite.defaultPageCropX == 0)
  #expect(nonFinite.defaultPageCropY == 0)

  let decoded = try JSONDecoder().decode(
    ReaderPreferences.self,
    from: Data(#"{"defaultPageCropEnabled":true,"defaultPageCropX":-0.1,"defaultPageCropY":0.8}"#.utf8)
  )
  #expect(decoded.defaultPageCropEnabled)
  #expect(decoded.defaultPageCropX == 0)
  #expect(decoded.defaultPageCropY == 0.5)
}

@Test func defaultPageCropPreferencesRoundTrip() throws {
  let preferences = ReaderPreferences(
    defaultPageCropEnabled: true,
    defaultPageCropX: 0.37,
    defaultPageCropY: 0.12
  )
  let encoded = try JSONEncoder().encode(preferences)
  let persisted = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(persisted["defaultPageCropEnabled"] as? Bool == true)
  #expect(persisted["defaultPageCropX"] as? Double == 0.37)
  #expect(persisted["defaultPageCropY"] as? Double == 0.12)
  #expect(try JSONDecoder().decode(ReaderPreferences.self, from: encoded) == preferences)
}
