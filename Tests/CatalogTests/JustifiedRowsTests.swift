import XCTest
@testable import PhotoApp

/// The justified-rows layout maths (`JustifiedRows`): pure, so every rule is checked on numbers.
final class JustifiedRowsTests: XCTestCase {
    private func layout(_ aspects: [Double], width: Double = 900, target: Double = 150, spacing: Double = 8,
                        minWidth: Double = 116) -> [JustifiedRows.Row] {
        JustifiedRows.layout(aspects: aspects, availableWidth: width, targetRowHeight: target, spacing: spacing, minCellWidth: minWidth)
    }

    private func total(_ row: JustifiedRows.Row, spacing: Double = 8) -> Double {
        row.items.reduce(0) { $0 + $1.width } + Double(max(0, row.items.count - 1)) * spacing
    }

    private let mixed: [Double] = [1.5, 0.67, 1.5, 1.0, 2.0, 0.75, 1.33, 1.5, 0.67, 1.0, 1.78, 1.5, 0.8, 1.5, 1.0]

    func testEmptyInputGivesNoRows() {
        XCTAssertTrue(layout([]).isEmpty)
    }

    func testEveryJustifiedRowFillsTheWidthExactly() {
        let rows = layout(mixed)
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows where row.isJustified {
            XCTAssertEqual(total(row), 900, accuracy: 1e-6)
        }
    }

    func testAllPhotosOfARowShareTheRowHeightAndKeepTheirOrder() {
        let rows = layout(mixed)
        XCTAssertEqual(rows.flatMap { $0.items.map(\.index) }, Array(0..<mixed.count), "every photo once, in order")
        for row in rows where row.isJustified && row.items.count > 1 && !row.items.contains(where: { abs($0.width - 116) < 1e-6 }) {
            // In a row where no cell had to be raised to the minimum width, width / height == the aspect ratio: the photo is not distorted.
            // (A row WITH a raised cell shrinks the others by a few percent to make room; they are then cropped by `.fill`, never stretched.)
            for item in row.items {
                let aspect = min(3.0, max(116.0 / 150.0, mixed[item.index]))
                XCTAssertEqual(item.width / row.height, aspect, accuracy: 0.02, "photo \(item.index) keeps its shape")
            }
        }
    }

    func testRowHeightsStayNearTheTarget() {
        for row in layout(mixed) where row.isJustified {
            XCTAssertGreaterThan(row.height, 150 * 0.55)
            XCTAssertLessThan(row.height, 150 * 1.8)
        }
    }

    func testNoCellIsNarrowerThanTheMinimum() {
        let tall = [Double](repeating: 0.4, count: 12) + [1.5, 1.5] + [Double](repeating: 0.3, count: 5)
        for row in layout(tall) {
            for item in row.items { XCTAssertGreaterThanOrEqual(item.width, 116 - 1e-6, "photo \(item.index)") }
        }
        for row in layout(tall) where row.isJustified { XCTAssertEqual(total(row), 900, accuracy: 1e-6) }
    }

    func testAShortLastRowIsLeftAtTheTargetHeight() throws {
        let rows = layout([1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.0])
        let last = try XCTUnwrap(rows.last)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertFalse(last.isJustified, "2 of 4 photos' worth of width is well under 70% full")
        XCTAssertEqual(last.height, 150, accuracy: 1e-9)
        XCTAssertLessThan(total(last), 900 * 0.7)
    }

    func testANearlyFullLastRowIsJustified() throws {
        // Eight 3:2 photos make two rows of four (see the squeeze test); three more are a last row of 3 * 225 + 2 * 8 = 691 pt, 77% of 900: justified.
        let rows = layout([Double](repeating: 1.5, count: 11))
        XCTAssertEqual(rows.map { $0.items.count }, [4, 4, 3])
        let last = try XCTUnwrap(rows.last)
        XCTAssertTrue(last.isJustified)
        XCTAssertEqual(total(last), 900, accuracy: 1e-6)
    }

    func testTheNextPhotoIsSqueezedInWhenThatKeepsTheScaleCloserToOne() {
        // Three 3:2 photos fill 3 * 225 + 2 * 8 = 691 pt of 900 (stretch x1.31); a fourth squeezes the row to x0.97, which is closer to 1.
        let rows = layout([Double](repeating: 1.5, count: 8))
        XCTAssertEqual(rows.map { $0.items.count }, [4, 4])
        XCTAssertLessThan(rows[0].height, 150, "the squeezed row is a little shorter than the target")
    }

    func testAPanoramaAndATallPhotoAreClampedNotDistorted() throws {
        let rows = layout([6.0, 0.1, 1.5, 1.5, 1.5, 1.5])
        let first = try XCTUnwrap(rows.first?.items.first)
        XCTAssertLessThanOrEqual(first.width / rows[0].height, 3.0 + 1e-6, "a 6:1 panorama is treated as 3:1")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rows.first?.items.dropFirst().first).width, 116 - 1e-6)
    }

    func testOnePhotoAlone() {
        let rows = layout([1.5])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].items.count, 1)
        XCTAssertFalse(rows[0].isJustified, "a lone photo is a short last row: it keeps the target height")
        XCTAssertEqual(rows[0].height, 150, accuracy: 1e-9)
    }

    func testBadAspectsCountAsSquare() {
        let bad = layout([.nan, -2, 0, .infinity, 1.0])
        let good = layout([1.0, 1.0, 1.0, 1.0, 1.0])
        XCTAssertEqual(bad, good)
    }

    func testAnAvailableWidthSmallerThanOneCellStillGivesOneMinimumCellPerRow() {
        let rows = layout([1.5, 1.0, 1.0], width: 60)
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(row.items.count, 1)
            XCTAssertGreaterThanOrEqual(row.items[0].width, 116 - 1e-6)
        }
    }

    func testBadParametersFallBackToUsableOnes() {
        let rows = JustifiedRows.layout(aspects: [1, 1, 1], availableWidth: .nan, targetRowHeight: -5, spacing: .infinity)
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertTrue(row.height.isFinite && row.height > 0) }
    }

    func testLayoutIsDeterministic() {
        XCTAssertEqual(layout(mixed), layout(mixed))
    }

    func testXOffsetsAreCumulative() {
        for row in layout(mixed) {
            var x = 0.0
            for item in row.items {
                XCTAssertEqual(item.x, x, accuracy: 1e-9)
                x += item.width + 8
            }
        }
    }

    // MARK: Up / Down

    func testNeighborPicksTheNearestCentreInTheAdjacentRow() throws {
        let rows = layout(mixed)
        XCTAssertGreaterThan(rows.count, 2)
        let middle = rows[1].items[rows[1].items.count / 2]
        let up = try XCTUnwrap(JustifiedRows.neighbor(of: middle.index, direction: .up, in: rows))
        XCTAssertTrue(rows[0].items.contains { $0.index == up })
        let centre = middle.x + middle.width / 2
        let best = try XCTUnwrap(rows[0].items.min { abs($0.x + $0.width / 2 - centre) < abs($1.x + $1.width / 2 - centre) })
        XCTAssertEqual(up, best.index)
        let down = try XCTUnwrap(JustifiedRows.neighbor(of: middle.index, direction: .down, in: rows))
        XCTAssertTrue(rows[2].items.contains { $0.index == down })
    }

    func testNeighborIsNilAtTheEdges() {
        let rows = layout(mixed)
        XCTAssertNil(JustifiedRows.neighbor(of: rows[0].items[0].index, direction: .up, in: rows))
        XCTAssertNil(JustifiedRows.neighbor(of: rows[rows.count - 1].items[0].index, direction: .down, in: rows))
        XCTAssertNil(JustifiedRows.neighbor(of: 9999, direction: .down, in: rows), "an index that is not in the layout")
    }

    func testDownFromTheRowAboveAShortLastRowStillLands() throws {
        let rows = layout([1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.0, 1.0])
        guard rows.count >= 2 else { return XCTFail("need at least two rows") }
        let above = try XCTUnwrap(rows[rows.count - 2].items.last)
        let down = JustifiedRows.neighbor(of: above.index, direction: .down, in: rows)
        XCTAssertNotNil(down, "unlike the square grid's +columnCount, a short last row can still be reached")
        XCTAssertTrue(rows[rows.count - 1].items.contains { $0.index == down })
    }

    func testRowIndex() {
        let rows = layout(mixed)
        XCTAssertEqual(JustifiedRows.rowIndex(of: 0, in: rows), 0)
        XCTAssertNil(JustifiedRows.rowIndex(of: -1, in: rows))
    }
}
