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

// MARK: - Field search and capture-date sort (field-based search step 3)

final class LibraryFieldSearchTests: XCTestCase {
    private func photo(_ id: Int64, _ name: String, rating: Int = 0) -> Photo {
        var p = Photo(id: id, path: "/tmp/\(name)", filename: name, fileSize: 1, importedAt: Date(timeIntervalSince1970: Double(id)))
        p.rating = rating
        return p
    }

    private func meta(_ id: Int64, iso: Int? = nil, date: String? = nil) -> PhotoMetadata {
        PhotoMetadata(photoId: id, fileSize: 1, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision,
                      captureDate: date.flatMap { CaptureDate.parseEXIFDate($0)?.timeIntervalSince1970 }, iso: iso,
                      cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutter: nil,
                      pixelWidth: nil, pixelHeight: nil, scannedAt: Date())
    }

    private func apply(_ photos: [Photo], search: String, sort: LibrarySortOption = .dateOldest,
                       metadata: [Int64: PhotoMetadata] = [:], keywords: [Int64: [String]] = [:], minimumRating: Int = 0) -> [Int64] {
        LibraryFilterSort.apply(to: photos, sort: sort, minimumRating: minimumRating, flagFilter: .all, searchText: search,
                                keywordNamesByPhotoID: keywords, metadataByPhotoID: metadata).compactMap(\.id)
    }

    func testFieldQueryUsesTheMetadataMap() {
        let photos = [photo(1, "a.jpg"), photo(2, "b.jpg"), photo(3, "c.jpg")]
        let metadata: [Int64: PhotoMetadata] = [1: meta(1, iso: 200), 2: meta(2, iso: 1600)]
        XCTAssertEqual(apply(photos, search: "iso:>800", metadata: metadata), [2])
        XCTAssertEqual(apply(photos, search: "iso:<=1600", metadata: metadata), [1, 2], "photo 3 has no camera data")
        XCTAssertEqual(apply(photos, search: "iso:>800"), [], "no metadata at all: nothing matches a camera field")
    }

    func testFieldQueryCombinesWithTheOtherFiltersAndKeywordSearch() {
        let photos = [photo(1, "a.jpg", rating: 5), photo(2, "b.jpg", rating: 1)]
        let metadata: [Int64: PhotoMetadata] = [1: meta(1, iso: 1600), 2: meta(2, iso: 1600)]
        XCTAssertEqual(apply(photos, search: "iso:>800", metadata: metadata, minimumRating: 3), [1])
        XCTAssertEqual(apply(photos, search: "moun iso:>800", metadata: metadata, keywords: [2: ["Mountains"]]), [2])
        XCTAssertEqual(apply(photos, search: "rating:>3 iso:>800", metadata: metadata), [1])
    }

    func testPlainSearchStillWorksWithoutAnyMetadata() {
        let photos = [photo(1, "sunset.jpg"), photo(2, "IMG_1.jpg")]
        XCTAssertEqual(apply(photos, search: "sun"), [1])
        XCTAssertEqual(apply(photos, search: "  SUN  "), [1])
    }

    func testCaptureDateSortPutsPhotosWithoutADateLastInBothDirections() {
        // The undated photos come FIRST in the input, so the sort has to move them.
        let photos = [photo(3, "c.jpg"), photo(4, "d.jpg"), photo(1, "a.jpg"), photo(2, "b.jpg")]
        let metadata: [Int64: PhotoMetadata] = [
            1: meta(1, date: "2020:01:01 00:00:00"), 2: meta(2, date: "2024:01:01 00:00:00"), 3: meta(3)
        ]
        XCTAssertEqual(apply(photos, search: "", sort: .captureNewest, metadata: metadata), [2, 1, 3, 4])
        XCTAssertEqual(apply(photos, search: "", sort: .captureOldest, metadata: metadata), [1, 2, 3, 4])
    }

    func testCaptureDateSortIsStableForEqualDates() {
        let photos = [photo(5, "e.jpg"), photo(3, "c.jpg"), photo(4, "d.jpg")]
        let same = "2022:06:06 06:06:06"
        let metadata: [Int64: PhotoMetadata] = [3: meta(3, date: same), 4: meta(4, date: same), 5: meta(5, date: same)]
        XCTAssertEqual(apply(photos, search: "", sort: .captureNewest, metadata: metadata), [3, 4, 5])
        XCTAssertEqual(apply(photos, search: "", sort: .captureOldest, metadata: metadata), [3, 4, 5])
    }

    func testTheNewSortOptionsAreLabelledAndListed() {
        XCTAssertTrue(LibrarySortOption.allCases.contains(.captureNewest))
        XCTAssertEqual(LibrarySortOption.captureNewest.label, "Capture Date, Newest")
        XCTAssertEqual(LibrarySortOption.captureOldest.label, "Capture Date, Oldest")
    }
}
