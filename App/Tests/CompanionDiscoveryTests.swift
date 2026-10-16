import Foundation
import ReaderCore
import XCTest

@testable import PDFMathReader

private final class QuietCompanionBrowser: NetServiceBrowser {
  override func searchForServices(ofType type: String, inDomain domainString: String) {}
  override func stop() {}
}

private final class TailnetCompanionService: NetService {
  override var hostName: String? { "computer.local." }
  override var port: Int { 8891 }
  override func resolve(withTimeout timeout: TimeInterval) {}
  override func stop() {}
  override func txtRecordData() -> Data? {
    NetService.data(fromTXTRecord: [
      "ts": Data("100.80.1.2,fd7a:115c:a1e0::1234,192.168.1.2,100.100.100.100".utf8)
    ])
  }
}

@MainActor
final class CompanionDiscoveryTests: XCTestCase {
  func testBonjourLearnsOnlyTailnetAddressesIncludingIPv6() async throws {
    let suite = "CompanionDiscoveryTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let browser = QuietCompanionBrowser()
    let discovery = CompanionDiscovery(defaults: defaults, makeBrowser: { browser }, probe: { _ in true })
    let service = TailnetCompanionService(domain: "local.", type: "_pdfmathreader._tcp.", name: "Computer")
    discovery.start()
    discovery.netServiceBrowser(browser, didFind: service, moreComing: false)
    discovery.netServiceDidResolveAddress(service)
    for _ in 0..<100 where discovery.computers.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(Set(discovery.computers.map(\.address)), [
      "http://computer.local:8891", "http://100.80.1.2:8891", "http://[fd7a:115c:a1e0::1234]:8891"
    ])
    XCTAssertTrue(discovery.hasRememberedComputers)
    discovery.stop()
  }

  func testRememberedTailnetComputersSurviveRestartAndForget() async throws {
    let suite = "CompanionDiscoveryTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = CompanionDiscovery(defaults: defaults, makeBrowser: { QuietCompanionBrowser() }, probe: { _ in true })
    first.rememberConnection(address: "100.80.1.2", computer: nil)
    first.rememberConnection(address: "https://example.com", computer: nil)
    XCTAssertTrue(first.hasRememberedComputers)

    let restored = CompanionDiscovery(defaults: defaults, makeBrowser: { QuietCompanionBrowser() }, probe: { _ in true })
    restored.start()
    for _ in 0..<100 where restored.computers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(restored.computers.map(\.address), ["http://100.80.1.2:8891"])
    restored.forgetComputers()
    XCTAssertTrue(restored.computers.isEmpty)
    XCTAssertFalse(restored.hasRememberedComputers)
    restored.stop()
    let forgotten = CompanionDiscovery(defaults: defaults)
    XCTAssertFalse(forgotten.hasRememberedComputers)
  }

  func testStoppedSearchCannotRepopulateFromLateProbe() async throws {
    let suite = "CompanionDiscoveryTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = DiscoveryProbeGate()
    let discovery = CompanionDiscovery(defaults: defaults, makeBrowser: { QuietCompanionBrowser() }, probe: { _ in
      await gate.wait()
    })
    discovery.rememberConnection(address: "100.80.1.2", computer: nil)
    discovery.start()
    for _ in 0..<100 {
      if await gate.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await gate.started
    XCTAssertTrue(started)
    guard started else { discovery.stop(); return }
    discovery.stop()
    await gate.finish()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(discovery.isSearching)
    XCTAssertTrue(discovery.computers.isEmpty)
  }

  func testBonjourFailureDoesNotCancelTailnetSearch() async throws {
    let suite = "CompanionDiscoveryTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let browser = QuietCompanionBrowser()
    let discovery = CompanionDiscovery(defaults: defaults, makeBrowser: { browser }, probe: { _ in true })
    discovery.rememberConnection(address: "100.80.1.2", computer: nil)
    discovery.start()
    discovery.netServiceBrowser(browser, didNotSearch: [:])
    for _ in 0..<100 where discovery.computers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(discovery.failed)
    XCTAssertEqual(discovery.computers.count, 1)
    discovery.stop()
  }
}

private actor DiscoveryProbeGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  private(set) var started = false

  func wait() async -> Bool {
    await withCheckedContinuation {
      continuation = $0
      started = true
    }
  }

  func finish() {
    continuation?.resume(returning: true)
    continuation = nil
  }
}
