import XCTest
@testable import PhotoApp

/// Verifies `LibraryNavigation`'s pure prev/next stepping — extracted from the
/// Photo menu's commands specifically so this gets direct unit test coverage,
/// matching this project's established pattern for pure logic
/// (`LibraryFilterSort`, `CropAspectMath`, `CompareLayout`, `ZoomPanGeometry`).
final class LibraryNavigationTests: XCTestCase {
    private func photo(id: Int64, filename: String, rating: Int = 0) -> Photo {
        Photo(id: id, path: "/tmp/\(filename)", filename: filename, fileSize: nil,
              importedAt: Date(timeIntervalSince1970: 0), rating: rating, flagStatus: .none)
    }

    private lazy var three = [
        photo(id: 1, filename: "a.jpg"),
        photo(id: 2, filename: "b.jpg"),
        photo(id: 3, filename: "c.jpg")
    ]

    // MARK: - Stepping

    func testNextFromMiddleReturnsFollowingPhoto() {
        XCTAssertEqual(LibraryNavigation.neighbor(of: "/tmp/b.jpg", in: three, offset: 1)?.id, 3)
    }

    func testPreviousFromMiddleReturnsPrecedingPhoto() {
        XCTAssertEqual(LibraryNavigation.neighbor(of: "/tmp/b.jpg", in: three, offset: -1)?.id, 1)
    }

    // MARK: - Ends (no wraparound)

    func testPreviousAtFirstPhotoReturnsNil() {
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/a.jpg", in: three, offset: -1))
    }

    func testNextAtLastPhotoReturnsNil() {
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/c.jpg", in: three, offset: 1))
    }

    func testSinglePhotoListHasNoNeighborInEitherDirection() {
        let one = [photo(id: 1, filename: "only.jpg")]
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/only.jpg", in: one, offset: 1))
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/only.jpg", in: one, offset: -1))
    }

    // MARK: - No usable current position

    func testNilCurrentPathReturnsNil() {
        XCTAssertNil(LibraryNavigation.neighbor(of: nil, in: three, offset: 1))
    }

    /// The open photo having been filtered out of the displayed set (or the
    /// sidebar having moved to a collection it isn't in) disables navigation
    /// rather than guessing a position.
    func testCurrentPathAbsentFromListReturnsNil() {
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/elsewhere.jpg", in: three, offset: 1))
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/elsewhere.jpg", in: three, offset: -1))
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/a.jpg", in: [], offset: 1))
    }

    // MARK: - Order comes from the caller

    /// The Photo menu passes `CatalogModel.displayedPhotos`, so "next" must
    /// follow the grid's CURRENT sort/filter, not the catalog's own order.
    /// Feeding the same three photos through `LibraryFilterSort` in a
    /// different order flips what "next" means.
    func testNeighborFollowsTheDisplayedOrderItIsGiven() {
        let rated = [
            photo(id: 1, filename: "a.jpg", rating: 1),
            photo(id: 2, filename: "b.jpg", rating: 5),
            photo(id: 3, filename: "c.jpg", rating: 3)
        ]
        let displayed = LibraryFilterSort.apply(
            to: rated, sort: .ratingHighToLow, minimumRating: 0, flagFilter: .all, searchText: ""
        )
        XCTAssertEqual(displayed.map(\.id), [2, 3, 1])
        XCTAssertEqual(LibraryNavigation.neighbor(of: "/tmp/b.jpg", in: displayed, offset: 1)?.id, 3)
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/b.jpg", in: displayed, offset: -1))
    }

    /// A rating filter that excludes the open photo removes it from the
    /// displayed set, so both directions disable — the same case as
    /// `testCurrentPathAbsentFromListReturnsNil`, reached the way a user
    /// actually would.
    func testFilteringOutTheOpenPhotoDisablesNavigation() {
        let rated = [
            photo(id: 1, filename: "a.jpg", rating: 1),
            photo(id: 2, filename: "b.jpg", rating: 5),
            photo(id: 3, filename: "c.jpg", rating: 3)
        ]
        let displayed = LibraryFilterSort.apply(
            to: rated, sort: .dateOldest, minimumRating: 3, flagFilter: .all, searchText: ""
        )
        XCTAssertEqual(displayed.map(\.id), [2, 3])
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/a.jpg", in: displayed, offset: 1))
        XCTAssertNil(LibraryNavigation.neighbor(of: "/tmp/a.jpg", in: displayed, offset: -1))
    }
}
