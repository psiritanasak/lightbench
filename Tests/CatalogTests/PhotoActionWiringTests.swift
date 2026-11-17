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
}
