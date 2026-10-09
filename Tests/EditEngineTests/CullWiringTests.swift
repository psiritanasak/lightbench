import XCTest
@testable import PhotoApp

/// The app-level wiring of culling cannot be driven by key events here, so these pin it in the source: while culling, ⌘Z must undo the
/// CULL action (never the Editor's edit history), Redo and the Editor's prev / next photo (⌘←/⌘→) must be off, and the toolbar must hide.
final class CullWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
    }

    func testCommandZRoutesToTheCullUndoWhileCulling() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains { $0.contains("if cull.isActive { cull.undo() } else { document.undo() }") })
        XCTAssertTrue(app.contains { $0.contains("cull.isActive ? !cull.canUndo : !document.canUndo") })
        XCTAssertTrue(app.contains { $0.contains("cull.isActive || !document.canRedo") }, "Redo is off while culling")
    }

    func testEditorNavigationIsOffWhileCulling() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains { $0.contains("guard !showLibrary, !cull.isActive") }, "⌘←/⌘→ must not open Editor photos behind the cull view")
    }

    func testTheCullViewReplacesTheWindowAndHidesTheToolbar() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains { $0.contains("if cull.isActive {") })
        XCTAssertTrue(content.contains { $0.contains(".toolbar(cull.isActive ? .hidden : .automatic, for: .windowToolbar)") })
    }

    /// Menu items that act on the hidden Library selection or the hidden Editor photo must be off while the cull view is up.
    func testPhotoMenuItemsThatActOnHiddenStateAreOffWhileCulling() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        let text = app.joined(separator: "\n")
        for (title, needle) in [("Copy Settings", "cull.isActive || document.currentImage == nil"),
                                ("Paste Settings", "cull.isActive || pasteModel.copied == nil"),
                                ("Edit Keywords", "cull.isActive || !showLibrary || catalog.selectedPhotos.isEmpty"),
                                ("Find Duplicates", "cull.isActive || !showLibrary || catalog.duplicatesSheetPresented"),
                                ("Rename Files", "cull.isActive || catalog.selectedPhotos.isEmpty"),
                                ("Undo Rename", "cull.isActive || !renameModel.canUndo")] {
            XCTAssertTrue(text.contains(needle), "\(title) must be disabled while culling")
        }
    }

    /// A held key must not flag a run of photos: repeats are ignored for everything but moving.
    func testKeyRepeatOnlyMovesNeverFlags() throws {
        let view = try source("Sources/UI/CullView.swift").joined(separator: "\n")
        XCTAssertTrue(view.contains("press.phase == .repeat"))
        XCTAssertTrue(view.contains("case .previous, .next: break"))
    }
}

