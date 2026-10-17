import Foundation
import PDFKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderTabsModelTests: XCTestCase {
  func testDragCloseReturnsToStartPageAndRetainsOtherTabs() throws {
    let fixture = try makeFixture(ids: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()
    fixture.sessions.forEach { tabs.open($0, library: library) }
    let retained = try XCTUnwrap(tabs.tabs.first)

    tabs.close("second", showStartPage: true)

    XCTAssertNil(tabs.selectedTab)
    XCTAssertEqual(tabs.tabs.map(\.id), ["first"])
    tabs.open(fixture.sessions[0], library: library)
    XCTAssertTrue(tabs.selectedTab === retained)
  }

  func testOpeningDuplicateSelectsExistingTabWithoutAddingAnother() throws {
    let fixture = try makeFixture(ids: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    tabs.open(fixture.sessions[0], library: library)
    tabs.open(fixture.sessions[1], library: library)
    let firstTab = try XCTUnwrap(tabs.tabs.first)

    tabs.open(fixture.sessions[0], library: library)

    XCTAssertEqual(tabs.tabs.map(\.id), ["first", "second"])
    XCTAssertEqual(tabs.selectedID, "first")
    XCTAssertTrue(tabs.selectedTab === firstTab)
  }

  func testClosingActiveTabSelectsNeighbor() throws {
    let fixture = try makeFixture(ids: ["first", "second", "third"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    fixture.sessions.forEach { tabs.open($0, library: library) }
    tabs.select("second")
    tabs.close("second")

    XCTAssertEqual(tabs.tabs.map(\.id), ["first", "third"])
    XCTAssertEqual(tabs.selectedID, "third")
  }

  func testClosingInactiveTabRetainsSelection() throws {
    let fixture = try makeFixture(ids: ["first", "second", "third"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    fixture.sessions.forEach { tabs.open($0, library: library) }
    tabs.select("third")
    tabs.close("first")

    XCTAssertEqual(tabs.tabs.map(\.id), ["second", "third"])
    XCTAssertEqual(tabs.selectedID, "third")
  }

  func testClosingLastTabClearsSelection() throws {
    let fixture = try makeFixture(ids: ["only"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    tabs.open(fixture.sessions[0], library: library)
    tabs.close("only")

    XCTAssertTrue(tabs.tabs.isEmpty)
    XCTAssertNil(tabs.selectedID)
    XCTAssertNil(tabs.selectedTab)
  }

  func testSelectingUnknownTabIsANoOp() throws {
    let fixture = try makeFixture(ids: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    fixture.sessions.forEach { tabs.open($0, library: library) }
    tabs.select("first")
    let selectedTab = tabs.selectedTab

    tabs.select("missing")

    XCTAssertEqual(tabs.selectedID, "first")
    XCTAssertTrue(tabs.selectedTab === selectedTab)
  }

  func testTabModelIdentitySurvivesSwitching() throws {
    let fixture = try makeFixture(ids: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = LibraryModel(directory: fixture.libraryDirectory)
    let tabs = ReaderTabsModel()

    tabs.open(fixture.sessions[0], library: library)
    let firstTab = try XCTUnwrap(tabs.selectedTab)
    let firstModel = firstTab.model
    tabs.open(fixture.sessions[1], library: library)
    tabs.select("first")

    XCTAssertTrue(tabs.selectedTab === firstTab)
    XCTAssertTrue(tabs.selectedTab?.model === firstModel)
  }

  private func makeFixture(ids: [String]) throws -> (
    root: URL,
    libraryDirectory: URL,
    sessions: [DocumentSession]
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFMathReader-ReaderTabsModelTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sessions = try ids.map { id -> DocumentSession in
      let document = PDFDocument()
      let page = PDFPage()
      page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
      document.insert(page, at: 0)
      let url = root.appendingPathComponent("\(id).pdf")
      try XCTUnwrap(document.dataRepresentation()).write(to: url)
      return DocumentSession(
        id: id,
        title: "\(id).pdf",
        url: url,
        access: SecurityScopedAccess(url: url)
      )
    }

    return (
      root: root,
      libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
      sessions: sessions
    )
  }
}
