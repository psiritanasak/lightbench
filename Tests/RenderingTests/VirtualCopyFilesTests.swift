import XCTest
@testable import PhotoApp

/// Virtual copies, file half: per-version sidecar naming, writing a copy's edit file, and the rename engine carrying copies' edit files.
final class VirtualCopyFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VirtualCopyFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func photo(_ url: URL, key: String? = nil) -> Photo {
        Photo(id: 1, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: key == nil ? nil : 99, versionKey: key, versionName: key == nil ? nil : "Copy 1")
    }

    // MARK: Naming

    func testAMastersSidecarNameIsUnchangedAndACopysCarriesItsKey() {
        let url = URL(fileURLWithPath: "/p/IMG_1.jpg")
        XCTAssertEqual(SidecarStore.sidecarURL(for: url).lastPathComponent, "IMG_1.jpg.photoapp.json")
        XCTAssertEqual(SidecarStore.versionedSidecarURL(for: url, versionKey: nil)?.lastPathComponent, "IMG_1.jpg.photoapp.json")
        XCTAssertEqual(SidecarStore.versionedSidecarURL(for: url, versionKey: "0a1b2c3d")?.lastPathComponent, "IMG_1.jpg.0a1b2c3d.photoapp.json")
        XCTAssertEqual(SidecarStore.sidecarURL(for: photo(url))?.lastPathComponent, "IMG_1.jpg.photoapp.json")
        XCTAssertEqual(SidecarStore.sidecarURL(for: photo(url, key: "0a1b2c3d"))?.lastPathComponent, "IMG_1.jpg.0a1b2c3d.photoapp.json")
        XCTAssertEqual(
            SidecarStore.versionSidecarURLs(forMasterAt: url, keys: ["aaaaaaaa", "bbbbbbbb"]).map(\.lastPathComponent),
            ["IMG_1.jpg.aaaaaaaa.photoapp.json", "IMG_1.jpg.bbbbbbbb.photoapp.json"])
    }

    func testVersionKeyValidationAcceptsOnlyEightLowercaseHex() {
        XCTAssertTrue(SidecarStore.isValidVersionKey("0a1b2c3d"))
        for bad in ["", "0A1B2C3D", "0a1b2c3", "0a1b2c3d4", "../../xx", "0a1b2c3g", "a b c d e"] {
            XCTAssertFalse(SidecarStore.isValidVersionKey(bad), bad)
        }
    }

    func testEditKeyIsThePathForAMasterAndDiffersPerVersion() {
        let url = URL(fileURLWithPath: "/p/a.jpg")
        XCTAssertEqual(photo(url).editKey, "/p/a.jpg")
        XCTAssertNotEqual(photo(url, key: "aaaaaaaa").editKey, photo(url, key: "bbbbbbbb").editKey)
        XCTAssertNotEqual(photo(url, key: "aaaaaaaa").editKey, "/p/a.jpg")
    }

    func testEachVersionReadsAndWritesItsOwnFile() throws {
        let url = try file("a.jpg")
        var master = EditState(); master.exposureEV = 1
        var copy = EditState(); copy.exposureEV = -2
        try SidecarStore.write(master, forPhotoAt: url)
        try SidecarStore.write(copy, forPhotoAt: url, versionKey: "aaaaaaaa")
        XCTAssertEqual(SidecarStore.read(forPhotoAt: url), .decoded(master))
        XCTAssertEqual(SidecarStore.read(forPhotoAt: url, versionKey: "aaaaaaaa"), .decoded(copy))
        XCTAssertEqual(SidecarStore.read(forPhotoAt: url, versionKey: "bbbbbbbb"), .missing, "another version never reads this one's file")
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo(url)).exposureEV, 1)
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo(url, key: "aaaaaaaa")).exposureEV, -2, "export and thumbnails read the version's edits")
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo(url, key: "bbbbbbbb")), .identity)
    }

    func testVersionKeysOnDiskAreFoundAndMalformedNamesIgnored() throws {
        let url = try file("a.jpg")
        _ = try file("a.jpg.photoapp.json")
        _ = try file("a.jpg.bbbbbbbb.photoapp.json")
        _ = try file("a.jpg.aaaaaaaa.photoapp.json")
        _ = try file("a.jpg.notakey.photoapp.json")
        _ = try file("b.jpg.cccccccc.photoapp.json")
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: url), ["aaaaaaaa", "bbbbbbbb"])
    }

    func testAMalformedKeyIsRefusedNeverRepairedIntoAnotherVersionsKey() throws {
        let url = try file("a.jpg")
        for bad in ["aaaaaaaaZ", "AAAAAAAA", "aaaaaaa", "aaaaaaaa/", "../../x"] {
            XCTAssertNil(SidecarStore.versionedSidecarURL(for: url, versionKey: bad), bad)
            XCTAssertEqual(SidecarStore.read(forPhotoAt: url, versionKey: bad), .undecodable, "never read: \(bad)")
            XCTAssertThrowsError(try SidecarStore.write(EditState(), forPhotoAt: url, versionKey: bad), bad)
            XCTAssertNil(SidecarStore.readHistory(forPhotoAt: url, versionKey: bad))
        }
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: url), [], "nothing was written for a bad key")
    }

    func testAnUnreadableSourceEditFileIsRefusedEvenWithLiveEdits() throws {
        let url = try file("a.jpg")
        let broken = try file("a.jpg.photoapp.json", "{not json")
        var live = EditState(); live.exposureEV = 2
        XCTAssertThrowsError(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa", liveState: live)) {
            XCTAssertEqual($0 as? VirtualCopyFiles.Failure, .sourceEditsUnreadable)
        }
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: url), [])
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{not json", "the source's file is left exactly as it was")
        // With a readable (or absent) file the live state wins.
        try FileManager.default.removeItem(at: broken)
        XCTAssertNotNil(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa", liveState: live))
    }

    // MARK: Writing a copy's edit file

    func testACopyStartsWithTheSourceEditsAndNoHistory() throws {
        let url = try file("a.jpg")
        var state = EditState(); state.exposureEV = 0.5
        try SidecarStore.write(state, historyObject: ["entries": []], forPhotoAt: url)
        let written = try XCTUnwrap(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa"))
        XCTAssertEqual(written.lastPathComponent, "a.jpg.aaaaaaaa.photoapp.json")
        XCTAssertEqual(SidecarStore.read(forPhotoAt: url, versionKey: "aaaaaaaa"), .decoded(state))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any]
        XCTAssertNil(raw?[HistoryArchive.sidecarKey], "the copy does not inherit the source's undo history")
        // The master's own file is untouched (its history object is still there).
        let masterRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: SidecarStore.sidecarURL(for: url))) as? [String: Any]
        XCTAssertNotNil(masterRaw?[HistoryArchive.sidecarKey])
    }

    func testACopyOfACopyReadsTheCopysEdits() throws {
        let url = try file("a.jpg")
        var master = EditState(); master.exposureEV = 1
        var first = EditState(); first.exposureEV = 3
        try SidecarStore.write(master, forPhotoAt: url)
        try SidecarStore.write(first, forPhotoAt: url, versionKey: "aaaaaaaa")
        try VirtualCopyFiles.writeVersionSidecar(from: photo(url, key: "aaaaaaaa"), versionKey: "bbbbbbbb")
        XCTAssertEqual(SidecarStore.read(forPhotoAt: url, versionKey: "bbbbbbbb"), .decoded(first))
    }

    func testAnUneditedSourceWritesNoFile() throws {
        let url = try file("a.jpg")
        XCTAssertNil(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa"))
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: url), [])
    }

    func testAnExistingVersionFileIsNeverOverwritten() throws {
        let url = try file("a.jpg")
        var state = EditState(); state.exposureEV = 2
        try SidecarStore.write(state, forPhotoAt: url)
        let existing = try file("a.jpg.aaaaaaaa.photoapp.json", "PRECIOUS")
        XCTAssertThrowsError(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa")) {
            XCTAssertEqual($0 as? VirtualCopyFiles.Failure, .versionFileExists)
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "PRECIOUS")
    }

    func testAnUnreadableSourceEditFileIsRefusedNotCopiedAsUnedited() throws {
        let url = try file("a.jpg")
        _ = try file("a.jpg.photoapp.json", "{not json")
        XCTAssertThrowsError(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa")) {
            XCTAssertEqual($0 as? VirtualCopyFiles.Failure, .sourceEditsUnreadable)
        }
        XCTAssertEqual(SidecarStore.versionSidecarKeys(forPhotoAt: url), [])
    }

    func testACopyCannotBeCreatedFromAMissingFile() {
        let url = dir.appendingPathComponent("gone.jpg")
        XCTAssertThrowsError(try VirtualCopyFiles.writeVersionSidecar(from: photo(url), versionKey: "aaaaaaaa")) {
            XCTAssertEqual($0 as? VirtualCopyFiles.Failure, .fileMissing)
        }
    }

    func testNewVersionKeyAvoidsExistingFilesAndGivesUpAfterManyCollisions() throws {
        let url = try file("a.jpg")
        _ = try file("a.jpg.00000001.photoapp.json")
        var values: [UInt32] = [1, 2]
        let key = VirtualCopyFiles.newVersionKey(forPhotoAt: url, random: { values.removeFirst() })
        XCTAssertEqual(key, "00000002", "the first key's edit file exists, so the next is used")
        XCTAssertNil(VirtualCopyFiles.newVersionKey(forPhotoAt: url, random: { 1 }), "a stuck generator ends in nil, not a reused key")
        XCTAssertTrue(SidecarStore.isValidVersionKey(try XCTUnwrap(VirtualCopyFiles.newVersionKey(forPhotoAt: url))))
    }

    // MARK: Rename carries the copies' edit files

    func testRenameMovesVersionEditFilesWithTheSharedFile() throws {
        let url = try file("a.jpg")
        _ = try file("a.jpg.photoapp.json", "M")
        _ = try file("a.jpg.aaaaaaaa.photoapp.json", "A")
        _ = try file("a.jpg.bbbbbbbb.photoapp.json", "B")
        let target = dir.appendingPathComponent("z.jpg")
        try RenameEngine.apply([RenameMove(photoID: 1, oldPath: url.path, newPath: target.path)])
        let fm = FileManager.default
        for name in ["z.jpg", "z.jpg.photoapp.json", "z.jpg.aaaaaaaa.photoapp.json", "z.jpg.bbbbbbbb.photoapp.json"] {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        for name in ["a.jpg", "a.jpg.photoapp.json", "a.jpg.aaaaaaaa.photoapp.json", "a.jpg.bbbbbbbb.photoapp.json"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("z.jpg.aaaaaaaa.photoapp.json"), encoding: .utf8), "A")
        // Undo (the inverse move) brings every one back.
        try RenameEngine.apply([RenameMove(photoID: 1, oldPath: target.path, newPath: url.path)])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.jpg.bbbbbbbb.photoapp.json"), encoding: .utf8), "B")
    }

    func testAFailedRenameRestoresTheVersionEditFilesToo() throws {
        let url = try file("a.jpg")
        _ = try file("a.jpg.aaaaaaaa.photoapp.json", "A")
        let target = dir.appendingPathComponent("z.jpg")
        var calls = 0
        let failing: RenameEngine.MoveFunction = { from, to in
            calls += 1
            if calls == 4 { throw POSIXError(.EIO) } // fail midway: the photo and the version file are parked, the final move fails
            try RenameEngine.exclusiveMove(from, to)
        }
        XCTAssertThrowsError(try RenameEngine.apply([RenameMove(photoID: 1, oldPath: url.path, newPath: target.path)], move: failing))
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.jpg.aaaaaaaa.photoapp.json"), encoding: .utf8), "A")
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("z.jpg.aaaaaaaa.photoapp.json").path))
    }
}
