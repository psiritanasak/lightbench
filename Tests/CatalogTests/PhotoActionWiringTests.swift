import XCTest
@testable import PhotoApp

/// Source pins for the photo action menu's UI wiring (batch 3: the grid cell's menu).
final class PhotoActionWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheGridCellMenuComesFromTheModel() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains(".contextMenu {"))
        XCTAssertTrue(grid.contains("PhotoActionMenuItems("))
        XCTAssertFalse(grid.contains("folder.badge.plus"), "the ellipsis replaced the folder glyph")
        XCTAssertTrue(grid.contains("ellipsis.circle") && grid.contains(".accessibilityLabel(\"Photo options\")"))
        for literal in ["\"Remove from Library\"", "\"Make Cover\"", "\"Create Virtual Copy\""] {
            XCTAssertFalse(grid.contains(literal), "\(literal) is a model title now")
        }
        XCTAssertFalse(grid.contains("onRequestRemoval"))
    }

    func testTheCellMenuUsesTheGhostFreeSelectionAndTheTargetRule() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("PhotoActionTarget.ghostFreeSelection(catalog: catalog, cells: items)"))
        XCTAssertTrue(grid.contains("selection: actions.selection, selectionTarget: actions.selectionTarget"), "forCell gets the ghost-free selection")
        XCTAssertTrue(grid.contains("PhotoActionMenu.cellPlan(for: item, hasCell: target.cell != nil, selection: selection)"), "the pure plan decides")
        XCTAssertTrue(grid.contains("catalog.selectOnlyGridCell(item)"))
        XCTAssertTrue(grid.contains("clicked: plan.passesClicked ? item.photo : nil, batchIDs: plan.batchIDs"), "the plan sets the clicked photo and the rate/flag/label ids")
        XCTAssertEqual(grid.components(separatedBy: "PhotoActionTarget.selection(").count - 1, 1, "the selection target is built once per grid body")
    }

    func testTheRemovalAlertAndRelocateStay() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("\"Remove from Library?\""))
        XCTAssertTrue(grid.contains("catalog.removePhoto(photo)"))
        XCTAssertEqual(grid.components(separatedBy: ".alert(").count - 1, 1)
        let performer = try source("Sources/UI/PhotoActionPerformer.swift")
        XCTAssertTrue(performer.contains("catalog.relocatePhoto(clicked)") && performer.contains("catalog.relocateSelectedPhotos()"))
        XCTAssertTrue(performer.contains("requestRemoval?(clicked)"))
    }

    func testThePerformerCallsWhatTheOldItemsCalled() throws {
        let performer = try source("Sources/UI/PhotoActionPerformer.swift")
        for needle in [
            "catalog.createVirtualCopies(", "catalog.keywordSheetRequested = true", "catalog.editorKeywordsToggleRequested = true",
            "catalog.infoSheetRequested = true", "catalog.editorInfoToggleRequested = true",
            "pasteModel.copy(document.editState, fileName: document.currentFileName ?? \"photo\")",
            "pasteModel.requestPaste(onto: catalog.selectedPhotos)", "catalog.stackSelected()", "catalog.unstackSelected()",
            "catalog.mergeRequested = .hdr", "catalog.mergeRequested = .panorama", "catalog.xmpRequested = .write", "catalog.xmpRequested = .read",
            "renameModel.request = .rename", "catalog.trashRequested = .selected", "catalog.toggleMembership(of: clicked, in: collection)",
            "catalog.addSelectedPhotos(to: collection)", "catalog.setRating(stars, forPhotoIDs: ids)",
            "catalog.setFlagStatus(status, forPhotoIDs: ids)", "catalog.setColorLabel(label, forPhotoIDs: ids)", "catalog.clearSelection()",
            "beginExport?()", "catalog.post(.error("
        ] {
            XCTAssertTrue(performer.contains(needle), needle)
        }
        XCTAssertFalse(performer.contains("ToastCenter") || performer.contains("ActivityCenter"))
    }

    func testTheContentViewBuildsTheContextAndPerformerOutsideBody() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("private var photoActionContext: PhotoActionContext {"))
        XCTAssertTrue(content.contains("private var photoActionPerformer: PhotoActionPerformer {"))
        XCTAssertTrue(content.contains("LibraryGridView(catalog: catalog, actionContext: photoActionContext, performer: photoActionPerformer)"))
        XCTAssertTrue(content.contains("beginExport: { exportModel.beginExport() }"))
        XCTAssertTrue(content.contains("cullActive: cull.isActive"))
    }

    func testTheMenuItemsViewKeepsTheCheckmarkAndRedLabelPattern() throws {
        let items = try source("Sources/UI/PhotoActionMenuItems.swift")
        XCTAssertTrue(items.contains("\\(entry.title), current") && items.contains("\\(collection.name), member"))
        XCTAssertTrue(items.contains(".foregroundStyle(.red)"))
        XCTAssertFalse(items.contains(".secondary") || items.contains(".accentColor"))
    }

    // MARK: The selection bar replaced the toolbar's selection menu

    func testTheToolbarSelectionMenuIsGone() throws {
        let content = try source("Sources/UI/ContentView.swift")
        // Each needle was in the removed toolbar block and nowhere else in ContentView (checked when the block was deleted).
        for needle in ["\"Selected\", systemImage: \"checkmark.circle\"", "Stack Selected (", "catalog.mergeRequested", "catalog.xmpRequested",
                       "trashRequested = .selected", "pasteModel.requestPaste(", "Clear Selection", "Locate Selected"] {
            XCTAssertFalse(content.contains(needle), needle)
        }
        // The toolbar keeps its Export button.
        XCTAssertTrue(content.contains("exportModel.beginExport()") && content.contains("exportButtonTitle"))
    }

    func testTheBarIsMountedOutsideTheFeedbackAreaOnRawIDsAndTheGridStaysFocused() throws {
        let grid = try source("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("catalog.selectedPhotoIDs.count >= 2"), "the raw ids, ghosts included (D33)")
        let area = try XCTUnwrap(grid.range(of: ".feedbackArea()")).lowerBound
        let bar = try XCTUnwrap(grid.range(of: "LibrarySelectionBar(")).lowerBound
        let sizeBar = try XCTUnwrap(grid.range(of: "thumbnailSizeBar\n")).lowerBound
        XCTAssertLessThan(area, bar)
        XCTAssertLessThan(bar, sizeBar, "between the grid and the thumbnail-size bar")
        XCTAssertTrue(grid.contains("onDidAct: { isGridFocused = true }"))
        XCTAssertTrue(grid.contains("accessibilityReduceMotion"))
        let barSource = try source("Sources/UI/LibrarySelectionBar.swift")
        XCTAssertTrue(barSource.contains("PhotoActionMenuItems(") && barSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(barSource.contains("ToastCenter") || barSource.contains("ActivityCenter"))
        XCTAssertFalse(barSource.contains(".feedbackArea()") || barSource.contains(".alert(") || barSource.contains(".sheet("))
        XCTAssertFalse(barSource.contains("CellPlan") || barSource.contains("forCell"), "the bar target has no cell")
        XCTAssertTrue(barSource.contains("perform(.run(.clearSelection))"))
        XCTAssertFalse(barSource.contains("gridPhotos") || barSource.contains("selectedPhotos."), "the bar reads the grid's target, no second filter + sort")
        XCTAssertTrue(barSource.contains("alignment: .leading") && !barSource.contains(".fixedSize(horizontal: true"), "Clear sits at the right edge")
        XCTAssertFalse(barSource.contains(".disabled(!isEnabled(.clearSelection"), "Clear is never gated (D33)")
    }

    func testTheEmptyCollectionAdvicePointsAtTheRightClickMenu() throws {
        let text = try source("Sources/UI/EmptyStates.swift")
        XCTAssertTrue(text.contains("right-click them and choose \\u{201c}Add to Collection\\u{201d}."))
        XCTAssertFalse(text.contains("selection menu in the toolbar"))
    }

    // MARK: The Photo menu reads the model

    func testThePhotoMenuTakesTitleAndEnabledStateFromTheModelAndRunsThroughThePerformer() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        let ids = ["copySettings", "pasteSettings", "createVirtualCopy", "stackSelected", "unstack", "mergeHDR", "mergePanorama",
                   "writeXMP", "readXMP", "renameFiles", "editKeywords", "editInfo"]
        for id in ids {
            XCTAssertTrue(app.contains("PhotoActionMenu.title(.\(id))"), id)
            XCTAssertTrue(app.contains("actions.perform(.run(.\(id)), clicked: nil)"), id)
            XCTAssertTrue(app.contains("PhotoActionMenu.isEnabled(.\(id), target: actionTarget, context: actionContext)"), id)
        }
        for literal in ["\"Merge Photos to HDR…\"", "\"Merge Photos to Panorama…\"", "\"Locate Selected…\"", "\"Copy Settings\"", "\"Paste Settings\"",
                        "\"Create Virtual Copy\"", "\"Stack Selected\"", "\"Unstack\"", "\"Edit Keywords…\"", "\"Edit Info…\"",
                        "\"Rename Files…\"", "\"Write Metadata to XMP…\"", "\"Read Metadata from XMP…\""] {
            XCTAssertFalse(app.contains("Button(\(literal))"), "\(literal) is a model title now")
        }
        // The context, target and performer are bound once, outside the buttons; the scene cannot see the export or the grid's alert.
        XCTAssertEqual(app.components(separatedBy: "PhotoActionTarget.menuBar(").count - 1, 1)
        XCTAssertEqual(app.components(separatedBy: "PhotoActionContext.make(").count - 1, 1)
        XCTAssertTrue(app.contains("cullActive: cull.isActive, showLibrary: showLibrary, exportActive: false"))
        XCTAssertTrue(app.contains("open: nil, requestRemoval: nil, beginExport: nil"))
        XCTAssertTrue(app.contains("cullActive: cull.isActive, openEditKey: document.currentEditKey, hasOpenImage: document.currentImage != nil"))
        let performer = try source("Sources/UI/PhotoActionPerformer.swift")
        let early = try XCTUnwrap(performer.range(of: "if cullActive { return target }")).lowerBound
        let filter = try XCTUnwrap(performer.range(of: "catalog.selectedPhotosInDisplayedGrid.count")).lowerBound
        XCTAssertLessThan(early, filter, "culling returns before the filter + sort")
        XCTAssertFalse(app.contains("selectedPhotosInDisplayedGrid") || app.contains("virtualCopyTargets("), "the scene body never filters and sorts the library itself")
        XCTAssertTrue(try source("Sources/UI/PhotoActionPerformer.swift").contains("context.editorPopoverOpen = catalog.editorPopoverOpen"))
    }

    /// The model titles that no other file uses are the single source of the label; the ones another file also spells (a sheet's own
    /// title, the Editor rating bar's button) are different controls with their own wording, listed here so a new copy is a decision.
    func testEachModelTitleLiteralLivesInOneFileUnlessAnotherControlLegitimatelySharesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        var files: [(String, String)] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        let shared: [PhotoActionID: Set<String>] = [
            .copySettings: ["EditorRatingBar.swift", "PasteSettingsModel.swift", "ContentView.swift"],
            .pasteSettings: ["ImageDocumentModel.swift", "PasteSettingsModel.swift", "ContentView.swift"],
            .collectionMenu: ["CatalogModel.swift", "ContentView.swift"],
            .editKeywords: ["KeywordSheetView.swift", "CatalogModel.swift", "EditorKeywordsModel.swift"],
            .editInfo: ["InfoSheetView.swift", "CatalogModel.swift", "EditorInfoModel.swift"],
            .createVirtualCopy: ["CatalogModel.swift", "VirtualCopyModel.swift", "VirtualCopyFiles.swift"],
            .writeXMP: ["XMPModel.swift"], .readXMP: ["CatalogModel.swift", "XMPModel.swift", "XMPImportPolicy.swift"],
            .renameFiles: ["CatalogModel.swift", "RenameSheetView.swift", "RenameModel.swift", "ContentView.swift", "NamingTemplate.swift",
                           "RenameSummary.swift", "CatalogDatabase.swift", "009_rename_log.swift"],
            .moveToTrash: ["TrashModel.swift"], .export: ["ContentView.swift"],
            .ratingMenu: ["LibraryGridView.swift", "LibraryFilterBar.swift"], .flagMenu: ["LibraryGridView.swift", "LibraryFilterBar.swift"],
            .labelMenu: ["LibraryFilterBar.swift"], .metadataMenu: ["ExportOptionsView.swift"],
            .clearSelection: ["InfoSheetView.swift", "PeopleSheetView.swift"]
        ]
        for id in PhotoActionID.allCases {
            let literal = "\"\(PhotoActionMenu.title(id))\""
            let holders = Set(files.filter { $0.1.contains(literal) }.map(\.0))
            XCTAssertTrue(holders.contains("PhotoActionMenu.swift"), "\(id)")
            XCTAssertEqual(holders.subtracting(["PhotoActionMenu.swift"]), shared[id] ?? [], "\(literal) appears in an unexpected file")
        }
    }
}
