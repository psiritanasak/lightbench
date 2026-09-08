import XCTest
@testable import PhotoApp

/// Verifies `LibraryGridColumns.count` — the pure fit formula D4
/// (IMPROVEMENTS.md) relies on for BOTH the Library grid's explicit column
/// count and Up/Down arrow-key row math, so a bug here would desync the
/// two (arrows jumping the wrong number of rows relative to what's
/// actually on screen).
final class LibraryGridColumnsTests: XCTestCase {
    func testExactFitCountsAllColumns() {
        // 3 columns of 100 + 2 gaps of 12 = 324, exactly the width.
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 324, cellSize: 100, spacing: 12), 3)
    }

    func testRemainderNarrowerThanOneMoreColumnStaysAtTheLowerCount() {
        // Same as above plus a few extra points — not enough for a 4th
        // column (100 + 12 = 112 needed) — must still report 3, not 4.
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 330, cellSize: 100, spacing: 12), 3)
    }

    func testRemainderWideEnoughForOneMoreColumnCountsIt() {
        // 4 columns of 100 + 3 gaps of 12 = 436, exactly enough for a 4th.
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 436, cellSize: 100, spacing: 12), 4)
    }

    func testNarrowerThanOneCellStillReportsOneColumn() {
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 50, cellSize: 100, spacing: 12), 1)
    }

    func testZeroWidthReportsOneColumnNotZero() {
        // The real failure mode this guards: a `GeometryReader` reporting
        // `0` on its very first layout pass, before the real width is
        // known — must never compute a grid with zero columns.
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 0, cellSize: 100, spacing: 12), 1)
    }

    func testNegativeWidthReportsOneColumn() {
        XCTAssertEqual(LibraryGridColumns.count(forWidth: -10, cellSize: 100, spacing: 12), 1)
    }

    func testNonPositiveCellSizeAndSpacingDoesNotDivideByZero() {
        let result = LibraryGridColumns.count(forWidth: 500, cellSize: 0, spacing: 0)
        XCTAssertFalse(Double(result).isNaN)
        XCTAssertEqual(result, 1)
    }

    func testZeroCellSizeWithPositiveSpacingReportsOneColumn() {
        // Reviewer-caught regression: the old guard only checked
        // `cellSize + spacing > 0`, so a zero `cellSize` with a real
        // `spacing` slipped through and returned a large, meaningless
        // column count instead of the documented fallback.
        XCTAssertEqual(LibraryGridColumns.count(forWidth: 500, cellSize: 0, spacing: 12), 1)
    }

    func testHugeFiniteWidthDoesNotTrapOnIntConversion() {
        let result = LibraryGridColumns.count(forWidth: 1e300, cellSize: 100, spacing: 12)
        XCTAssertEqual(result, 1_000_000)
    }

    func testNonFiniteWidthReportsOneColumn() {
        XCTAssertEqual(LibraryGridColumns.count(forWidth: .infinity, cellSize: 100, spacing: 12), 1)
        XCTAssertEqual(LibraryGridColumns.count(forWidth: .nan, cellSize: 100, spacing: 12), 1)
    }
}
