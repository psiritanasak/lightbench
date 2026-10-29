import CoreImage
import GRDB
import XCTest
@testable import PhotoApp

/// Second round for virtual copies: neighbour navigation by edit key, Trash / Remove wording from the database's copy counts, migration
/// counter and key constraint, key retry, live-state copies, merge input, and export of a copy.
@MainActor
final class VirtualCopyReviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VirtualCopyReviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func row(_ path: String, id: Int64, name: String = "a.jpg") -> Photo {
        Photo(id: id, path: path, filename: name, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func copyRow(_ path: String, id: Int64, master: Int64, key: String, name: String = "Copy 1") -> Photo {
        Photo(id: id, path: path, filename: "a.jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: master, versionKey: key, versionName: name)
    }

    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: "VirtualCopyReviewTests-\(UUID().uuidString)") ?? .standard }

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // MARK: 1. Navigation (the menu path)

    func testNeighboursOfAnOpenCopyAreItsOwnPositionNotTheMasters() {
        let before = row("/p/0.jpg", id: 9, name: "0.jpg")
        let master = row("/p/a.jpg", id: 1)
        let copy = copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa")
        let after = row("/p/z.jpg", id: 8, name: "z.jpg")
        let grid = [before, master, copy, after]
        let open = LibraryNavigation.neighbors(ofEditKey: copy.editKey, in: grid)
        XCTAssertEqual(open.previous?.id, 1, "Previous from the copy is the master")
        XCTAssertEqual(open.next?.id, 8, "Next from the copy moves ON, instead of re-opening the copy")
        let fromMaster = LibraryNavigation.neighbors(ofEditKey: master.editKey, in: grid)
        XCTAssertEqual(fromMaster.previous?.id, 9)
        XCTAssertEqual(fromMaster.next?.id, 2)
    }

    func testTheMenuNeighbourLookupAndNoOtherVersionIdentitySiteStillUsesThePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/App/PhotoAppApp.swift"), encoding: .utf8)
        // By EDIT KEY, over the flat list (no stacks) or the filmstrip's cells (stacks) — both of which are lists of the SAME photos.
        XCTAssertTrue(app.contains("LibraryNavigation.neighbors(ofEditKey: currentKey, in: walked)"))
        XCTAssertTrue(app.contains("catalog.stacks.isEmpty ? catalog.displayedPhotos : catalog.filmstripItems(openEditKey: currentKey).map(\\.photo)"))
        XCTAssertTrue(app.contains("cull.begin(startingAtPath: showLibrary ? catalog.focusedPhotoPath : document.currentEditKey)"))
        let neighbours = try XCTUnwrap(app.range(of: "private var photoNeighbors"))
        XCTAssertFalse(app[neighbours.lowerBound...].prefix(900).contains("currentURL?.path"))
    }

    // MARK: 2. Trash confirmation counts copies from the database

    func testCopiesWithMastersCountsOnlyUnselectedCopies() {
        let master = row("/p/a.jpg", id: 1)
        let c1 = copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa")
        let c2 = copyRow("/p/a.jpg", id: 3, master: 1, key: "bbbbbbbb")
        XCTAssertEqual(TrashModel.copiesWithMasters(targets: [master], copiesByMaster: [1: [c1, c2]]), 2)
        XCTAssertEqual(TrashModel.copiesWithMasters(targets: [master, c1], copiesByMaster: [1: [c1, c2]]), 1)
        XCTAssertEqual(TrashModel.copiesWithMasters(targets: [c1], copiesByMaster: [1: [c1, c2]]), 0, "a copy trashed alone takes no others")
    }

    func testTheRequestNamesCopiesEvenWhenTheViewDoesNotShowThem() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(try await db.photo(atPath: "/p/a.jpg"))
        _ = try await db.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        _ = try await db.createVirtualCopy(of: master, versionKey: "bbbbbbbb")
        let catalog = CatalogModel(database: db, defaults: isolatedDefaults())
        // No refresh: `catalog.photos` is empty, like a view of an album that holds only the master. The count must come from the database.
        XCTAssertTrue(catalog.photos.isEmpty)
        let model = TrashModel()
        let providers = RenameProviders(openPhotoPath: { nil }, busyReason: { nil })
        await model.request(.selected, shown: [master], scope: "Album", providers: providers, catalog: catalog)
        let request = try XCTUnwrap(model.pending)
        XCTAssertEqual(request.copiesWithMasters, 2)
        XCTAssertTrue(TrashModel.confirmationMessage(request).contains("2 virtual copies of these photos go with them"))
    }

    // MARK: 3. Remove from Library wording

    func testRemovalTextNamesTheCopiesThatGoAndTheLeftEditFiles() {
        let master = row("/p/a.jpg", id: 1)
        let none = LibraryRemovalText.message(for: master, copyCount: 0)
        XCTAssertFalse(none.contains("virtual cop"))
        XCTAssertTrue(LibraryRemovalText.message(for: master, copyCount: 1).contains("Its 1 virtual copy will be removed from the Library too"))
        let two = LibraryRemovalText.message(for: master, copyCount: 2)
        XCTAssertTrue(two.contains("Its 2 virtual copies"))
        XCTAssertTrue(two.contains("edit files are left next to the photo"))
        let copy = copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa", name: "Copy 3")
        let text = LibraryRemovalText.message(for: copy, copyCount: 5)
        XCTAssertTrue(text.contains("a.jpg · Copy 3"))
        XCTAssertFalse(text.contains("Its 5"), "a copy removes only itself")
        XCTAssertTrue(text.contains("edit file is left next to the photo"))
    }

    // MARK: 4/5. Migration counter and key constraint

    func testAnEmptyTableKeepsItsAutoincrementCounterAcrossMigration015() async throws {
        let path = NSTemporaryDirectory() + "vc-empty-\(UUID().uuidString).sqlite"
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
            try migrator.migrate(queue)
            try await queue.write { db in
                for index in 1...7 {
                    try db.execute(sql: "INSERT INTO photo (path, filename, importedAt) VALUES (?, 'x', '2026-01-01 00:00:00')", arguments: ["/p/\(index).jpg"])
                }
                try db.execute(sql: "DELETE FROM photo") // empty table, counter 7
            }
        }
        let db = try CatalogDatabase(path: path)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/new.jpg")])
        let photo = try unwrapped(try await db.photo(atPath: "/p/new.jpg"))
        XCTAssertEqual(photo.id, 8, "a deleted id (a stale Undo Rename batch may still name it) is never reissued")
    }

    func testTheDatabaseRefusesAMalformedVersionKey() throws {
        let db = try CatalogDatabase(inMemory: true)
        try db.dbQueue.write { database in
            try database.execute(sql: "INSERT INTO photo (path, filename, importedAt) VALUES ('/p/a.jpg', 'a', '2026-01-01 00:00:00')")
            for bad in ["../x", "ABCDEF01", "abc", "abcdefgh", "abcdef012"] {
                XCTAssertThrowsError(try database.execute(
                    sql: "INSERT INTO photo (path, filename, importedAt, masterId, versionKey) VALUES ('/p/a.jpg', 'a', '2026-01-01 00:00:00', 1, ?)",
                    arguments: [bad]), bad)
            }
        }
    }

    func testASidecarPathIsNeverBuiltFromAMalformedKey() {
        let bad = copyRow("/p/a.jpg", id: 2, master: 1, key: "../x")
        XCTAssertNil(SidecarStore.sidecarURL(for: bad))
        XCTAssertNil(SidecarStore.versionedSidecarURL(for: URL(fileURLWithPath: "/p/a.jpg"), versionKey: "../../etc/pw"),
                     "even the low-level builder refuses rather than building any path")
    }

    // MARK: Round 2: counting failures, selection, grid hook

    func testCopiesCannotBeCountedWhenTheCatalogIsNotReadyAndTheDialogsRefuse() async throws {
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: isolatedDefaults())
        let master = row("/p/a.jpg", id: 1)
        let counted = await LibraryRemovalText.copyCount(for: master, loading: { throw CatalogDatabaseError(message: "boom") })
        XCTAssertNil(counted, "a failed read must not become 0 copies")
        let ok = await LibraryRemovalText.copyCount(for: master, loading: { [1: [self.copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa")]] })
        XCTAssertEqual(ok, 1)
        let none = await LibraryRemovalText.copyCount(for: copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa"), loading: { throw CatalogDatabaseError(message: "x") })
        XCTAssertEqual(none, 0, "a copy takes no others, so there is nothing to count")
        // A catalog with no open database throws instead of returning an empty map.
        let unopened = CatalogModel(defaults: isolatedDefaults())
        do { _ = try await unopened.copiesByMaster(); XCTFail("expected a throw") } catch {}
        _ = catalog
    }

    func testTheTrashRequestRefusesInsteadOfUndercountingWhenCopiesCannotBeRead() async throws {
        let unopened = CatalogModel(defaults: isolatedDefaults()) // no database yet: copiesByMaster throws
        let model = TrashModel()
        await model.request(.selected, shown: [row("/p/a.jpg", id: 1)], scope: "All Photos",
                            providers: RenameProviders(openPhotoPath: { nil }, busyReason: { nil }), catalog: unopened)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.statusMessage?.contains("Couldn't count") == true, model.statusMessage ?? "nil")
    }

    func testRemovingAMasterAlsoDeselectsItsCopies() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let master = try unwrapped(try await db.photo(atPath: "/p/a.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        let catalog = CatalogModel(database: db, defaults: isolatedDefaults())
        await catalog.refresh()
        catalog.toggleSelection(of: master)
        catalog.toggleSelection(of: copy)
        XCTAssertEqual(catalog.selectedPhotoIDs.count, 2)
        catalog.removePhoto(master)
        XCTAssertTrue(catalog.selectedPhotoIDs.isEmpty, "the cascade removed the copy; it must not stay selected")
    }

    func testTheGridMenuAndThePhotoMenuShareTheOpenVersionHooks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let grid = try String(contentsOf: root.appendingPathComponent("Sources/UI/LibraryGridView.swift"), encoding: .utf8)
        XCTAssertTrue(grid.contains("catalog.createVirtualCopy(of: photo)"))
        let content = try String(contentsOf: root.appendingPathComponent("Sources/UI/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("catalog.openVersionProvider = { document.currentEditKey.map { ($0, document.editState) } }"))
        XCTAssertTrue(content.contains("catalog.flushOpenEdits = { document.flushPendingSidecarSave() }"))
        let model = try String(contentsOf: root.appendingPathComponent("Sources/UI/CatalogModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("let open = openVersion ?? openVersionProvider?()"), "every entry point falls back to the hooks")
    }

    func testAnOpenVersionIsUsedByTheDefaultHook() async throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        var stale = EditState(); stale.exposureEV = 1
        try SidecarStore.write(stale, forPhotoAt: image)
        var live = EditState(); live.exposureEV = 3
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let master = try unwrapped(try await db.photo(atPath: image.path))
        let catalog = CatalogModel(database: db, defaults: isolatedDefaults())
        catalog.openVersionProvider = { (master.editKey, live) }
        var flushed = false
        catalog.flushOpenEdits = { flushed = true }
        let model = VirtualCopyModel(folderAccess: StubAccess(try scopedDir()))
        // The catalog entry point resolves the hooks exactly as the grid cell menu does.
        let open = catalog.openVersionProvider?()
        _ = await model.create(from: [master], catalog: catalog, flushEdits: catalog.flushOpenEdits ?? {}, openVersion: open)
        XCTAssertTrue(flushed)
        let key = try unwrapped(try await db.copies(ofMasterID: try XCTUnwrap(master.id)).first?.versionKey)
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image, versionKey: key), .decoded(live))
    }

    // MARK: 7. Key retry on a unique-index collision

    private final class StubAccess: SidecarFolderAccessing {
        let granted: URL
        init(_ granted: URL) { self.granted = granted }
        func resolvedURL(for folder: URL) -> URL? { granted }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(granted) }
    }

    private func scopedDir() throws -> URL {
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func testAKeyAlreadyUsedByAnUneditedCopyIsRetriedWithAFreshOne() async throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let master = try unwrapped(try await db.photo(atPath: image.path))
        _ = try await db.createVirtualCopy(of: master, versionKey: "00000001") // unedited: no file on disk
        let catalog = CatalogModel(database: db, defaults: isolatedDefaults())
        var values: [UInt32] = [1, 2]
        let model = VirtualCopyModel(folderAccess: StubAccess(try scopedDir()), randomKey: { values.isEmpty ? 3 : values.removeFirst() })
        let message = await model.create(from: [master], catalog: catalog)
        XCTAssertTrue(message.hasPrefix("Created 1 virtual copy"), message)
        let keys = try await db.copies(ofMasterID: try XCTUnwrap(master.id)).compactMap(\.versionKey)
        XCTAssertEqual(Set(keys), ["00000001", "00000002"])
    }

    // MARK: 8. A copy of the open version carries the in-memory edits

    func testACopyOfTheOpenVersionCarriesTheLiveEditsNotAStaleFile() async throws {
        let image = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: image)
        var stale = EditState(); stale.exposureEV = 1
        try SidecarStore.write(stale, forPhotoAt: image) // what a failed/declined save left on disk
        var live = EditState(); live.exposureEV = 2.5 // what is on screen
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [image])
        let master = try unwrapped(try await db.photo(atPath: image.path))
        let catalog = CatalogModel(database: db, defaults: isolatedDefaults())
        let model = VirtualCopyModel(folderAccess: StubAccess(try scopedDir()))
        _ = await model.create(from: [master], catalog: catalog, openVersion: (master.editKey, live))
        let key = try unwrapped(try await db.copies(ofMasterID: try XCTUnwrap(master.id)).first?.versionKey)
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image, versionKey: key), .decoded(live))
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image), .decoded(stale), "the master's own file is not rewritten by creating a copy")
        // A source that is NOT the open version still copies from its file.
        _ = await model.create(from: [master], catalog: catalog, openVersion: ("/some/other", live))
        let keys = try await db.copies(ofMasterID: try XCTUnwrap(master.id)).compactMap(\.versionKey)
        let others = keys.filter { $0 != key }
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(SidecarStore.read(forPhotoAt: image, versionKey: others[0]), .decoded(stale))
    }

    // MARK: 9. Merge input

    func testAMergeNeverTakesVirtualCopiesAsInput() async {
        let merge = MergeModel(folderAccess: StubAccess(dir))
        let catalog = CatalogModel(database: try! CatalogDatabase(inMemory: true), defaults: isolatedDefaults()) // swiftlint:disable:this force_try
        let master = row("/p/a.jpg", id: 1)
        let copy = copyRow("/p/a.jpg", id: 2, master: 1, key: "aaaaaaaa")
        merge.request(.hdr, photos: [master, copy], catalog: catalog)
        XCTAssertNil(merge.pending, "a master and its own copy are one frame, not a bracket")
        XCTAssertNotNil(merge.statusMessage)
        let other = row("/p/b.jpg", id: 3, name: "b.jpg")
        merge.statusMessage = nil
        merge.request(.hdr, photos: [master, copy, other], catalog: catalog)
        await merge.checkTask?.value
        XCTAssertEqual(merge.pending?.photos.map(\.id), [1, 3])
    }

    // MARK: Export of a copy

    func testExportOfACopyUsesThatVersionsEditsAndTheCollisionName() async throws {
        let source = dir.appendingPathComponent("a.png")
        let gray = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        try CIContext().writePNGRepresentation(of: gray, to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var bright = EditState(); bright.exposureEV = 2
        try SidecarStore.write(bright, forPhotoAt: source, versionKey: "aaaaaaaa")
        let master = row(source.path, id: 1, name: "a.png")
        let copy = copyRow(source.path, id: 2, master: 1, key: "aaaaaaaa")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let settings = ExportSettings(format: .png)

        let masterOut = try await PhotoExporter.export(master, editState: PhotoExporter.loadEditState(for: master), to: out, settings: settings)
        let copyOut = try await PhotoExporter.export(copy, editState: PhotoExporter.loadEditState(for: copy), to: out, settings: settings)

        XCTAssertEqual(masterOut.lastPathComponent, "a.png")
        XCTAssertEqual(copyOut.lastPathComponent, "a (2).png", "the copy never overwrites the master's export")
        func red(_ url: URL) throws -> UInt8 {
            let image = try XCTUnwrap(CIImage(contentsOf: url))
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel[0]
        }
        XCTAssertGreaterThan(try red(copyOut), try red(masterOut) + 40, "the copy's export carries its own +2 EV edit")
    }
}
