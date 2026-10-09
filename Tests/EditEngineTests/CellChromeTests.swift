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

    /// Live-caught (2026-10-09): the row `.opacity` was once attached AFTER the cell's outer VStack closed, which dimmed the thumbnail and
    /// filename too. It must follow the control row's own `HStack(spacing: 4) { … }`: the braces from that HStack's opening to the modifier
    /// must balance to exactly zero (the HStack is closed, and nothing bigger is).
    func testTheRowOpacityIsAttachedToTheControlRowAndNothingBigger() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/LibraryGridView.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let modifier = try XCTUnwrap(lines.firstIndex { $0.contains(".opacity(CellChrome.rowOpacity(") })
        let start = try XCTUnwrap(lines[..<modifier].lastIndex { $0.contains("HStack(spacing: 4) {") })
        var depth = 0
        for line in lines[start..<modifier] {
            let code = line.components(separatedBy: "//").first ?? ""
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
        }
        XCTAssertEqual(depth, 0, "the modifier must directly follow the control row's HStack, not an enclosing container")
    }
}

