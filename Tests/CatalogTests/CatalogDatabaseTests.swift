import GRDB
import XCTest
@testable import PhotoApp

/// Exercises `CatalogDatabase` against an in-memory GRDB queue — fast,
/// disk/network-free, matching this project's existing math/logic-focused
/// test convention (`EditHistoryTests`, `EditStateCodableTests`, etc.).
final class CatalogDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase(inMemory: true)
    }

    func testImportInsertsNewPhotos() async throws {
        let db = try makeDatabase()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.png")
        ]

        let result = try await db.importPhotos(at: urls)

        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.skipped, 0)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 2)
    }

    func testReimportingSamePathsIsIdempotent() async throws {
        let db = try makeDatabase()
        let urls = [URL(fileURLWithPath: "/tmp/a.jpg")]

        _ = try await db.importPhotos(at: urls)
        let second = try await db.importPhotos(at: urls)

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.skipped, 1)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1, "re-importing the same path must not create a duplicate row")
    }

    func testMixedNewAndExistingPathsReportsBothCounts() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])

        let result = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/c.heic")
        ])

        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    func testInsertedFieldsRoundTripThroughFetch() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/IMG_0001.jpg")])

        let photos = try await db.allPhotos()

        XCTAssertEqual(photos.count, 1)
        let photo = try XCTUnwrap(photos.first)
        XCTAssertNotNil(photo.id, "GRDB should assign the autoincremented rowid on insert")
        XCTAssertEqual(photo.path, "/tmp/IMG_0001.jpg")
        XCTAssertEqual(photo.filename, "IMG_0001.jpg")
    }

    func testAllPhotosOrdersByImportedAt() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/first.jpg")])
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/second.jpg")])

        let photos = try await db.allPhotos()

        XCTAssertEqual(photos.map(\.filename), ["first.jpg", "second.jpg"])
    }

    // MARK: - Ratings and flags (Phase 4 slice 3)

    func testNewlyImportedPhotoDefaultsToUnratedAndUnflagged() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)

        XCTAssertEqual(photo.rating, 0)
        XCTAssertEqual(photo.flagStatus, FlagStatus.none)
    }

    func testSetRatingUpdatesTheStoredValue() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(3, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 3)
    }

    func testSetRatingClampsAboveFive() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(99, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 5)
    }

    func testSetRatingClampsBelowZero() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(-1, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 0)
    }

    func testSetFlagStatusStoresEveryState() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)
        XCTAssertEqual(importedPhotos.first?.flagStatus, FlagStatus.none)

        for status in [FlagStatus.picked, .rejected, .none] {
            try await db.setFlagStatus(status, for: id)
            let stored = try await db.allPhotos().first
            XCTAssertEqual(stored?.flagStatus, status)
        }
    }

    /// A catalog created before Migration 007 (migrated only through 006,
    /// with real flagged/unflagged rows) must upgrade in place: flagged rows
    /// become Picks, and the old boolean column is gone.
    func testMigration007ConvertsIsFlaggedToPickedAndDropsColumn() async throws {
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
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO photo (path, filename, importedAt, rating, isFlagged)
                    VALUES ('/tmp/flagged.jpg', 'flagged.jpg', '2026-01-01 00:00:00', 3, 1),
                           ('/tmp/plain.jpg', 'plain.jpg', '2026-01-01 00:00:00', 0, 0)
                    """)
            }
        }

        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.first { $0.filename == "flagged.jpg" }?.flagStatus, .picked)
        XCTAssertEqual(photos.first { $0.filename == "flagged.jpg" }?.rating, 3)
        XCTAssertEqual(photos.first { $0.filename == "plain.jpg" }?.flagStatus, FlagStatus.none)

        let columns = try await DatabaseQueue(path: path).read { try $0.columns(in: "photo").map(\.name) }
        XCTAssertFalse(columns.contains("isFlagged"))
        XCTAssertTrue(columns.contains("flagStatus"))
    }

    // MARK: - Removal (D5, IMPROVEMENTS.md)

    func testDeletePhotoRemovesTheRow() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg")
        ])
        let photos = try await db.allPhotos()
        let idToDelete = try XCTUnwrap(photos.first { $0.path == "/tmp/a.jpg" }?.id)

        try await db.deletePhoto(id: idToDelete)

        let remaining = try await db.allPhotos()
        XCTAssertEqual(remaining.map(\.path), ["/tmp/b.jpg"])
    }

    /// A real, executable proof of the `ON DELETE CASCADE` FK
    /// (`Migrations/003_collections.swift`) rather than trusting its own
    /// comment — this is the first live DELETE on `photo` in the whole
    /// project, so the cascade had never actually been exercised before.
    func testDeletePhotoCascadeDeletesCollectionMemberships() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let photoID = try XCTUnwrap(importedPhotos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        let membershipsBeforeDelete = try await db.allMemberships()
        XCTAssertEqual(membershipsBeforeDelete.count, 1)

        try await db.deletePhoto(id: photoID)

        let membershipsAfterDelete = try await db.allMemberships()
        XCTAssertTrue(membershipsAfterDelete.isEmpty)
        // The collection itself must survive — only the membership row
        // cascades, not the collection it points to.
        let remainingCollections = try await db.allCollections()
        XCTAssertEqual(remainingCollections.count, 1)
    }

    func testDeletingANonexistentIDIsANoOp() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])

        try await db.deletePhoto(id: 999_999)

        let remaining = try await db.allPhotos()
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Relocating missing photos (D5 follow-up)

    /// Real temp files (not fake `/tmp/...` paths) so `fileSize` is
    /// meaningfully asserted, not just left at its imported-time value —
    /// reviewer-caught: the original version of this test used
    /// nonexistent paths throughout, so its own `fileSize` claim in the
    /// test name was never actually exercised.
    func testRelocatePhotosUpdatesPathFilenameAndFileSize() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let oldURL = tempDir.appendingPathComponent("a.jpg")
        FileManager.default.createFile(atPath: oldURL.path, contents: Data(repeating: 0, count: 10))
        let newURL = tempDir.appendingPathComponent("renamed.jpg")
        FileManager.default.createFile(atPath: newURL.path, contents: Data(repeating: 0, count: 99))

        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [oldURL])
        let imported = try await db.allPhotos()
        let photoID = try XCTUnwrap(imported.first?.id)
        XCTAssertEqual(imported.first?.fileSize, 10)

        let relocated = try await db.relocatePhotos([(photoID: photoID, newPath: newURL.path)])

        XCTAssertEqual(relocated, [photoID])
        let updated = try await db.allPhotos()
        let photo = try XCTUnwrap(updated.first)
        XCTAssertEqual(photo.path, newURL.path)
        XCTAssertEqual(photo.filename, "renamed.jpg", "filename is denormalized from path and must be refreshed too")
        XCTAssertEqual(photo.fileSize, 99, "fileSize must be refreshed from the NEW location, not left stale")
    }

    /// The real collision case a batch move can hit: the destination
    /// path is already claimed by a DIFFERENT catalogued row. Unlike
    /// `addPhotos`' FK-violation precedent (abort the whole transaction),
    /// this must skip only the offending pair and still relocate the rest.
    func testRelocatePhotosSkipsADestinationAlreadyClaimedByAnotherRow() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/old/a.jpg"),
            URL(fileURLWithPath: "/tmp/old/b.jpg"),
            URL(fileURLWithPath: "/tmp/existing/taken.jpg")
        ])
        let photos = try await db.allPhotos()
        let idA = try XCTUnwrap(photos.first { $0.path == "/tmp/old/a.jpg" }?.id)
        let idB = try XCTUnwrap(photos.first { $0.path == "/tmp/old/b.jpg" }?.id)

        let relocated = try await db.relocatePhotos([
            (photoID: idA, newPath: "/tmp/new/a.jpg"),
            (photoID: idB, newPath: "/tmp/existing/taken.jpg") // collides with the third imported photo
        ])

        XCTAssertEqual(relocated, [idA], "only the non-colliding pair should relocate")
        let updated = try await db.allPhotos()
        XCTAssertEqual(updated.first { $0.id == idA }?.path, "/tmp/new/a.jpg")
        XCTAssertEqual(updated.first { $0.id == idB }?.path, "/tmp/old/b.jpg", "the colliding photo must be left untouched")
        XCTAssertEqual(updated.count, 3, "no row was deleted or merged")
    }

    /// Two entries in the SAME batch targeting the same not-yet-existing
    /// destination — a within-batch collision, distinct from colliding
    /// with a pre-existing row. GRDB serializes the whole batch inside one
    /// transaction/connection, so the second pair's collision probe sees
    /// the first pair's already-applied UPDATE and correctly skips it.
    func testRelocatePhotosWithinBatchCollisionOnlyFirstWins() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/old/a.jpg"),
            URL(fileURLWithPath: "/tmp/old/b.jpg")
        ])
        let photos = try await db.allPhotos()
        let idA = try XCTUnwrap(photos.first { $0.path == "/tmp/old/a.jpg" }?.id)
        let idB = try XCTUnwrap(photos.first { $0.path == "/tmp/old/b.jpg" }?.id)

        let relocated = try await db.relocatePhotos([
            (photoID: idA, newPath: "/tmp/new/shared.jpg"),
            (photoID: idB, newPath: "/tmp/new/shared.jpg")
        ])

        XCTAssertEqual(relocated, [idA], "only the first pair in the batch should claim the shared destination")
        let updated = try await db.allPhotos()
        XCTAssertEqual(updated.first { $0.id == idB }?.path, "/tmp/old/b.jpg", "the second pair must be left untouched")
    }

    /// A photo "relocated" back to its OWN current path (a stale
    /// `isMissing` snapshot, or the file having been restored) must
    /// succeed, not be reported as colliding with itself.
    func testRelocatePhotosToItsOwnCurrentPathSucceeds() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/old/a.jpg")])
        let imported = try await db.allPhotos()
        let photoID = try XCTUnwrap(imported.first?.id)

        let relocated = try await db.relocatePhotos([(photoID: photoID, newPath: "/tmp/old/a.jpg")])

        XCTAssertEqual(relocated, [photoID], "relocating to the photo's own current path must not read as a collision")
    }

    func testRelocatePhotosOnNonexistentIDIsANoOp() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/old/a.jpg")])

        let relocated = try await db.relocatePhotos([(photoID: 999_999, newPath: "/tmp/new/a.jpg")])

        XCTAssertTrue(relocated.isEmpty)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 1, "a no-op must not insert, delete, or otherwise change row count")
        XCTAssertEqual(photos.first?.path, "/tmp/old/a.jpg", "the unrelated existing row must be untouched")
    }

    // MARK: - Collections (Phase 4 slice 4)

    func testCreateCollectionAssignsAnID() async throws {
        let db = try makeDatabase()

        let collection = try await db.createCollection(name: "Trip")

        XCTAssertNotNil(collection.id)
        XCTAssertEqual(collection.name, "Trip")
    }

    func testAllCollectionsOrdersByName() async throws {
        let db = try makeDatabase()
        _ = try await db.createCollection(name: "Zebra")
        _ = try await db.createCollection(name: "Apple")

        let collections = try await db.allCollections()

        XCTAssertEqual(collections.map(\.name), ["Apple", "Zebra"])
    }

    func testSetMembershipAddsPhotoToCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg")
        ])
        let photos = try await db.allPhotos()
        let targetID = try XCTUnwrap(photos.first(where: { $0.filename == "a.jpg" })?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: targetID, collectionID: collectionID, isMember: true)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(inCollection.map(\.filename), ["a.jpg"])

        // Collections don't affect the base library.
        let all = try await db.allPhotos()
        XCTAssertEqual(all.count, 2)
    }

    func testSetMembershipIsIdempotent() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(inCollection.count, 1, "adding the same membership twice must not duplicate the row")
    }

    func testSetMembershipRemovesPhotoFromCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: false)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertTrue(inCollection.isEmpty)
    }

    func testAddPhotosAddsAllToCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/c.jpg")
        ])
        let photoIDs = try await db.allPhotos().map { try XCTUnwrap($0.id) }
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.addPhotos(photoIDs, toCollection: collectionID)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(Set(inCollection.map(\.id)), Set(photoIDs))
    }

    func testAddPhotosIsIdempotentForAlreadyMembers() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg")
        ])
        let photoIDs = try await db.allPhotos().map { try XCTUnwrap($0.id) }
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        try await db.setMembership(photoID: photoIDs[0], collectionID: collectionID, isMember: true)

        try await db.addPhotos(photoIDs, toCollection: collectionID)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(
            Set(inCollection.map(\.id)), Set(photoIDs),
            "a photo already a member must not error or duplicate when included in a batch add"
        )
    }

    /// Reviewer-verified claim, now pinned: `insert(db, onConflict: .ignore)`
    /// only suppresses a UNIQUE/PK conflict, NOT a foreign-key violation —
    /// so a stale/nonexistent photo ID in the batch throws, and because
    /// the whole loop runs inside one `dbQueue.write`, GRDB rolls back the
    /// ENTIRE transaction, not just the offending row.
    func testAddPhotosRollsBackEntirelyOnAnInvalidPhotoID() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let validID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        let nonexistentID: Int64 = 999_999

        do {
            try await db.addPhotos([validID, nonexistentID], toCollection: collectionID)
            XCTFail("a batch containing a nonexistent photo ID must throw, not silently skip it")
        } catch {
            // Expected — the foreign-key violation on `nonexistentID`.
        }

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertTrue(
            inCollection.isEmpty,
            "a failed batch must leave zero rows added, not just skip the invalid one"
        )
    }

    func testAllMembershipsReflectsCurrentState() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)

        let memberships = try await db.allMemberships()
        XCTAssertEqual(memberships, [CollectionPhoto(collectionId: collectionID, photoId: photoID)])
    }

    func testRenameCollectionUpdatesTheName() async throws {
        let db = try makeDatabase()
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.renameCollection(id: collectionID, to: "Vacation")

        let collections = try await db.allCollections()
        XCTAssertEqual(collections.map(\.name), ["Vacation"])
    }

    func testRenameCollectionOnNonexistentIDIsANoOp() async throws {
        let db = try makeDatabase()
        _ = try await db.createCollection(name: "Trip")

        try await db.renameCollection(id: 999_999, to: "Vacation")

        let collections = try await db.allCollections()
        XCTAssertEqual(collections.map(\.name), ["Trip"])
    }

    /// A real, executable proof of the `ON DELETE CASCADE` FK, the
    /// collection-delete mirror of
    /// `testDeletePhotoCascadeDeletesCollectionMemberships` — this is the
    /// first live DELETE on `collection` in the whole project.
    func testDeleteCollectionCascadeDeletesMemberships() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let photoID = try XCTUnwrap(importedPhotos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        let membershipsBeforeDelete = try await db.allMemberships()
        XCTAssertEqual(membershipsBeforeDelete.count, 1)

        try await db.deleteCollection(id: collectionID)

        let membershipsAfterDelete = try await db.allMemberships()
        XCTAssertTrue(membershipsAfterDelete.isEmpty)
        let remainingCollections = try await db.allCollections()
        XCTAssertTrue(remainingCollections.isEmpty)
        // The photo itself must survive — only the collection and its
        // membership row go, the mirror image of the photo-delete cascade
        // test's own assertion.
        let remainingPhotos = try await db.allPhotos()
        XCTAssertEqual(remainingPhotos.count, 1)
    }

    func testDeleteCollectionOnNonexistentIDIsANoOp() async throws {
        let db = try makeDatabase()
        _ = try await db.createCollection(name: "Trip")

        try await db.deleteCollection(id: 999_999)

        let remaining = try await db.allCollections()
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Folder-mirrored collections

    /// Builds a `FolderScanNode` tree directly (no real filesystem walk —
    /// that's `PhotoImporterTests`' concern) so these tests exercise only
    /// `CatalogDatabase`'s DB-writing logic. Fake `/tmp/...` paths match
    /// this file's existing convention (`FileManager.attributesOfItem` is
    /// wrapped in `try?` inside `insertPhotoIfNeeded`, so a nonexistent
    /// path just yields a `nil` `fileSize`, not an error).
    private func yearTripDayTree(dayFileCount: Int = 1) -> FolderScanNode {
        let day = FolderScanNode(
            url: URL(fileURLWithPath: "/tmp/2024/Trip/Day1"),
            imageFiles: (1...dayFileCount).map { URL(fileURLWithPath: "/tmp/2024/Trip/Day1/\($0).jpg") },
            children: []
        )
        let trip = FolderScanNode(
            url: URL(fileURLWithPath: "/tmp/2024/Trip"),
            imageFiles: [URL(fileURLWithPath: "/tmp/2024/Trip/group.jpg")],
            children: [day]
        )
        return FolderScanNode(
            url: URL(fileURLWithPath: "/tmp/2024"),
            imageFiles: [],
            children: [trip]
        )
    }

    func testImportFolderTreeCreatesNestedCollectionsWithParentChain() async throws {
        let db = try makeDatabase()

        _ = try await db.importFolderTree(yearTripDayTree())

        let collections = try await db.allCollections()
        let year = try XCTUnwrap(collections.first { $0.name == "2024" })
        let trip = try XCTUnwrap(collections.first { $0.name == "Trip" })
        let day = try XCTUnwrap(collections.first { $0.name == "Day1" })

        XCTAssertTrue(year.isFolder)
        XCTAssertNil(year.parentId)
        XCTAssertEqual(year.folderPath, "/tmp/2024")

        XCTAssertEqual(trip.parentId, year.id)
        XCTAssertEqual(trip.folderPath, "/tmp/2024/Trip")

        XCTAssertEqual(day.parentId, trip.id)
        XCTAssertEqual(day.folderPath, "/tmp/2024/Trip/Day1")
    }

    func testImportFolderTreePhotosAreMembersOfDirectFolderOnly() async throws {
        let db = try makeDatabase()
        _ = try await db.importFolderTree(yearTripDayTree())

        let collections = try await db.allCollections()
        let trip = try XCTUnwrap(collections.first { $0.name == "Trip" })
        let day = try XCTUnwrap(collections.first { $0.name == "Day1" })
        let tripID = try XCTUnwrap(trip.id)
        let dayID = try XCTUnwrap(day.id)

        let tripPhotos = try await db.photos(inCollection: tripID)
        XCTAssertEqual(tripPhotos.map(\.filename), ["group.jpg"], "Trip's own collection should hold only its DIRECT photo, not Day1's")

        let dayPhotos = try await db.photos(inCollection: dayID)
        XCTAssertEqual(dayPhotos.map(\.filename), ["1.jpg"])
    }

    func testImportFolderTreeIsIdempotentOnReimport() async throws {
        let db = try makeDatabase()
        _ = try await db.importFolderTree(yearTripDayTree())

        _ = try await db.importFolderTree(yearTripDayTree())

        let collections = try await db.allCollections()
        XCTAssertEqual(collections.count, 3, "re-importing the same tree must not create duplicate collections")
        let photoCount = try await db.photoCount()
        // yearTripDayTree() has 2 photos total: Trip/group.jpg + Day1/1.jpg
        // (the year node itself has no direct photos).
        XCTAssertEqual(photoCount, 2, "re-importing the same tree must not duplicate photos")
    }

    func testImportFolderTreePicksUpNewPhotosOnReimport() async throws {
        let db = try makeDatabase()
        _ = try await db.importFolderTree(yearTripDayTree(dayFileCount: 1))

        let result = try await db.importFolderTree(yearTripDayTree(dayFileCount: 2))

        XCTAssertEqual(result.inserted, 1, "only the newly-added Day1 photo should count as inserted")
        let collections = try await db.allCollections()
        XCTAssertEqual(collections.count, 3, "no new/duplicate collections from the second import")
        let day = try XCTUnwrap(collections.first { $0.name == "Day1" })
        let dayID = try XCTUnwrap(day.id)
        let dayPhotos = try await db.photos(inCollection: dayID)
        XCTAssertEqual(Set(dayPhotos.map(\.filename)), ["1.jpg", "2.jpg"])
    }

    func testImportFolderTreeAssociatesAPreviouslyFlatImportedPhoto() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/2024/Trip/Day1/1.jpg")])
        let photoCountBefore = try await db.photoCount()

        _ = try await db.importFolderTree(yearTripDayTree(dayFileCount: 1))

        // Trip/group.jpg is genuinely new (+1); Day1/1.jpg already existed
        // from the flat import above and must NOT be duplicated.
        let photoCountAfter = try await db.photoCount()
        XCTAssertEqual(photoCountAfter, photoCountBefore + 1, "only the new group.jpg should be added; 1.jpg must not be duplicated")
        let allPhotos = try await db.allPhotos()
        XCTAssertEqual(allPhotos.filter { $0.filename == "1.jpg" }.count, 1, "1.jpg must appear exactly once across the whole catalog")
        let collections = try await db.allCollections()
        let day = try XCTUnwrap(collections.first { $0.name == "Day1" })
        let dayID = try XCTUnwrap(day.id)
        let dayPhotos = try await db.photos(inCollection: dayID)
        XCTAssertEqual(dayPhotos.map(\.filename), ["1.jpg"], "the tree import should associate the pre-existing photo with Day1's collection")
    }

    // MARK: - Presets (Phase 5 slice 2)

    /// A fully non-identity `EditState` — every color/tone field pushed away
    /// from default, plus geometry and red-eye points, so the round-trip
    /// test below can't pass by coincidentally comparing two all-default
    /// structs.
    private func fullyEditedState() -> EditState {
        var s = EditState()
        s.exposureEV = 1.5
        s.whiteBalanceTemperature = 8000
        s.whiteBalanceTint = 20
        s.hslHue = 0.2
        s.selectiveColorRange = 0.7
        s.redHue = 0.1; s.redSaturation = 0.2; s.redLuminance = 0.3
        s.magentaHue = -0.1; s.magentaSaturation = -0.2; s.magentaLuminance = -0.3
        s.blackAndWhite = true
        s.shadowHue = 210; s.shadowSaturation = 0.6; s.shadowLuminance = -0.3
        s.midtoneHue = 30; s.midtoneSaturation = 0.4; s.midtoneLuminance = 0.2
        s.highlightHue = 50; s.highlightSaturation = 0.5; s.highlightLuminance = 0.1
        s.vignetteStrength = 0.5
        s.clarity = 0.4
        s.sharpness = 0.6
        s.noiseReduction = 0.3
        s.defringePurple = 0.4
        s.defringeGreen = 0.35
        s.grain = 0.2
        s.redEyeSize = 0.8
        s.redEyeStrength = 0.9
        s.redEyePoints = [RedEyePoint(x: 0.3, y: 0.4), RedEyePoint(x: 0.6, y: 0.5)]
        s.pointColors = [PointColor(hasTarget: true, targetHue: 30, targetSaturation: 0.5, range: 0.4, hue: 0.2)]
        s.straightenAngle = 12
        s.transformScale = 1.2
        s.transformAspect = 0.3
        s.cropInsetTop = 0.1
        s.flipHorizontal = true
        return s
    }

    /// A real, executable proof that GRDB's Codable-record support actually
    /// serializes the nested `EditState` to a JSON column and back
    /// correctly — including the 24 selective-color fields and the
    /// variable-length `redEyePoints`/`pointColors` arrays — not just an
    /// assumption from the framework's docs. The first blob/JSON column in
    /// this codebase.
    func testCreatePresetRoundTripsTheFullEditState() async throws {
        let db = try makeDatabase()
        let state = fullyEditedState()

        let created = try await db.createPreset(name: "Moody", editState: state)

        XCTAssertNotNil(created.id)
        let fetched = try await db.allPresets()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.editState, state, "the fetched EditState must equal the saved one, field for field")
    }

    func testCreatePresetWithAnExistingNameReplacesRatherThanDuplicating() async throws {
        let db = try makeDatabase()
        _ = try await db.createPreset(name: "Moody", editState: EditState())
        var updated = EditState()
        updated.exposureEV = 2.0

        _ = try await db.createPreset(name: "Moody", editState: updated)

        let presets = try await db.allPresets()
        XCTAssertEqual(presets.count, 1, "saving under an existing name must overwrite, not duplicate")
        XCTAssertEqual(presets.first?.editState.exposureEV, 2.0)
    }

    /// Reviewer-flagged gap (Texture/Clarity split): the "presets need no SQL
    /// migration" claim rested on transitivity — `EditStateCodableTests`
    /// proves `EditState`'s decoder handles the legacy `definition` key, and
    /// `Preset.editState` is a nested `Codable` on a JSON TEXT column
    /// (`Preset.swift`), so GRDB routes it through that same decoder. This
    /// closes the gap at the decoder boundary GRDB actually uses, with a
    /// preset payload whose `editState` still carries the PRE-SPLIT key.
    ///
    /// Scope, stated honestly: this decodes a `Preset` directly rather than
    /// inserting a raw row, because `CatalogDatabase.dbQueue` is private and
    /// widening production visibility purely for a test is a worse trade
    /// than this. What it proves is the nested-decoding step — the only step
    /// the split could have broken. The surrounding GRDB column plumbing is
    /// already covered by `testCreatePresetRoundTripsTheFullEditState`.
    func testPresetWithLegacyDefinitionKeyDecodesIntoClarity() throws {
        let json = """
        {
            "id": 7,
            "name": "Punchy",
            "createdAt": 758246400,
            "editState": { "exposureEV": 0.25, "definition": 0.62 }
        }
        """

        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))

        XCTAssertEqual(preset.name, "Punchy")
        XCTAssertEqual(preset.editState.clarity, 0.62, "a preset saved before the split must migrate to clarity")
        XCTAssertEqual(preset.editState.texture, 0)
        XCTAssertEqual(preset.editState.exposureEV, 0.25)
    }

    /// The other half of the same guarantee: a migrated value must then
    /// survive a real round trip through the database.
    func testMigratedClarityValueSurvivesAPresetRoundTrip() async throws {
        let db = try makeDatabase()
        let legacy = try JSONDecoder().decode(
            EditState.self,
            from: Data(#"{ "definition": 0.62 }"#.utf8)
        )

        _ = try await db.createPreset(name: "Punchy", editState: legacy)

        let fetched = try await db.allPresets()
        XCTAssertEqual(fetched.first?.editState.clarity, 0.62)
    }

    func testDeletePresetRemovesIt() async throws {
        let db = try makeDatabase()
        let created = try await db.createPreset(name: "Moody", editState: EditState())
        let id = try XCTUnwrap(created.id)

        try await db.deletePreset(id: id)

        let presets = try await db.allPresets()
        XCTAssertTrue(presets.isEmpty)
    }

    func testDeletingANonexistentPresetIDIsANoOp() async throws {
        let db = try makeDatabase()
        _ = try await db.createPreset(name: "Moody", editState: EditState())

        try await db.deletePreset(id: 999_999)

        let presets = try await db.allPresets()
        XCTAssertEqual(presets.count, 1)
    }

    func testAllPresetsOrdersByName() async throws {
        let db = try makeDatabase()
        _ = try await db.createPreset(name: "Zebra", editState: EditState())
        _ = try await db.createPreset(name: "Apple", editState: EditState())

        let presets = try await db.allPresets()

        XCTAssertEqual(presets.map(\.name), ["Apple", "Zebra"])
    }

    // MARK: - registerPhoto / photo(atPath:) (Enhance/Super Resolution)

    func testRegisterPhotoInsertsANewRow() async throws {
        let db = try makeDatabase()

        let photo = try await db.registerPhoto(at: URL(fileURLWithPath: "/tmp/IMG_0001-Enhanced-SR.jpg"))

        XCTAssertEqual(photo.filename, "IMG_0001-Enhanced-SR.jpg")
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1)
    }

    func testRegisterPhotoIsIdempotentReturningTheSameRow() async throws {
        let db = try makeDatabase()
        let url = URL(fileURLWithPath: "/tmp/IMG_0001-Enhanced-SR.jpg")

        let first = try await db.registerPhoto(at: url)
        let second = try await db.registerPhoto(at: url)

        XCTAssertEqual(first.id, second.id)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1, "re-registering the same path must not create a duplicate row")
    }

    func testRegisterPhotoJoinsAnExistingMatchingFolderCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importFolderTree(yearTripDayTree())
        let allCollections = try await db.allCollections()
        let day = try XCTUnwrap(allCollections.first { $0.name == "Day1" })
        let trip = try XCTUnwrap(allCollections.first { $0.name == "Trip" })
        let year = try XCTUnwrap(allCollections.first { $0.name == "2024" })
        let dayID = try XCTUnwrap(day.id)
        let tripID = try XCTUnwrap(trip.id)
        let yearID = try XCTUnwrap(year.id)

        _ = try await db.registerPhoto(at: URL(fileURLWithPath: "/tmp/2024/Trip/Day1/2-Enhanced-SR.jpg"))

        let dayPhotos = try await db.photos(inCollection: dayID)
        XCTAssertEqual(Set(dayPhotos.map(\.filename)), ["1.jpg", "2-Enhanced-SR.jpg"])
        // Reviewer-caught: only checking Day1's own members can't tell
        // "joined the DIRECT parent only" apart from "joined every
        // ancestor in the chain too" — Trip and 2024 (Day1's parent and
        // grandparent) must be COMPLETELY unaffected.
        let tripPhotos = try await db.photos(inCollection: tripID)
        let yearPhotos = try await db.photos(inCollection: yearID)
        XCTAssertEqual(tripPhotos.map(\.filename), ["group.jpg"], "must join ONLY the direct parent folder, not ancestors")
        XCTAssertTrue(yearPhotos.isEmpty, "must join ONLY the direct parent folder, not ancestors")
    }

    func testRegisterPhotoDoesNotCreateANewFolderCollection() async throws {
        let db = try makeDatabase()

        _ = try await db.registerPhoto(at: URL(fileURLWithPath: "/tmp/untracked-folder/IMG_0001-Enhanced-SR.jpg"))

        let collections = try await db.allCollections()
        XCTAssertTrue(collections.isEmpty, "registerPhoto must never create a collection, only join an existing one")
    }

    func testRegisterPhotoDoesNotJoinAnUnrelatedFolderCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importFolderTree(yearTripDayTree())
        let allCollections = try await db.allCollections()
        let trip = try XCTUnwrap(allCollections.first { $0.name == "Trip" })
        let day = try XCTUnwrap(allCollections.first { $0.name == "Day1" })
        let tripID = try XCTUnwrap(trip.id)
        let dayID = try XCTUnwrap(day.id)

        _ = try await db.registerPhoto(at: URL(fileURLWithPath: "/tmp/some-other-folder/IMG_0001-Enhanced-SR.jpg"))

        let tripPhotos = try await db.photos(inCollection: tripID)
        let dayPhotos = try await db.photos(inCollection: dayID)
        XCTAssertEqual(tripPhotos.map(\.filename), ["group.jpg"])
        XCTAssertEqual(dayPhotos.map(\.filename), ["1.jpg"])
    }

    /// A user album's own `folderPath` is always `nil` (`createCollection`
    /// never sets it), so this only proves the `folderPath` EQUALITY
    /// check itself works — it passes whether or not `registerPhoto`
    /// separately checks `isFolder`, since a `nil` folderPath can never
    /// match a real folder path either way. See
    /// `testRegisterPhotoRefusesANonFolderCollectionWithAMatchingFolderPath`
    /// below for the test that actually exercises the `isFolder` check.
    func testRegisterPhotoDoesNotJoinAUserAlbum() async throws {
        let db = try makeDatabase()
        let album = try await db.createCollection(name: "My Favorites")
        let albumID = try XCTUnwrap(album.id)

        _ = try await db.registerPhoto(at: URL(fileURLWithPath: "/tmp/some-folder/IMG_0001-Enhanced-SR.jpg"))

        let albumPhotos = try await db.photos(inCollection: albumID)
        XCTAssertTrue(albumPhotos.isEmpty)
    }

    /// Reviewer-caught: no production code path can ever create an
    /// `isFolder: false` row with a non-nil `folderPath` (only
    /// `findOrCreateFolderCollection` sets `folderPath`, always alongside
    /// `isFolder: true`), so without `insertCollectionForTesting`'s own
    /// bypass, `registerPhoto`'s `isFolder == true` filter is untestable
    /// through the public API — confirmed by mutation: deleting that
    /// filter left every OTHER test in this group passing.
    func testRegisterPhotoRefusesANonFolderCollectionWithAMatchingFolderPath() async throws {
        let db = try makeDatabase()
        let path = "/tmp/weird-collection"
        let nonFolderCollection = PhotoCollection(id: nil, name: "Weird", createdAt: Date(), isFolder: false, folderPath: path)
        let inserted = try await db.insertCollectionForTesting(nonFolderCollection)
        let collectionID = try XCTUnwrap(inserted.id)

        _ = try await db.registerPhoto(at: URL(fileURLWithPath: "\(path)/IMG_0001-Enhanced-SR.jpg"))

        let members = try await db.photos(inCollection: collectionID)
        XCTAssertTrue(members.isEmpty, "registerPhoto must check isFolder, not just a matching folderPath")
    }

    func testPhotoAtPathFindsAnExistingRow() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/IMG_0001.jpg")])

        let found = try await db.photo(atPath: "/tmp/IMG_0001.jpg")

        XCTAssertEqual(found?.filename, "IMG_0001.jpg")
    }

    func testPhotoAtPathReturnsNilForAnUnknownPath() async throws {
        let db = try makeDatabase()

        let found = try await db.photo(atPath: "/tmp/does-not-exist.jpg")

        XCTAssertNil(found)
    }
}
