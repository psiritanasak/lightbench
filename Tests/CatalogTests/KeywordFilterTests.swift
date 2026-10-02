import XCTest
@testable import PhotoApp

/// Pure `LibraryFilterSort` keyword filtering/search, combined with the other filters.
final class KeywordFilterTests: XCTestCase {
    private func photo(_ id: Int64, _ name: String, rating: Int = 0) -> Photo {
        var p = Photo(id: nil, path: "/tmp/\(name)", filename: name, fileSize: nil, importedAt: Date(timeIntervalSince1970: Double(id)))
        p.id = id
        p.rating = rating
        return p
    }

    private func ids(_ photos: [Photo]) -> [Int64] { photos.compactMap(\.id) }


    func testFilterKeepsPhotosWithAnyChosenKeywordAndDropsUntagged() {
        let photos = [photo(1, "a"), photo(2, "b"), photo(3, "c")]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
            keywordFilter: [10, 11], keywordIDsByPhotoID: [1: [10], 2: [99], 3: [11, 99]])
        XCTAssertEqual(ids(result), [1, 3])
    }

    func testNilFilterKeepsEverything() {
        let photos = [photo(1, "a"), photo(2, "b")]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "")
        XCTAssertEqual(ids(result), [1, 2])
    }

    func testKeywordFilterCombinesWithRatingByAND() {
        let photos = [photo(1, "a", rating: 5), photo(2, "b", rating: 1)]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 3, flagFilter: .all, searchText: "",
            keywordFilter: [10], keywordIDsByPhotoID: [1: [10], 2: [10]])
        XCTAssertEqual(ids(result), [1])
    }

    func testSearchMatchesKeywordOrFilenameCaseInsensitively() {
        let photos = [photo(1, "beach.jpg"), photo(2, "city.jpg"), photo(3, "SUNSET.jpg")]
        let result = LibraryFilterSort.apply(
            to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: " sun ",
            keywordNamesByPhotoID: [1: ["Golden Sunset"], 2: ["Night"]])
        XCTAssertEqual(ids(result), [1, 3])
    }
}
