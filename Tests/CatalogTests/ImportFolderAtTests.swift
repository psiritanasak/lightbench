import XCTest
@testable import PhotoApp

@MainActor
final class ImportFolderAtTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportFolderAtTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "ImportFolderAtTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func photos(in relative: String, _ names: [String]) throws -> URL {
        let folder = dir.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func waitForImport() async throws {
        for _ in 0..<2000 where catalog.isImporting || catalog.importStatusMessage == nil { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testImportFolderAtImportsThePhotosOfAFolderWithoutAPanel() async throws {
        let folder = try photos(in: "shoot", ["a.jpg", "b.jpg"])
        catalog.importFolder(at: folder)
        try await waitForImport()
        let count = try await db.allPhotos().count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(catalog.isImporting)
        XCTAssertNotNil(catalog.importStatusMessage)
    }

    func testImportFolderTreeAtMirrorsSubfolders() async throws {
        _ = try photos(in: "trip/day1", ["a.jpg"])
        let root = try photos(in: "trip", ["top.jpg"])
        catalog.importFolderTree(at: root)
        try await waitForImport()
        let photoCount = try await db.allPhotos().count
        XCTAssertEqual(photoCount, 2)
        let collectionCount = try await db.allCollections().count
        XCTAssertEqual(collectionCount, 2, "one collection per folder")
    }

    func testSeveralDroppedFoldersImportInTurnWithOneCombinedMessage() async throws {
        let one = try photos(in: "one", ["a.jpg"]), two = try photos(in: "two", ["b.jpg", "c.jpg"])
        catalog.importFolders([.init(url: one, asTree: false), .init(url: two, asTree: false)])
        try await waitForImport()
        let count = try await db.allPhotos().count
        XCTAssertEqual(count, 3)
        let message = try XCTUnwrap(catalog.importStatusMessage)
        XCTAssertTrue(message.contains("one:") && message.contains("two:"), "each folder is named when there are several: \(message)")
    }

    func testAnEmptyDropDoesNothing() {
        catalog.importFolders([])
        XCTAssertFalse(catalog.isImporting)
        XCTAssertNil(catalog.importStatusMessage)
    }

    func testAnImportIsRefusedWhileARenameRuns() async throws {
        let folder = try photos(in: "blocked", ["a.jpg"])
        catalog.isRenameInProgress = true
        catalog.importFolder(at: folder)
        XCTAssertEqual(catalog.importStatusMessage, CatalogModel.renameInProgressMessage)
        XCTAssertFalse(catalog.isImporting)
        let count = try await db.allPhotos().count
        XCTAssertEqual(count, 0)
    }

    func testBeforeTheCatalogOpensAnImportSaysSoInsteadOfDoingNothing() {
        // The background open cannot finish before this synchronous code yields the main actor, so the database is still nil here.
        let model = CatalogModel(defaults: UserDefaults(suiteName: suiteName)!)
        model.importFolder(at: dir)
        XCTAssertNotNil(model.importStatusMessage)
        XCTAssertFalse(model.isImporting)
    }

    func testAnOpenCatalogIsSettledAndAStillOpeningOneIsNot() async throws {
        XCTAssertTrue(catalog.openSettled, "the test-seam init takes an already-open catalog")
        let model = CatalogModel(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertFalse(model.openSettled, "the background open cannot finish before this code yields the main actor")
        for _ in 0..<2000 where !model.openSettled { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.openSettled)
    }

    func testFinderOpensArrivingBeforeTheCatalogIsOpenWaitInsteadOfBeingRefused() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/UI/DropAndOpenModifier.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("guard catalog.openSettled else { waitingForCatalog.append(contentsOf: urls); return }"))
        XCTAssertTrue(source.contains(".onChange(of: catalog.openSettled)"), "the waiting opens are handled when the catalog settles")
    }

    func testAReadableFolderWithoutAScopedGrantImportsWithoutAFalseAccessWarning() async throws {
        let folder = try photos(in: "plain", ["a.jpg"])
        catalog.importFolder(at: folder) // a plain URL: startAccessingSecurityScopedResource() is false, yet the folder reads fine
        try await waitForImport()
        XCTAssertFalse(try XCTUnwrap(catalog.importStatusMessage).contains("Couldn't get access"))
    }

    func testAFolderTheSandboxDeniesStillGetsTheAccessWarning() async throws {
        let folder = try photos(in: "denied", ["a.jpg"])
        catalog.readabilityProbe = { _ in .sandboxDenied }
        catalog.importFolder(at: folder)
        try await waitForImport()
        XCTAssertTrue(try XCTUnwrap(catalog.importStatusMessage).contains("Couldn't get access"))
    }
}
