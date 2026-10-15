import Testing

@testable import ReaderCore

@Test func parityVersionIsSet() {
  #expect(!ReaderCore.desktopParityVersion.isEmpty)
}
