import GRDB
import XCTest
@testable import PhotoApp

/// Virtual copies, catalog half: Migration 015 (table rebuild that must not lose or alter any row/child), the two uniqueness indexes,
/// the cascade, `createVirtualCopy`, and Rename/Relocate/re-import behaviour when copies exist.
final class VirtualCopyDatabaseTests: XCTestCase {
    // MARK: - Helpers

    private func tempPath() -> String { NSTemporaryDirectory() + "vc-catalog-\(UUID().uuidString).sqlite" }

    /// Migrates `queue` through 014 only (a pre-virtual-copies catalog).
    private func migrateThrough014(_ queue: DatabaseQueue) throws {
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
        Migration011SmartCollections.register(in: &migrator)
        Migration012PhotoFingerprint.register(in: &migrator)
        Migration013Faces.register(in: &migrator)
        Migration014PhotoMetadata.register(in: &migrator)
        try migrator.migrate(queue)
    }

    private func populatePre015(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO photo (id, path, filename, fileSize, importedAt, rating, flagStatus, colorLabel) VALUES
                (1, '/p/a.jpg', 'a.jpg', 100, '2026-01-01 00:00:00', 4, 1, 2),
                (2, '/p/b.jpg', 'b.jpg', NULL, '2026-01-02 00:00:00', 0, -1, 0),
                (7, '/p/c.jpg', 'c.jpg', 300, '2026-01-03 00:00:00', 5, 0, 5)
                """)
            try db.execute(sql: "DELETE FROM photo WHERE id = 7") // leaves the AUTOINCREMENT counter at 7
            try db.execute(sql: "INSERT INTO collection (id, name, createdAt) VALUES (1, 'Album', '2026-01-01 00:00:00')")
            try db.execute(sql: "INSERT INTO collection_photo (collectionId, photoId) VALUES (1, 1), (1, 2)")
            try db.execute(sql: "INSERT INTO keyword (id, name, nameKey, createdAt) VALUES (1, 'Sky', 'sky', '2026-01-01 00:00:00')")
            try db.execute(sql: "INSERT INTO photo_keyword (keywordId, photoId) VALUES (1, 1)")
            try db.execute(sql: "INSERT INTO photo_fingerprint (photoId, fileSize, mtime, computedAt) VALUES (1, 100, 5.0, '2026-01-01 00:00:00')")
            try db.execute(sql: "INSERT INTO face_scan (photoId, fileSize, mtime, detectRevision, printRevision, faceCount, scannedAt) VALUES (1, 100, 5.0, 1, 1, 1, '2026-01-01 00:00:00')")
            try db.execute(sql: """
                INSERT INTO face (id, photoId, x, y, w, h, quality, detectRevision, printRevision, featurePrint, isConfirmed)
                VALUES (1, 1, 0.1, 0.1, 0.2, 0.2, 0.9, 1, 1, X'00', 0)
                """)
            try db.execute(sql: "INSERT INTO photo_metadata (photoId, fileSize, mtime, readerRevision, iso, scannedAt) VALUES (2, 1, 1.0, 1, 400, '2026-01-01 00:00:00')")
        }
    }

    private func counts(_ queue: DatabaseQueue) throws -> [String: Int] {
        try queue.read { db in
            var out: [String: Int] = [:]
            for table in ["photo", "collection", "collection_photo", "keyword", "photo_keyword", "photo_fingerprint", "face_scan", "face",
                          "photo_metadata"] {
                out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
            return out
        }
    }

    private func photoRows(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, filename, fileSize, importedAt, rating, flagStatus, colorLabel FROM photo ORDER BY id")
                .map { "\($0)" }
        }
    }

    private func integrityFacts(_ queue: DatabaseQueue) throws -> (foreignKeyViolations: Int, copyColumnRows: Int, sequence: Int?) {
        try queue.read { db in
            (try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo WHERE masterId IS NOT NULL OR versionKey IS NOT NULL OR versionName IS NOT NULL") ?? -1,
             try Int.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'photo'"))
        }
    }

    // MARK: - Migration 015

    func testMigration015KeepsEveryRowAndChildOfAPopulatedCatalog() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try migrateThrough014(queue)
        try populatePre015(queue)
        let before = try counts(queue)
        let rowsBefore = try photoRows(queue)
        XCTAssertEqual(before["photo"], 2)

        let db = try CatalogDatabase(path: path) // runs ONLY 015 on this file

        let after = try counts(queue)
        XCTAssertEqual(after, before, "every photo and child row must survive the table rebuild")
        let rowsAfter = try photoRows(queue)
        XCTAssertEqual(rowsAfter, rowsBefore, "no existing photo column may change")
        let integrity = try integrityFacts(queue)
        XCTAssertEqual(integrity.foreignKeyViolations, 0)
        XCTAssertEqual(integrity.copyColumnRows, 0)
        XCTAssertEqual(integrity.sequence, 7, "the AUTOINCREMENT counter is carried over: a deleted id is not reissued")
        // The children still reference photo(id): deleting a photo still cascades to them.
        try await db.deletePhoto(id: 1)
        let finalCounts = try counts(queue)
        XCTAssertEqual(finalCounts["photo"], 1)
        XCTAssertEqual(finalCounts["collection_photo"], 1)
        XCTAssertEqual(finalCounts["photo_keyword"], 0)
        XCTAssertEqual(finalCounts["photo_fingerprint"], 0)
        XCTAssertEqual(finalCounts["face"], 0)
        XCTAssertEqual(finalCounts["face_scan"], 0)
        XCTAssertEqual(finalCounts["photo_metadata"], 1, "photo 2's row must be untouched")
    }

    func testMigration015IsIdempotentOnReopen() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try migrateThrough014(queue)
        try populatePre015(queue)
        _ = try CatalogDatabase(path: path)
        let once = try counts(queue)
        _ = try CatalogDatabase(path: path)
        XCTAssertEqual(try counts(queue), once)
    }

    func testMastersStayUniqueByPathButTwoCopiesOfOnePathAreAllowed() throws {
        let catalog = try CatalogDatabase(inMemory: true)
        try catalog.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO photo (path, filename, importedAt) VALUES ('/p/a.jpg', 'a.jpg', '2026-01-01 00:00:00')")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO photo (path, filename, importedAt) VALUES ('/p/a.jpg', 'a.jpg', '2026-01-01 00:00:00')"),
                                 "two MASTERS at one path must still be refused")
        }
        try catalog.dbQueue.write { db in
            let masterID = try Int64.fetchOne(db, sql: "SELECT id FROM photo")
            for key in ["aaaaaaaa", "bbbbbbbb"] {
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, masterId, versionKey) VALUES ('/p/a.jpg', 'a.jpg', '2026-01-01 00:00:00', ?, ?)",
                               arguments: [masterID, key])
            }
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, masterId, versionKey) VALUES ('/p/a.jpg', 'a.jpg', '2026-01-01 00:00:00', ?, 'aaaaaaaa')",
                                                arguments: [masterID]), "the same (path, versionKey) twice must be refused")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo WHERE path = '/p/a.jpg'"), 3)
        }
    }

    func testDeletingAMasterRowCascadesToItsCopiesOnly() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg"), URL(fileURLWithPath: "/p/b.jpg")])
        let a = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        let b = try unwrapped(await catalog.photo(atPath: "/p/b.jpg"))
        let copyA = try await catalog.createVirtualCopy(of: a, versionKey: "11111111")
        let copyB = try await catalog.createVirtualCopy(of: b, versionKey: "22222222")
        try await catalog.deletePhoto(id: try XCTUnwrap(a.id))
        let remaining = try await catalog.allPhotos().compactMap(\.id)
        XCTAssertFalse(remaining.contains(try XCTUnwrap(copyA.id)), "a master's copies go with it")
        XCTAssertEqual(Set(remaining), Set([try XCTUnwrap(b.id), try XCTUnwrap(copyB.id)]))
        // Deleting a COPY leaves the master.
        try await catalog.deletePhoto(id: try XCTUnwrap(copyB.id))
        let ids = try await catalog.allPhotos().compactMap(\.id)
        XCTAssertEqual(ids, [try XCTUnwrap(b.id)])
    }

    // MARK: - createVirtualCopy

    func testCreateVirtualCopyHangsOffTheMasterAndJoinsItsFolderCollectionOnly() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        let masterID = try XCTUnwrap(master.id)
        try await catalog.setRating(4, for: masterID)
        let folder = try await catalog.insertCollectionForTesting(
            PhotoCollection(id: nil, name: "p", createdAt: Date(), parentId: nil, isFolder: true, folderPath: "/p")
        )
        let album = try await catalog.createCollection(name: "Album")
        try await catalog.addPhotos([masterID], toCollection: try XCTUnwrap(folder.id))
        try await catalog.addPhotos([masterID], toCollection: try XCTUnwrap(album.id))

        let first = try await catalog.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        // A copy of a COPY still hangs off the master and takes the next number.
        let second = try await catalog.createVirtualCopy(of: first, versionKey: "bbbbbbbb")

        XCTAssertEqual(first.masterId, masterID)
        XCTAssertEqual(second.masterId, masterID)
        XCTAssertEqual(first.versionName, "Copy 1")
        XCTAssertEqual(second.versionName, "Copy 2")
        XCTAssertEqual(first.path, "/p/a.jpg")
        XCTAssertEqual(first.rating, 0, "per-version metadata starts fresh")
        XCTAssertTrue(first.isVirtualCopy)
        XCTAssertFalse(master.isVirtualCopy)
        XCTAssertNotEqual(first.editKey, master.editKey)
        XCTAssertEqual(master.editKey, "/p/a.jpg", "a master's edit key is its path, exactly as before")
        let inFolder = try await catalog.photos(inCollection: try XCTUnwrap(folder.id)).compactMap(\.id)
        XCTAssertTrue(inFolder.contains(try XCTUnwrap(first.id)))
        let inAlbum = try await catalog.photos(inCollection: try XCTUnwrap(album.id)).compactMap(\.id)
        XCTAssertFalse(inAlbum.contains(try XCTUnwrap(first.id)), "only FOLDER collections are joined")
        let copies = try await catalog.copies(ofMasterID: masterID)
        XCTAssertEqual(copies.count, 2)
    }

    func testCreateVirtualCopyRefusesMalformedAndDuplicateKeys() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        do { _ = try await catalog.createVirtualCopy(of: master, versionKey: "../evil"); XCTFail("malformed key accepted") } catch {}
        _ = try await catalog.createVirtualCopy(of: master, versionKey: "cccccccc")
        do { _ = try await catalog.createVirtualCopy(of: master, versionKey: "cccccccc"); XCTFail("duplicate key accepted") } catch {}
        let count = try await catalog.photoCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Re-import / lookup / relocate / rename

    func testReimportAndPathLookupSeeTheMasterNotACopy() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        _ = try await catalog.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        let again = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.skipped, 1)
        let found = try await catalog.photo(atPath: "/p/a.jpg")
        XCTAssertEqual(found?.id, master.id)
        let count = try await catalog.photoCount()
        XCTAssertEqual(count, 2)
    }

    func testRelocatingAMasterMovesItsCopiesAndACopyNeverRelocatesAlone() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        let copy = try await catalog.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        let skipped = try await catalog.relocatePhotos([(try XCTUnwrap(copy.id), "/q/a.jpg")])
        XCTAssertTrue(skipped.isEmpty, "a copy follows its master and never relocates by itself")
        let done = try await catalog.relocatePhotos([(try XCTUnwrap(master.id), "/q/a.jpg")])
        XCTAssertEqual(done, [try XCTUnwrap(master.id)])
        let all = try await catalog.allPhotos()
        XCTAssertEqual(Set(all.map(\.path)), ["/q/a.jpg"], "master and copy must still share one path")
    }

    func testRenamingAMasterMovesItsCopiesRowsAndACopyCannotBeRenamed() async throws {
        let catalog = try CatalogDatabase(inMemory: true)
        _ = try await catalog.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg"), URL(fileURLWithPath: "/p/b.jpg")])
        let a = try unwrapped(await catalog.photo(atPath: "/p/a.jpg"))
        let b = try unwrapped(await catalog.photo(atPath: "/p/b.jpg"))
        let copyOfB = try await catalog.createVirtualCopy(of: b, versionKey: "bbbbbbbb")
        let aID = try XCTUnwrap(a.id), bID = try XCTUnwrap(b.id)
        // A chain a -> b while b -> c: the copy of b (still at /p/b.jpg) must not look like "a foreign photo holds b".
        _ = try await catalog.renamePhotos([
            RenameMove(photoID: aID, oldPath: "/p/a.jpg", newPath: "/p/b.jpg"),
            RenameMove(photoID: bID, oldPath: "/p/b.jpg", newPath: "/p/c.jpg")
        ])
        let all = try await catalog.allPhotos()
        XCTAssertEqual(all.first { $0.id == copyOfB.id }?.path, "/p/c.jpg")
        XCTAssertEqual(all.first { $0.id == copyOfB.id }?.filename, "c.jpg")
        XCTAssertEqual(all.first { $0.id == aID }?.path, "/p/b.jpg")
        do {
            _ = try await catalog.renamePhotos([RenameMove(photoID: try XCTUnwrap(copyOfB.id), oldPath: "/p/c.jpg", newPath: "/p/z.jpg")])
            XCTFail("renaming through a copy row must be refused")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .copyCannotBeRenamed(try XCTUnwrap(copyOfB.id)))
        }
        // Undo of the batch brings the copy back too.
        let log = try unwrapped(await catalog.lastRenameLog())
        try await catalog.revertRenameBatch(log)
        let reverted = try await catalog.allPhotos()
        XCTAssertEqual(reverted.first { $0.id == copyOfB.id }?.path, "/p/b.jpg")
    }

    // MARK: - Small async helpers

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
