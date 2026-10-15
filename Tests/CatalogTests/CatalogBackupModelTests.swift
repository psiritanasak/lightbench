import GRDB
import XCTest
@testable import PhotoApp

@MainActor
final class CatalogBackupModelTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var model: CatalogBackupModel!
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogBackupModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<3).map { URL(fileURLWithPath: "/tmp/bm-\($0).jpg") })
        suiteName = "CatalogBackupModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        await catalog.refresh()
        model = catalog.catalogBackup
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func waitIdle() async {
        for _ in 0..<600 where model.isWorking { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isWorking)
    }

    /// A healthy backup file with `count` photos, made through the real engine.
    private func makeBackupFile(photos count: Int, named name: String) async throws -> URL {
        let source = try CatalogDatabase(inMemory: true)
        _ = try await source.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/src-\(name)-\($0).jpg") })
        let destination = url(name)
        _ = try await source.backUp(to: destination)
        return destination
    }

    /// Synchronous on purpose (inside an async test the `write` overload would be the async one).
    private nonisolated static func insertFutureMigration(into file: URL) throws {
        let queue = try DatabaseQueue(path: file.path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('099_future')") }
    }

    // MARK: Back up

    func testBackUpWritesASnapshotAndSaysWhatIsAndIsNotInIt() async throws {
        let destination = url("my-backup.sqlite")
        model.seams.chooseDestination = { _ in destination }
        model.request(.backUp, catalog: catalog)
        XCTAssertTrue(catalog.backupBusy, "busy while the snapshot is written")
        await waitIdle()
        XCTAssertFalse(catalog.backupBusy)
        XCTAssertEqual(try CatalogDatabase.inspectCatalogFile(at: destination).photoCount, 3)
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertTrue(message.contains("3 photos"))
        XCTAssertTrue(message.contains("my-backup.sqlite"))
        XCTAssertTrue(message.contains("edits are stored next to your photos"), "the limits are stated up front")
    }

    func testCancellingTheSavePanelDoesNothing() async throws {
        model.seams.chooseDestination = { _ in nil }
        model.request(.backUp, catalog: catalog)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(catalog.backupBusy)
        XCTAssertNil(model.statusMessage)
    }

    func testTheSuggestedNameUsesTheProductNameAndADate() {
        let name = CatalogBackupModel.suggestedBackupName(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(name.hasPrefix("\(AppInfo.name) Catalog 20"), name)
        XCTAssertTrue(name.hasSuffix(".sqlite"))
    }

    func testABackupFailureIsReportedNotSwallowed() async throws {
        model.seams.chooseDestination = { [dir] _ in dir!.appendingPathComponent("no-such-folder/inside/x.sqlite") }
        model.request(.backUp, catalog: catalog)
        await waitIdle()
        XCTAssertTrue(model.statusMessage?.hasPrefix("Couldn't back up the catalog") ?? false, model.statusMessage ?? "nil")
        XCTAssertFalse(catalog.backupBusy)
    }

    // MARK: Restore

    func testChoosingAGoodBackupAsksForConfirmationAndStagesNothingYet() async throws {
        let backup = try await makeBackupFile(photos: 7, named: "good.sqlite")
        let staging = url("catalog-dir")
        model.seams.chooseBackupFile = { backup }
        model.seams.catalogDirectory = { staging }
        model.request(.restore, catalog: catalog)
        await waitIdle()
        let request = try XCTUnwrap(model.pendingRestore)
        XCTAssertEqual(request.info.photoCount, 7)
        XCTAssertTrue(catalog.backupBusy, "a pending confirmation blocks other tools")
        XCTAssertTrue(catalog.toolSheetIsBusy, "and batch rename")
        XCTAssertTrue(RenameBusyState(isBackupBusy: true).reason != nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(CatalogDatabase.pendingRestoreFileName).path))
        let text = CatalogBackupModel.restoreConfirmationMessage(request)
        XCTAssertTrue(text.contains("7 photos") && text.contains("next time"))

        model.cancelRestore()
        XCTAssertFalse(catalog.backupBusy)
    }

    func testConfirmingStagesTheRestoreAndAsksToRestart() async throws {
        let backup = try await makeBackupFile(photos: 5, named: "good.sqlite")
        let staging = url("catalog-dir")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        model.seams.chooseBackupFile = { backup }
        model.seams.catalogDirectory = { staging }
        model.request(.restore, catalog: catalog)
        await waitIdle()
        model.confirmRestore(try XCTUnwrap(model.pendingRestore))
        XCTAssertNil(model.pendingRestore)
        await waitIdle()
        let staged = staging.appendingPathComponent(CatalogDatabase.pendingRestoreFileName)
        XCTAssertEqual(try CatalogDatabase.inspectCatalogFile(at: staged).photoCount, 5)
        XCTAssertTrue(model.statusMessage?.contains("Quit and reopen") ?? false)
        let live = try await db.allPhotos().count
        XCTAssertEqual(live, 3, "the running catalog is not touched")
        XCTAssertFalse(catalog.backupBusy)
    }

    func testGarbageAndNewerBackupsAreRefusedWithAReason() async throws {
        let garbage = url("garbage.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        model.seams.chooseBackupFile = { garbage }
        model.request(.restore, catalog: catalog)
        await waitIdle()
        XCTAssertNil(model.pendingRestore)
        XCTAssertTrue(model.statusMessage?.hasPrefix("That backup can't be used") ?? false, model.statusMessage ?? "nil")

        let newer = try await makeBackupFile(photos: 1, named: "newer.sqlite")
        try Self.insertFutureMigration(into: newer)
        model.statusMessage = nil
        model.seams.chooseBackupFile = { newer }
        model.request(.restore, catalog: catalog)
        await waitIdle()
        XCTAssertNil(model.pendingRestore)
        XCTAssertTrue(model.statusMessage?.contains("newer version") ?? false, model.statusMessage ?? "nil")
    }

    func testCancellingTheOpenPanelDoesNothing() {
        model.seams.chooseBackupFile = { nil }
        model.request(.restore, catalog: catalog)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.pendingRestore)
    }

    func testARequestWhileBusyIsIgnored() async throws {
        let backup = try await makeBackupFile(photos: 2, named: "good.sqlite")
        model.seams.chooseBackupFile = { backup }
        model.request(.restore, catalog: catalog)
        await waitIdle()
        var panelOpened = false
        model.seams.chooseDestination = { _ in panelOpened = true; return nil }
        model.request(.backUp, catalog: catalog)   // a restore confirmation is up
        XCTAssertFalse(panelOpened)
    }

    // MARK: Wiring

    func testTheMenuTheDialogAndTheBusyFlagsAreWiredIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Back Up Catalog…\") { catalog.backupRequested = .backUp }"))
        XCTAssertTrue(app.contains("Button(\"Restore Catalog from Backup…\") { catalog.backupRequested = .restore }"))
        XCTAssertTrue(try source("Sources/UI/DuplicatesSheetView.swift").contains("CatalogBackupDialogModifier("))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("isBackupBusy: catalog.backupBusy"))
        let catalogModel = try source("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(catalogModel.contains("CatalogRestoreReportStore.shared.take()"), "a restore result is shown after launch")
        XCTAssertTrue(catalogModel.contains("Couldn't open the photo catalog: "), "a refused or damaged catalog is announced at launch")
        let database = try source("Sources/Catalog/CatalogDatabase.swift")
        XCTAssertTrue(database.contains("if !Self.isRunningUnderXCTest {"), "launch backup/restore never run in the test host")
        XCTAssertTrue(database.contains("Self.applyPendingRestore(in: supportDir)"))
        XCTAssertTrue(database.contains("Self.launchBackup(catalogURL: dbURL)"))
        XCTAssertLessThan(try XCTUnwrap(database.range(of: "Self.launchBackup")).lowerBound, try XCTUnwrap(database.range(of: "try self.init(path: dbURL.path)")).lowerBound,
                          "the backup is taken BEFORE the catalog is opened and migrated")
    }
}
