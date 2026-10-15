import Foundation

public enum TranslationJobStatus: String, Codable, Sendable {
  case idle
  case queued
  case running
  case paused
  case cancelled
  case completed
  case failed
}

/// Progress for a document-wide translation run. Failed pages count as
/// terminal for the current run, but remain resumable on the next run.
public struct TranslationJobProgress: Codable, Equatable, Sendable {
  public let totalPages: Int
  public let completedPages: Int
  public let failedPages: Int
  public let processedPages: Int
  public let fraction: Double

  public init(totalPages: Int, completedPages: Int, failedPages: Int = 0) {
    let total = max(0, totalPages)
    let completed = max(0, min(total, completedPages))
    let failed = max(0, min(total - completed, failedPages))
    self.totalPages = total
    self.completedPages = completed
    self.failedPages = failed
    self.processedPages = completed + failed
    self.fraction = total == 0 ? 1 : Double(completed + failed) / Double(total)
  }
}

/// Persisted page-level state for a document-wide translation run.
///
/// Page indices are zero-based, matching PDFKit and PageTranslationState. A
/// completed page is safe to skip on resume; a failed page is retried.
public struct TranslationJobState: Codable, Equatable, Sendable {
  public var documentID: String
  public var configurationID: String
  public var totalPages: Int
  public var status: TranslationJobStatus
  public var completedPageIndices: [Int]
  public var failedPages: [Int: String]
  public var lastError: String?

  public init(
    documentID: String,
    configurationID: String,
    totalPages: Int,
    status: TranslationJobStatus = .idle,
    completedPageIndices: [Int] = [],
    failedPages: [Int: String] = [:],
    lastError: String? = nil
  ) {
    self.documentID = documentID
    self.configurationID = configurationID
    self.totalPages = max(0, totalPages)
    self.status = status
    self.completedPageIndices = Self.validPageIndices(completedPageIndices, totalPages: totalPages)
    self.failedPages = Self.validFailedPages(failedPages, totalPages: totalPages)
    self.lastError = lastError
  }

  public var progress: TranslationJobProgress {
    TranslationJobProgress(
      totalPages: totalPages,
      completedPages: completedPageIndices.count,
      failedPages: failedPages.keys.filter { !completedPageIndices.contains($0) }.count
    )
  }

  /// Pages that are not already complete and therefore need work on resume.
  public var resumablePageIndices: [Int] {
    let completed = Set(completedPageIndices)
    return (0..<totalPages).filter { !completed.contains($0) }
  }

  public var isComplete: Bool {
    totalPages == completedPageIndices.count
  }

  public mutating func beginRun() {
    status = .running
    failedPages.removeAll()
    lastError = nil
  }

  public mutating func markCompleted(pageIndex: Int) {
    guard (0..<totalPages).contains(pageIndex) else { return }
    if !completedPageIndices.contains(pageIndex) {
      completedPageIndices.append(pageIndex)
      completedPageIndices.sort()
    }
    failedPages.removeValue(forKey: pageIndex)
  }

  public mutating func markFailed(pageIndex: Int, error: String) {
    guard (0..<totalPages).contains(pageIndex), !completedPageIndices.contains(pageIndex) else {
      return
    }
    failedPages[pageIndex] = error
    lastError = error
  }

  public mutating func markCancelled() {
    status = .cancelled
  }

  public mutating func markPaused() {
    status = .paused
  }

  public mutating func markFinished() {
    status = failedPages.isEmpty && isComplete ? .completed : .failed
  }

  public mutating func mergeCachedPages(_ pageIndices: some Sequence<Int>) {
    for pageIndex in pageIndices {
      markCompleted(pageIndex: pageIndex)
    }
  }

  public mutating func resetForRetranslation() {
    completedPageIndices.removeAll()
    failedPages.removeAll()
    lastError = nil
    status = .idle
  }

  private static func validPageIndices(_ pageIndices: [Int], totalPages: Int) -> [Int] {
    let total = max(0, totalPages)
    return Array(Set(pageIndices.filter { (0..<total).contains($0) })).sorted()
  }

  private static func validFailedPages(_ pages: [Int: String], totalPages: Int) -> [Int: String] {
    let total = max(0, totalPages)
    return pages.reduce(into: [:]) { result, pair in
      guard (0..<total).contains(pair.key), !pair.value.isEmpty else { return }
      result[pair.key] = pair.value
    }
  }
}
