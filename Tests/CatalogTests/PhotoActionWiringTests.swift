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
}
