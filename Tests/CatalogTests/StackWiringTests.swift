import XCTest
@testable import PhotoApp

/// Source-scan wiring for photo stacks (the Info sheet's wiring tests' pattern): the busy flags, the menus, the shortcut catalog and
/// the places that must keep reading the FLAT list.
final class StackWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func lines(_ path: String, containing needle: String) throws -> [Substring] {
        try source(path).split(separator: "\n").filter { $0.contains(needle) }
    }

    // MARK: Busy flags

    /// Every guard that names the People sheet (the closest sibling: a sheet with a scan) must also name the Auto Stack sheet, in the
    /// Photo menu and in the sheet modifiers. (The People modifier's own line is `blocked` for others: it has no "own flag" term.)
    func testEveryGuardThatNamesThePeopleSheetAlsoNamesTheAutoStackSheet() throws {
        for path in ["Sources/App/PhotoAppApp.swift", "Sources/UI/DuplicatesSheetView.swift"] {
            for line in try lines(path, containing: "catalog.peopleSheetPresented") where !line.contains("AutoStackSheetModifier(") {
                XCTAssertTrue(line.contains("catalog.autoStackSheetPresented"), "\(path): \(line)")
            }
        }
    }

    func testEverySheetModifierBlocksOnTheAutoStackSheet() throws {
        let sheets = try source("Sources/UI/DuplicatesSheetView.swift")
        for modifier in ["KeywordSheetModifier", "InfoSheetModifier", "DuplicatesSheetModifier", "PeopleSheetModifier", "MergeDialogModifier",
                         "XMPDialogModifier", "TrashDialogModifier", "ImportCopyDialogModifier", "CatalogBackupDialogModifier"] {
            let start = try XCTUnwrap(sheets.range(of: ".modifier(\(modifier)("), "\(modifier) is registered").lowerBound
            let rest = sheets[start...]
            let end = rest.range(of: "))\n")?.upperBound ?? rest.endIndex
            XCTAssertTrue(rest[..<end].contains("catalog.autoStackSheetPresented"), "\(modifier) must not open over the Auto Stack sheet")
        }
        XCTAssertEqual(sheets.components(separatedBy: ".modifier(AutoStackSheetModifier(").count - 1, 1)
        // The Auto Stack sheet itself yields to every other sheet and dialog.
        let line = try XCTUnwrap(try lines("Sources/UI/DuplicatesSheetView.swift", containing: "AutoStackSheetModifier(").first)
        for flag in ["keywordSheetPhotoIDs", "infoSheetPhotoIDs", "duplicatesSheetPresented", "peopleSheetPresented", "mergeBusy", "fileToolBusy"] {
            XCTAssertTrue(line.contains(flag), "Auto Stack must not open over \(flag)")
        }
    }

    func testBatchRenameAndTheMenusSeeTheAutoStackSheetAndItsScan() throws {
        let model = try source("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(model.contains("peopleSheetPresented || autoStackSheetPresented || autoStack.isWorking || faces.isWorking || mergeBusy"),
                      "toolSheetIsBusy (the other pins keep reading its tail)")
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("isToolScanRunning: catalog.faces.isWorking || catalog.duplicates.isScanning || catalog.autoStack.isWorking"),
                      "a running Auto Stack scan blocks batch rename like the other scans")
    }

    // MARK: Menus

    func testThePhotoMenuHasTheStackItemsAndTheShortcutsAreListed() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Stack Selected\")"))
        XCTAssertTrue(app.contains("Button(\"Unstack\")"))
        XCTAssertTrue(app.contains("Button(\"Auto Stack…\") { catalog.autoStackSheetRequested = true }"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"g\", modifiers: .command)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"g\", modifiers: [.command, .shift])"))
        // Library only, and not while culling.
        for item in ["Stack Selected", "Unstack", "Auto Stack…"] {
            let from = try XCTUnwrap(app.range(of: "Button(\"\(item)\")")).lowerBound
            let window = app[from...].prefix(900)
            XCTAssertTrue(window.contains("cull.isActive || !showLibrary"), "\(item): Library only")
        }
        let keys = KeyboardShortcutCatalog.sections.flatMap(\.entries).map(\.keys)
        XCTAssertTrue(keys.contains("\u{2318}G  \u{21E7}\u{2318}G"))
    }

    func testTheSelectionMenuHasTheStackItemsNextToEditInfo() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("Button(\"Stack Selected (\\(selectedPhotosVisibleInGrid.count))\")"))
        XCTAssertTrue(content.contains("Button(\"Unstack (\\(selectedPhotosVisibleInGrid.count))\")"))
        let info = try XCTUnwrap(content.range(of: "Button(\"Edit Info (")).lowerBound
        let stack = try XCTUnwrap(content.range(of: "Button(\"Stack Selected (")).lowerBound
        XCTAssertLessThan(info, stack)
    }

    // MARK: The grid reads cells; everything else reads the flat list

    func testTheGridDrawsAndNavigatesTheSameCells() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("let items = catalog.gridPhotos") && grid.contains("ForEach(items) { item in"))
        XCTAssertTrue(grid.contains("let displayed = cells.map(\\.photo)"), "arrows, Return and the photo keys walk the cells")
        XCTAssertTrue(grid.contains("let freshList = catalog.gridCellPhotos"), "focus advance walks the cells")
        XCTAssertTrue(grid.contains("catalog.toggleSelection(of: item)"), "the checkbox ticks the cell, not just its cover")
        XCTAssertFalse(grid.contains("ForEach(catalog.displayedPhotos)"))
        XCTAssertTrue(grid.contains("isFocused: focusKey == photo.editKey"), "the focus ring uses the resolved key")
        XCTAssertTrue(grid.contains("catalog.normalizeFocus(in: cells)"), "every key handler starts from a normalised focus")
        XCTAssertEqual(grid.components(separatedBy: "StackCellPresentation.scrollTarget(forFocusedKey:").count - 1, 2, "scroll-to and the initial scroll target the cell id")
        XCTAssertTrue(grid.contains(".id(item.cellID)"), "the cell view is rebuilt when its stack role changes")
        XCTAssertFalse(grid.contains(".id(photo.editKey)"), "an editKey id would keep a stale badge across a role change")
        XCTAssertTrue(grid.contains("minus.circle.fill"), "a partly selected stack shows a mixed checkbox")
        XCTAssertTrue(grid.contains("selectionState != .none"))
        XCTAssertTrue(grid.contains("Make Cover") && grid.contains("Remove from Stack"))
    }

    func testCullFilmstripNavigationAndExportKeepTheFlatList() throws {
        for path in ["Sources/UI/CullView.swift", "Sources/UI/CullModel.swift", "Sources/UI/EditorFilmstripView.swift", "Sources/UI/CullSession.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("gridPhotos") || text.contains("gridCellPhotos") || text.contains("StackDisplay"),
                           "\(path) ignores stacking in v1 (a collapsed stack's members are still in it)")
        }
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertFalse(app.contains("gridPhotos"), "⌘←/⌘→ walk the flat displayed list")
    }

    // MARK: The sheet's promises

    func testTheSheetSaysWhatItWillAndWillNotDo() throws {
        let sheet = try source("Sources/UI/AutoStackSheetView.swift")
        for promise in ["Nothing changes until you press Apply", "Stacks you made or changed by hand are never changed",
                        "Photos you unstacked are remembered", "Forget unstacked photos", "Camera data is still being read",
                        "best-rated, Picked or largest", "rules of thumb"] {
            XCTAssertTrue(sheet.contains(promise), promise)
        }
        XCTAssertTrue(sheet.contains("covering"), "the preview names stacks and photos")
    }

    func testAutoStackReusesTheDuplicateScannerWithoutHashing() throws {
        let model = try source("Sources/UI/AutoStackModel.swift")
        XCTAssertTrue(model.contains("DuplicateScanner.scan("))
        XCTAssertTrue(model.contains("hash: { _ in nil }"))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("catalog.normalizeFocus() // Cull ignores stacks"), "leaving Cull normalises focus")
        // refresh() and applyAutoStack call normalizeFocus explicitly; their behaviour tests also pass through setStacks (which normalises
        // too), so these two calls are pinned by source rather than by a discriminating behaviour test.
        XCTAssertTrue(try source("Sources/UI/CatalogModel.swift").contains("normalizeFocus() // the photos or the stacks changed"))
        XCTAssertTrue(try source("Sources/UI/CatalogModel+Stacks.swift").contains("await self?.refresh()\n            self?.normalizeFocus()"))
        XCTAssertTrue(try source("Sources/UI/AutoStackSheetView.swift").contains("model.shownCount"), "the scope count is not recomputed on every redraw")
        XCTAssertFalse(try source("Sources/UI/AutoStackSheetView.swift").contains("catalog.autoStackScopePhotos.count) photos shown"))
        let sheet = try source("Sources/UI/AutoStackSheetView.swift")
        XCTAssertTrue(sheet.contains("&& !catalog.autoStack.isWorking"), "the sheet cannot be reopened over a running Apply")
        XCTAssertTrue(sheet.contains(".disabled(!model.canApply)") && sheet.contains("interactiveDismissDisabled(model.isApplying)"))
        XCTAssertTrue(try source("Sources/App/PhotoAppApp.swift").contains("catalog.autoStackSheetPresented || catalog.autoStack.isWorking || catalog.duplicatesSheetPresented"),
                      "the Auto Stack menu item is off while it works")
        XCTAssertTrue(sheet.contains("whole library") && sheet.contains("Narrow the view"))
        XCTAssertTrue(model.contains("replaceAutomaticStacks(inScope: plan.plannedIDs, with: plan.proposals)"))
        XCTAssertTrue(model.contains("Task.detached"), "planning runs off the main thread")
        XCTAssertFalse(model.contains("removeItem") || model.contains("moveItem") || model.contains("trashItem"), "no file is ever touched")
    }
}
