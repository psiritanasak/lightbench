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
}
