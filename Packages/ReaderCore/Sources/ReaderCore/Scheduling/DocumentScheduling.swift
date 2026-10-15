import Foundation

/// Swift concurrency equivalent of the desktop's post-commit/post-paint
/// scheduling boundary. UIKit/AppKit callers can add their own display-link
/// boundary around this cooperative yield when they need a visual frame.
public func yieldToPaint() async {
  await Task.yield()
}

public func scheduleAfterPaint<T: Sendable>(
  afterCommit: @escaping @Sendable () async -> Void = {},
  task: @escaping @Sendable () async throws -> T
) async rethrows -> T {
  await afterCommit()
  await yieldToPaint()
  return try await task()
}

public func scheduleTaskCleanup(
  _ cleanup: @escaping @Sendable () async -> Void
) async {
  await yieldToPaint()
  await cleanup()
}
