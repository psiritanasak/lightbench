import XCTest
@testable import PhotoApp

final class XMPImportPolicyTests: XCTestCase {
    private func photo(rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none) -> Photo {
        Photo(id: 1, path: "/tmp/a.jpg", filename: "a.jpg", fileSize: 1, importedAt: Date(), rating: rating, flagStatus: flag, colorLabel: label)
    }

    private func change(_ p: Photo, _ f: XMPLibraryFields, _ mode: XMPImportPolicy.Mode, keys: Set<String> = []) -> XMPImportPolicy.Change {
        XMPImportPolicy.change(current: p, currentKeywordKeys: keys, fields: f, mode: mode)
    }

    func testReplaceTakesTheFileValuesAndLeavesAbsentFieldsAlone() {
        let c = change(photo(rating: 1, label: .red), XMPLibraryFields(rating: 4, isRejected: false), .replace)
        XCTAssertEqual(c.rating, 4)
        XCTAssertNil(c.label, "the file carried no label")
        XCTAssertNil(c.flag)
    }

    func testReplaceCanClearALabelWithAnExplicitNone() {
        XCTAssertEqual(change(photo(label: .red), XMPLibraryFields(label: ColorLabel.none), .replace).label, ColorLabel.none)
    }

    func testFillDefaultsNeverOverwritesAUserValue() {
        let user = photo(rating: 2, flag: .picked, label: .green)
        for f in [XMPLibraryFields(rating: 5, isRejected: false, label: .blue), XMPLibraryFields(rating: 0, isRejected: true, label: .blue)] {
            XCTAssertTrue(change(user, f, .fillDefaults).isEmpty)
        }
        let rated = change(photo(), XMPLibraryFields(rating: 5, isRejected: false, label: .blue), .fillDefaults)
        XCTAssertEqual(rated.rating, 5)
        XCTAssertEqual(rated.label, .blue)
        XCTAssertEqual(change(photo(), XMPLibraryFields(rating: 0, isRejected: true), .fillDefaults).flag, .rejected)
    }

    func testRejectHandling() {
        XCTAssertEqual(change(photo(flag: .picked), XMPLibraryFields(rating: 0, isRejected: true), .replace).flag, .rejected)
        XCTAssertNil(change(photo(flag: .picked), XMPLibraryFields(rating: 0, isRejected: true), .fillDefaults).flag)
        XCTAssertEqual(change(photo(flag: .rejected), XMPLibraryFields(rating: 3, isRejected: false), .replace).flag, FlagStatus.none)
        XCTAssertNil(change(photo(flag: .rejected), XMPLibraryFields(rating: 3, isRejected: false), .fillDefaults).flag)
        XCTAssertNil(change(photo(flag: .picked), XMPLibraryFields(rating: 3, isRejected: false), .replace).flag, "a Pick is never undone by a normal rating")
    }

    func testARejectMarkerNeverZeroesTheStars() {
        for mode in [XMPImportPolicy.Mode.replace, .fillDefaults] {
            let c = change(photo(rating: 3), XMPLibraryFields(rating: 0, isRejected: true), mode)
            XCTAssertNil(c.rating, "\(mode)")
            XCTAssertEqual(c.flag, .rejected, "\(mode)")
        }
    }

    func testKeywordsAreOnlyAddedDedupedAndSkipAlreadyPresentOnes() {
        let c = change(photo(), XMPLibraryFields(keywords: ["Sky", "sky", "Beach", " "]), .replace, keys: [KeywordName.key(for: "Sky")])
        XCTAssertEqual(c.keywordsToAdd, ["Beach"])
    }

    func testNothingToDoIsEmpty() {
        XCTAssertTrue(change(photo(rating: 3), XMPLibraryFields(rating: 3, isRejected: false), .replace).isEmpty)
        XCTAssertTrue(change(photo(), XMPLibraryFields(), .replace).isEmpty)
    }
}

final class XMPApplyLibraryFieldsTests: XCTestCase {
    private func makeDatabase() async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<3).map { URL(fileURLWithPath: "/tmp/x\($0).jpg") })
        return (db, try await db.allPhotos().compactMap(\.id).sorted())
    }

    func testAppliesRatingFlagLabelAndKeywordsInOneBatchAndReportsOnlyRealChanges() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.setRating(2, for: ids[1])
        let changed = try await db.applyLibraryFields([
            (ids[0], XMPLibraryFields(rating: 4, isRejected: false, label: .green, keywords: ["Sky", "Beach"])),
            (ids[1], XMPLibraryFields(rating: 2, isRejected: false)),          // already equal: no change
            (ids[2], XMPLibraryFields(rating: 0, isRejected: true))
        ], mode: .replace)
        XCTAssertEqual(changed, [ids[0], ids[2]])
        let photos = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.id!, $0) })
        XCTAssertEqual(photos[ids[0]]?.rating, 4)
        XCTAssertEqual(photos[ids[0]]?.colorLabel, .green)
        XCTAssertEqual(photos[ids[2]]?.flagStatus, .rejected)
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(links.filter { $0.photoId == ids[0] }.count, 2)
    }

    func testFillDefaultsKeepsWhatTheUserAlreadySetAndStaleIdsAreSkipped() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.setRating(1, for: ids[0])
        let changed = try await db.applyLibraryFields([
            (ids[0], XMPLibraryFields(rating: 5, isRejected: false)),
            (9_999, XMPLibraryFields(rating: 5, isRejected: false)),
            (ids[1], XMPLibraryFields(rating: 5, isRejected: false))
        ], mode: .fillDefaults)
        XCTAssertEqual(changed, [ids[1]])
        let rating0 = try await db.allPhotos().first { $0.id == ids[0] }?.rating
        XCTAssertEqual(rating0, 1)
    }

    func testRepeatingAnApplyChangesNothing() async throws {
        let (db, ids) = try await makeDatabase()
        let item = [(ids[0], XMPLibraryFields(rating: 3, isRejected: false, label: .red, keywords: ["A"]))]
        let first = try await db.applyLibraryFields(item, mode: .replace)
        let second = try await db.applyLibraryFields(item, mode: .replace)
        XCTAssertEqual(first, [ids[0]])
        XCTAssertTrue(second.isEmpty)
    }
}
