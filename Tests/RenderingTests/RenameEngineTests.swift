import XCTest
@testable import PhotoApp

/// `RenameEngine` moves REAL files, so these run against a real temp folder.
final class RenameEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    /// Writes `name` with `content`, plus its sidecar (`<name>.photoapp.json`) holding "sidecar-of-<content>".
    @discardableResult
    private func write(_ name: String, _ content: String, sidecar: Bool = true) throws -> String {
        try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        if sidecar {
            try Data("sidecar-of-\(content)".utf8).write(to: dir.appendingPathComponent(name + ".photoapp.json"))
        }
        return path(name)
    }

    private func read(_ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func move(_ from: String, _ to: String, id: Int64 = 1) -> RenameMove {
        RenameMove(photoID: id, oldPath: path(from), newPath: path(to))
    }

    // MARK: Success paths

    func testRenamesAPhotoAndItsSidecarTogether() throws {
        try write("a.jpg", "A")
        try RenameEngine.apply([move("a.jpg", "new.jpg")])
        XCTAssertEqual(try listing(), ["new.jpg", "new.jpg.photoapp.json"])
        XCTAssertEqual(read("new.jpg"), "A")
        XCTAssertEqual(read("new.jpg.photoapp.json"), "sidecar-of-A")
    }

    func testRenamesAPhotoThatHasNoSidecar() throws {
        try write("a.jpg", "A", sidecar: false)
        try RenameEngine.apply([move("a.jpg", "b.jpg")])
        XCTAssertEqual(try listing(), ["b.jpg"])
    }

    func testAChainKeepsEveryFileAndItsSidecar() throws {
        try write("x.jpg", "X")
        try write("y.jpg", "Y")
        // x -> y and y -> z: y's name is claimed by x only after y has moved away.
        try RenameEngine.apply([move("x.jpg", "y.jpg", id: 1), move("y.jpg", "z.jpg", id: 2)])
        XCTAssertEqual(try listing(), ["y.jpg", "y.jpg.photoapp.json", "z.jpg", "z.jpg.photoapp.json"])
        XCTAssertEqual(read("y.jpg"), "X")
        XCTAssertEqual(read("y.jpg.photoapp.json"), "sidecar-of-X")
        XCTAssertEqual(read("z.jpg"), "Y")
        XCTAssertEqual(read("z.jpg.photoapp.json"), "sidecar-of-Y")
    }

    func testASwapExchangesTheTwoPhotosAndTheirSidecars() throws {
        try write("a.jpg", "A")
        try write("b.jpg", "B")
        try RenameEngine.apply([move("a.jpg", "b.jpg", id: 1), move("b.jpg", "a.jpg", id: 2)])
        XCTAssertEqual(read("a.jpg"), "B")
        XCTAssertEqual(read("b.jpg"), "A")
        XCTAssertEqual(read("a.jpg.photoapp.json"), "sidecar-of-B")
        XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-A")
        XCTAssertEqual(try listing().count, 4) // nothing stray left behind
    }

    func testACaseOnlyRenameChangesTheStoredCase() throws {
        try write("IMG.jpg", "I")
        try RenameEngine.apply([move("IMG.jpg", "img.jpg")])
        XCTAssertEqual(try listing(), ["img.jpg", "img.jpg.photoapp.json"]) // "IMG.jpg" no longer listed
        XCTAssertEqual(read("img.jpg"), "I")
    }

    func testAnEmptyBatchIsANoOp() throws {
        try write("a.jpg", "A")
        try RenameEngine.apply([])
        XCTAssertEqual(try listing(), ["a.jpg", "a.jpg.photoapp.json"])
    }

    // MARK: No overwrite

    func testNeverOverwritesAnExistingFileAndRestoresEverythingElse() throws {
        try write("a.jpg", "A")
        try write("b.jpg", "B")
        try write("keep.jpg", "KEEP")
        let before = try listing()

        XCTAssertThrowsError(try RenameEngine.apply([move("a.jpg", "new1.jpg", id: 1), move("b.jpg", "keep.jpg", id: 2)])) { error in
            XCTAssertTrue((error as? RenameEngine.Failure)?.message.contains("nothing was renamed") ?? false, "\(error)")
        }

        XCTAssertEqual(try listing(), before) // every name back, no hidden temp files
        XCTAssertEqual(read("keep.jpg"), "KEEP") // the existing file was never touched
        XCTAssertEqual(read("keep.jpg.photoapp.json"), "sidecar-of-KEEP")
        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-B")
    }

    func testExclusiveMoveRefusesToReplaceAndMovesWhenFree() throws {
        try write("a.jpg", "A", sidecar: false)
        try write("b.jpg", "B", sidecar: false)
        XCTAssertThrowsError(try RenameEngine.exclusiveMove(dir.appendingPathComponent("a.jpg"), dir.appendingPathComponent("b.jpg"))) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(read("b.jpg"), "B")
        XCTAssertEqual(read("a.jpg"), "A")
        try RenameEngine.exclusiveMove(dir.appendingPathComponent("a.jpg"), dir.appendingPathComponent("c.jpg"))
        XCTAssertEqual(try listing(), ["b.jpg", "c.jpg"])
    }

    func testAMissingSourceFailsAndPutsTheOthersBack() throws {
        try write("a.jpg", "A")
        let before = try listing()
        XCTAssertThrowsError(try RenameEngine.apply([move("a.jpg", "a2.jpg", id: 1), move("ghost.jpg", "g2.jpg", id: 2)]))
        XCTAssertEqual(try listing(), before)
        XCTAssertEqual(read("a.jpg"), "A")
    }

    // MARK: Injected failures

    private struct Boom: Error {}

    func testAFailureMidwayThroughPhaseTwoRollsBackEveryFile() throws {
        for name in ["a", "b", "c"] { try write("\(name).jpg", name.uppercased()) }
        let before = try listing()
        var calls = 0
        // Phase 1 = 6 moves (3 photos + 3 sidecars); fail on the 9th call, i.e. inside phase 2.
        let failing: RenameEngine.MoveFunction = { from, to in
            calls += 1
            if calls == 9 { throw Boom() }
            try RenameEngine.exclusiveMove(from, to)
        }

        XCTAssertThrowsError(try RenameEngine.apply(
            [move("a.jpg", "a2.jpg", id: 1), move("b.jpg", "b2.jpg", id: 2), move("c.jpg", "c2.jpg", id: 3)], move: failing
        )) { error in
            XCTAssertTrue((error as? RenameEngine.Failure)?.message.contains("nothing was renamed") ?? false, "\(error)")
        }

        XCTAssertGreaterThan(calls, 9) // it really did get into phase 2 and then roll back
        XCTAssertEqual(try listing(), before)
        for name in ["a", "b", "c"] {
            XCTAssertEqual(read("\(name).jpg"), name.uppercased())
            XCTAssertEqual(read("\(name).jpg.photoapp.json"), "sidecar-of-\(name.uppercased())")
        }
    }

    func testEveryPossibleFailurePointRestoresTheOriginalState() throws {
        // Exhaustive: fail on move #k for every k the batch can reach; the folder must always end up untouched.
        let names = ["a", "b"]
        let moves = [move("a.jpg", "b.jpg", id: 1), move("b.jpg", "a.jpg", id: 2)] // a swap: the hardest case
        for failAt in 1...8 {
            for name in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).jpg")) }
            for file in try listing() { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
            for name in names { try write("\(name).jpg", name.uppercased()) }
            let before = try listing()
            var calls = 0
            let failing: RenameEngine.MoveFunction = { from, to in
                calls += 1
                if calls == failAt { throw Boom() }
                try RenameEngine.exclusiveMove(from, to)
            }
            XCTAssertThrowsError(try RenameEngine.apply(moves, move: failing), "failAt \(failAt)")
            XCTAssertEqual(try listing(), before, "failAt \(failAt)")
            XCTAssertEqual(read("a.jpg"), "A", "failAt \(failAt)")
            XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-B", "failAt \(failAt)")
        }
    }

    func testARollbackThatItselfFailsNamesTheStuckFileAndLosesNothing() throws {
        try write("a.jpg", "A", sidecar: false)
        try write("b.jpg", "B", sidecar: false)
        var calls = 0
        let failing: RenameEngine.MoveFunction = { from, to in
            calls += 1
            if calls == 3 { throw Boom() } // forward failure (b's park step is call 2; call 3 is phase 2)
            if to.lastPathComponent == "b.jpg" { throw Boom() } // and putting b back always fails
            try RenameEngine.exclusiveMove(from, to)
        }

        XCTAssertThrowsError(try RenameEngine.apply([move("a.jpg", "a2.jpg", id: 1), move("b.jpg", "b2.jpg", id: 2)], move: failing)) { error in
            let message = (error as? RenameEngine.Failure)?.message ?? ""
            XCTAssertTrue(message.contains("could not be put back"), message)
            XCTAssertTrue(message.contains("b.jpg"), message)
        }
        // Not lost, and identifiable: b's content still exists under a hidden temp name that ENDS with its original name.
        let names = try listing()
        XCTAssertTrue(names.contains { $0.hasPrefix(".photoapp-rename-") && $0.hasSuffix("-b.jpg") }, "\(names)")
        let survivors = try listing().compactMap { read($0) }
        XCTAssertTrue(survivors.contains("B"))
        XCTAssertTrue(survivors.contains("A"))
    }

    // MARK: Destination sidecars, temp names, symlinks (batch-rename commit 3 review)

    /// A photo with no sidecar of its own must never land beside an existing one at its new name —
    /// it would silently adopt those edits. Also what makes Undo (which has no planner) safe.
    func testRefusesToPlaceASidecarlessPhotoNextToAnExistingSidecarAtItsNewName() throws {
        try write("a.jpg", "A", sidecar: false)
        try Data("orphan-edits".utf8).write(to: dir.appendingPathComponent("new.jpg.photoapp.json"))
        let before = try listing()

        XCTAssertThrowsError(try RenameEngine.apply([move("a.jpg", "new.jpg")])) { error in
            XCTAssertTrue((error as? RenameEngine.Failure)?.message.contains("nothing was renamed") ?? false, "\(error)")
        }
        XCTAssertEqual(try listing(), before) // photo put back, nothing else changed
        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(read("new.jpg.photoapp.json"), "orphan-edits") // the orphan is untouched
    }

    func testASidecarThePhotoOwnsMovesWithItEvenWhenItsNewNameLooksTaken() throws {
        // Chain: x -> y, y -> z. y's sidecar is at the destination of x's move ONLY until y has been parked.
        try write("x.jpg", "X")
        try write("y.jpg", "Y")
        XCTAssertNoThrow(try RenameEngine.apply([move("x.jpg", "y.jpg", id: 1), move("y.jpg", "z.jpg", id: 2)]))
        XCTAssertEqual(read("y.jpg.photoapp.json"), "sidecar-of-X")
    }

    func testTempNamesKeepTheOriginalNameAndExtensionAndStayWithin255Bytes() {
        XCTAssertEqual(
            RenameEngine.tempName(token: "ab12cd34", index: 3, original: "IMG_0001.NEF", reserve: 8),
            ".photoapp-rename-ab12cd34-3-IMG_0001.NEF"
        )
        let long = String(repeating: "x", count: 240) + ".jpg"
        let name = RenameEngine.tempName(token: "ab12cd34", index: 12, original: long, reserve: ".sidecar".utf8.count)
        XCTAssertLessThanOrEqual(name.utf8.count + ".sidecar".utf8.count, 255)
        XCTAssertTrue(name.hasSuffix(".jpg")) // the END (extension) is what survives trimming
        let cjk = String(repeating: "日", count: 90) + ".jpg"
        let cjkName = RenameEngine.tempName(token: "ab12cd34", index: 0, original: cjk, reserve: 0)
        XCTAssertLessThanOrEqual(cjkName.utf8.count, 255)
        XCTAssertTrue(cjkName.hasSuffix(".jpg"))
    }

    func testItemExistsSeesADanglingSymlinkThatFileManagerCallsAbsent() throws {
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path)) // follows the link: "absent"
        XCTAssertTrue(RenameEngine.itemExists(link)) // lstat: the link itself is there
        XCTAssertFalse(RenameEngine.itemExists(dir.appendingPathComponent("truly-missing")))
    }

    func testExclusiveMoveRefusesToReplaceADanglingSymlink() throws {
        try write("a.jpg", "A", sidecar: false)
        let link = dir.appendingPathComponent("b.jpg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        XCTAssertThrowsError(try RenameEngine.exclusiveMove(dir.appendingPathComponent("a.jpg"), link))
        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), dir.appendingPathComponent("nowhere").path)
    }
}

