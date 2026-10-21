import XCTest
@testable import PhotoApp

/// Virtual-copy POLICIES: scans and XMP act on master rows only (a copy inherits), Rename leaves copies out, creating a copy refuses a
/// missing file, never overwrites another version's edit file, and the catalog model removes/relocates masters and copies consistently.
@MainActor
final class VirtualCopyPolicyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VirtualCopyPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func masterRow(_ path: String, id: Int64 = 1) -> Photo {
        Photo(id: id, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func copyRow(_ path: String, id: Int64 = 2, master: Int64 = 1, key: String = "aaaaaaaa") -> Photo {
        Photo(id: id, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: master, versionKey: key, versionName: "Copy 1")
    }

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // MARK: Scans skip copies

    func testDuplicateScanNeverStatsOrHashesACopy() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let seen = Seen()
        let env = DuplicateScanner.Environment(
            stat: { seen.add($0); return (1, 1) }, hash: { _ in "h" }, featurePrint: { _ in nil })
        let result = try await DuplicateScanner.scan(
            photos: [masterRow("/p/a.jpg"), copyRow("/p/a.jpg")], database: db, environment: env, persist: { _ in })
        XCTAssertEqual(seen.count, 1, "the shared file is read once, for the master only")
        XCTAssertEqual(result.candidates.count, 1)
    }

    func testFaceScanNeverDetectsOnACopy() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let seen = Seen()
        let env = FaceScanner.Environment(stat: { _ in (1, 1) }, detect: { seen.add($0); return [] })
        _ = try await FaceScanner.scan(photos: [copyRow("/p/a.jpg")], database: db, environment: env, persist: { _ in })
        XCTAssertEqual(seen.count, 0)
    }

    func testCameraDataScanSkipsCopies() {
        let wanted = MetadataScanner.photosNeedingScan([masterRow("/p/a.jpg"), copyRow("/p/a.jpg")], cached: [:])
        XCTAssertEqual(wanted.map(\.id), [1])
    }

    func testACopyInheritsItsMastersCameraDataAndFaces() {
        let photos = [masterRow("/p/a.jpg"), copyRow("/p/a.jpg")]
        let map = CatalogModel.inheritingFromMasters([1: "iso 400"], photos: photos)
        XCTAssertEqual(map[2], "iso 400")
        let own = CatalogModel.inheritingFromMasters([1: "master", 2: "own"], photos: photos)
        XCTAssertEqual(own[2], "own", "a copy's own entry wins")
    }

    // MARK: XMP

    func testXMPWriteAndReadActOnMastersOnly() throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        var rated = copyRow(image.path)
        rated.rating = 4 // something to write: an all-default row writes nothing, which would make this test vacuous
        let outcome = XMPModel.writeAll(photos: [rated], allPaths: [image.path], keywords: [:])
        XCTAssertEqual(outcome.written, 0)
        let controlMaster = { () -> Photo in var m = self.masterRow(image.path); m.rating = 4; return m }()
        XCTAssertGreaterThan(XMPModel.writeAll(photos: [controlMaster], allPaths: [image.path], keywords: [:]).written, 0, "control: a rated MASTER does write")
        try? FileManager.default.removeItem(at: XMPSidecarStore.sidecarURL(for: image))
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecarStore.sidecarURL(for: image).path), "a copy never writes the file's .xmp")
        let read = XMPModel.readAll(photos: [copyRow(image.path)], allPaths: [image.path])
        XCTAssertTrue(read.items.isEmpty)
        XCTAssertEqual(read.noXMP, 0)
    }

    // MARK: Rename

    func testRenamePlanLeavesCopiesOut() throws {
        let template = try XCTUnwrap(try? NamingTemplate.compile("renamed-{seq}").get())
        let env = RenameEnvironment(fileExists: { _ in true }, catalogPhotoID: { _ in nil }, openPhotoPath: nil)
        let plan = RenamePlan.make(
            photos: [masterRow("/p/a.jpg"), copyRow("/p/a.jpg")], template: template, sequenceStart: 1, captureDates: [:], environment: env)
        XCTAssertEqual(plan.entries.map(\.photo.id), [1], "a virtual copy shares its master's file and is never planned for a rename")
    }

    // MARK: Creating a copy

    private final class StubAccess: SidecarFolderAccessing {
        let granted: URL?
        private(set) var asked = 0
        init(_ granted: URL?) { self.granted = granted }
        func resolvedURL(for folder: URL) -> URL? { granted }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
            asked += 1
            return granted.map { .granted($0) } ?? .declined
        }
    }

    private func scopedDir() throws -> URL {
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func testCreateVirtualCopyWritesTheEditFileAndTheRowAndLeavesTheImageAlone() async throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("PIXELS".utf8).write(to: image)
        var state = EditState(); state.exposureEV = 1.25
        try SidecarStore.write(state, forPhotoAt: image)
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        await catalog.refresh()
        let source = try unwrapped(try await db.photo(atPath: image.path))

        let model = VirtualCopyModel(folderAccess: StubAccess(try scopedDir()))
        let message = await model.create(from: [source], catalog: catalog)

        XCTAssertTrue(message.hasPrefix("Created 1 virtual copy"), message)
        let copies = try await db.copies(ofMasterID: try XCTUnwrap(source.id))
        XCTAssertEqual(copies.count, 1)
        let key = try XCTUnwrap(copies[0].versionKey)
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image, versionKey: key), .decoded(state))
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "PIXELS", "the image file is untouched")
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image), .decoded(state), "the master's edit file is untouched")
        XCTAssertEqual(catalog.photos.count, 2, "the Library shows the new version")
    }

    func testCreateVirtualCopyRefusesAMissingFileAndCreatesNothing() async throws {
        let image = dir.appendingPathComponent("gone.jpg")
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        let source = try unwrapped(try await db.photo(atPath: image.path))
        let message = await VirtualCopyModel(folderAccess: StubAccess(try scopedDir())).create(from: [source], catalog: catalog)
        XCTAssertTrue(message.contains("missing"), message)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: image), [])
    }

    func testDecliningFolderAccessCreatesNothing() async throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        let source = try unwrapped(try await db.photo(atPath: image.path))
        _ = await VirtualCopyModel(folderAccess: StubAccess(nil)).create(from: [source], catalog: catalog)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: image), [])
    }

    func testAFailedRowInsertRemovesOnlyTheFileJustWritten() async throws {
        // The photo row is gone from the catalog: `createVirtualCopy` throws AFTER the edit file was written.
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: image)
        let other = try file("a.jpg.bbbbbbbb.photoapp.json", "ANOTHER VERSION")
        let db = try CatalogDatabase(inMemory: true)
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        let ghost = masterRow(image.path, id: 777) // not in the catalog
        let message = await VirtualCopyModel(folderAccess: StubAccess(try scopedDir())).create(from: [ghost], catalog: catalog)
        XCTAssertTrue(message.contains("couldn't copy"), message)
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: image), ["bbbbbbbb"], "the half-made version's file is removed; another version's file is untouched")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "ANOTHER VERSION")
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image), .decoded(state))
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Catalog model: remove / targets

    func testRemovingAMasterFromTheLibraryAlsoDropsItsCopiesFromTheList() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg"), URL(fileURLWithPath: "/p/b.jpg")])
        let a = try unwrapped(try await db.photo(atPath: "/p/a.jpg"))
        _ = try await db.createVirtualCopy(of: a, versionKey: "aaaaaaaa")
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        await catalog.refresh()
        XCTAssertEqual(catalog.photos.count, 3)
        catalog.removePhoto(a)
        XCTAssertEqual(catalog.photos.map(\.filename), ["b.jpg"])
        XCTAssertEqual(catalog.photoCount, 1)
    }

    func testVirtualCopyTargetsInTheEditorIsTheOpenVersionByEditKey() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let a = try unwrapped(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: a, versionKey: "aaaaaaaa")
        let catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: "VirtualCopyPolicyTests-\(UUID().uuidString)") ?? .standard)
        await catalog.refresh()
        XCTAssertEqual(catalog.virtualCopyTargets(showLibrary: false, openEditKey: copy.editKey).map(\.id), [copy.id])
        XCTAssertEqual(catalog.virtualCopyTargets(showLibrary: false, openEditKey: a.editKey).map(\.id), [a.id])
        XCTAssertTrue(catalog.virtualCopyTargets(showLibrary: false, openEditKey: nil).isEmpty)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var count: Int { lock.withLock { items.count } }
    func add(_ item: String) { lock.withLock { items.append(item) } }
}
