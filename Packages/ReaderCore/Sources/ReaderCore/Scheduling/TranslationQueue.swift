import Foundation

public enum TranslationMode: String, Sendable {
  case full
  case reading
  case readingAhead
}

public struct TranslationQueueContext: Hashable, Sendable {
  public var documentID: String
  public var language: String
  public var engine: String

  public init(documentID: String = "", language: String = "", engine: String = "") {
    self.documentID = documentID
    self.language = language
    self.engine = engine
  }
}

public struct TranslationQueueSnapshot: Sendable, Equatable {
  public let queuedPages: [Int]
  public let runningPages: [Int]
  public let completedPages: [Int]
  public let errors: [Int: String]
  public let context: TranslationQueueContext
  public let state: TranslationQueueState

  public init(
    queuedPages: [Int],
    runningPages: [Int],
    completedPages: [Int],
    errors: [Int: String],
    context: TranslationQueueContext,
    state: TranslationQueueState
  ) {
    self.queuedPages = queuedPages
    self.runningPages = runningPages
    self.completedPages = completedPages
    self.errors = errors
    self.context = context
    self.state = state
  }
}

/// Ports the desktop scope-pages ordering used by the translation queue.
public func prioritizedTranslationPages(
  mode: TranslationMode,
  currentPage: Int?,
  totalPages: Int,
  visiblePages: [Int] = [],
  aheadPages: [Int] = [],
  direction: Int = 1,
  moving: Bool = false
) -> [Int] {
  guard totalPages > 0 else { return [] }
  let current = boundedUnique(currentPage.map { [$0] } ?? [], total: totalPages)
  let visible = boundedUnique(visiblePages, total: totalPages)
  let ahead = boundedUnique(aheadPages, total: totalPages)
  switch mode {
  case .full:
    return boundedUnique(current + visible + ahead + Array(1...totalPages), total: totalPages)
  case .readingAhead:
    let orderedVisible = boundedUnique(current + visible, total: totalPages)
    let sign = direction == -1 ? -1 : 1
    let frontier: Int
    if orderedVisible.isEmpty {
      frontier = 1
    } else if sign == 1 {
      frontier = orderedVisible.max() ?? 1
    } else {
      frontier = orderedVisible.min() ?? 1
    }
    let forward = (1...6).map { frontier + $0 * sign }
    let behind: [Int]
    if let currentPage, !current.isEmpty {
      behind = [currentPage - sign, currentPage - 2 * sign]
    } else {
      behind = []
    }
    return boundedUnique(orderedVisible + forward + behind, total: totalPages)
  case .reading:
    let orderedVisible = current + visible
    if moving {
      return boundedUnique(orderedVisible, total: totalPages)
    }
    if visiblePages.isEmpty && aheadPages.isEmpty {
      guard let currentPage else { return [] }
      let sign = direction == -1 ? -1 : 1
      return boundedUnique(
        [currentPage, currentPage + sign, currentPage - sign, currentPage + 2 * sign, currentPage - 2 * sign],
        total: totalPages
      )
    }
    let sign = direction == -1 ? -1 : 1
    return boundedUnique(
      orderedVisible + ahead + [currentPage.map { $0 + sign }, currentPage.map { $0 + 2 * sign },
        currentPage.map { $0 - sign }, currentPage.map { $0 - 2 * sign }].compactMap { $0 },
      total: totalPages
    )
  }
}

private func boundedUnique(_ pages: [Int], total: Int) -> [Int] {
  var seen = Set<Int>()
  return pages.filter { page in
    guard page >= 1, page <= total, seen.insert(page).inserted else { return false }
    return true
  }
}

/// Actor-isolated page scheduler. The work closure is deliberately generic
/// from the queue's perspective: callers can plug in Ultra fast, remote math,
/// or another per-page implementation without changing scheduling logic.
public actor TranslationQueue {
  public typealias PageWork = @Sendable (Int) async throws -> Void

  private struct JobKey: Hashable, Sendable {
    let generation: Int
    let page: Int
  }

  private struct Job: Sendable {
    let key: JobKey
    let page: Int
    let manual: Bool
    let priority: Int
  }

  private let work: PageWork
  private var maximumConcurrency: Int
  private var generation = 0
  private var context = TranslationQueueContext()
  private var pending: [Job] = []
  private var active: [JobKey: Task<Void, Never>] = [:]
  private var completed = Set<JobKey>()
  private var errors: [Int: String] = [:]
  private var queueState = TranslationQueueState()

  public init(
    pageConcurrency: Int = 2,
    concurrency: Int? = nil,
    work: @escaping PageWork
  ) {
    self.maximumConcurrency = max(1, concurrency ?? pageConcurrency)
    self.work = work
  }

  public func updateConcurrency(_ limit: Int) {
    maximumConcurrency = max(1, limit)
    pump()
  }

  /// Changing any of these values invalidates queued and running work from the
  /// previous document configuration.
  public func updateContext(_ newContext: TranslationQueueContext) {
    guard newContext != context else { return }
    generation += 1
    context = newContext
    pending.removeAll()
    errors.removeAll()
    completed.removeAll()
    for task in active.values {
      task.cancel()
    }
    pump()
  }

  public func setContext(documentID: String, language: String, engine: String) {
    updateContext(
      TranslationQueueContext(documentID: documentID, language: language, engine: engine)
    )
  }

  /// Alias used by settings observers when a language or engine changes.
  public func cancelOutdatedWork(for newContext: TranslationQueueContext) {
    updateContext(newContext)
  }

  public func currentContext() -> TranslationQueueContext {
    context
  }

  public func enqueue(
    page: Int,
    manual: Bool = false,
    priority: Int = 0,
    force: Bool = false
  ) {
    enqueuePages([page], manual: manual, priorities: [priority], force: force)
  }

  public func enqueue(
    pages: [Int],
    manual: Bool = false,
    force: Bool = false
  ) {
    enqueuePages(pages, manual: manual, priorities: Array(pages.indices), force: force)
  }

  private func enqueuePages(
    _ pages: [Int],
    manual: Bool,
    priorities: [Int],
    force: Bool
  ) {
    var seen = Set<Int>()
    for (index, page) in pages.enumerated() {
      guard page > 0, seen.insert(page).inserted else { continue }
      let key = JobKey(generation: generation, page: page)
      if pending.contains(where: { $0.key == key }) || active[key] != nil || (!force && completed.contains(key)) {
        continue
      }
      errors.removeValue(forKey: page)
      let priority = priorities.indices.contains(index) ? priorities[index] : index
      pending.append(Job(key: key, page: page, manual: manual, priority: priority))
    }
    sortPending()
    pump()
  }

  /// Schedules pages around the visible page, or all pages in full-document
  /// mode. The returned order is also the order in which pending work starts.
  public func schedule(
    totalPages: Int,
    currentPage: Int? = nil,
    mode: TranslationMode = .readingAhead,
    visiblePages: [Int] = [],
    aheadPages: [Int] = [],
    direction: Int = 1,
    moving: Bool = false,
    manual: Bool = false,
    force: Bool = false,
    context: TranslationQueueContext? = nil
  ) {
    if let context, context != self.context {
      updateContext(context)
    }
    let pages = prioritizedTranslationPages(
      mode: mode,
      currentPage: currentPage,
      totalPages: totalPages,
      visiblePages: visiblePages,
      aheadPages: aheadPages,
      direction: direction,
      moving: moving
    )
    queueState.translateAllPages = mode == .full
    let priorities = Array(pages.indices)
    enqueuePages(pages, manual: manual, priorities: priorities, force: force)
  }

  public func setFullDocumentMode(_ enabled: Bool) {
    queueState.translateAllPages = enabled
  }

  public func setTranslationDeferred(_ deferred: Bool) {
    queueState.translationDeferred = deferred
  }

  public func setReadingDirection(_ direction: Int) {
    queueState.readingDirection = direction == -1 ? -1 : 1
  }

  public func setTranslationMoving(_ moving: Bool) {
    queueState.translationMoving = moving
  }

  public func setForceRetranslation(_ force: Bool) {
    queueState.forceRetranslation = force
  }

  public func state() -> TranslationQueueState {
    queueState
  }

  public func cancel(page: Int) {
    pending.removeAll { $0.page == page && $0.key.generation == generation }
    for (key, task) in active where key.generation == generation && key.page == page {
      task.cancel()
    }
  }

  /// Cancels queued/running work. Completed pages remain deduplicated unless
  /// resetCompleted is requested or the context changes.
  public func cancelAll(resetCompleted: Bool = false) {
    pending.removeAll()
    for task in active.values {
      task.cancel()
    }
    if resetCompleted {
      completed.removeAll()
      errors.removeAll()
    }
  }

  public func reset() {
    generation += 1
    pending.removeAll()
    completed.removeAll()
    errors.removeAll()
    for task in active.values {
      task.cancel()
    }
  }

  public func waitUntilIdle() async throws {
    while !pending.isEmpty || !active.isEmpty {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  public func isIdle() -> Bool {
    pending.isEmpty && active.isEmpty
  }

  public func snapshot() -> TranslationQueueSnapshot {
    TranslationQueueSnapshot(
      queuedPages: pending.map(\.page),
      runningPages: active.keys
        .filter { $0.generation == generation }
        .map(\.page)
        .sorted(),
      completedPages: completed.filter { $0.generation == generation }.map(\.page).sorted(),
      errors: errors,
      context: context,
      state: queueState
    )
  }

  private func sortPending() {
    pending.sort {
      if $0.manual != $1.manual { return $0.manual && !$1.manual }
      if $0.priority != $1.priority { return $0.priority < $1.priority }
      return $0.page < $1.page
    }
  }

  private func pump() {
    sortPending()
    while active.count < maximumConcurrency, !pending.isEmpty {
      let job = pending.removeFirst()
      let task = Task { [work] in
        var errorMessage: String?
        do {
          try await work(job.page)
        } catch {
          if !Task.isCancelled, !(error is CancellationError) {
            errorMessage = error.localizedDescription
          }
        }
        self.finish(job: job, errorMessage: errorMessage)
      }
      active[job.key] = task
    }
  }

  private func finish(job: Job, errorMessage: String?) {
    guard active.removeValue(forKey: job.key) != nil else { return }
    guard job.key.generation == generation else {
      pump()
      return
    }
    if let errorMessage {
      errors[job.page] = errorMessage
    } else {
      errors.removeValue(forKey: job.page)
      completed.insert(job.key)
    }
    pump()
  }
}


