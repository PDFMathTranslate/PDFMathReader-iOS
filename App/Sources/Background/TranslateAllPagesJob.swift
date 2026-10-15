import BackgroundTasks
import Combine
import Foundation
import ReaderCore
import SwiftUI
import UIKit

private enum TranslationJobPersistence {
  static func url(documentID: String, configurationID: String) -> URL {
    let key = sha256Hex(Data("\(documentID)\n\(configurationID)".utf8))
    return LibraryDirectory.default
      .appendingPathComponent("translation-jobs", isDirectory: true)
      .appendingPathComponent(key)
      .appendingPathExtension("json")
  }

  static func load(from url: URL) -> TranslationJobState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(TranslationJobState.self, from: data)
  }

  static func save(_ state: TranslationJobState, to url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(state).write(to: url, options: [.atomic])
    } catch {
      // A failed snapshot must not interrupt an in-flight translation.
    }
  }
}

@MainActor
final class TranslateAllPagesJob: ObservableObject {
  private static let continuedProcessingIdentifierPrefix =
    "com.pdfmathtranslate.PDFMathReader.continuedProcessingTask"

  private weak var coordinator: ReaderTranslationCoordinator?
  private let persistenceURL: URL
  private var runTask: Task<Void, Never>?
  private var isRunActive = false
  private var continuedTaskIdentifier: String?
  private var continuedTask: BGTask?
  private var legacyBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  @Published private(set) var state: TranslationJobState
  @Published private(set) var progress: TranslationJobProgress

  init(coordinator: ReaderTranslationCoordinator) {
    self.coordinator = coordinator
    let documentID = coordinator.translationDocumentID
    let configurationID = coordinator.translationConfigurationID
    let url = TranslationJobPersistence.url(
      documentID: documentID,
      configurationID: configurationID
    )
    self.persistenceURL = url

    let restored: TranslationJobState? = TranslationJobPersistence.load(from: url).flatMap {
      (value: TranslationJobState) -> TranslationJobState? in
      guard value.documentID == documentID,
        value.configurationID == configurationID,
        value.totalPages == coordinator.translationPageCount
      else { return nil }
      return value
    }
    var initial = restored ?? TranslationJobState(
      documentID: documentID,
      configurationID: configurationID,
      totalPages: coordinator.translationPageCount
    )
    if initial.status == .queued || initial.status == .running {
      initial.markPaused()
    }
    self.state = initial
    self.progress = initial.progress
    mergeCachedPages()
  }

  var isRunning: Bool {
    isRunActive || state.status == .queued || state.status == .running
  }

  var isFinished: Bool { state.status == .completed }

  func start() {
    guard !isRunActive, runTask == nil else { return }
    guard let coordinator, coordinator.translationPageCount > 0 else {
      state.status = .failed
      state.lastError = L10n.string("ios.noTranslatablePages")
      publish(persist: true)
      return
    }

    mergeCachedPages()
    if state.isComplete {
      state.status = .completed
      publish(persist: true)
      return
    }

    state.beginRun()
    publish(persist: true)
    if #available(iOS 26.0, *) {
      submitContinuedProcessingTask()
    } else {
      beginLegacyBackgroundTask()
      beginWork()
    }
  }

  func cancel() {
    guard isRunning else { return }
    isRunActive = false
    runTask?.cancel()
    runTask = nil
    cancelCoordinatorWork()

    if #available(iOS 26.0, *), let identifier = continuedTaskIdentifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    finishSystemTask(success: false)
    state.markCancelled()
    publish(persist: true)
  }

  private func mergeCachedPages() {
    guard let coordinator else { return }
    let before = state.completedPageIndices
    state.mergeCachedPages(coordinator.readyTranslationPageIndices)
    if before != state.completedPageIndices {
      publish(persist: true)
    }
  }

  private func publish(persist: Bool) {
    progress = state.progress
    updateContinuedTaskProgress()
    if persist {
      TranslationJobPersistence.save(state, to: persistenceURL)
    }
  }

  @available(iOS 26.0, *)
  private func submitContinuedProcessingTask() {
    let identifier = "\(Self.continuedProcessingIdentifierPrefix).\(UUID().uuidString)"
    continuedTaskIdentifier = identifier
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier,
      using: nil
    ) { [weak self] task in
      guard let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Task { @MainActor [weak self] in
        self?.beginWork(with: task)
      }
    }
    guard registered else {
      beginLegacyBackgroundTask()
      beginWork()
      return
    }

    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: L10n.string("ios.translateAllPages"),
      subtitle: L10n.string("ios.translatingPDF")
    )
    request.strategy = .queue
    do {
      try BGTaskScheduler.shared.submit(request)
      state.status = .queued
      publish(persist: true)
    } catch {
      continuedTaskIdentifier = nil
      beginLegacyBackgroundTask()
      beginWork()
    }
  }

  private func beginLegacyBackgroundTask() {
    guard legacyBackgroundTaskID == .invalid else { return }
    legacyBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
      withName: L10n.string("ios.translateAllPages")
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleExpiration()
      }
    }
  }

  private func beginWork(with task: BGTask? = nil) {
    guard !isRunActive, state.status != .cancelled else {
      task?.setTaskCompleted(success: false)
      return
    }
    if let task {
      continuedTask = task
      task.expirationHandler = { [weak self] in
        Task { @MainActor [weak self] in
          self?.handleExpiration()
        }
      }
    }
    isRunActive = true
    state.status = .running
    publish(persist: true)
    runTask = Task { @MainActor [weak self] in
      await self?.performRun()
    }
  }

  private func performRun() async {
    guard let coordinator else {
      state.status = .failed
      state.lastError = L10n.string("ios.translationCoordinatorUnavailable")
      publish(persist: true)
      isRunActive = false
      finishSystemTask(success: false)
      runTask = nil
      return
    }

    mergeCachedPages()
    guard isRunActive, !Task.isCancelled else {
      runTask = nil
      return
    }

    guard let pendingPages = await coordinator.scheduleFullDocumentTranslation(
      excluding: Set(state.completedPageIndices)
    ) else {
      state.status = .failed
      state.lastError = L10n.string("ios.translationPipelineUnavailable")
      publish(persist: true)
      isRunActive = false
      finishSystemTask(success: false)
      runTask = nil
      return
    }

    for pageIndex in pendingPages.sorted() {
      guard isRunActive, !Task.isCancelled else { break }
      await watchPage(pageIndex, coordinator: coordinator)
    }

    guard isRunActive, !Task.isCancelled else {
      runTask = nil
      return
    }
    state.markFinished()
    publish(persist: true)
    isRunActive = false
    finishSystemTask(success: state.status == .completed)
    runTask = nil
  }

  private func watchPage(
    _ pageIndex: Int,
    coordinator: ReaderTranslationCoordinator
  ) async {
    guard let stream = await coordinator.translationStream(for: pageIndex) else {
      state.markFailed(pageIndex: pageIndex, error: L10n.string("ios.translationStreamUnavailable"))
      publish(persist: true)
      return
    }

    var reachedTerminalState = false
    for await pageState in stream {
      guard isRunActive, !Task.isCancelled else { return }
      switch pageState.status {
      case .ready:
        state.markCompleted(pageIndex: pageIndex)
        reachedTerminalState = true
      case .error:
        state.markFailed(
          pageIndex: pageIndex,
          error: pageState.error ?? L10n.string("ios.pageTranslationFailed")
        )
        reachedTerminalState = true
      case .cancelled:
        state.markFailed(pageIndex: pageIndex, error: L10n.string("ios.pageTranslationCancelled"))
        reachedTerminalState = true
      case .idle, .queued, .extracting, .translating:
        continue
      }
      publish(persist: true)
      if reachedTerminalState { return }
    }

    guard isRunActive, !Task.isCancelled, !reachedTerminalState else { return }
    state.markFailed(pageIndex: pageIndex, error: L10n.string("ios.pageStreamEnded"))
    publish(persist: true)
  }

  private func handleExpiration() {
    guard isRunActive else { return }
    isRunActive = false
    runTask?.cancel()
    runTask = nil
    cancelCoordinatorWork()
    state.markPaused()
    publish(persist: true)
    finishSystemTask(success: false)
  }

  private func cancelCoordinatorWork() {
    guard let coordinator else { return }
    Task { @MainActor [weak coordinator] in
      await coordinator?.cancelAllTranslations()
    }
  }

  private func updateContinuedTaskProgress() {
    guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else {
      return
    }
    let total = max(1, progress.totalPages)
    task.progress.totalUnitCount = Int64(total)
    task.progress.completedUnitCount = Int64(min(total, progress.processedPages))
    task.updateTitle(
      L10n.string("ios.translateAllPages"),
      subtitle: L10n.string(
        "ios.pagesProgress",
        String(progress.processedPages),
        String(progress.totalPages)
      )
    )
  }

  private func finishSystemTask(success: Bool) {
    continuedTask?.expirationHandler = nil
    continuedTask?.setTaskCompleted(success: success)
    continuedTask = nil
    continuedTaskIdentifier = nil
    if legacyBackgroundTaskID != .invalid {
      UIApplication.shared.endBackgroundTask(legacyBackgroundTaskID)
      legacyBackgroundTaskID = .invalid
    }
  }
}

struct TranslateAllPagesButton: View {
  @StateObject private var job: TranslateAllPagesJob

  init(coordinator: ReaderTranslationCoordinator) {
    _job = StateObject(wrappedValue: TranslateAllPagesJob(coordinator: coordinator))
  }

  var body: some View {
    Button {
      if job.isRunning {
        job.cancel()
      } else {
        job.start()
      }
    } label: {
      HStack(spacing: 6) {
        if job.isRunning {
          ProgressView(value: job.progress.fraction)
            .frame(width: 56)
        }
        Label(labelTitle, systemImage: labelSymbol)
      }
    }
    .disabled(job.isFinished && !job.isRunning)
    .accessibilityValue(
      L10n.string(
        "ios.pagesProgress",
        String(job.progress.processedPages),
        String(job.progress.totalPages)
      )
    )
  }

  private var labelTitle: String {
    if job.isRunning { return L10n.string("ios.cancelTranslation") }
    if job.isFinished { return L10n.string("ios.allPagesTranslated") }
    return job.progress.processedPages > 0
      ? L10n.string("ios.resumeTranslation")
      : L10n.string("ios.translateAllPages")
  }

  private var labelSymbol: String {
    if job.isRunning { return "xmark.circle" }
    if job.isFinished { return "checkmark.circle" }
    return "text.badge.plus"
  }
}
