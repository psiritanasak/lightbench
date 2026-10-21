import XCTest
@testable import PhotoApp

/// Virtual copies and Move to Trash. The rules that matter: trashing a COPY never moves the shared image file; trashing a MASTER takes all
/// its copies (rows and edit files); a copy of the open photo is left alone; a failed move keeps the row.
final class VirtualCopyTrashTests: XCTestCase {
    private func master(_ path: String, id: Int64) -> Photo {
        Photo(id: id, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func copy(of master: Photo, id: Int64, key: String) -> Photo {
        var photo = master
        photo.id = id
        photo.masterId = master.id
        photo.versionKey = key
        photo.versionName = "Copy 1"
        return photo
    }

    private func plan(
        _ photos: [Photo], open: String? = nil, catalogued: [String], files: Set<String>, copiesOfMasters: [Int64: [Photo]] = [:]
    ) -> TrashPlan {
        TrashPlan.make(
            photos: photos, openPhotoPath: open, cataloguedPaths: catalogued, copiesOfMasters: copiesOfMasters,
            fileKind: { files.contains($0.standardizedFileURL.path) ? .file : .missing },
            folderListing: { folder in
                files.map { URL(fileURLWithPath: $0) }.filter { $0.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path }
            })
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var moved: [String] = []
        var failing: Set<String> = []
        var paths: [String] { lock.withLock { moved } }
        func move(_ url: URL) throws -> URL? {
            if failing.contains(url.lastPathComponent) { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "nope"]) }
            lock.withLock { moved.append(url.path) }
            return nil
        }
    }

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // MARK: Plan

    func testTrashingOnlyACopyPlansItsEditFileAndNeverTheSharedImage() {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([c], catalogued: ["/p/a.jpg", "/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.photoapp.json", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertEqual(result.items.count, 1)
        let item = result.items[0]
        XCTAssertTrue(item.isVersionOnly)
        XCTAssertEqual(item.photoID, 2)
        XCTAssertEqual(item.companions.map(\.url.lastPathComponent), ["a.jpg.aaaaaaaa.photoapp.json"], "only the copy's own edit file; not the master's")
    }

    func testTrashingAMasterTakesItsCopiesRowsAndEditFilesEvenWhenTheyAreNotSelected() {
        let m = master("/p/a.jpg", id: 1)
        let c1 = copy(of: m, id: 2, key: "aaaaaaaa")
        let c2 = copy(of: m, id: 3, key: "bbbbbbbb")
        let result = plan(
            [m], catalogued: ["/p/a.jpg", "/p/a.jpg", "/p/a.jpg"],
            files: ["/p/a.jpg", "/p/a.jpg.photoapp.json", "/p/a.jpg.aaaaaaaa.photoapp.json", "/p/a.jpg.bbbbbbbb.photoapp.json"],
            copiesOfMasters: [1: [c1, c2]])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.items[0].isVersionOnly)
        XCTAssertEqual(Set(result.items[0].alsoIDs), [2, 3])
        XCTAssertEqual(
            Set(result.items[0].companions.map(\.url.lastPathComponent)),
            ["a.jpg.photoapp.json", "a.jpg.aaaaaaaa.photoapp.json", "a.jpg.bbbbbbbb.photoapp.json"])
    }

    func testAnOrphanVersionEditFileBesideATrashedMasterGoesWithIt() {
        let m = master("/p/a.jpg", id: 1)
        let result = plan([m], catalogued: ["/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.cccccccc.photoapp.json", "/p/a.jpg.notakey.photoapp.json"])
        XCTAssertEqual(result.items[0].companions.map(\.url.lastPathComponent), ["a.jpg.cccccccc.photoapp.json"], "only well-formed version keys")
    }

    func testAMasterAndItsSelectedCopyAreOneItemNotTwo() {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([m, c], catalogued: ["/p/a.jpg", "/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].alsoIDs, [2])
        XCTAssertEqual(result.items[0].companions.count, 1, "the copy's edit file is planned once")
    }

    func testACopyOfTheOpenPhotoIsSkippedLikeTheOpenPhotoItself() {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([c], open: "/p/a.jpg", catalogued: ["/p/a.jpg", "/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), [.openInEditor])
    }

    func testACopyOfAMissingFileCanStillBeTrashedOnItsOwn() {
        let m = master("/p/gone.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([c], catalogued: ["/p/gone.jpg"], files: ["/p/gone.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertEqual(result.items.count, 1, "the copy's rows and edit file do not need the image")
        XCTAssertTrue(result.items[0].isVersionOnly)
    }

    // MARK: Engine

    func testTheEngineNeverMovesTheSharedFileForACopyOnlyItem() async {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([c], catalogued: ["/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(result, mover: { try recorder.move($0) })
        XCTAssertEqual(recorder.paths, ["/p/a.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertEqual(outcome.trashedIDs, [2])
        XCTAssertFalse(recorder.paths.contains("/p/a.jpg"))
    }

    func testACopyWhoseEditFileCannotBeMovedKeepsItsRow() async {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([c], catalogued: ["/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        let recorder = Recorder()
        recorder.failing = ["a.jpg.aaaaaaaa.photoapp.json"]
        let outcome = await TrashEngine.apply(result, mover: { try recorder.move($0) })
        XCTAssertTrue(outcome.trashedIDs.isEmpty, "the row must stay when its edits could not be moved")
        XCTAssertEqual(outcome.failures.map(\.photoID), [2])
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testTheEngineMovesAMastersFileAndAllItsCopiesEditFilesAndReportsAllRows() async {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([m], catalogued: ["/p/a.jpg", "/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"], copiesOfMasters: [1: [c]])
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(result, mover: { try recorder.move($0) })
        XCTAssertEqual(recorder.paths, ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"])
        XCTAssertEqual(Set(outcome.trashedIDs), [1, 2])
    }

    func testAMasterThatFailsToMoveKeepsItsCopiesAndTheirEditFiles() async {
        let m = master("/p/a.jpg", id: 1)
        let c = copy(of: m, id: 2, key: "aaaaaaaa")
        let result = plan([m], catalogued: ["/p/a.jpg", "/p/a.jpg"], files: ["/p/a.jpg", "/p/a.jpg.aaaaaaaa.photoapp.json"], copiesOfMasters: [1: [c]])
        let recorder = Recorder()
        recorder.failing = ["a.jpg"]
        let outcome = await TrashEngine.apply(result, mover: { try recorder.move($0) })
        XCTAssertTrue(outcome.trashedIDs.isEmpty, "no row (the copies' included) is removed when the shared file stayed")
        XCTAssertTrue(recorder.paths.isEmpty, "the copies' edit files stay too")
    }

    // MARK: Database: only the rows named go

    func testRemovingACopysRowLeavesTheMasterAndRemovingAMastersRowTakesTheCopies() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/p/a.jpg")])
        let m = try unwrapped(try await db.photo(atPath: "/p/a.jpg"))
        let c = try await db.createVirtualCopy(of: m, versionKey: "aaaaaaaa")
        try await db.deletePhotos(ids: [try XCTUnwrap(c.id)])
        var ids = try await db.allPhotos().compactMap(\.id)
        XCTAssertEqual(ids, [try XCTUnwrap(m.id)])
        _ = try await db.createVirtualCopy(of: m, versionKey: "bbbbbbbb")
        try await db.deletePhotos(ids: [try XCTUnwrap(m.id)])
        ids = try await db.allPhotos().compactMap(\.id)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: Source pins

    func testTheTrashEngineHasNoPathToTheFileForAVersionOnlyItem() throws {
        let source = try String(contentsOfFile: Self.repoFile("Sources/Rendering/TrashPlan.swift"), encoding: .utf8)
        let branch = try XCTUnwrap(source.range(of: "if item.isVersionOnly {"))
        let tail = String(source[branch.upperBound...])
        let end = try XCTUnwrap(tail.range(of: "continue\n            }"))
        XCTAssertFalse(tail[..<end.lowerBound].contains("item.photoURL"), "a copy-only item must never hand the shared image file to the mover")
    }

    static func repoFile(_ relative: String, file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative).path
    }
}
