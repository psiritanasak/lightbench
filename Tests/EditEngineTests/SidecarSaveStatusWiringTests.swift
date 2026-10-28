import XCTest
@testable import PhotoApp

/// Source pins for the "Edits not saved" indicator: the Editor's bar is built through the host that observes the document, and
/// the new UI uses theme tokens only.
final class SidecarSaveStatusWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testContentViewBuildsTheBarThroughTheStatusHost() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("EditorRatingBarHost("))
        XCTAssertFalse(content.contains("EditorRatingBar("), "the bare bar has no document, so it could never show the status")
    }

    func testTheHostReadsTheModelsStatusAndConfirmsTheReload() throws {
        let host = try source("Sources/UI/EditorRatingBarHost.swift")
        XCTAssertTrue(host.contains("document.sidecarSaveStatus"))
        XCTAssertTrue(host.contains("confirmationDialog"))
        XCTAssertTrue(host.contains("reloadCurrentPhotoFromSidecar"))
        XCTAssertTrue(host.contains("activateFileViewerSelecting"))
        XCTAssertTrue(host.contains("grantAccessAndRetrySidecarSave"))
        XCTAssertTrue(host.contains("retrySidecarSave"))
    }

    func testTheChipUsesTheWarningTokenNotARawColour() throws {
        for file in ["Sources/UI/EditorRatingBar.swift", "Sources/UI/EditorRatingBarHost.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains(".orange"), file)
            XCTAssertFalse(text.contains(".yellow"), file)
            XCTAssertFalse(text.contains(".accentColor"), file)
        }
        XCTAssertTrue(try source("Sources/UI/EditorRatingBar.swift").contains("Theme.warning"))
    }
}
