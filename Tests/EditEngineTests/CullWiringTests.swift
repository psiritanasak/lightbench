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
        // Copy / Paste Settings, Create Virtual Copy, Stack, Merge, XMP and Rename Files read the model, which is off in `.cull`
        // (`testTheModelItemsAreOffWhileCulling` below); the scene must hand it the cull state.
        XCTAssertTrue(text.contains("cullActive: cull.isActive, showLibrary: showLibrary, exportActive: false"), "the model's cull mode comes from the cull model")
        for (title, needle) in [("Edit Keywords", "cullActive: cull.isActive, libraryBlocked: keywordsLibraryBlocked"),
                                ("Find Duplicates", "cull.isActive || !showLibrary || catalog.duplicatesSheetPresented"),
                                ("Undo Rename", "cull.isActive || !renameModel.canUndo")] {
            XCTAssertTrue(text.contains(needle), "\(title) must be disabled while culling")
        }
    }

    func testTheModelItemsAreOffWhileCulling() {
        var target = PhotoActionTarget()
        target.count = 3
        target.visibleCount = 3
        target.virtualCopyCount = 3
        target.isOpenPhoto = true
        var context = PhotoActionContext()
        context.hasCopiedSettings = true
        context.hasOpenImage = true
        let ids: [PhotoActionID] = [.copySettings, .pasteSettings, .createVirtualCopy, .stackSelected, .unstack, .mergeHDR, .mergePanorama,
                                    .writeXMP, .readXMP, .renameFiles, .editKeywords, .editInfo]
        for id in ids { XCTAssertTrue(PhotoActionMenu.isEnabled(id, target: target, context: context), "\(id) is on in the Library") }
        context.mode = .cull
        for id in ids { XCTAssertFalse(PhotoActionMenu.isEnabled(id, target: target, context: context), "\(id) must be disabled while culling") }
    }

    /// The View menu and the bare app keys are off while the cull view is up: the pure rules say so for every command and key, and the
    /// scene / `ContentView` build the context from the cull model.
    func testViewMenuAndAppKeysAreOffWhileCulling() throws {
        var context = ViewCommandContext()
        context.hasOpenImage = true
        context.canCompare = true
        context.canRevert = true
        context.canExport = true
        let commands: [ViewCommand] = [.showLibrary, .showEditor, .toggleBefore, .toggleSideBySide, .setCompare(.split),
                                       .selectTab(.crop), .toggleFilmstrip, .revertToOriginal, .export]
        context.mode = .library
        XCTAssertTrue(ViewCommandRules.isEnabled(.showEditor, context: context), "the rules are not simply always off")
        context.mode = .cull
        for command in commands { XCTAssertFalse(ViewCommandRules.isEnabled(command, context: context), "\(command) must be off while culling") }
        for scalar in 32...126 {
            let character = Character(UnicodeScalar(UInt8(scalar)))
            XCTAssertNil(AppKeyCommand.command(for: character, mode: .cull), "\"\(character)\" must not be an app key while culling")
        }
        let app = try source("Sources/App/PhotoAppApp.swift").joined(separator: "\n")
        XCTAssertTrue(app.contains("c.mode = cull.isActive ? .cull : (showLibrary ? .library : .editor)"), "the scene builds the view context from the cull model")
        let content = try source("Sources/UI/ContentView.swift").joined(separator: "\n")
        XCTAssertTrue(content.contains("c.mode = cull.isActive ? .cull : (showLibrary ? .library : .editor)"))
        XCTAssertTrue(content.contains("guard !cull.isActive, let character = keyPress.characters.first else { return .ignored }"))
    }

    /// A held key must not flag a run of photos: repeats are ignored for everything but moving.
    func testKeyRepeatOnlyMovesNeverFlags() throws {
        let view = try source("Sources/UI/CullView.swift").joined(separator: "\n")
        XCTAssertTrue(view.contains("press.phase == .repeat"))
        XCTAssertTrue(view.contains("case .previous, .next: break"))
    }
}

