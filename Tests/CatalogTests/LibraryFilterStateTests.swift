import XCTest
@testable import PhotoApp

final class LibraryFilterStateTests: XCTestCase {
    func testDefaultsAreInactive() {
        let s = LibraryFilterState()
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.activeCount, 0)
    }

    func testEachFilterCountsOnItsOwn() {
        var s = LibraryFilterState(); s.minimumRating = 1
        XCTAssertTrue(s.isRatingActive); XCTAssertEqual(s.activeCount, 1)
        s = LibraryFilterState(); s.flagFilter = .notRejected
        XCTAssertTrue(s.isFlagActive); XCTAssertEqual(s.activeCount, 1)
        s = LibraryFilterState(); s.labelFilter = .unlabeled
        XCTAssertTrue(s.isLabelActive); XCTAssertEqual(s.activeCount, 1)
        s = LibraryFilterState(); s.keywordFilterID = 3
        XCTAssertTrue(s.isKeywordActive); XCTAssertEqual(s.activeCount, 1)
        s = LibraryFilterState(); s.searchText = "x"
        XCTAssertTrue(s.isSearchActive); XCTAssertEqual(s.activeCount, 1)
    }

    func testAWhitespaceOnlySearchIsNotASearch() {
        var s = LibraryFilterState(); s.searchText = "  \n\t "
        XCTAssertFalse(s.isSearchActive)
        XCTAssertFalse(s.isActive)
    }

    func testAllFiltersTogether() {
        let s = LibraryFilterState(minimumRating: 5, flagFilter: .picked, labelFilter: .red, keywordFilterID: 1, searchText: "a")
        XCTAssertEqual(s.activeCount, 5)
    }

    // MARK: menuFilterCount

    func testMenuFilterCountIsOneForEachMenuFilterAlone() {
        var s = LibraryFilterState(); s.minimumRating = 2
        XCTAssertEqual(s.menuFilterCount, 1)
        s = LibraryFilterState(); s.flagFilter = .picked
        XCTAssertEqual(s.menuFilterCount, 1)
        s = LibraryFilterState(); s.labelFilter = .red
        XCTAssertEqual(s.menuFilterCount, 1)
        s = LibraryFilterState(); s.keywordFilterID = 4
        XCTAssertEqual(s.menuFilterCount, 1)
        s = LibraryFilterState(); s.personFilterID = 9
        XCTAssertEqual(s.menuFilterCount, 1)
    }

    func testMenuFilterCountIgnoresSearch() {
        var s = LibraryFilterState(); s.searchText = "iso:>800"
        XCTAssertEqual(s.menuFilterCount, 0)
        s.searchText = "  \n "
        XCTAssertEqual(s.menuFilterCount, 0)
    }

    func testMenuFilterCountWithEverythingSetIsFive() {
        let s = LibraryFilterState(minimumRating: 5, flagFilter: .picked, labelFilter: .red, keywordFilterID: 1,
                                   searchText: "a", personFilterID: 2)
        XCTAssertEqual(s.menuFilterCount, 5)
        XCTAssertEqual(s.activeCount, 6)
    }

    func testActiveCountIsMenuCountPlusSearchOverAllCombinations() {
        for mask in 0..<64 {
            var s = LibraryFilterState()
            if mask & 1 != 0 { s.minimumRating = 3 }
            if mask & 2 != 0 { s.flagFilter = .picked }
            if mask & 4 != 0 { s.labelFilter = .red }
            if mask & 8 != 0 { s.keywordFilterID = 1 }
            if mask & 16 != 0 { s.searchText = "x" }
            if mask & 32 != 0 { s.personFilterID = 1 }
            XCTAssertEqual(s.activeCount, s.menuFilterCount + (s.isSearchActive ? 1 : 0), "mask \(mask)")
        }
    }
}
