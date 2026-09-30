import GRDB
import XCTest
@testable import PhotoApp

/// The catalog half of batch rename: `renamePhotos`, the rename log, undo, and Migration 009.
final class CatalogRenameTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    /// `XCTUnwrap`'s argument is a non-async autoclosure, so an awaited value must be unwrapped here.
    private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Creates real files and catalogs them; returns photos keyed by file name.
    private func importFiles(_ names: [String], size: Int = 3) async throws -> [String: Photo] {
        for name in names { try Data(repeating: 0x41, count: size).write(to: dir.appendingPathComponent(name)) }
        _ = try await db.importPhotos(at: names.map { dir.appendingPathComponent($0) })
        let all = try await db.allPhotos()
        return Dictionary(uniqueKeysWithValues: all.map { ($0.filename, $0) })
    }

    private func photo(_ id: Int64?) async throws -> Photo? {
        try await db.allPhotos().first { $0.id == id }
    }

    private func move(_ photo: Photo, to name: String) -> RenameMove {
        RenameMove(photoID: photo.id!, oldPath: photo.path, newPath: path(name))
    }

    // MARK: renamePhotos

    func testRenameUpdatesPathFilenameAndRefreshesTheFileSize() async throws {
        let photos = try await importFiles(["a.jpg"], size: 3)
        let a = try XCTUnwrap(photos["a.jpg"])
        try Data(repeating: 0x42, count: 10).write(to: dir.appendingPathComponent("new.jpg")) // the renamed file (different size)

        _ = try await db.renamePhotos([move(a, to: "new.jpg")])

        let after = try need(try await photo(a.id))
        XCTAssertEqual(after.path, path("new.jpg"))
        XCTAssertEqual(after.filename, "new.jpg")
        XCTAssertEqual(after.fileSize, 10)
    }

    func testAChainAndASwapDoNotTripTheUniquePathConstraint() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg", "c.jpg"])
        let (a, b, c) = (try XCTUnwrap(photos["a.jpg"]), try XCTUnwrap(photos["b.jpg"]), try XCTUnwrap(photos["c.jpg"]))
        // a -> b, b -> a (swap) and c -> d (independent)
        _ = try await db.renamePhotos([move(a, to: "b.jpg"), move(b, to: "a.jpg"), move(c, to: "d.jpg")])
        let pa = try await photo(a.id)?.path, pb = try await photo(b.id)?.path, pc = try await photo(c.id)?.path
        XCTAssertEqual(pa, path("b.jpg"))
        XCTAssertEqual(pb, path("a.jpg"))
        XCTAssertEqual(pc, path("d.jpg"))
    }

    func testRatingFlagLabelAndCollectionMembershipSurviveARename() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        try await db.setRating(4, for: a.id!)
        try await db.setFlagStatus(.picked, for: a.id!)
        try await db.setColorLabel(.blue, for: a.id!)
        let collection = try await db.createCollection(name: "Trip")
        try await db.setMembership(photoID: a.id!, collectionID: collection.id!, isMember: true)

        _ = try await db.renamePhotos([move(a, to: "renamed.jpg")])

        let after = try need(try await photo(a.id))
        XCTAssertEqual(after.id, a.id) // same row
        XCTAssertEqual(after.rating, 4)
        XCTAssertEqual(after.flagStatus, .picked)
        XCTAssertEqual(after.colorLabel, .blue)
        let members = try await db.photos(inCollection: collection.id!)
        XCTAssertEqual(members.map(\.path), [path("renamed.jpg")])
    }

    // MARK: All-or-nothing

    func testAStaleSecondMoveRollsBackTheFirstAndWritesNoLog() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try XCTUnwrap(photos["a.jpg"]), try XCTUnwrap(photos["b.jpg"]))
        let stale = RenameMove(photoID: b.id!, oldPath: path("not-b.jpg"), newPath: path("b2.jpg"))

        do {
            _ = try await db.renamePhotos([move(a, to: "a2.jpg"), stale])
            XCTFail("expected pathChanged")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathChanged(b.id!))
        }

        let pa = try await photo(a.id)?.path
        XCTAssertEqual(pa, a.path) // untouched
        let log = try await db.lastRenameLog()
        XCTAssertNil(log)
    }

    func testAPathOwnedByAPhotoOutsideTheBatchIsRefusedAndNothingChanges() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try XCTUnwrap(photos["a.jpg"]), try XCTUnwrap(photos["b.jpg"]))
        do {
            _ = try await db.renamePhotos([move(a, to: "b.jpg")]) // b is NOT in the batch
            XCTFail("expected pathTaken")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathTaken(path("b.jpg")))
        }
        let pa = try await photo(a.id)?.path, pb = try await photo(b.id)?.path
        XCTAssertEqual(pa, a.path)
        XCTAssertEqual(pb, b.path)
    }

    /// SQLite's `=` is case-sensitive but APFS isn't: a photo catalogued at "B.jpg" IS the file "b.jpg" there.
    func testARenameOntoADifferentlyCasedPathOfAnotherPhotoIsRefused() async throws {
        let photos = try await importFiles(["a.jpg", "B.jpg"])
        let (a, upperB) = (try need(photos["a.jpg"]), try need(photos["B.jpg"]))
        do {
            _ = try await db.renamePhotos([move(a, to: "b.jpg")]) // b.jpg vs the catalogued B.jpg
            XCTFail("expected pathTaken")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathTaken(path("b.jpg")))
        }
        let pa = try await photo(a.id)?.path, pb = try await photo(upperB.id)?.path
        XCTAssertEqual(pa, a.path)
        XCTAssertEqual(pb, upperB.path)
    }

    /// A case-only rename of the SAME photo is not "taken by another photo".
    func testACaseOnlyRenameOfThePhotoItselfIsAllowed() async throws {
        let a = try need(try await importFiles(["IMG.jpg"])["IMG.jpg"])
        _ = try await db.renamePhotos([move(a, to: "img.jpg")])
        let after = try await photo(a.id)?.path
        XCTAssertEqual(after, path("img.jpg"))
    }

    func testAMissingPhotoIsRefused() async throws {
        do {
            _ = try await db.renamePhotos([RenameMove(photoID: 9999, oldPath: path("x.jpg"), newPath: path("y.jpg"))])
            XCTFail("expected photoMissing")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .photoMissing(9999))
        }
    }

    // MARK: The log

    func testTheLogHoldsTheBatchAndOnlyTheMostRecentOne() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try XCTUnwrap(photos["a.jpg"]), try XCTUnwrap(photos["b.jpg"]))
        let firstID = try await db.renamePhotos([move(a, to: "a2.jpg")])
        var log = try await db.lastRenameLog()
        XCTAssertEqual(log?.batchID, firstID)
        XCTAssertEqual(log?.moves, [RenameMove(photoID: a.id!, oldPath: a.path, newPath: path("a2.jpg"))])

        let secondID = try await db.renamePhotos([move(b, to: "b2.jpg")])
        log = try await db.lastRenameLog()
        XCTAssertEqual(log?.batchID, secondID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(log?.moves.map(\.photoID), [b.id!]) // a's older batch is gone
        let count = try await db.renameEntryCountForTesting()
        XCTAssertEqual(count, 1)
    }

    // MARK: Undo (catalog half)

    func testRevertPutsRowsBackAndDeletesTheLog() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try XCTUnwrap(photos["a.jpg"]), try XCTUnwrap(photos["b.jpg"]))
        _ = try await db.renamePhotos([move(a, to: "b.jpg"), move(b, to: "a.jpg")]) // swap
        let log = try need(try await db.lastRenameLog())

        try await db.validateUndo(of: log)
        try await db.revertRenameBatch(log)

        let pa = try await photo(a.id)?.path, pb = try await photo(b.id)?.path
        XCTAssertEqual(pa, a.path)
        XCTAssertEqual(pb, b.path)
        let after = try await db.lastRenameLog()
        XCTAssertNil(after)
    }

    func testUndoIsRefusedWhenARowHasMovedSinceAndTheLogSurvives() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        _ = try await db.renamePhotos([move(a, to: "a2.jpg")])
        let log = try need(try await db.lastRenameLog())
        _ = try await db.relocatePhotos([(photoID: a.id!, newPath: path("elsewhere.jpg"))]) // moved again since

        do {
            try await db.validateUndo(of: log)
            XCTFail("expected pathChanged")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathChanged(a.id!))
        }
        do {
            try await db.revertRenameBatch(log)
            XCTFail("expected pathChanged")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathChanged(a.id!))
        }
        let still = try await db.lastRenameLog()
        XCTAssertNotNil(still)
    }

    func testUndoIsRefusedWhenAPhotoWasRemovedFromTheCatalogSince() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        _ = try await db.renamePhotos([move(a, to: "a2.jpg")])
        let log = try need(try await db.lastRenameLog())
        try await db.deletePhoto(id: a.id!)
        do {
            try await db.validateUndo(of: log)
            XCTFail("expected photoMissing")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .photoMissing(a.id!))
        }
    }

    // MARK: Migration 009

    func testMigration009AddsTheLogTablesToAnExistingCatalogWithoutTouchingData() async throws {
        let file = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let queue = try DatabaseQueue(path: file)
            var migrator = DatabaseMigrator()
            Migration001Initial.register(in: &migrator)
            Migration002RatingsAndFlags.register(in: &migrator)
            Migration003Collections.register(in: &migrator)
            Migration004FolderCollections.register(in: &migrator)
            Migration005Presets.register(in: &migrator)
            Migration006CollectionFolderPathIndex.register(in: &migrator)
            Migration007PickRejectFlags.register(in: &migrator)
            Migration008ColorLabels.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating) VALUES ('/tmp/x.jpg', 'x.jpg', '2026-01-01 00:00:00', 5)")
            }
        }

        let upgraded = try CatalogDatabase(path: file)

        let photos = try await upgraded.allPhotos()
        XCTAssertEqual(photos.map(\.filename), ["x.jpg"])
        XCTAssertEqual(photos.first?.rating, 5)
        let log = try await upgraded.lastRenameLog()
        XCTAssertNil(log)
        let queue = try DatabaseQueue(path: file)
        let tables = try await queue.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(tables.contains("rename_batch") && tables.contains("rename_entry"))
    }
}
