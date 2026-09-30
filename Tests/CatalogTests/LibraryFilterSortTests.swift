import XCTest
@testable import PhotoApp

/// Verifies `LibraryFilterSort`'s pure sort/filter logic — extracted from
/// `CatalogModel` specifically so this gets direct unit test coverage,
/// matching this project's established pattern for pure UI-layer logic
/// (`CropAspectMath`, `CompareLayout`, `ZoomPanGeometry`).
final class LibraryFilterSortTests: XCTestCase {
    private func photo(
        id: Int64, filename: String, importedAt: Date, rating: Int = 0, flagStatus: FlagStatus = .none,
        colorLabel: ColorLabel = .none
    ) -> Photo {
        Photo(id: id, path: "/tmp/\(filename)", filename: filename, fileSize: nil, importedAt: importedAt,
              rating: rating, flagStatus: flagStatus, colorLabel: colorLabel)
    }

    private let day0 = Date(timeIntervalSince1970: 0)
    private let day1 = Date(timeIntervalSince1970: 86400)
    private let day2 = Date(timeIntervalSince1970: 172800)

    // MARK: - Sort

    func testDateOldestSortsAscending() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day2),
            photo(id: 2, filename: "b", importedAt: day0),
            photo(id: 3, filename: "c", importedAt: day1)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.map(\.id), [2, 3, 1])
    }

    func testDateNewestSortsDescending() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day2),
            photo(id: 2, filename: "b", importedAt: day0),
            photo(id: 3, filename: "c", importedAt: day1)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateNewest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.map(\.id), [1, 3, 2])
    }

    func testRatingHighToLowSortsDescending() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day0, rating: 2),
            photo(id: 2, filename: "b", importedAt: day0, rating: 5),
            photo(id: 3, filename: "c", importedAt: day0, rating: 0)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .ratingHighToLow, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.map(\.id), [2, 1, 3])
    }

    func testNameAZUsesNaturalNumericOrdering() {
        // Finder-style natural sort: "Photo 2" before "Photo 10", not
        // lexical ("Photo 10" < "Photo 2" under plain string comparison).
        let photos = [
            photo(id: 1, filename: "Photo 10.jpg", importedAt: day0),
            photo(id: 2, filename: "Photo 2.jpg", importedAt: day0),
            photo(id: 3, filename: "Photo 1.jpg", importedAt: day0)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .nameAZ, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.map(\.id), [3, 2, 1])
    }

    // MARK: - Minimum rating filter

    func testZeroMinimumRatingIncludesEverythingEvenUnrated() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day0, rating: 0),
            photo(id: 2, filename: "b", importedAt: day0, rating: 3)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.count, 2)
    }

    func testMinimumRatingIsAThresholdIncludingTheBoundary() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day0, rating: 2),
            photo(id: 2, filename: "b", importedAt: day0, rating: 3),
            photo(id: 3, filename: "c", importedAt: day0, rating: 5)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 3, flagFilter: .all, searchText: "")
        XCTAssertEqual(Set(result.map(\.id)), [2, 3])
    }

    // MARK: - Flag filter

    private var mixedFlags: [Photo] {
        [
            photo(id: 1, filename: "a", importedAt: day0, flagStatus: .picked),
            photo(id: 2, filename: "b", importedAt: day0, flagStatus: .none),
            photo(id: 3, filename: "c", importedAt: day0, flagStatus: .rejected)
        ]
    }

    private func ids(_ filter: LibraryFlagFilter) -> [Int64?] {
        LibraryFilterSort.apply(
            to: mixedFlags, sort: .dateOldest, minimumRating: 0, flagFilter: filter, searchText: ""
        ).map(\.id)
    }

    func testFlagFilterAllKeepsEverything() { XCTAssertEqual(ids(.all), [1, 2, 3]) }
    func testFlagFilterPickedKeepsOnlyPicked() { XCTAssertEqual(ids(.picked), [1]) }
    func testFlagFilterUnflaggedKeepsOnlyUnflagged() { XCTAssertEqual(ids(.unflagged), [2]) }
    func testFlagFilterRejectedKeepsOnlyRejected() { XCTAssertEqual(ids(.rejected), [3]) }
    func testFlagFilterNotRejectedHidesRejected() { XCTAssertEqual(ids(.notRejected), [1, 2]) }

    // MARK: - Search

    func testSearchIsCaseInsensitiveSubstringMatch() {
        let photos = [
            photo(id: 1, filename: "IMG_0001.jpg", importedAt: day0),
            photo(id: 2, filename: "sunset.jpg", importedAt: day0)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "sun")
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testSearchTrimsWhitespace() {
        let photos = [photo(id: 1, filename: "sunset.jpg", importedAt: day0)]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "  sunset  "
        )
        XCTAssertEqual(result.map(\.id), [1])
    }

    func testEmptySearchTextIsNoFilter() {
        let photos = [
            photo(id: 1, filename: "a.jpg", importedAt: day0),
            photo(id: 2, filename: "b.jpg", importedAt: day0)
        ]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(result.count, 2)
    }

    func testWhitespaceOnlySearchTextIsNoFilter() {
        let photos = [photo(id: 1, filename: "a.jpg", importedAt: day0)]
        let result = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "   ")
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Combined + edge cases

    func testFiltersCombineAndSortIsAppliedLast() {
        let photos = [
            photo(id: 1, filename: "beach.jpg", importedAt: day2, rating: 4, flagStatus: .picked),
            photo(id: 2, filename: "beach.jpg", importedAt: day0, rating: 5, flagStatus: .picked),
            photo(id: 3, filename: "beach.jpg", importedAt: day1, rating: 2, flagStatus: .picked),
            photo(id: 4, filename: "beach.jpg", importedAt: day0, rating: 5, flagStatus: .none)
        ]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateNewest, minimumRating: 3, flagFilter: .picked, searchText: "beach"
        )
        // id 3 excluded (rating < 3), id 4 excluded (not flagged); 1 and 2
        // remain, newest first.
        XCTAssertEqual(result.map(\.id), [1, 2])
    }

    func testEmptyInputReturnsEmptyOutput() {
        let result = LibraryFilterSort.apply(to: [], sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertTrue(result.isEmpty)
    }
    // MARK: - Color label filter

    private func labeledSet() -> [Photo] {
        [
            photo(id: 1, filename: "a", importedAt: day0, colorLabel: .red),
            photo(id: 2, filename: "b", importedAt: day1, colorLabel: .blue),
            photo(id: 3, filename: "c", importedAt: day2),
            photo(id: 4, filename: "d", importedAt: day2, colorLabel: .red)
        ]
    }

    func testLabelFilterAllKeepsEverything() {
        let result = LibraryFilterSort.apply(
            to: labeledSet(), sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
            labelFilter: .all)
        XCTAssertEqual(result.count, 4)
    }

    func testLabelFilterMatchesOnlyThatColor() {
        let result = LibraryFilterSort.apply(
            to: labeledSet(), sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
            labelFilter: .red)
        XCTAssertEqual(Set(result.compactMap(\.id)), [1, 4])
    }

    func testLabelFilterUnlabeledMatchesOnlyPhotosWithNoLabel() {
        let result = LibraryFilterSort.apply(
            to: labeledSet(), sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
            labelFilter: .unlabeled)
        XCTAssertEqual(result.compactMap(\.id), [3])
    }

    func testLabelFilterIsAnEmptyResultForAColorNobodyHas() {
        let result = LibraryFilterSort.apply(
            to: labeledSet(), sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
            labelFilter: .purple)
        XCTAssertTrue(result.isEmpty)
    }

    func testLabelFilterCombinesWithFlagFilter() {
        let photos = [
            photo(id: 1, filename: "a", importedAt: day0, flagStatus: .picked, colorLabel: .red),
            photo(id: 2, filename: "b", importedAt: day1, flagStatus: .none, colorLabel: .red),
            photo(id: 3, filename: "c", importedAt: day2, flagStatus: .picked, colorLabel: .blue)
        ]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .picked, searchText: "",
            labelFilter: .red)
        XCTAssertEqual(result.compactMap(\.id), [1])
    }

    func testEveryLabelFilterCaseMatchesExactlyItsOwnLabel() {
        for filter in LibraryLabelFilter.allCases {
            for label in ColorLabel.allCases {
                let expected: Bool
                switch filter {
                case .all: expected = true
                case .unlabeled: expected = label == .none
                case .red: expected = label == .red
                case .yellow: expected = label == .yellow
                case .green: expected = label == .green
                case .blue: expected = label == .blue
                case .purple: expected = label == .purple
                }
                XCTAssertEqual(filter.matches(label), expected, "\(filter) vs \(label)")
            }
        }
    }
}
