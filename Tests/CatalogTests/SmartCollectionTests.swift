import XCTest
import GRDB
@testable import PhotoApp

final class SmartCollectionCriteriaTests: XCTestCase {
    private func photo(_ id: Int64, rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none) -> Photo {
        var p = Photo(id: id, path: "/tmp/\(id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: Double(id)))
        p.rating = rating
        p.flagStatus = flag
        p.colorLabel = label
        return p
    }

    private func keyword(_ id: Int64, _ name: String) -> Keyword {
        Keyword(id: id, name: name, nameKey: KeywordName.key(for: name), createdAt: Date())
    }

    private func ids(_ photos: [Photo]) -> [Int64] { photos.compactMap(\.id) }

    func testEmptyCriteriaKeepEverythingInOrder() {
        let photos = [photo(3), photo(1), photo(2)]
        XCTAssertTrue(SmartCollectionCriteria.empty.isEmpty)
        XCTAssertEqual(ids(SmartCollectionCriteria.empty.apply(to: photos, keywords: [], keywordIDsByPhotoID: [:])), [3, 1, 2])
    }

    func testEachCriterionIsApplied() {
        let photos = [photo(1, rating: 5), photo(2, rating: 2), photo(3, rating: 5, flag: .picked), photo(4, rating: 5, label: .red)]
        var criteria = SmartCollectionCriteria()
        criteria.minimumRating = 4
        XCTAssertEqual(ids(criteria.apply(to: photos, keywords: [], keywordIDsByPhotoID: [:])), [1, 3, 4])
        criteria.flag = .picked
        XCTAssertEqual(ids(criteria.apply(to: photos, keywords: [], keywordIDsByPhotoID: [:])), [3])
        criteria.flag = .all
        criteria.label = .red
        XCTAssertEqual(ids(criteria.apply(to: photos, keywords: [], keywordIDsByPhotoID: [:])), [4])
    }

    func testResultKeepsTheCallersOrderNotImportOrder() {
        let photos = [photo(3, rating: 5), photo(1, rating: 5), photo(2, rating: 5)]
        var criteria = SmartCollectionCriteria()
        criteria.minimumRating = 5
        XCTAssertEqual(ids(criteria.apply(to: photos, keywords: [], keywordIDsByPhotoID: [:])), [3, 1, 2])
    }

    func testKeywordCriterionResolvesByKeyAndMatchesOnlyTaggedPhotos() {
        let sky = keyword(10, "Sky")
        var criteria = SmartCollectionCriteria()
        criteria.keywordKey = sky.nameKey
        let photos = [photo(1), photo(2), photo(3)]
        let links: [Int64: Set<Int64>] = [1: [10], 3: [11]]
        XCTAssertEqual(ids(criteria.apply(to: photos, keywords: [sky, keyword(11, "Sea")], keywordIDsByPhotoID: links)), [1])
    }

    /// The dangerous case: a criterion on a keyword that no longer exists must match NOTHING, not everything.
    func testCriterionOnADeletedKeywordMatchesNothing() {
        var criteria = SmartCollectionCriteria()
        criteria.keywordKey = KeywordName.key(for: "Gone")
        XCTAssertEqual(criteria.keywordFilter(resolving: []), Set<Int64>())
        XCTAssertEqual(ids(criteria.apply(to: [photo(1), photo(2)], keywords: [], keywordIDsByPhotoID: [1: [5]])), [])
        XCTAssertFalse(criteria.isEmpty, "a keyword-only criterion is a real restriction")
    }

    func testMissingKeysMeanNoRestrictionAndRatingIsClamped() throws {
        let decoded = try JSONDecoder().decode(SmartCollectionCriteria.self, from: Data(#"{"minimumRating":9,"label":"red","keywordKey":"sky"}"#.utf8))
        XCTAssertEqual(decoded.minimumRating, 5)
        XCTAssertEqual(decoded.flag, .all, "absent key = no restriction")
        XCTAssertEqual(decoded.label, .red)
        XCTAssertEqual(decoded.keywordKey, "sky")
        XCTAssertFalse(decoded.hasUnrecognizedCriterion)
        XCTAssertEqual(try JSONDecoder().decode(SmartCollectionCriteria.self, from: Data("{}".utf8)), .empty)
        XCTAssertEqual(try JSONDecoder().decode(SmartCollectionCriteria.self, from: Data(#"{"flag":null}"#.utf8)), .empty, "null = absent")
    }

    /// A PRESENT but not understood criterion (renamed case, newer build) must match nothing, never everything.
    func testAnUnrecognizedStoredCriterionMatchesNothing() throws {
        for json in [#"{"flag":"bogus"}"#, #"{"label":"mauve"}"#, #"{"minimumRating":"high"}"#, #"{"keywordKey":7}"#] {
            let decoded = try JSONDecoder().decode(SmartCollectionCriteria.self, from: Data(json.utf8))
            XCTAssertTrue(decoded.hasUnrecognizedCriterion, json)
            XCTAssertFalse(decoded.isEmpty, json)
            XCTAssertEqual(ids(decoded.apply(to: [photo(1, rating: 5), photo(2)], keywords: [], keywordIDsByPhotoID: [:])), [], json)
        }
    }

    /// The stored raw strings are an on-disk format: renaming a case would silently break every saved criterion.
    func testStoredRawValuesArePinned() {
        XCTAssertEqual(LibraryFlagFilter.allCases.map(\.rawValue), ["all", "picked", "unflagged", "rejected", "notRejected"])
        XCTAssertEqual(LibraryLabelFilter.allCases.map(\.rawValue), ["all", "unlabeled", "red", "yellow", "green", "blue", "purple"])
    }

    func testRoundTrip() throws {
        let criteria = SmartCollectionCriteria(minimumRating: 3, flag: .picked, label: .blue, keywordKey: "sky")
        let data = try JSONEncoder().encode(criteria)
        XCTAssertEqual(try JSONDecoder().decode(SmartCollectionCriteria.self, from: data), criteria)
    }
}

final class SmartCollectionDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> CatalogDatabase { try CatalogDatabase(inMemory: true) }

    func testCreateListRenameUpdateDelete() async throws {
        let db = try makeDatabase()
        let created = try await db.createSmartCollection(name: "  Best  of ", criteria: SmartCollectionCriteria(minimumRating: 4))
        XCTAssertEqual(created.name, "Best of", "name is normalised like a keyword")
        let id = try XCTUnwrap(created.id)
        var all = try await db.allSmartCollections()
        XCTAssertEqual(all.map(\.name), ["Best of"])
        XCTAssertEqual(all.first?.criteria.minimumRating, 4)

        try await db.renameSmartCollection(id: id, to: "Keepers")
        try await db.updateSmartCollectionCriteria(id: id, to: SmartCollectionCriteria(minimumRating: 5, flag: .picked))
        all = try await db.allSmartCollections()
        XCTAssertEqual(all.first?.name, "Keepers")
        XCTAssertEqual(all.first?.criteria, SmartCollectionCriteria(minimumRating: 5, flag: .picked))

        try await db.deleteSmartCollection(id: id)
        try await db.deleteSmartCollection(id: id) // second delete is a no-op
        let remaining = try await db.allSmartCollections()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testEmptyAndDuplicateNamesAreRejectedCaseInsensitivelyIncludingNonASCII() async throws {
        let db = try makeDatabase()
        _ = try await db.createSmartCollection(name: "Éclair", criteria: .empty)
        do { _ = try await db.createSmartCollection(name: "  ", criteria: .empty); XCTFail("empty name") } catch {
            XCTAssertEqual(error as? SmartCollectionError, .emptyName)
        }
        do { _ = try await db.createSmartCollection(name: "éclair", criteria: .empty); XCTFail("duplicate") } catch {
            XCTAssertEqual(error as? SmartCollectionError, .duplicateName("Éclair"), "SQLite NOCASE would have missed this")
        }
        let b = try await db.createSmartCollection(name: "B", criteria: .empty)
        let bID = try XCTUnwrap(b.id)
        do { try await db.renameSmartCollection(id: bID, to: "ÉCLAIR"); XCTFail("rename duplicate") } catch {
            XCTAssertEqual(error as? SmartCollectionError, .duplicateName("Éclair"))
        }
        // Renaming to its own name (different case) is fine.
        try await db.renameSmartCollection(id: bID, to: "b")
        let names = try await db.allSmartCollections().map(\.name)
        XCTAssertEqual(Set(names), ["Éclair", "b"])
    }

    /// Renaming must not re-serialise (and so degrade) the criteria it does not touch.
    func testRenameLeavesTheStoredCriteriaBytesAlone() async throws {
        let path = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try CatalogDatabase(path: path)
        let smart = try await db.createSmartCollection(name: "Future", criteria: .empty)
        let id = try XCTUnwrap(smart.id)
        let futureJSON = #"{"flag":"someFutureFlag","extra":{"a":1}}"#
        let queue = try DatabaseQueue(path: path)
        try await queue.write { try $0.execute(sql: "UPDATE smart_collection SET criteria = ? WHERE id = ?", arguments: [futureJSON, id]) }
        try await db.renameSmartCollection(id: id, to: "Renamed")
        let stored = try await queue.read { try String.fetchOne($0, sql: "SELECT criteria FROM smart_collection WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(stored, futureJSON)
    }

    func testMissingRowsThrowNotFound() async throws {
        let db = try makeDatabase()
        do { try await db.renameSmartCollection(id: 99, to: "x"); XCTFail() } catch { XCTAssertEqual(error as? SmartCollectionError, .notFound) }
        do { try await db.updateSmartCollectionCriteria(id: 99, to: .empty); XCTFail() } catch { XCTAssertEqual(error as? SmartCollectionError, .notFound) }
    }

    func testDeletingAKeywordLeavesTheSmartCollectionIntact() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/sc1.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let sky = try await db.addKeywords(["Sky"], to: [photoID])[0]
        let smart = try await db.createSmartCollection(name: "Skies", criteria: SmartCollectionCriteria(keywordKey: sky.nameKey))
        let skyID = try XCTUnwrap(sky.id)
        try await db.deleteKeyword(id: skyID)
        let after = try await db.allSmartCollections()
        XCTAssertEqual(after.map(\.id), [smart.id])
        XCTAssertEqual(after.first?.criteria.keywordKey, sky.nameKey)
        let keywords = try await db.allKeywords()
        XCTAssertEqual(after.first?.criteria.keywordFilter(resolving: keywords), Set<Int64>())
    }

    func testMigration011UpgradesAnExistingCatalogAndKeepsItsData() async throws {
        let path = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let queue = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            Migration001Initial.register(in: &migrator)
            Migration002RatingsAndFlags.register(in: &migrator)
            Migration003Collections.register(in: &migrator)
            Migration004FolderCollections.register(in: &migrator)
            Migration005Presets.register(in: &migrator)
            Migration006CollectionFolderPathIndex.register(in: &migrator)
            Migration007PickRejectFlags.register(in: &migrator)
            Migration008ColorLabels.register(in: &migrator)
            Migration009RenameLog.register(in: &migrator)
            Migration010Keywords.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 3, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.first?.rating, 3, "existing data survives the upgrade")
        let before = try await db.allSmartCollections().count
        XCTAssertEqual(before, 0)
        _ = try await db.createSmartCollection(name: "Fresh", criteria: SmartCollectionCriteria(minimumRating: 3))
        let after = try await db.allSmartCollections().count
        XCTAssertEqual(after, 1)
    }
}
