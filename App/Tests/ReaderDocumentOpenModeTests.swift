import PDFKit
import ReaderCore
import UIKit
import XCTest

@testable import PDFMathReader

@MainActor
final class ReaderDocumentOpenModeTests: XCTestCase {
  private func coordinator(_ mode: ReaderDocumentOpenMode = .original) throws -> ReaderTranslationCoordinator {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { renderer in
      renderer.beginPage()
      ("A scientific paragraph." as NSString).draw(at: CGPoint(x: 30, y: 40))
    }
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = mode
    // An invalid base URL prevents requests even if the simulator has a saved key.
    preferences.translationService = .openAICompatible
    preferences.openAIBaseURL = "http://["
    return ReaderTranslationCoordinator(document: try XCTUnwrap(PDFDocument(data: data)),
      documentID: UUID().uuidString, preferences: preferences, sourceData: data)
  }

  func testDefaultDoesNotConfigureOrScheduleUntilExplicitlyEnabled() async throws {
    let reader = try coordinator()
    reader.updateViewport(currentPageIndex: 0, visiblePageIndices: [0])
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertFalse(reader.translationEnabled)
    XCTAssertFalse(reader.showTranslations)
    XCTAssertNil(reader.appleTranslationLanguages)
    XCTAssertTrue(reader.debugPipelineStatus.contains("pipeline not ready"))
    reader.toggleTranslations()
    XCTAssertTrue(reader.translationEnabled)
    XCTAssertTrue(reader.showTranslations)
    reader.toggleTranslations()
    XCTAssertTrue(reader.translationEnabled)
    XCTAssertFalse(reader.showTranslations)
  }

  func testOpenModesSeparateWorkFromVisibilityAndSettingsDoNotResetSessionToggle() throws {
    let background = try coordinator(.originalWithBackgroundTranslation)
    XCTAssertTrue(background.translationEnabled)
    XCTAssertFalse(background.showTranslations)
    let translated = try coordinator(.translated)
    XCTAssertTrue(translated.translationEnabled)
    XCTAssertTrue(translated.showTranslations)
    translated.toggleTranslations()
    var preferences = ReaderPreferences()
    preferences.documentOpenMode = .translated
    preferences.theme = .dark
    translated.updatePreferences(preferences)
    XCTAssertFalse(translated.showTranslations)
    preferences.documentOpenMode = .original
    translated.updatePreferences(preferences)
    XCTAssertFalse(translated.translationEnabled)
    XCTAssertFalse(translated.showTranslations)
  }
}
