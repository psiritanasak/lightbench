import XCTest
@testable import PhotoApp

final class HistoryRowTests: XCTestCase {
    private func entries(_ summaries: [String]) -> [HistoryEntry] {
        summaries.map { HistoryEntry(state: EditState(), summary: $0) }
    }

    func testRowsAreNewestFirstAndKeepTheEntryIDs() {
        let e = entries(["Opened", "Exposure", "Contrast"])
        let rows = HistoryRow.rows(entries: e, currentIndex: 2)
        XCTAssertEqual(rows.map(\.summary), ["Contrast", "Exposure", "Opened"])
        XCTAssertEqual(rows.map(\.id), e.reversed().map(\.id))
    }

    func testPositionsAroundTheCursor() {
        let rows = HistoryRow.rows(entries: entries(["a", "b", "c", "d"]), currentIndex: 1)
        // newest first: d (undone), c (undone), b (current), a (past)
        XCTAssertEqual(rows.map(\.position), [.undone, .undone, .current, .past])
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.summary), ["b"])
    }

    func testTheCursorAtEitherEnd() {
        let e = entries(["a", "b", "c"])
        XCTAssertEqual(HistoryRow.rows(entries: e, currentIndex: 2).map(\.position), [.current, .past, .past])
        XCTAssertEqual(HistoryRow.rows(entries: e, currentIndex: 0).map(\.position), [.undone, .undone, .current])
    }

    func testAccessibilityTextMatchesTheOldAdjustSectionStrings() {
        let rows = HistoryRow.rows(entries: entries(["Opened", "Exposure EV", "Contrast"]), currentIndex: 1)
        XCTAssertEqual(rows.map(\.accessibilityText), ["Contrast, undone", "Exposure EV, current", "Opened"])
    }

    func testAnIndexOutsideTheListMarksNoRowCurrent() {
        let e = entries(["a", "b"])
        XCTAssertEqual(HistoryRow.rows(entries: e, currentIndex: 5).map(\.position), [.past, .past])
        XCTAssertEqual(HistoryRow.rows(entries: e, currentIndex: -1).map(\.position), [.undone, .undone])
    }

    func testEmptyAndFullTimelines() {
        XCTAssertTrue(HistoryRow.rows(entries: [], currentIndex: 0).isEmpty)
        let full = entries((0..<101).map { "e\($0)" })
        let rows = HistoryRow.rows(entries: full, currentIndex: 100)
        XCTAssertEqual(rows.count, 101)
        XCTAssertEqual(rows.first?.summary, "e100")
        XCTAssertEqual(rows.first?.position, .current)
        XCTAssertEqual(rows.last?.summary, "e0")
        XCTAssertEqual(Set(rows.map(\.id)).count, 101)
    }
}
