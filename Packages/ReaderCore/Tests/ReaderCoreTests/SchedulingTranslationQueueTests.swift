import Foundation
import Testing

@testable import ReaderCore

private actor PageRecorder {
  private(set) var started: [Int] = []
  private(set) var finished: [Int] = []
  private(set) var cancelled: [Int] = []
  private var active = 0
  private(set) var peak = 0

  func start(_ page: Int) {
    started.append(page)
    active += 1
    peak = max(peak, active)
  }

  func finish(_ page: Int) {
    finished.append(page)
    active = max(0, active - 1)
  }

  func cancel(_ page: Int) {
    cancelled.append(page)
    active = max(0, active - 1)
  }

  func startedCount() -> Int {
    started.count
  }
}

private func waitForStart(_ recorder: PageRecorder, count: Int) async throws {
  for _ in 0..<100 {
    if await recorder.startedCount() >= count { return }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
}

@Suite(.serialized)
struct TranslationQueueTests {
  @Test
  func preservesDesktopNearbyAndFullDocumentOrder() {
    #expect(
      prioritizedTranslationPages(
        mode: .readingAhead,
        currentPage: 10,
        totalPages: 50,
        visiblePages: [10, 11],
        aheadPages: [12, 13],
        direction: 1,
        moving: true
      ) == [10, 11, 12, 13, 14, 15, 16, 17, 9, 8]
    )
    #expect(
      prioritizedTranslationPages(
        mode: .readingAhead,
        currentPage: 10,
        totalPages: 50,
        visiblePages: [9, 10],
        direction: -1,
        moving: true
      ) == [10, 9, 8, 7, 6, 5, 4, 3, 11, 12]
    )
    #expect(
      prioritizedTranslationPages(
        mode: .full,
        currentPage: 3,
        totalPages: 4,
        visiblePages: [3, 4]
      ) == [3, 4, 1, 2]
    )
  }

  @Test
  func deduplicatesPagesAndHonorsConcurrencyLimit() async throws {
    let recorder = PageRecorder()
    let queue = TranslationQueue(pageConcurrency: 2) { page in
      await recorder.start(page)
      do {
        try await Task.sleep(nanoseconds: 5_000_000)
        await recorder.finish(page)
      } catch {
        await recorder.cancel(page)
        throw error
      }
    }
    await queue.enqueue(pages: [1, 2, 3, 1, 2])
    try await queue.waitUntilIdle()
    let snapshot = await queue.snapshot()
    let startedCount = await recorder.startedCount()
    let peak = await recorder.peak
    #expect(snapshot.completedPages == [1, 2, 3])
    #expect(startedCount == 3)
    #expect(peak <= 2)

    await queue.enqueue(page: 2)
    try await queue.waitUntilIdle()
    let secondStartedCount = await recorder.startedCount()
    #expect(secondStartedCount == startedCount)

    await queue.enqueue(page: 2, force: true)
    try await queue.waitUntilIdle()
    let forcedStartedCount = await recorder.startedCount()
    #expect(forcedStartedCount == startedCount + 1)
  }

  @Test
  func fullDocumentScheduleStartsInPriorityOrder() async throws {
    let recorder = PageRecorder()
    let queue = TranslationQueue(pageConcurrency: 1) { page in
      await recorder.start(page)
      try await Task.sleep(nanoseconds: 1_000_000)
      await recorder.finish(page)
    }
    await queue.schedule(
      totalPages: 5,
      currentPage: 3,
      mode: .full,
      visiblePages: [3, 4],
      manual: true
    )
    try await queue.waitUntilIdle()
    let started = await recorder.started
    #expect(started == [3, 4, 1, 2, 5])
  }

  @Test
  func contextChangesCancelOutdatedWorkAndClearDedupe() async throws {
    let recorder = PageRecorder()
    let queue = TranslationQueue(pageConcurrency: 1) { page in
      await recorder.start(page)
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
        await recorder.finish(page)
      } catch {
        await recorder.cancel(page)
        throw error
      }
    }
    await queue.setContext(documentID: "doc-a", language: "en", engine: "fast")
    await queue.enqueue(page: 1)
    try await waitForStart(recorder, count: 1)
    await queue.updateContext(
      TranslationQueueContext(documentID: "doc-a", language: "zh", engine: "precise")
    )
    try await queue.waitUntilIdle()
    let cancelled = await recorder.cancelled
    #expect(cancelled == [1])

    await queue.enqueue(page: 1)
    try await queue.waitUntilIdle()
    let snapshot = await queue.snapshot()
    let started = await recorder.started
    #expect(started == [1, 1])
    #expect(snapshot.completedPages == [1])
    #expect(snapshot.context.language == "zh")
    #expect(snapshot.context.engine == "precise")
  }
}
