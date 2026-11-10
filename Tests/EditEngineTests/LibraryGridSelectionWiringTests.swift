import XCTest
@testable import PhotoApp

/// Source pins for the Library grid's click and keyboard selection wiring (A1). Behaviour is in `GridSelectionTests`; these catch the
/// view wiring being undone (a single click opening the Editor again, an arrow no longer selecting, the photo keys acting on the selection).
final class LibraryGridSelectionWiringTests: XCTestCase {
    private func gridSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/UI/LibraryGridView.swift"), encoding: .utf8)
    }

    func testASingleClickNoLongerOpensTheEditor() throws {
        let source = try gridSource()
        XCTAssertFalse(source.contains(".onTapGesture(perform: onTap)"))
        XCTAssertFalse(source.contains("onTapGesture(count: 2"))
        XCTAssertTrue(source.contains("NSApp.currentEvent"))
        XCTAssertTrue(source.contains("GridSelection.clickEffect("))
    }

    func testTheVoiceOverActionStillOpens() throws {
        XCTAssertTrue(try gridSource().contains(".accessibilityAction { onOpen() }"))
    }

    func testEmptySpaceClearsTheSelection() throws {
        XCTAssertTrue(try gridSource().contains("if !flags.contains(.command), !flags.contains(.shift) { _ = catalog.clearGridSelection() }"))
    }

    func testShiftArrowsExtendInBothLayouts() throws {
        let source = try gridSource()
        XCTAssertTrue(source.contains("case .leftArrow: return moveFocus(by: -1, in: cells, extending: extend)"))
        XCTAssertTrue(source.contains("case .downArrow: return moveFocus(by: columnCount, in: cells, extending: extend)"))
        XCTAssertTrue(source.contains("moveFocusVertically(keyPress.key == .upArrow ? .up : .down, in: cells, extending: extend)"))
        XCTAssertTrue(source.contains("let extend = keyPress.modifiers.contains(.shift)"))
    }

    func testAPlainArrowSelectsOnlyTheCellItMovesTo() throws {
        let source = try gridSource()
        XCTAssertTrue(source.contains("catalog.selectOnlyGridCell(cells[index])"))
        XCTAssertTrue(source.contains("catalog.selectOnlyGridCell(cells[0])"))
        // Both movers route through the one helper, which is the only place a plain arrow selects.
        XCTAssertTrue(source.contains("private func moveSelection(toCellAt index: Int"))
        XCTAssertEqual(source.components(separatedBy: "moveSelection(toCellAt: ").count - 1, 2, "one call from each mover")
    }

    func testThePhotoKeysStillActOnTheFocusedCellOnly() throws {
        let source = try gridSource()
        XCTAssertTrue(source.contains("setRatingOnFocused(digit, in: displayed)"))
        XCTAssertFalse(source.contains("selectedPhotos"))
        let start = try XCTUnwrap(source.range(of: "private func advanceFocusIfNoLongerVisible("))
        let body = String(source[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("catalog.focusedPhotoPath ="))
        XCTAssertFalse(body.contains("Selection") || body.contains("selectOnly"), "advanceFocusIfNoLongerVisible must move the focus only")
    }

    func testSelectedCellsUseTheThemeSelectionMarks() throws {
        let source = try gridSource()
        XCTAssertTrue(source.contains("Theme.selectedFill"))
        XCTAssertTrue(source.contains("Theme.selectedOutline"))
        XCTAssertTrue(source.contains("if CellChrome.showsSelectionPlate(selectionState) {"), "the card must be drawn from the cell's selection state")
    }
}
