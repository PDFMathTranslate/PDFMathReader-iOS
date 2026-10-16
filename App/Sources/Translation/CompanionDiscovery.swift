import Combine
import Foundation
import Network
import ReaderCore

/// Browses only while the user is choosing a computer. Discovery supplies an
/// address, never credentials; the companion health request still authenticates.
@MainActor
final class CompanionDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate,
  @preconcurrency NetServiceDelegate
{
  struct Computer: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
  }

  @Published private(set) var computers: [Computer] = []
  @Published private(set) var isSearching = false
  @Published private(set) var failed = false
  @Published private(set) var hasRememberedComputers = false
  private var browser: NetServiceBrowser?
  private var services: [String: NetService] = [:]
  private let defaults: UserDefaults
  private let makeBrowser: () -> NetServiceBrowser
  private let probe: @Sendable (String) async -> Bool
  private var probes: [String: Task<Void, Never>] = [:]
  private var generation = UUID()
  private static let storageKey = "companion.rememberedTailscaleComputers.v1"

  private struct RememberedComputer: Codable {
    let name: String
    let address: String
  }

  init(
    defaults: UserDefaults = .standard,
    makeBrowser: @escaping () -> NetServiceBrowser = { NetServiceBrowser() },
    probe: @escaping @Sendable (String) async -> Bool = { await CompanionReachability.check($0) }
  ) {
    self.defaults = defaults
    self.makeBrowser = makeBrowser
    self.probe = probe
    super.init()
    hasRememberedComputers = !remembered().isEmpty
  }

  func start() {
    stop()
    computers = []
    failed = false
    isSearching = true
    let browser = makeBrowser()
    self.browser = browser
    browser.delegate = self
    browser.searchForServices(ofType: "_pdfmathreader._tcp.", inDomain: "local.")
    for computer in remembered() { searchRemembered(computer) }
  }

  func stop() {
    generation = UUID()
    for task in probes.values { task.cancel() }
    probes = [:]
    browser?.delegate = nil
    browser?.stop()
    browser = nil
    for service in services.values {
      service.delegate = nil
      service.stop()
    }
    services = [:]
    computers = []
    isSearching = false
  }

  /// Called only after authentication; older desktops simply remember a
  /// manually entered Tailscale address without needing metadata support.
  func rememberConnection(address: String, computer: CompanionComputer?) {
    let name = computer?.name ?? URLComponents(string: normalizeCompanionURL(address))?.host ?? address
    remember(name: name, addresses: [address] + (computer?.addresses ?? []))
  }

  func forgetComputers() {
    defaults.removeObject(forKey: Self.storageKey)
    hasRememberedComputers = false
    for task in probes.values { task.cancel() }
    probes = [:]
    generation = UUID()
    computers.removeAll { $0.id.hasPrefix("tailscale:") }
  }

  private func remembered() -> [RememberedComputer] {
    guard let data = defaults.data(forKey: Self.storageKey),
      let values = try? JSONDecoder().decode([RememberedComputer].self, from: data)
    else { return [] }
    return Array(values.filter { tailscaleCompanionURL($0.address) != nil }.prefix(16))
  }

  private func remember(name: String, addresses: [String]) {
    var values = remembered()
    for raw in addresses.prefix(8) {
      guard let address = tailscaleCompanionURL(raw) else { continue }
      values.removeAll { $0.address == address }
      let value = RememberedComputer(name: String(name.prefix(128)), address: address)
      values.insert(value, at: 0)
      if isSearching { searchRemembered(value) }
    }
    values = Array(values.prefix(16))
    if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.storageKey) }
    hasRememberedComputers = !values.isEmpty
  }

  private func searchRemembered(_ computer: RememberedComputer) {
    guard probes[computer.address] == nil else { return }
    let currentGeneration = generation
    let probe = probe
    probes[computer.address] = Task { [weak self] in
      let reachable = await probe(computer.address)
      guard !Task.isCancelled, let self, generation == currentGeneration, isSearching else { return }
      guard reachable else { return }
      let id = "tailscale:\(computer.address)"
      computers.removeAll { $0.id == id }
      computers.append(Computer(id: id, name: computer.name, address: computer.address))
      sortComputers()
    }
  }

  private func sortComputers() {
    computers.sort {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.address < $1.address : order == .orderedAscending
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard browser === self.browser else { return }
    let id = identifier(service)
    guard services[id] == nil else { return }
    services[id] = service
    service.delegate = self
    service.resolve(withTimeout: 10)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    guard browser === self.browser else { return }
    let id = identifier(service)
    if let removed = services.removeValue(forKey: id) {
      removed.delegate = nil
      removed.stop()
    }
    computers.removeAll { $0.id == id }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    guard browser === self.browser else { return }
    // A denied Wi-Fi permission must not cancel reachable tailnet computers.
    browser.delegate = nil
    browser.stop()
    self.browser = nil
    failed = true
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    let id = identifier(sender)
    guard services[id] === sender, let host = sender.hostName, sender.port > 0 else { return }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host.hasSuffix(".") ? String(host.dropLast()) : host
    components.port = sender.port
    guard let address = components.url?.absoluteString else { return }
    computers.removeAll { $0.id == id }
    computers.append(Computer(id: id, name: sender.name, address: address))
    sortComputers()
    if let data = sender.txtRecordData(), data.count <= 2048,
      let addresses = NetService.dictionary(fromTXTRecord: data)["ts"],
      let text = String(data: addresses, encoding: .utf8)
    {
      let urls = text.split(separator: ",").prefix(8).compactMap { ip -> String? in
        guard isTailscaleHost(String(ip)) else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = ip.contains(":") ? "[\(ip)]" : String(ip)
        parts.port = sender.port
        return parts.url?.absoluteString
      }
      remember(name: sender.name, addresses: urls)
    }
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    let id = identifier(sender)
    guard services[id] === sender else { return }
    sender.delegate = nil
    sender.stop()
    services.removeValue(forKey: id)
  }

  private func identifier(_ service: NetService) -> String {
    "\(service.name).\(service.type)\(service.domain)"
  }
}

/// A bounded TCP reachability check, with no pairing code, PDF, or API request.
/// It only contacts addresses previously learned or successfully paired.
@MainActor
private final class CompanionReachability {
  private let connection: NWConnection
  private var continuation: CheckedContinuation<Bool, Never>?
  private var timeout: Task<Void, Never>?
  private var finished = false

  private init(host: String, port: UInt16) {
    connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  }

  static func check(_ address: String) async -> Bool {
    guard let valid = tailscaleCompanionURL(address), let url = URL(string: valid),
      let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
      let port = UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)), port > 0
    else { return false }
    let check = CompanionReachability(host: host, port: port)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled || check.finished { continuation.resume(returning: false); return }
        check.continuation = continuation
        check.connection.stateUpdateHandler = { state in
          Task { @MainActor in
            switch state {
            case .ready: check.finish(true)
            case .failed, .cancelled: check.finish(false)
            default: break
            }
          }
        }
        check.connection.start(queue: .main)
        check.timeout = Task {
          do { try await Task.sleep(for: .seconds(4)) } catch { return }
          check.finish(false)
        }
      }
    } onCancel: {
      Task { @MainActor in check.finish(false) }
    }
  }

  private func finish(_ reachable: Bool) {
    guard !finished else { return }
    finished = true
    connection.stateUpdateHandler = nil
    connection.cancel()
    timeout?.cancel()
    timeout = nil
    continuation?.resume(returning: reachable)
    continuation = nil
  }
}
