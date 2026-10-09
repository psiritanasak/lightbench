import XCTest
@testable import PhotoApp

final class CellChromeTests: XCTestCase {
    private let bools = [false, true]

    /// Every combination: the row is dimmed ONLY when nothing at all calls for it.
    func testTheControlRowDimsOnlyWhenNothingCallsForIt() {
        for hovered in bools { for selected in bools { for focused in bools { for info in bools {
            let o = CellChrome.rowOpacity(isHovered: hovered, isSelected: selected, isFocused: focused, hasRatingFlagOrLabel: info)
            let anyReason = hovered || selected || focused || info
            XCTAssertEqual(o, anyReason ? 1 : CellChrome.dimmedRowOpacity, "h\(hovered) s\(selected) f\(focused) i\(info)")
        } } } }
    }

    func testTheCheckCircleDimsOnlyWhenUnselectedUnhoveredAndNothingIsSelected() {
        for hovered in bools { for selected in bools { for any in bools {
            let o = CellChrome.checkOpacity(isHovered: hovered, isSelected: selected, anySelected: any)
            XCTAssertEqual(o, (hovered || selected || any) ? 1 : CellChrome.dimmedCheckOpacity, "h\(hovered) s\(selected) a\(any)")
        } } }
    }

    func testRatedFlaggedOrLabelledPhotosAreNeverDimmed() {
        XCTAssertEqual(CellChrome.rowOpacity(isHovered: false, isSelected: false, isFocused: false, hasRatingFlagOrLabel: true), 1)
    }

    /// Dimmed means still visible and still tappable (opacity only — a touchpad has no hover): a floor well above invisible, below full.
    func testTheDimmedLevelsAreVisibleButClearlyQuieter() {
        for level in [CellChrome.dimmedRowOpacity, CellChrome.dimmedCheckOpacity] {
            XCTAssertGreaterThanOrEqual(level, 0.25)
            XCTAssertLessThanOrEqual(level, 0.6)
        }
    }

    /// The chrome is dimmed with `.opacity`, never removed with `if`/`.hidden()` (layout, hit area and VoiceOver unchanged).
    func testTheCellOnlyDimsAndNeverRemovesTheControls() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/LibraryGridView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(".opacity(CellChrome.rowOpacity("))
        XCTAssertTrue(text.contains(".opacity(CellChrome.checkOpacity("))
        XCTAssertFalse(text.contains(".hidden()"), "no control in the grid is hidden outright")
    }
}
