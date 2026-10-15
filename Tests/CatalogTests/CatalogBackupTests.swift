import CryptoKit
import GRDB
import XCTest
@testable import PhotoApp

final class CatalogBackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A real on-disk catalog with `count` photos.
    private func makeCatalog(at file: URL, photos count: Int) async throws {
        let db = try CatalogDatabase(path: file.path)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/bk-\(file.lastPathComponent)-\($0).jpg") })
    }

    private func photoCount(at file: URL) throws -> Int {
        try CatalogDatabase.inspectCatalogFile(at: file).photoCount
    }

    private func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private func readOnlyQueue(_ file: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: file.path, configuration: configuration)
    }

    /// Runs SQL on a file synchronously (the async `write` overload would otherwise be picked inside async tests).
    private func run(_ sql: String, on file: URL) throws {
        let queue = try DatabaseQueue(path: file.path)
        try queue.write { try $0.execute(sql: sql) }
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Leaves `folder/catalog.sqlite` + `catalog.sqlite-journal` in the state a crash mid-write produces (a HOT rollback journal: with synchronous OFF SQLite
    /// writes the journal magic immediately, which is what makes SQLite treat the journal as hot). Returns the committed photo count.
    /// Synchronous on purpose (GRDB's async overloads would be picked inside an async test).
    private func crash(source: URL, into folder: URL) throws {
        let queue = try DatabaseQueue(path: source.path)
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA synchronous = OFF") }
        struct Stop: Error {}
        do {
            try queue.inTransaction { db in
                try db.execute(sql: "UPDATE photo SET path = path || hex(randomblob(4000))")
                for suffix in ["", "-journal"] {
                    try FileManager.default.copyItem(atPath: source.path + suffix, toPath: folder.appendingPathComponent("catalog.sqlite" + suffix).path)
                }
                throw Stop()
            }
        } catch is Stop {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("catalog.sqlite-journal").path), "premise: a hot journal")
        XCTAssertThrowsError(try readOnlyQueue(folder.appendingPathComponent("catalog.sqlite")).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo") },
                             "premise: a read-only open cannot roll the journal back")
    }

    private func makeCrashedCatalog(in folder: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = url("crash-source.sqlite")
        try await makeCatalog(at: source, photos: 200)
        try crash(source: source, into: folder)
        return 200
    }

    // MARK: snapshot / round trip

    func testASnapshotIsAFullWorkingCatalogWithEverythingInIt() async throws {
        let live = url("live.sqlite")
        let db = try CatalogDatabase(path: live.path)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg"), URL(fileURLWithPath: "/tmp/c.jpg")])
        let ids = try await db.allPhotos().compactMap(\.id)
        try await db.setRating(4, for: ids[0])
        try await db.addKeywords(["Sky", "Beach"], to: [ids[0]])

        let backup = url("backup.sqlite")
        let info = try await db.backUp(to: backup)
        XCTAssertEqual(info, CatalogFileInfo(photoCount: 3, needsMigration: false))

        let reopened = try CatalogDatabase(path: backup.path)
        let photos = try await reopened.allPhotos()
        XCTAssertEqual(photos.count, 3)
        XCTAssertEqual(photos.first { $0.id == ids[0] }?.rating, 4)
        let keywords = try await reopened.allKeywords().map(\.name)
        XCTAssertEqual(Set(keywords), ["Sky", "Beach"])
    }

    func testTheLiveCatalogKeepsWorkingAndIsUnchangedByABackup() async throws {
        let live = url("live.sqlite")
        try await makeCatalog(at: live, photos: 2)
        let db = try CatalogDatabase(path: live.path)
        _ = try await db.backUp(to: url("b.sqlite"))
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/more.jpg")])
        let count = try await db.allPhotos().count
        XCTAssertEqual(count, 3, "still writable after a backup")
        XCTAssertEqual(try photoCount(at: url("b.sqlite")), 2, "and the backup is a snapshot, not a mirror")
    }

    func testBackingUpOverAnExistingFileReplacesIt() async throws {
        let first = url("one.sqlite"), second = url("two.sqlite")
        try await makeCatalog(at: first, photos: 1)
        try await makeCatalog(at: second, photos: 4)
        let destination = url("dest.sqlite")
        _ = try await CatalogDatabase(path: first.path).backUp(to: destination)
        _ = try await CatalogDatabase(path: second.path).backUp(to: destination)
        XCTAssertEqual(try photoCount(at: destination), 4)
    }

    func testAFailedSnapshotLeavesNoScratchFileAndNoDestination() async throws {
        let live = url("live.sqlite")
        try await makeCatalog(at: live, photos: 1)
        let scratch = url("scratch")
        let impossible = url("missing-folder/inside/backup.sqlite")   // its folder does not exist, so publishing fails
        XCTAssertThrowsError(try CatalogDatabase.snapshot(from: try readOnlyQueue(live), to: impossible, scratch: scratch))
        XCTAssertEqual(names(scratch), [], "the scratch copy is removed on failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: impossible.path))
        // ...and on success the scratch folder is clean too.
        _ = try CatalogDatabase.snapshot(from: try readOnlyQueue(live), to: url("ok.sqlite"), scratch: scratch)
        XCTAssertEqual(names(scratch), [])
    }

    // MARK: inspect

    func testInspectionAcceptsHealthyOldAndRejectsGarbageForeignAndNewer() async throws {
        let healthy = url("healthy.sqlite")
        try await makeCatalog(at: healthy, photos: 2)
        XCTAssertEqual(try CatalogDatabase.inspectCatalogFile(at: healthy), CatalogFileInfo(photoCount: 2, needsMigration: false))

        // An OLDER catalog (only the first migration applied) is acceptable: it migrates when opened.
        let old = url("old.sqlite")
        do {
            let queue = try DatabaseQueue(path: old.path)
            var migrator = DatabaseMigrator()
            Migration001Initial.register(in: &migrator)
            try migrator.migrate(queue)
        }
        XCTAssertEqual(try CatalogDatabase.inspectCatalogFile(at: old).needsMigration, true)

        let garbage = url("garbage.sqlite")
        try Data("this is not a database".utf8).write(to: garbage)
        XCTAssertThrowsError(try CatalogDatabase.inspectCatalogFile(at: garbage))

        let foreign = url("foreign.sqlite")
        try run("CREATE TABLE other(x INTEGER)", on: foreign)
        XCTAssertThrowsError(try CatalogDatabase.inspectCatalogFile(at: foreign)) {
            XCTAssertEqual(($0 as? CatalogDatabaseError)?.message, "That file isn't a Lightbench catalog.")
        }

        let newer = url("newer.sqlite")
        try await makeCatalog(at: newer, photos: 1)
        try run("INSERT INTO grdb_migrations(identifier) VALUES ('099_from_the_future')", on: newer)
        XCTAssertThrowsError(try CatalogDatabase.inspectCatalogFile(at: newer)) {
            XCTAssertEqual(($0 as? CatalogDatabaseError)?.message, CatalogDatabase.newerVersionMessage)
        }
    }

    func testACatalogFromANewerBuildIsRefusedAndLeftByteIdentical() async throws {
        let file = url("future.sqlite")
        try await makeCatalog(at: file, photos: 2)
        try run("INSERT INTO grdb_migrations(identifier) VALUES ('099_from_the_future')", on: file)
        let before = try digest(file)
        XCTAssertThrowsError(try CatalogDatabase(path: file.path)) {
            XCTAssertEqual(($0 as? CatalogDatabaseError)?.message, CatalogDatabase.newerVersionMessage)
        }
        XCTAssertEqual(try digest(file), before, "refusing must not write a single byte")
    }

    // MARK: names + pruning

    func testBackupNamesRoundTripAndForeignNamesAreIgnored() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for kind in CatalogBackupKind.allCases {
            let name = CatalogDatabase.backupFileName(kind, at: date)
            XCTAssertEqual(CatalogDatabase.parseBackupFileName(name)?.kind, kind, name)
        }
        for bad in ["catalog.sqlite", "catalog-notadate.sqlite", "catalog-20261015-120000.sqlite.partial", "notes.txt", "catalog-20261015-120000-weird.sqlite"] {
            XCTAssertNil(CatalogDatabase.parseBackupFileName(bad), bad)
        }
    }

    func testPruningKeepsTheNewestOfEachKindAndNeverTouchesOtherFiles() throws {
        let folder = url("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamps = ["20261001-100000", "20261002-100000", "20261003-100000", "20261004-100000"]
        var created: [String] = []
        for kind in CatalogBackupKind.allCases {
            for stamp in stamps {
                let name = "catalog-\(stamp)\(kind.rawValue).sqlite"
                try Data([1]).write(to: folder.appendingPathComponent(name)); created.append(name)
            }
        }
        try Data([1]).write(to: folder.appendingPathComponent("my-notes.txt"))
        try Data([1]).write(to: folder.appendingPathComponent("catalog-keepme.sqlite"))

        let removed = CatalogDatabase.pruneBackups(in: folder, keepNewest: 2)
        XCTAssertEqual(removed.count, CatalogBackupKind.allCases.count * 2)
        for kind in CatalogBackupKind.allCases {
            XCTAssertTrue(names(folder).contains("catalog-20261004-100000\(kind.rawValue).sqlite"), "newest \(kind) survives")
            XCTAssertTrue(names(folder).contains("catalog-20261003-100000\(kind.rawValue).sqlite"))
            XCTAssertFalse(names(folder).contains("catalog-20261001-100000\(kind.rawValue).sqlite"))
        }
        XCTAssertTrue(names(folder).contains("my-notes.txt"))
        XCTAssertTrue(names(folder).contains("catalog-keepme.sqlite"))
        // Asking to keep zero still keeps one: pruning can never empty the folder.
        CatalogDatabase.pruneBackups(in: folder, keepNewest: 0)
        XCTAssertTrue(names(folder).contains("catalog-20261004-100000.sqlite"))
    }

    // MARK: launch backup

    func testLaunchBackupDoesNothingWithoutACatalogAndNeverThrowsOnAGarbageOne() throws {
        CatalogDatabase.launchBackup(catalogURL: url("catalog.sqlite"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogDatabase.backupsDirectory(in: dir).path))
        try Data("not sqlite".utf8).write(to: url("catalog.sqlite"))
        CatalogDatabase.launchBackup(catalogURL: url("catalog.sqlite"))
        XCTAssertEqual(names(CatalogDatabase.backupsDirectory(in: dir)), [], "a damaged catalog is not copied")
    }

    func testLaunchBackupIsDailyAndLeavesTheCatalogUntouched() async throws {
        let catalog = url("catalog.sqlite")
        try await makeCatalog(at: catalog, photos: 2)
        let before = try digest(catalog)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = CatalogDatabase.backupsDirectory(in: dir)

        CatalogDatabase.launchBackup(catalogURL: catalog, now: now)
        XCTAssertEqual(names(folder).count, 1)
        XCTAssertEqual(CatalogDatabase.parseBackupFileName(names(folder)[0])?.kind, .automatic)
        XCTAssertEqual(try photoCount(at: folder.appendingPathComponent(names(folder)[0])), 2)

        CatalogDatabase.launchBackup(catalogURL: catalog, now: now.addingTimeInterval(3600))
        XCTAssertEqual(names(folder).count, 1, "an hour later: no new backup")
        CatalogDatabase.launchBackup(catalogURL: catalog, now: now.addingTimeInterval(21 * 3600))
        XCTAssertEqual(names(folder).count, 2, "21 hours later: a new one")
        XCTAssertEqual(try digest(catalog), before, "taking backups never modifies the catalog")
    }

    func testLaunchBackupAlwaysSnapshotsBeforePendingMigrations() async throws {
        let catalog = url("catalog.sqlite")
        do {
            let queue = try DatabaseQueue(path: catalog.path)
            var migrator = DatabaseMigrator()
            Migration001Initial.register(in: &migrator)
            try migrator.migrate(queue)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = CatalogDatabase.backupsDirectory(in: dir)
        // Even with a recent automatic backup already there, a pending migration forces a pre-migration copy.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent(CatalogDatabase.backupFileName(.automatic, at: now.addingTimeInterval(-60))))
        CatalogDatabase.launchBackup(catalogURL: catalog, now: now)
        XCTAssertTrue(names(folder).contains(CatalogDatabase.backupFileName(.preMigration, at: now)))
    }

    func testTheTestHostNeverTakesBackupsOrAppliesRestoresInTheRealCatalogFolder() throws {
        // `CatalogDatabase()` under XCTest uses a throwaway temp directory and skips launch backup/restore entirely.
        XCTAssertTrue(CatalogDatabase.isRunningUnderXCTest)
        let directory = try CatalogDatabase.defaultCatalogDirectory()
        XCTAssertTrue(directory.path.contains("PhotoApp-XCTest-catalog-"))
        // Make the guard the ONLY thing standing in the way: a catalog already exists (so launchBackup would otherwise snapshot it).
        _ = try CatalogDatabase(path: directory.appendingPathComponent("catalog.sqlite").path)
        _ = try CatalogDatabase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogDatabase.backupsDirectory(in: directory).path))
    }

    func testLaunchBackupAfterACrashRollsTheJournalBackFirstAndBacksUpTheCommittedData() async throws {
        let folder = url("crashed")
        let committed = try await makeCrashedCatalog(in: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        CatalogDatabase.launchBackup(catalogURL: folder.appendingPathComponent("catalog.sqlite"), now: now)
        let backup = CatalogDatabase.backupsDirectory(in: folder).appendingPathComponent(CatalogDatabase.backupFileName(.automatic, at: now))
        XCTAssertEqual(try photoCount(at: backup), committed, "the backup holds the last committed state, not the half-written pages")
    }

    func testRestoreOverACrashedCatalogKeepsItAsABeforeRestoreBackupNotAsDamaged() async throws {
        let folder = url("crashed-restore")
        let committed = try await makeCrashedCatalog(in: folder)
        let good = url("good.sqlite")
        try await makeCatalog(at: good, photos: 3)
        try CatalogDatabase.stageRestore(from: good, into: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CatalogDatabase.applyPendingRestore(in: folder, now: now), .restored(photoCount: 3))
        let backups = CatalogDatabase.backupsDirectory(in: folder)
        XCTAssertEqual(try photoCount(at: backups.appendingPathComponent(CatalogDatabase.backupFileName(.beforeRestore, at: now))), committed)
        XCTAssertFalse(names(backups).contains(CatalogDatabase.backupFileName(.damaged, at: now)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("catalog.sqlite-journal").path), "no stale journal left to replay")
    }

    func testAStaleJournalNextToTheOldCatalogIsNeverReplayedOntoTheRestoredOne() async throws {
        let live = url("catalog.sqlite"), good = url("good.sqlite")
        try Data("not a database".utf8).write(to: live)
        try Data("stale journal bytes".utf8).write(to: url("catalog.sqlite-journal"))
        try await makeCatalog(at: good, photos: 2)
        try CatalogDatabase.stageRestore(from: good, into: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CatalogDatabase.applyPendingRestore(in: dir, now: now), .restored(photoCount: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("catalog.sqlite-journal").path))
    }

    private struct SwapFailure: Error {}

    func testAFailedInstallPutsTheSetAsideCatalogBackAndSaysItWasNotChanged() async throws {
        let live = url("catalog.sqlite")
        try Data("broken".utf8).write(to: live)
        try await makeCatalog(at: url("good.sqlite"), photos: 1)
        try CatalogDatabase.stageRestore(from: url("good.sqlite"), into: dir)
        var sawCatalogGone = false
        let report = CatalogDatabase.applyPendingRestore(in: dir) { _, catalog in
            // By now the broken catalog has been moved to -damaged: the swap itself then fails.
            sawCatalogGone = !FileManager.default.fileExists(atPath: catalog.path)
            throw SwapFailure()
        }
        XCTAssertTrue(sawCatalogGone, "premise: the catalog was already set aside when the install failed")
        guard case .failed(let reason)? = report else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("current catalog was not changed"))
        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "broken", "put back where the next launch looks for it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(CatalogDatabase.pendingRestoreFileName).path), "the stage is discarded")
    }

    func testAFailedInstallThatCannotPutTheCatalogBackPointsToTheBackupsFolder() async throws {
        try Data("broken".utf8).write(to: url("catalog.sqlite"))
        try await makeCatalog(at: url("good.sqlite"), photos: 1)
        try CatalogDatabase.stageRestore(from: url("good.sqlite"), into: dir)
        let backups = CatalogDatabase.backupsDirectory(in: dir)
        let report = CatalogDatabase.applyPendingRestore(in: dir) { _, _ in
            // Make the move-back impossible too: remove the set-aside file, then fail.
            for name in self.names(backups) { try? FileManager.default.removeItem(at: backups.appendingPathComponent(name)) }
            throw SwapFailure()
        }
        guard case .failed(let reason)? = report else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("Backups folder"))
        XCTAssertFalse(reason.contains("was not changed"))
    }

    func testAFutureDatedBackupDoesNotSuppressTheDailyBackup() async throws {
        let catalog = url("catalog.sqlite")
        try await makeCatalog(at: catalog, photos: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = CatalogDatabase.backupsDirectory(in: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let future = CatalogDatabase.backupFileName(.automatic, at: now.addingTimeInterval(30 * 86_400))
        try Data([1]).write(to: folder.appendingPathComponent(future))
        CatalogDatabase.launchBackup(catalogURL: catalog, now: now)
        XCTAssertTrue(names(folder).contains(CatalogDatabase.backupFileName(.automatic, at: now)))
    }

    func testWhenTheAtomicSwapIsUnavailableTheOldBackupIsReplacedOnlyAfterTheNewCopyIsComplete() async throws {
        let live = url("live.sqlite"), destination = url("keep.sqlite"), scratch = url("scratch")
        try await makeCatalog(at: live, photos: 2)
        try await makeCatalog(at: destination, photos: 7)
        let queue = try readOnlyQueue(live)
        try CatalogDatabase.snapshot(from: queue, to: destination, scratch: scratch) { _, _ in throw SwapFailure() }
        XCTAssertEqual(try photoCount(at: destination), 2, "the fallback copy replaced it")
        XCTAssertTrue(names(scratch).isEmpty, "nothing left in scratch")
    }

    func testWhenTheSwapAndTheCopyBothFailTheOldBackupIsRestoredByteForByte() async throws {
        let live = url("live.sqlite"), destination = url("keep.sqlite"), scratch = url("scratch")
        try await makeCatalog(at: live, photos: 2)
        try await makeCatalog(at: destination, photos: 7)
        let before = try digest(destination)
        let queue = try readOnlyQueue(live)
        // The swap fails (so the old file is moved aside) and deletes the partial copy, so the following copy fails too.
        XCTAssertThrowsError(try CatalogDatabase.snapshot(from: queue, to: destination, scratch: scratch) { _, partial in
            try FileManager.default.removeItem(at: partial)
            throw SwapFailure()
        })
        XCTAssertEqual(try digest(destination), before)
    }

    // MARK: restore

    func testRestoreStagesThenSwapsAtTheNextLaunchKeepingTheOldCatalog() async throws {
        let live = url("catalog.sqlite"), source = url("old-backup.sqlite")
        try await makeCatalog(at: live, photos: 2)
        try await makeCatalog(at: source, photos: 5)

        let info = try CatalogDatabase.stageRestore(from: source, into: dir)
        XCTAssertEqual(info.photoCount, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url(CatalogDatabase.pendingRestoreFileName).path))
        XCTAssertEqual(try photoCount(at: live), 2, "staging alone changes nothing")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CatalogDatabase.applyPendingRestore(in: dir, now: now), .restored(photoCount: 5))
        XCTAssertEqual(try photoCount(at: live), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(CatalogDatabase.pendingRestoreFileName).path))
        let kept = CatalogDatabase.backupsDirectory(in: dir).appendingPathComponent(CatalogDatabase.backupFileName(.beforeRestore, at: now))
        XCTAssertEqual(try photoCount(at: kept), 2, "the catalog that was replaced is kept")
        XCTAssertNil(CatalogDatabase.applyPendingRestore(in: dir), "nothing staged: nothing to do")
    }

    func testRestoreRejectsGarbageAndNewerBackupsBeforeStagingAnything() async throws {
        let garbage = url("garbage.sqlite")
        try Data("nope".utf8).write(to: garbage)
        XCTAssertThrowsError(try CatalogDatabase.stageRestore(from: garbage, into: dir))
        let newer = url("newer.sqlite")
        try await makeCatalog(at: newer, photos: 1)
        try run("INSERT INTO grdb_migrations(identifier) VALUES ('099_x')", on: newer)
        XCTAssertThrowsError(try CatalogDatabase.stageRestore(from: newer, into: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(CatalogDatabase.pendingRestoreFileName).path))
    }

    func testACorruptStagedFileIsDiscardedAndTheCurrentCatalogIsKept() async throws {
        let live = url("catalog.sqlite")
        try await makeCatalog(at: live, photos: 3)
        let before = try digest(live)
        try Data("corrupted in transit".utf8).write(to: url(CatalogDatabase.pendingRestoreFileName))
        guard case .failed? = CatalogDatabase.applyPendingRestore(in: dir) else { return XCTFail("should have failed") }
        XCTAssertEqual(try digest(live), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(CatalogDatabase.pendingRestoreFileName).path))
    }

    func testAnUnreadableCurrentCatalogIsSetAsideWholeNotLost() async throws {
        let source = url("good.sqlite")
        try await makeCatalog(at: source, photos: 4)
        try Data("this catalog is broken".utf8).write(to: url("catalog.sqlite"))
        try CatalogDatabase.stageRestore(from: source, into: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CatalogDatabase.applyPendingRestore(in: dir, now: now), .restored(photoCount: 4))
        XCTAssertEqual(try photoCount(at: url("catalog.sqlite")), 4)
        let damaged = CatalogDatabase.backupsDirectory(in: dir).appendingPathComponent(CatalogDatabase.backupFileName(.damaged, at: now))
        XCTAssertEqual(try String(contentsOf: damaged, encoding: .utf8), "this catalog is broken", "the broken file was kept")
    }

    func testRestoringIntoAFolderWithNoCatalogJustInstallsIt() async throws {
        let source = url("good.sqlite")
        try await makeCatalog(at: source, photos: 2)
        try CatalogDatabase.stageRestore(from: source, into: dir)
        XCTAssertEqual(CatalogDatabase.applyPendingRestore(in: dir), .restored(photoCount: 2))
        XCTAssertEqual(try photoCount(at: url("catalog.sqlite")), 2)
    }

    func testReportMessagesAreHumanReadable() {
        XCTAssertTrue(CatalogRestoreReport.restored(photoCount: 1).message.contains("1 photo)"))
        XCTAssertTrue(CatalogRestoreReport.restored(photoCount: 3).message.contains("3 photos"))
        XCTAssertTrue(CatalogRestoreReport.failed("Bad file.").message.contains("Bad file."))
    }
}
