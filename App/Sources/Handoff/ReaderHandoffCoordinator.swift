import Combine
import Foundation
import OSLog
import PDFKit
import ReaderCore
import UIKit

/// Retains the native activity for the visible reader. Every advertised state
/// has a complete committed PDF snapshot; edits withdraw it until saved again.
@MainActor
final class ReaderHandoffCoordinator: NSObject, ObservableObject, NSUserActivityDelegate {
  private enum DiagnosticStatus: String, Codable {
    case idle
    case preparing
    case published
    case failed
    case continued
    case released
  }

  private struct Diagnostic: Codable {
    let status: DiagnosticStatus
    let time: Date
    let errorDomain: String?
    let errorCode: Int?
    let errorDescription: String?
    let isManaged: Bool
    let page: Int?
  }

  private struct SafeErrorInfo {
    let domain: String
    let code: Int
    let description: String
  }

  private struct LocalExportSnapshot: Sendable {
    let sourceData: Data
    let annotations: [ReaderAnnotation]
    let quickLinks: [ReaderQuickLink]
    let readingState: ReadingState
    let nativeRefs: [String]
  }

  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PDFMathReader",
    category: "Handoff"
  )
  private static let maximumDiagnosticBytes = 4 * 1024
  private let diagnosticURL = LibraryDirectory.default
    .appendingPathComponent("Handoff", isDirectory: true)
    .appendingPathComponent("diagnostic.json")
  private var diagnosticHistory: [Diagnostic] = []

  private(set) var activity: NSUserActivity?
  private var subscriptions: Set<AnyCancellable> = []
  private var preparation: Task<Void, Never>?
  private var retry: Task<Void, Never>?
  private weak var tab: ReaderTab?
  private weak var library: LibraryModel?
  private var generation = UUID()
  private var change = 0
  @Published private(set) var isTransferring = false
  private var onTransferred: ((String) -> Void)?
  private let localTransfer = ReaderHandoffLocalTransfer()

  func start(tab: ReaderTab?, library: LibraryModel, onTransferred: @escaping (String) -> Void) {
    stop()
    recordDiagnostic(.idle)
    self.tab = tab
    self.library = library
    self.onTransferred = onTransferred
    guard let tab else { return }
    retry = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        guard let self else { return }
        if UIApplication.shared.applicationState == .active,
           self.activity == nil, self.preparation == nil { self.changed() }
      }
    }
    tab.model.$readingState.removeDuplicates().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    tab.annotations.$annotations.removeDuplicates().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    tab.annotations.$quickLinks.removeDuplicates().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    tab.drawings.$drawings.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    library.$preferences.map(\.companionURL).removeDuplicates().sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: .companionPairingCodeDidChange).sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
  }

  func stop() {
    generation = UUID()
    subscriptions.removeAll()
    retry?.cancel()
    retry = nil
    preparation?.cancel()
    preparation = nil
    activity?.invalidate()
    activity = nil
    tab = nil
    isTransferring = false
  }

  func refresh() { changed() }

  private func changed() {
    guard !isTransferring else { return }
    change += 1
    activity?.invalidate()
    activity = nil
    guard preparation == nil else { return }
    let token = generation
    preparation = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == token { self.preparation = nil } }
      while !Task.isCancelled, self.generation == token {
        let version = self.change
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        guard version == self.change else { continue }
        guard let tab = self.tab, let library = self.library else { return }
        self.recordDiagnostic(.preparing, tab: tab, library: library)
        do {
          let payload = try await self.prepare(tab, library: library)
          guard !Task.isCancelled, self.generation == token else { return }
          guard version == self.change else { continue }
          self.publish(payload, title: tab.session.title)
          return
        } catch {
          guard !Task.isCancelled, self.generation == token else { return }
          // Background advertisement failure must not disrupt local reading.
          // No activity is published until a complete authenticated save works.
          self.recordDiagnostic(.failed, tab: tab, library: library, error: error)
          if version != self.change { continue }
          return
        }
      }
    }
  }

  private func publish(_ payload: ReaderHandoffActivity, title: String) {
    let activity = NSUserActivity(activityType: ReaderHandoffActivity.activityType)
    activity.title = title
    activity.userInfo = payload.userInfo
    activity.requiredUserInfoKeys = ["version", "documentID", "page"]
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    activity.delegate = self
    self.activity = activity
    activity.becomeCurrent()
    recordDiagnostic(.published, tab: tab, library: library, page: payload.page)
  }

  private func prepare(_ tab: ReaderTab, library: LibraryModel) async throws -> ReaderHandoffActivity {
    if library.computerDocuments.isManaged(tab.session) {
      guard await library.computerDocuments.sync(tab, release: false),
            let value = library.computerDocuments.handoffActivity(for: tab) else {
        throw CompanionDocumentError.documentBusy
      }
      return value
    }
    return try await prepareLocal(tab, library: library)
  }

  nonisolated func userActivityWillSave(_ userActivity: NSUserActivity) {
    // Called during ordinary advertisement too: never release a document here.
    // All required fields already describe a committed snapshot.
    userActivity.needsSave = false
  }

  nonisolated func userActivityWasContinued(_ userActivity: NSUserActivity) {
    // Foundation delivers activity delegate callbacks on its own serial queue.
    // Carry only identity across executors; reader state belongs to MainActor.
    let identity = ObjectIdentifier(userActivity)
    Task { @MainActor [weak self] in
      guard let self, let activity = self.activity,
            ObjectIdentifier(activity) == identity else { return }
      self.completeContinuation(activity)
    }
  }

  private func completeContinuation(_ userActivity: NSUserActivity) {
    guard activity === userActivity else { return }
    recordDiagnostic(.continued, tab: tab, library: library)
    if let tab, let library, library.computerDocuments.isManaged(tab.session) {
      releaseForContinuation(userActivity)
    } else {
      userActivity.invalidate()
      activity = nil
      // Local snapshots are already committed and unlocked before publication.
      // Retire this reader too so it cannot keep editing the transferred copy.
      if let tab { onTransferred?(tab.id) }
      stop()
    }
  }

  private func releaseForContinuation(_ userActivity: NSUserActivity) {
    guard activity === userActivity, !isTransferring, let tab, let library,
          library.computerDocuments.isManaged(tab.session) else { return }
    isTransferring = true
    Task {
      let background = UIApplication.shared.beginBackgroundTask(withName: "Complete Handoff")
      defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
      guard await library.computerDocuments.releaseForHandoff(tab) else {
        isTransferring = false
        recordDiagnostic(.failed, tab: tab, library: library, error: CompanionDocumentError.documentBusy)
        userActivity.invalidate()
        return
      }
      recordDiagnostic(.released, tab: tab, library: library)
      // Closing the released tab prevents edits after the Mac becomes owner.
      onTransferred?(tab.id)
      stop()
    }
  }

  private func prepareLocal(_ tab: ReaderTab, library: LibraryModel) async throws -> ReaderHandoffActivity {
    let computer = normalizeCompanionURL(library.preferences.companionURL)
    guard !computer.isEmpty else { throw CompanionDocumentError.invalidServerURL }
    let code = try await KeychainCredentialStore().read(account: companionPairingCodeAccount) ?? ""
    guard !normalizeCompanionPairingCode(code).isEmpty else { throw CompanionDocumentError.missingPairingCode }
    await tab.annotations.prepare()
    await tab.annotations.flushPendingSaves()
    await tab.drawings.prepare()
    guard tab.annotations.lastError == nil, tab.drawings.lastError == nil,
          let source = tab.annotations.exportSourceData else { throw CompanionDocumentError.invalidDocument }
    tab.model.persistReadingState()

    // Capture only Sendable value data on the main actor. PDFKit annotation
    // validation and native-reference traversal are detached below; the
    // previous synchronous export could trip the iPad watchdog on large PDFs.
    let drawings = try tab.drawings.exportDrawings()
    let snapshot = LocalExportSnapshot(
      sourceData: source,
      annotations: tab.annotations.annotations,
      quickLinks: tab.annotations.quickLinks,
      readingState: tab.model.readingState,
      nativeRefs: tab.annotations.exportNativeRefs
    )
    let portable = try await Task.detached(priority: .utility) {
      try ReaderTransferPDF.export(
        sourceData: snapshot.sourceData,
        annotations: snapshot.annotations,
        quickLinks: snapshot.quickLinks,
        readingState: snapshot.readingState,
        nativeRefs: snapshot.nativeRefs
      )
    }.value
    // PencilKit values are intentionally kept on the main actor. This is the
    // same safe path used by the managed-document sync: only the expensive,
    // Sendable PDF transfer export is detached, while drawing rendering stays
    // within ReaderDrawingPDF's existing actor isolation.
    let data = try ReaderDrawingPDF.embed(drawings, in: portable)
    let pageCount = try await Task.detached(priority: .utility) {
      guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
        throw CompanionDocumentError.invalidDocument
      }
      return pdf.pageCount
    }.value
    let documentID = try await localTransfer.save(sourceID: tab.session.id,
      title: tab.session.title, computerURL: computer, pairingCode: code,
      pdf: data, pageCount: pageCount)
    return ReaderHandoffActivity(documentID: documentID, page: tab.model.readingState.page,
      serverURL: computer)
  }

  private func recordDiagnostic(
    _ status: DiagnosticStatus,
    tab: ReaderTab? = nil,
    library: LibraryModel? = nil,
    page: Int? = nil,
    error: Error? = nil
  ) {
    let page = page ?? tab?.model.readingState.page
    let safePage = page.flatMap { $0 > 0 ? $0 : nil }
    let isManaged = if let tab, let library {
      library.computerDocuments.isManaged(tab.session)
    } else {
      false
    }
    let safeError = error.map(Self.safeErrorInfo)
    let diagnostic = Diagnostic(
      status: status,
      time: Date(),
      errorDomain: safeError?.domain,
      errorCode: safeError?.code,
      errorDescription: safeError?.description,
      isManaged: isManaged,
      page: safePage
    )

    do {
      var encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(diagnostic)
      guard data.count <= Self.maximumDiagnosticBytes else {
        Self.logger.error("handoff diagnostic record exceeded its size bound")
        return
      }
      try FileManager.default.createDirectory(
        at: diagnosticURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: diagnosticURL, options: [.atomic])
      diagnosticHistory.append(diagnostic)
      diagnosticHistory = Array(diagnosticHistory.suffix(24))
      try encoder.encode(diagnosticHistory).write(
        to: diagnosticURL.deletingLastPathComponent().appendingPathComponent("diagnostic-history.json"),
        options: [.atomic])
    } catch {
      // Diagnostics are best effort and must never affect local reading.
      Self.logger.error("handoff diagnostic write failed")
    }

    let pageValue = safePage.map(String.init) ?? "-"
    if let safeError {
      Self.logger.error(
        "handoff status=\(status.rawValue, privacy: .public) managed=\(isManaged, privacy: .public) page=\(pageValue, privacy: .public) errorDomain=\(safeError.domain, privacy: .public) errorCode=\(safeError.code, privacy: .public) errorDescription=\(safeError.description, privacy: .public)"
      )
    } else {
      Self.logger.log(
        "handoff status=\(status.rawValue, privacy: .public) managed=\(isManaged, privacy: .public) page=\(pageValue, privacy: .public)"
      )
    }
  }

  private static func safeErrorInfo(_ error: Error) -> SafeErrorInfo {
    let nsError = error as NSError
    return SafeErrorInfo(
      domain: safeDiagnosticDomain(nsError.domain),
      code: nsError.code,
      description: safeDiagnosticDescription(error)
    )
  }

  private static func safeDiagnosticDomain(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let filtered = String(value.unicodeScalars.filter { allowed.contains($0) }.prefix(128))
    return filtered.isEmpty ? "Error" : filtered
  }

  private static func safeDiagnosticDescription(_ error: Error) -> String {
    guard let error = error as? CompanionDocumentError else {
      return "Handoff operation failed"
    }
    switch error {
    case .invalidServerURL: return "Invalid server URL"
    case .missingPairingCode: return "Missing pairing code"
    case .wrongPairingCode: return "Wrong pairing code"
    case .documentBusy: return "Document busy"
    case .desktopUpdateRequired: return "Desktop update required"
    case .invalidIdentifier: return "Invalid document identifier"
    case .invalidRequest: return "Invalid handoff request"
    case .invalidResponse: return "Invalid handoff response"
    case .invalidDocument: return "Invalid document"
    case .documentTooLarge: return "Document too large"
    case .responseTooLarge: return "Response too large"
    case .timeout: return "Handoff request timed out"
    case let .httpStatus(status) where (100...599).contains(status): return "HTTP status \(status)"
    case .httpStatus: return "HTTP status error"
    case .rateLimited: return "Handoff request rate limited"
    case .networkFailure: return "Network failure"
    }
  }
}
