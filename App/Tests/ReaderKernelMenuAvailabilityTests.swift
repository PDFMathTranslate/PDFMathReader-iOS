import Foundation
import ReaderCore
import XCTest

@testable import PDFMathReader

private struct ReaderKernelMenuMockOutcome: Sendable {
  let statusCode: Int
  let body: Data
  let fails: Bool
}

private final class ReaderKernelMenuMockState: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome = ReaderKernelMenuMockOutcome(statusCode: 200, body: Data(), fails: false)
  private var paths: [String] = []

  func install(_ outcome: ReaderKernelMenuMockOutcome) {
    lock.lock()
    self.outcome = outcome
    paths.removeAll()
    lock.unlock()
  }

  func record(_ path: String) -> ReaderKernelMenuMockOutcome {
    lock.lock()
    paths.append(path)
    let outcome = self.outcome
    lock.unlock()
    return outcome
  }

  func requestedPaths() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return paths
  }
}

private final class ReaderKernelMenuURLProtocol: URLProtocol, @unchecked Sendable {
  private static let state = ReaderKernelMenuMockState()

  static func install(statusCode: Int = 200, body: Data = Data(), fails: Bool = false) {
    state.install(ReaderKernelMenuMockOutcome(statusCode: statusCode, body: body, fails: fails))
  }

  static func requestedPaths() -> [String] {
    state.requestedPaths()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let outcome = Self.state.record(request.url?.path ?? "")
    if outcome.fails {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: outcome.statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: outcome.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func readerKernelMenuTestSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ReaderKernelMenuURLProtocol.self]
  return URLSession(configuration: configuration)
}

final class ReaderKernelMenuAvailabilityTests: XCTestCase {
  private let remoteURL = "http://kernel.test:8890"

  @MainActor
  func testEnabledHealthyRemoteAddsPreciseAndMarksRemoteAvailable() async {
    ReaderKernelMenuURLProtocol.install(
      body: Data(#"{"status":"ok","version":"4.1.7"}"#.utf8)
    )
    let session = readerKernelMenuTestSession()
    defer { session.invalidateAndCancel() }
    let client = RemoteKernelClient(session: session)
    let availability = ReaderKernelMenuAvailability(remote: client)
    let preferences = ReaderPreferences(
      remoteKernelURL: remoteURL,
      remoteKernelEnabled: true
    )

    await availability.refresh(preferences)

    XCTAssertEqual(availability.engines, [.ultraFast, .precise])
    XCTAssertTrue(availability.remotePreciseAvailable)
    XCTAssertEqual(ReaderKernelMenuURLProtocol.requestedPaths(), ["/health"])
  }

  @MainActor
  func testDisabledRemoteDoesNotProbeOrExposePrecise() async {
    ReaderKernelMenuURLProtocol.install(
      body: Data(#"{"status":"ok","version":"4.1.7"}"#.utf8)
    )
    let session = readerKernelMenuTestSession()
    defer { session.invalidateAndCancel() }
    let client = RemoteKernelClient(session: session)
    let availability = ReaderKernelMenuAvailability(remote: client)
    let preferences = ReaderPreferences(
      remoteKernelURL: remoteURL,
      remoteKernelEnabled: false
    )

    await availability.refresh(preferences)

    XCTAssertEqual(availability.engines, [.ultraFast])
    XCTAssertFalse(availability.remotePreciseAvailable)
    XCTAssertTrue(ReaderKernelMenuURLProtocol.requestedPaths().isEmpty)
  }

  @MainActor
  func testUnreachableRemoteHidesPrecise() async {
    ReaderKernelMenuURLProtocol.install(fails: true)
    let session = readerKernelMenuTestSession()
    defer { session.invalidateAndCancel() }
    let client = RemoteKernelClient(session: session)
    let availability = ReaderKernelMenuAvailability(remote: client)
    let preferences = ReaderPreferences(
      remoteKernelURL: remoteURL,
      remoteKernelEnabled: true
    )

    await availability.refresh(preferences)

    XCTAssertEqual(availability.engines, [.ultraFast])
    XCTAssertFalse(availability.remotePreciseAvailable)
    XCTAssertEqual(ReaderKernelMenuURLProtocol.requestedPaths(), ["/health"])
  }
}
