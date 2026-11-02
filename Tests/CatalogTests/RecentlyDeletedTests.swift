import GRDB
import XCTest
@testable import PhotoApp

/// Recently Deleted, catalog half: the snapshot is written in the SAME transaction as the row delete, and a restore puts the rows back
/// with their ORIGINAL ids, never when the file is not there, never over a row that owns the path.
final class RecentlyDeletedDatabaseTests: XCTestCase {
    private let present: @Sendable (String) -> Bool = { _ in true }
    private let absent: @Sendable (String) -> Bool = { _ in false }

    private func makeCatalog(_ names: [String]) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: names.map { URL(fileURLWithPath: "/p/\($0)") })
        var ids: [Int64] = []
        for name in names { ids.append(try need(try await db.photo(atPath: "/p/\(name)")?.id)) }
        return (db, ids)
    }

    private func entries(_ db: CatalogDatabase) async throws -> [DeletedPhotoEntry] { try await db.deletedPhotoEntries() }

    // MARK: Snapshot

    func testTrashingWritesASnapshotAndRemovesTheRow() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg"])
        try await db.setRating(4, for: ids[0])
        let removed = try await db.trashPhotos(ids: [ids[0]], trashedPaths: [ids[0]: "/Users/x/.Trash/a.jpg"])
        XCTAssertEqual(removed, 1)
        let remaining = try await db.allPhotos().map(\.filename)
        XCTAssertEqual(remaining, ["b.jpg"])
        let list = try await entries(db)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].originalPath, "/p/a.jpg")
        XCTAssertEqual(list[0].trashedPath, "/Users/x/.Trash/a.jpg")
        XCTAssertEqual(list[0].snapshot.rows.first?.photo.rating, 4)
        XCTAssertEqual(list[0].snapshot.rows.first?.photo.id, ids[0])
    }

    func testTheSnapshotAndTheDeleteAreOneTransaction() async throws {
        // A failing snapshot insert must leave the row in place...
        let (db, ids) = try await makeCatalog(["a.jpg"])
        try await db.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER no_snapshot BEFORE INSERT ON deleted_photo BEGIN SELECT RAISE(ABORT, 'no snapshot'); END")
        }
        do { _ = try await db.trashPhotos(ids: ids, trashedPaths: [:]); XCTFail("should have thrown") } catch {}
        let stillThere = try await db.allPhotos().count
        XCTAssertEqual(stillThere, 1)
        // ...and a failing delete must leave NO snapshot behind.
        let (db2, ids2) = try await makeCatalog(["a.jpg"])
        try await db2.dbQueue.write { db in
            try db.execute(sql: "CREATE TRIGGER no_delete BEFORE DELETE ON photo BEGIN SELECT RAISE(ABORT, 'no delete'); END")
        }
        do { _ = try await db2.trashPhotos(ids: ids2, trashedPaths: [:]); XCTFail("should have thrown") } catch {}
        let snapshots = try await entries(db2)
        XCTAssertTrue(snapshots.isEmpty, "a delete that rolled back must not leave a Recently Deleted entry")
        let kept = try await db2.allPhotos().count
        XCTAssertEqual(kept, 1)
    }

    func testAMastersCopiesAreInItsSnapshot() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        let master = try need(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        try await db.setRating(5, for: try XCTUnwrap(copy.id))
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        let list = try await entries(db)
        XCTAssertEqual(list.count, 1, "one entry per photo, copies inside it")
        XCTAssertEqual(list[0].copyCount, 1)
        XCTAssertEqual(list[0].snapshot.rows.count, 2)
        let remaining = try await db.allPhotos()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testACopyTrashedOnItsOwnHasItsOwnEntry() async throws {
        let (db, _) = try await makeCatalog(["a.jpg"])
        let master = try need(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        _ = try await db.trashPhotos(ids: [try XCTUnwrap(copy.id)], trashedPaths: [:])
        let list = try await entries(db)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].snapshot.rows.first?.photo.versionKey, "abcdef12")
        let left = try await db.allPhotos().count
        XCTAssertEqual(left, 1, "the master stays")
    }

    // MARK: Restore

    private func decorate(_ db: CatalogDatabase, _ id: Int64) async throws -> Int64 {
        try await db.setRating(3, for: id)
        try await db.setColorLabel(.green, for: id)
        try await db.setFlagStatus(.picked, for: id)
        try await db.addKeywords(["Sunset", "Beach"], to: [id])
        let collection = try await db.createCollection(name: "Trip")
        try await db.addPhotos([id], toCollection: try XCTUnwrap(collection.id))
        try await db.setInfo(PhotoInfo(title: "T", caption: "C", creator: "", copyright: ""), forPhotoIDs: [id], fields: .all)
        return try XCTUnwrap(collection.id)
    }

    func testRestoreRoundTripPutsEverythingBackWithTheOriginalIds() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg"])
        let collectionID = try await decorate(db, ids[0])
        let master = try need(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        let copyID = try XCTUnwrap(copy.id)
        try await db.addKeywords(["Copy only"], to: [copyID])
        let before = try await db.allPhotos().filter { $0.id == ids[0] || $0.id == copyID }.sorted { $0.id! < $1.id! }
        _ = try await db.trashPhotos(ids: [ids[0]], trashedPaths: [ids[0]: "/T/a.jpg"])
        let entryID = try need(try await entries(db).first?.id)

        let outcome = try await db.restoreDeletedPhoto(id: entryID, fileExists: present)
        guard case .restored(let report) = outcome else { return XCTFail("expected restored, got \(outcome)") }
        XCTAssertEqual(report.restoredCopies, 1)
        XCTAssertTrue(report.missingCollections.isEmpty)

        let after = try await db.allPhotos().filter { $0.id == ids[0] || $0.id == copyID }.sorted { $0.id! < $1.id! }
        XCTAssertEqual(after, before, "same ids, ratings, flags, labels, paths, version keys")
        let info = try await db.allInfo()[ids[0]]
        XCTAssertEqual(info?.title, "T")
        let names = Set(try await db.allKeywords().map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Sunset", "Beach", "Copy only"]))
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(links.filter { $0.photoId == ids[0] }.count, 2)
        XCTAssertEqual(links.filter { $0.photoId == copyID }.count, 1)
        let members = try await db.photos(inCollection: collectionID).compactMap(\.id)
        XCTAssertTrue(members.contains(ids[0]))
        let remainingEntries = try await entries(db)
        XCTAssertTrue(remainingEntries.isEmpty, "a restored entry leaves the list")
    }

    func testRestoreIsRefusedWhenTheFileIsNotBack() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        let entryID = try need(try await entries(db).first?.id)
        let outcome = try await db.restoreDeletedPhoto(id: entryID, fileExists: absent)
        XCTAssertEqual(outcome, .fileMissing)
        let photos = try await db.allPhotos()
        XCTAssertTrue(photos.isEmpty)
        let list = try await entries(db)
        XCTAssertEqual(list.count, 1, "the entry stays so it can be restored later")
    }

    func testRestoreIsRefusedWhenAnotherRowOwnsThePath() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")]) // the file was imported again
        let entry = try need(try await entries(db).first)
        XCTAssertEqual(entry.blocker, .pathInUse)
        let outcome = try await db.restoreDeletedPhoto(id: entry.id, fileExists: present)
        XCTAssertEqual(outcome, .pathInUse)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 1)
        XCTAssertNotEqual(photos.first?.id, ids[0])
    }

    func testRestoringAnUnknownEntryIsReported() async throws {
        let (db, _) = try await makeCatalog(["a.jpg"])
        let outcome = try await db.restoreDeletedPhoto(id: 999, fileExists: present)
        XCTAssertEqual(outcome, .notFound)
    }

    func testCollectionsThatNoLongerExistAreReportedNotInvented() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        let collectionID = try await decorate(db, ids[0])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        try await db.deleteCollection(id: collectionID)
        let entryID = try need(try await entries(db).first?.id)
        guard case .restored(let report) = try await db.restoreDeletedPhoto(id: entryID, fileExists: present) else { return XCTFail("expected restored") }
        XCTAssertEqual(report.missingCollections, ["Trip"])
    }

    func testAStackIsRecreatedOnlyWithAnotherMemberAndNeverFromOne() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg", "c.jpg"])
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0])
        _ = try await db.trashPhotos(ids: [ids[0]], trashedPaths: [:]) // the trigger dissolves the 2-photo stack
        var stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
        let entryID = try need(try await entries(db).first?.id)
        guard case .restored(let report) = try await db.restoreDeletedPhoto(id: entryID, fileExists: present) else { return XCTFail("expected restored") }
        XCTAssertTrue(report.stackRestored)
        stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs, [ids[0], ids[1]])
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[0])

        // The only other member is gone too: no one-photo stack.
        let (db2, ids2) = try await makeCatalog(["a.jpg", "b.jpg"])
        try await db2.createStack(photoIDs: ids2, manual: true)
        _ = try await db2.trashPhotos(ids: [ids2[0]], trashedPaths: [:])
        _ = try await db2.trashPhotos(ids: [ids2[1]], trashedPaths: [:])
        let first = try need(try await entries(db2).first { $0.originalPath == "/p/a.jpg" })
        _ = try await db2.restoreDeletedPhoto(id: first.id, fileExists: present)
        let none = try await db2.allStacks()
        XCTAssertTrue(none.isEmpty)
    }

    func testACopyEntryCannotBeRestoredWithoutItsMaster() async throws {
        let (db, _) = try await makeCatalog(["a.jpg"])
        let master = try need(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        _ = try await db.trashPhotos(ids: [try XCTUnwrap(copy.id)], trashedPaths: [:])
        let entryID = try need(try await entries(db).first?.id)
        let ok = try await db.restoreDeletedPhoto(id: entryID, fileExists: present)
        guard case .restored = ok else { return XCTFail("expected restored") }
        let restoredCopy = try await db.photo(atPath: "/p/a.jpg")
        XCTAssertNotNil(restoredCopy)

        let (db2, ids2) = try await makeCatalog(["a.jpg"])
        let master2 = try need(try await db2.photo(atPath: "/p/a.jpg"))
        let copy2 = try await db2.createVirtualCopy(of: master2, versionKey: "abcdef12")
        _ = try await db2.trashPhotos(ids: [try XCTUnwrap(copy2.id)], trashedPaths: [:])
        _ = try await db2.trashPhotos(ids: ids2, trashedPaths: [:])
        let copyEntry = try need(try await entries(db2).first { $0.snapshot.rows.first?.photo.isVirtualCopy == true })
        XCTAssertEqual(copyEntry.blocker, .masterMissing)
        let outcome = try await db2.restoreDeletedPhoto(id: copyEntry.id, fileExists: present)
        XCTAssertEqual(outcome, .masterMissing)
    }

    func testRestoreWaitsForTheEditFileThatWentToTheTrashWithThePhoto() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:], editFiles: [ids[0]: ["/p/a.jpg.photoapp.json"]])
        let entry = try need(try await entries(db).first)
        XCTAssertEqual(entry.editFilePaths, ["/p/a.jpg.photoapp.json"])
        let onlyPhoto: @Sendable (String) -> Bool = { $0 == "/p/a.jpg" }
        let refused = try await db.restoreDeletedPhoto(id: entry.id, fileExists: onlyPhoto)
        XCTAssertEqual(refused, .editFileMissing)
        let none = try await db.allPhotos()
        XCTAssertTrue(none.isEmpty)
        let ok = try await db.restoreDeletedPhoto(id: entry.id, fileExists: present)
        guard case .restored = ok else { return XCTFail("expected restored") }
    }

    func testAStackThatStillExistsGetsItsCoverBack() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg", "c.jpg"])
        try await db.createStack(photoIDs: ids, manual: true, cover: ids[0])
        _ = try await db.trashPhotos(ids: [ids[0]], trashedPaths: [:]) // b and c keep the stack; the cover went NULL
        var stacks = try await db.allStacks()
        XCTAssertNil(stacks.first?.coverPhotoID)
        let entryID = try need(try await entries(db).first?.id)
        _ = try await db.restoreDeletedPhoto(id: entryID, fileExists: present)
        stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[0])
    }

    func testARecreatedStackDoesNotGiveTheRestoredPhotosManualFlagToTheOthers() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg"])
        try await db.createStack(photoIDs: ids, manual: true)
        try await db.dbQueue.write { db in try db.execute(sql: "UPDATE photo_stack_member SET addedManually = 1 WHERE photoId = ?", arguments: [ids[0]]) }
        _ = try await db.trashPhotos(ids: [ids[0]], trashedPaths: [:])
        let entryID = try need(try await entries(db).first?.id)
        _ = try await db.restoreDeletedPhoto(id: entryID, fileExists: present)
        let flags = try await db.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT photoId, addedManually FROM photo_stack_member ORDER BY photoId").map { ($0["photoId"] as Int64, $0["addedManually"] as Bool) }
        }
        XCTAssertEqual(flags.map(\.0), ids)
        XCTAssertEqual(flags.map(\.1), [true, false])
    }

    func testAFolderCollectionRecreatedByAReImportIsFoundByItsFolderPath() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        try await db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO collection (name, createdAt, isFolder, folderPath) VALUES ('p', '2026-01-01 00:00:00', 1, '/p')")
            try db.execute(sql: "INSERT INTO collection_photo (collectionId, photoId) SELECT id, ? FROM collection WHERE folderPath = '/p'", arguments: [ids[0]])
        }
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        let newID: Int64 = try await db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collection WHERE folderPath = '/p'")
            try db.execute(sql: "INSERT INTO collection (name, createdAt, isFolder, folderPath) VALUES ('p', '2026-02-01 00:00:00', 1, '/p')")
            return db.lastInsertedRowID
        }
        let entryID = try need(try await entries(db).first?.id)
        guard case .restored(let report) = try await db.restoreDeletedPhoto(id: entryID, fileExists: present) else { return XCTFail("expected restored") }
        XCTAssertTrue(report.missingCollections.isEmpty)
        let members = try await db.photos(inCollection: newID).compactMap(\.id)
        XCTAssertEqual(members, ids)
    }

    func testUnreadableEntriesAreListedAndCanBeRemoved() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg"])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        try await db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO deleted_photo (originalPath, deletedAt, schemaVersion, snapshot) VALUES ('/p/new.jpg', '2026-01-01 00:00:00', 99, '{}')")
            try db.execute(sql: "INSERT INTO deleted_photo (originalPath, deletedAt, schemaVersion, snapshot) VALUES ('/p/bad.jpg', '2026-01-01 00:00:00', 1, 'not json')")
        }
        let readable = try await entries(db)
        XCTAssertEqual(readable.map(\.originalPath), ["/p/a.jpg"])
        let unreadable = try await db.unreadableDeletedPhotos()
        XCTAssertEqual(Set(unreadable.map(\.originalPath)), ["/p/new.jpg", "/p/bad.jpg"])
        try await db.forgetDeletedPhotos(ids: unreadable.map(\.id))
        let again = try await db.unreadableDeletedPhotos()
        XCTAssertTrue(again.isEmpty)
        let kept = try await entries(db).count
        XCTAssertEqual(kept, 1)
    }

    // MARK: Forget

    func testForgettingRemovesOnlyTheListEntries() async throws {
        let (db, ids) = try await makeCatalog(["a.jpg", "b.jpg"])
        _ = try await db.trashPhotos(ids: ids, trashedPaths: [:])
        let list = try await entries(db)
        try await db.forgetDeletedPhotos(ids: [list[0].id])
        let left = try await entries(db)
        XCTAssertEqual(left.count, 1)
        try await db.forgetAllDeletedPhotos()
        let none = try await entries(db)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Migration

    func testMigration018AddsTheTableToAPopulatedPre018Catalog() async throws {
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
            Migration011SmartCollections.register(in: &migrator)
            Migration012PhotoFingerprint.register(in: &migrator)
            Migration013Faces.register(in: &migrator)
            Migration014PhotoMetadata.register(in: &migrator)
            Migration015VirtualCopies.register(in: &migrator)
            Migration016PhotoInfo.register(in: &migrator)
            Migration017PhotoStacks.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 3, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 1)
        let empty = try await entries(db)
        XCTAssertTrue(empty.isEmpty)
        _ = try await db.trashPhotos(ids: photos.compactMap(\.id), trashedPaths: [:])
        let stored = try await entries(db)
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: Drift guard

    /// Every table with a foreign key to `photo` must be named in `DeletedPhotoSnapshot.foreignKeyHandling`. A new table that references
    /// `photo` fails here until someone decides whether Recently Deleted snapshots it, rebuilds it later, or drops it on purpose.
    /// Limit: it only sees DECLARED foreign keys. `rename_entry.photoId` has none (it is a log column), so a rename entry is invisible here.
    func testEveryTableThatReferencesPhotoIsHandledBySnapshotOrRestore() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let referencing: Set<String> = try await db.dbQueue.read { db in
            var found = Set<String>()
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
                    let target: String = row["table"]
                    if target == "photo" { found.insert(table) }
                }
            }
            return found
        }
        let handled = Set(DeletedPhotoSnapshot.foreignKeyHandling.keys)
        XCTAssertEqual(referencing, handled, "a table referencing photo is not (or no longer) classified in DeletedPhotoSnapshot.foreignKeyHandling")
    }
}

// MARK: - Status, wording, source pin

final class RecentlyDeletedPureTests: XCTestCase {
    func testACopyAndAMissingEditFileHaveTheirOwnStatus() {
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: nil, fileExists: true, editFilesExist: false), .editFileMissing)
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: nil, fileExists: true, editFilesExist: true, isCopy: true), .readyCopy)
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: nil, fileExists: false, editFilesExist: false, isCopy: true), .mayBeInTrash)
        XCTAssertTrue(RecentlyDeletedStatus.readyCopy.canRestore)
        XCTAssertFalse(RecentlyDeletedStatus.editFileMissing.canRestore)
        XCTAssertFalse(RecentlyDeletedStatus.readyCopy.message.contains("File is back"), "a copy's image never left: do not claim the file came back")
        XCTAssertTrue(RecentlyDeletedStatus.editFileMissing.message.contains("edit file"))
        XCTAssertTrue(RecentlyDeletedModel.explanation.contains("TOGETHER with its edit file"))
    }

    func testStatusPicksTheBlockerFirstThenTheFile() {
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: nil, fileExists: true), .ready)
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: nil, fileExists: false), .mayBeInTrash)
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: .pathInUse, fileExists: true), .pathInUse)
        XCTAssertEqual(RecentlyDeletedStatus.of(blocker: .masterMissing, fileExists: false), .masterMissing)
        XCTAssertTrue(RecentlyDeletedStatus.ready.canRestore)
        for status in [RecentlyDeletedStatus.mayBeInTrash, .pathInUse, .masterMissing] { XCTAssertFalse(status.canRestore) }
        XCTAssertEqual(RecentlyDeletedStatus.mayBeInTrash.message, "May still be in the Trash — use Put Back in Finder first, together with its edit file and XMP sidecar")
        XCTAssertEqual(RecentlyDeletedStatus.ready.message, "File is back at its original location: ready to restore")
        XCTAssertEqual(RecentlyDeletedStatus.pathInUse.message, "Original location is used by another catalogued photo")
    }

    func testTheTrashConfirmationKeepsItsPinnedTextAndAddsTheRecordSentence() {
        let request = TrashModel.Request(kind: .selected, photos: [], scope: "All Photos")
        let text = TrashModel.confirmationMessage(request)
        XCTAssertTrue(text.contains("Nothing is permanently deleted"))
        XCTAssertTrue(text.contains("Put Back"))
        XCTAssertTrue(text.contains("Lightbench keeps a record so you can restore the photo's ratings, keywords, collections and info from Photo ▸ Recently Deleted. The file itself stays in the Finder's Trash."))
    }

    func testTheRecentlyDeletedCodeContainsNoFileOperation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Catalog/DeletedPhoto.swift", "Sources/Catalog/CatalogDatabase+RecentlyDeleted.swift",
                     "Sources/UI/RecentlyDeletedModel.swift", "Sources/UI/RecentlyDeletedSheetView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for forbidden in ["removeItem", "removeItems", "unlink(", "moveItem", "copyItem", "trashItem", "replaceItemAt", "recycle(", "createFile", "linkItem", "write(to", "createDirectory"] {
                XCTAssertFalse(code.contains(forbidden), "\(file) must perform no file operation (\(forbidden)): restore is catalog-only")
            }
        }
    }
}

@MainActor
final class RecentlyDeletedModelTests: XCTestCase {
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var suiteName = ""

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        suiteName = "RecentlyDeletedModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    private func trashOne(_ path: String) async throws {
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: path)])
        let id = try need(try await db.photo(atPath: path)?.id)
        try await catalog.removeTrashedPhotos(ids: [id], paths: [path], trashedURLs: [id: URL(fileURLWithPath: "/Users/x/.Trash/\((path as NSString).lastPathComponent)")], editFiles: [:])
    }

    func testTrashingThroughTheCatalogModelRecordsTheEntryWithItsTrashLocation() async throws {
        try await trashOne("/p/a.jpg")
        let list = try await db.deletedPhotoEntries()
        XCTAssertEqual(list.map(\.originalPath), ["/p/a.jpg"])
        XCTAssertEqual(list.first?.trashedPath, "/Users/x/.Trash/a.jpg")
        XCTAssertEqual(catalog.photoCount, 0)
    }

    func testTheModelListsAndRestoresOnlyWhenTheFileIsBack() async throws {
        try await trashOne("/p/a.jpg")
        let exists = ExistsFlag()
        let model = RecentlyDeletedModel(fileExists: { _ in exists.value })
        await model.load(catalog: catalog)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.status, .mayBeInTrash)
        await model.restore(model.rows[0].entry.id, catalog: catalog)
        XCTAssertEqual(catalog.photoCount, 0, "the file is not back: nothing is restored")
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("Put Back"))
        exists.value = true
        await model.load(catalog: catalog)
        XCTAssertEqual(model.rows.first?.status, .ready)
        await model.restore(model.rows[0].entry.id, catalog: catalog)
        XCTAssertEqual(catalog.photoCount, 1, "the library was re-read after the restore")
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testRemoveFromListAndEmptyListTouchOnlyTheEntries() async throws {
        try await trashOne("/p/a.jpg")
        try await trashOne("/p/b.jpg")
        let model = RecentlyDeletedModel(fileExists: { _ in true })
        await model.load(catalog: catalog)
        await model.forget(model.rows[0].entry.id, catalog: catalog)
        XCTAssertEqual(model.rows.count, 1)
        await model.emptyList(catalog: catalog)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(catalog.photoCount, 0)
    }
}

private final class ExistsFlag: @unchecked Sendable {
    var value = false
}

private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
