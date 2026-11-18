import XCTest
@testable import PhotoApp

final class LibraryFilterBarLayoutTests: XCTestCase {
    private typealias L = LibraryFilterBarLayout

    func testModeIsCollapsedBelowTheFullRowAndFullFromIt() {
        for people in [false, true] {
            let full = L.fullRowWidth(showsPeople: people)
            XCTAssertEqual(L.mode(forWidth: 0, showsPeople: people), .collapsed)
            XCTAssertEqual(L.mode(forWidth: 576, showsPeople: people), .collapsed)
            XCTAssertEqual(L.mode(forWidth: full - 0.5, showsPeople: people), .collapsed)
            XCTAssertEqual(L.mode(forWidth: full, showsPeople: people), .full)
            XCTAssertEqual(L.mode(forWidth: 1400 + full, showsPeople: people), .full)
        }
    }

    func testPeopleAddsOnePopUpAndOneGap() {
        XCTAssertEqual(L.fullRowWidth(showsPeople: true) - L.fullRowWidth(showsPeople: false), L.personWidth + L.spacing)
    }

    func testFullRowWidthIsTheHandWrittenSum() {
        // 8 children (search, help, spacer, rating, flag, label, keyword, clear) = 7 gaps; with Person 9 children = 8 gaps.
        let noPeople = 2 * L.horizontalPadding + L.searchIdealWidth + L.iconSlot + 0 + L.ratingWidth + L.flagWidth
            + L.labelWidth + L.keywordWidth + L.iconSlot + 7 * L.spacing
        XCTAssertEqual(L.fullRowWidth(showsPeople: false), noPeople)
        XCTAssertEqual(L.fullRowWidth(showsPeople: true), noPeople + L.personWidth + L.spacing)
    }

    func testFiltersTitleAndAccessibilityValue() {
        XCTAssertEqual(L.filtersTitle(count: 0), "Filters")
        XCTAssertEqual(L.filtersTitle(count: 3), "Filters (3)")
        XCTAssertEqual(L.filtersAccessibilityValue(count: 0), "none active")
        XCTAssertEqual(L.filtersAccessibilityValue(count: 1), "1 active")
        XCTAssertEqual(L.filtersAccessibilityValue(count: 4), "4 active")
    }
}
