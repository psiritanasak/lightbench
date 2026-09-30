import XCTest
@testable import PhotoApp

/// End to end: REAL files in a temp folder + an in-memory catalog. Proves the two halves (files, catalog)
/// stay in step — a failure in either leaves neither changed — and that Undo restores both.
final class RenameApplierTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameApplierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Creates `name` (content = its own upper-cased stem) + a sidecar, and catalogs it.
    private func importFiles(_ names: [String]) async throws -> [String: Photo] {
        for name in names {
            let stem = (name as NSString).deletingPathExtension.uppercased()
            try Data(stem.utf8).write(to: dir.appendingPathComponent(name))
            try Data("sidecar-of-\(stem)".utf8).write(to: dir.appendingPathComponent(name + ".photoapp.json"))
        }
        _ = try await db.importPhotos(at: names.map { dir.appendingPathComponent($0) })
        return Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.filename, $0) })
    }

    private func read(_ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func rowPaths() async throws -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.id!, $0.path) })
    }

    private func move(_ photo: Photo, to name: String) -> RenameMove {
        RenameMove(photoID: photo.id!, oldPath: photo.path, newPath: path(name))
    }

    private struct Boom: Error {}

    // MARK: Apply + Undo

    func testApplyRenamesFilesSidecarsAndRowsThenUndoRestoresAll() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try need(photos["a.jpg"]), try need(photos["b.jpg"]))
        let original = try listing()

        let count = try await RenameApplier.apply([move(a, to: "Trip_001.jpg"), move(b, to: "Trip_002.jpg")], database: db)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try listing(), ["Trip_001.jpg", "Trip_001.jpg.photoapp.json", "Trip_002.jpg", "Trip_002.jpg.photoapp.json"])
        XCTAssertEqual(read("Trip_001.jpg.photoapp.json"), "sidecar-of-A")
        let after = try await rowPaths()
        XCTAssertEqual(after[a.id!], path("Trip_001.jpg"))
        XCTAssertEqual(after[b.id!], path("Trip_002.jpg"))

        let restored = try await RenameApplier.undoLast(database: db)

        XCTAssertEqual(restored, 2)
        XCTAssertEqual(try listing(), original)
        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-B")
        let back = try await rowPaths()
        XCTAssertEqual(back[a.id!], a.path)
        XCTAssertEqual(back[b.id!], b.path)
        let log = try await db.lastRenameLog()
        XCTAssertNil(log)
    }

    func testASwapAppliesAndUndoesCleanly() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try need(photos["a.jpg"]), try need(photos["b.jpg"]))
        _ = try await RenameApplier.apply([move(a, to: "b.jpg"), move(b, to: "a.jpg")], database: db)
        XCTAssertEqual(read("a.jpg"), "B")
        XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-A")

        _ = try await RenameApplier.undoLast(database: db)
        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(read("b.jpg"), "B")
        let back = try await rowPaths()
        XCTAssertEqual(back[a.id!], a.path)
        XCTAssertEqual(back[b.id!], b.path)
    }

    func testUndoingTwiceThrowsNoLoggedRename() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        _ = try await RenameApplier.apply([move(a, to: "z.jpg")], database: db)
        _ = try await RenameApplier.undoLast(database: db)
        do {
            _ = try await RenameApplier.undoLast(database: db)
            XCTFail("expected noLoggedRename")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .noLoggedRename)
        }
    }

    func testOnlyTheMostRecentBatchIsUndone() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try need(photos["a.jpg"]), try need(photos["b.jpg"]))
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)
        let b1 = try need(try await db.allPhotos().first { $0.id == b.id })
        _ = try await RenameApplier.apply([move(b1, to: "b2.jpg")], database: db)

        _ = try await RenameApplier.undoLast(database: db)

        XCTAssertNotNil(read("a2.jpg")) // the FIRST batch stays applied
        XCTAssertNotNil(read("b.jpg"))  // the second was undone
        XCTAssertNil(read("b2.jpg"))
    }

    func testAnEmptyBatchDoesNothing() async throws {
        let count = try await RenameApplier.apply([], database: db)
        XCTAssertEqual(count, 0)
        let log = try await db.lastRenameLog()
        XCTAssertNil(log)
    }

    // MARK: Failures keep the two halves in step

    /// The files move first; if the catalog then rejects the batch, the files must be put back.
    func testACatalogFailureAfterTheFilesMovedPutsTheFilesBack() async throws {
        let photos = try await importFiles(["a.jpg"])
        let a = try need(photos["a.jpg"])
        let original = try listing()
        // A move for a photo id the catalog doesn't have: the file move succeeds, the catalog step throws photoMissing.
        let ghost = RenameMove(photoID: 9999, oldPath: a.path, newPath: path("moved.jpg"))

        do {
            _ = try await RenameApplier.apply([ghost], database: db)
            XCTFail("expected the catalog step to fail")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("put back"), error.message)
        }

        XCTAssertEqual(try listing(), original) // file + sidecar restored
        XCTAssertEqual(read("a.jpg"), "A")
        let rows = try await rowPaths()
        XCTAssertEqual(rows[a.id!], a.path)
        let log = try await db.lastRenameLog()
        XCTAssertNil(log)
    }

    func testACatalogFailureAndAFailedRollbackSaysSoAndPointsAtLocate() async throws {
        let photos = try await importFiles(["a.jpg"])
        let a = try need(photos["a.jpg"])
        let ghost = RenameMove(photoID: 9999, oldPath: a.path, newPath: path("moved.jpg"))
        var forwardDone = false
        let move: RenameEngine.MoveFunction = { from, to in
            // Forward moves succeed; once they have, every later (rollback) move fails.
            if forwardDone { throw Boom() }
            try RenameEngine.exclusiveMove(from, to)
            if to.lastPathComponent == "moved.jpg.photoapp.json" { forwardDone = true }
        }

        do {
            _ = try await RenameApplier.apply([ghost], database: db, move: move)
            XCTFail("expected a failure")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("Locate"), error.message)
            XCTAssertTrue(error.message.contains("AND the files couldn't be put back"), error.message)
        }
    }

    func testAFileFailureLeavesTheCatalogAndLogUntouched() async throws {
        let photos = try await importFiles(["a.jpg", "b.jpg"])
        let (a, b) = (try need(photos["a.jpg"]), try need(photos["b.jpg"]))
        try Data("blocker".utf8).write(to: dir.appendingPathComponent("taken.jpg")) // a file NOT in the batch
        do {
            _ = try await RenameApplier.apply([move(a, to: "ok.jpg"), move(b, to: "taken.jpg")], database: db)
            XCTFail("expected the file step to refuse")
        } catch is RenameEngine.Failure {
            // expected
        }
        XCTAssertEqual(read("taken.jpg"), "blocker") // never overwritten
        let rows = try await rowPaths()
        XCTAssertEqual(rows[a.id!], a.path)
        XCTAssertEqual(rows[b.id!], b.path)
        let log = try await db.lastRenameLog()
        XCTAssertNil(log)
        XCTAssertNotNil(read("a.jpg"))
    }

    // MARK: Undo refusals

    func testUndoIsRefusedUpFrontWhenTheCatalogNoLongerMatchesAndNothingMoves() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)
        _ = try await db.relocatePhotos([(photoID: a.id!, newPath: path("elsewhere.jpg"))])
        let before = try listing()

        do {
            _ = try await RenameApplier.undoLast(database: db)
            XCTFail("expected pathChanged")
        } catch let error as RenameCatalogError {
            XCTAssertEqual(error, .pathChanged(a.id!))
        }
        XCTAssertEqual(try listing(), before) // no file was touched
        let log = try await db.lastRenameLog()
        XCTAssertNotNil(log) // and the log survives
    }

    func testUndoFailsCleanlyWhenTheOldNameIsOccupiedAgain() async throws {
        let a = try need(try await importFiles(["a.jpg"])["a.jpg"])
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)
        try Data("newcomer".utf8).write(to: dir.appendingPathComponent("a.jpg")) // someone reused the old name
        let before = try listing()

        do {
            _ = try await RenameApplier.undoLast(database: db)
            XCTFail("expected the undo to refuse")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("Couldn't undo"), error.message)
        }
        XCTAssertEqual(try listing(), before)
        XCTAssertEqual(read("a.jpg"), "newcomer") // never overwritten
        XCTAssertEqual(read("a2.jpg"), "A")
        let rows = try await rowPaths()
        XCTAssertEqual(rows[a.id!], path("a2.jpg"))
        let log = try await db.lastRenameLog()
        XCTAssertNotNil(log) // still undoable once the user frees the name
    }

    // MARK: Undo hardening (batch-rename commit 3 review)

    /// A stale Editor save can drop `<old name>.photoapp.json` after the rename. Undo (which has no planner)
    /// must refuse rather than silently attach those edits to the photo it moves back.
    func testUndoRefusesWhenAStraySidecarAppearedAtTheOldName() async throws {
        try Data("A".utf8).write(to: dir.appendingPathComponent("a.jpg")) // NO sidecar of its own
        _ = try await db.importPhotos(at: [dir.appendingPathComponent("a.jpg")])
        let a = try need(try await db.allPhotos().first)
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)
        try Data("stray-edits".utf8).write(to: dir.appendingPathComponent("a.jpg.photoapp.json")) // stale save
        let before = try listing()

        do {
            _ = try await RenameApplier.undoLast(database: db)
            XCTFail("expected the undo to refuse")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("Couldn't undo"), error.message)
        }
        XCTAssertEqual(try listing(), before)
        XCTAssertEqual(read("a.jpg.photoapp.json"), "stray-edits")
        XCTAssertNotNil(read("a2.jpg"))
        let log = try await db.lastRenameLog()
        XCTAssertNotNil(log)
    }

    /// Undo: files moved back, then the catalog step fails -> files go FORWARD again to match the still-present log.
    func testAnUndoCatalogFailureAfterTheFilesMovedBackPutsThemBackUnderTheirNewNames() async throws {
        let photos = try await importFiles(["a.jpg"])
        let a = try need(photos["a.jpg"])
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)

        do {
            _ = try await RenameApplier.undoLast(database: db, afterFilesMoved: {
                // Simulates the catalog changing under us AFTER the files really moved back.
                _ = try await self.db.relocatePhotos([(photoID: a.id!, newPath: self.path("elsewhere.jpg"))])
            })
            XCTFail("expected the catalog revert to fail")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("under their new names"), error.message)
        }
        XCTAssertEqual(try listing(), ["a2.jpg", "a2.jpg.photoapp.json"]) // forward again, nothing lost
        XCTAssertEqual(read("a2.jpg"), "A")
        let log = try await db.lastRenameLog()
        XCTAssertNotNil(log) // log intact
    }

    /// Both the catalog revert AND the file roll-forward fail: the message must describe the state the
    /// catalog is really in — it lists the NEW names while the files sit under the OLD ones.
    func testAnUndoDoubleFailureDescribesTheCatalogAsListingTheNewNames() async throws {
        let photos = try await importFiles(["a.jpg"])
        let a = try need(photos["a.jpg"])
        _ = try await RenameApplier.apply([move(a, to: "a2.jpg")], database: db)
        var undoMovesDone = 0
        let move: RenameEngine.MoveFunction = { from, to in
            // Let the undo's own file moves through (park a2, park sidecar, place a, place sidecar = 4), then fail everything.
            if undoMovesDone >= 4 { throw Boom() }
            undoMovesDone += 1
            try RenameEngine.exclusiveMove(from, to)
        }

        do {
            _ = try await RenameApplier.undoLast(database: db, move: move, afterFilesMoved: {
                _ = try await self.db.relocatePhotos([(photoID: a.id!, newPath: self.path("elsewhere.jpg"))])
            })
            XCTFail("expected a double failure")
        } catch let error as RenameApplier.Failure {
            XCTAssertTrue(error.message.contains("still lists the NEW names"), error.message)
            XCTAssertFalse(error.message.contains("still lists the OLD names"), error.message)
            XCTAssertTrue(error.message.contains("Locate"), error.message)
        }
    }
}

