import Foundation
import Testing

@testable import ReaderCore

@Test func pageCropClampsValuesAndTracksActivity() {
  var crop = PageCrop(x: -1, y: 2)
  #expect(crop.x == 0)
  #expect(crop.y == PageCrop.maximumFraction)
  #expect(crop.isActive)

  crop.x = .nan
  crop.y = -.infinity
  #expect(crop.x == 0)
  #expect(crop.y == 0)
  #expect(!crop.isActive)

  let positiveInfinity = PageCrop(x: .infinity)
  #expect(positiveInfinity.x == PageCrop.maximumFraction)
  #expect(positiveInfinity.isActive)
}

@Test func pageCropStepAdjustmentsReachExactBoundaries() {
  var crop = PageCrop()
  for _ in 0..<16 {
    crop.x += PageCrop.adjustmentStep
    crop.y += PageCrop.adjustmentStep
  }
  #expect(crop.x == PageCrop.maximumFraction)
  #expect(crop.y == PageCrop.maximumFraction)

  for _ in 0..<16 {
    crop.x -= PageCrop.adjustmentStep
    crop.y -= PageCrop.adjustmentStep
  }
  #expect(crop.x == 0)
  #expect(crop.y == 0)
}

@Test func pageCropExposesRequestedAdjustmentStepAndRoundTrips() throws {
  #expect(PageCrop.adjustmentStep == 0.05)

  let crop = PageCrop(x: 0.12, y: 0.34)
  let data = try JSONEncoder().encode(crop)
  #expect(try JSONDecoder().decode(PageCrop.self, from: data) == crop)
}

@Test func readingStateDecodesLegacyDataWithoutPageCropAndRoundTrips() throws {
  let legacy = Data(
    #"{"page":7,"zoom":1.25,"scaleMode":"custom","displayMode":"twoPages","scrollDirection":"horizontal","sidebarVisible":false,"lastUpdated":0}"#.utf8
  )
  let decoded = try JSONDecoder().decode(ReadingState.self, from: legacy)

  #expect(decoded.page == 7)
  #expect(decoded.zoom == 1.25)
  #expect(decoded.scaleMode == .custom)
  #expect(decoded.displayMode == .twoPages)
  #expect(decoded.scrollDirection == .horizontal)
  #expect(!decoded.sidebarVisible)
  #expect(decoded.pageCrop == nil)

  let roundTripped = try JSONDecoder().decode(
    ReadingState.self,
    from: JSONEncoder().encode(decoded)
  )
  #expect(roundTripped == decoded)
}

@Test func readingStatePersistsPageCrop() throws {
  let state = ReadingState(page: 3, pageCrop: PageCrop(x: 0.18, y: 0.22))
  let encoded = try JSONEncoder().encode(state)
  let decoded = try JSONDecoder().decode(ReadingState.self, from: encoded)
  #expect(decoded.pageCrop == state.pageCrop)
}
