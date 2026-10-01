import XCTest
@testable import PhotoApp

final class LookStoreTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!
    private var library: LookLibrary!
    private var store: LookStore!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LookStoreTests-\(UUID().uuidString)")
        directory = root.appendingPathComponent("Looks")
        sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        library = LookLibrary()
        store = LookStore(directory: directory, library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func cubeText(size: Int = 2, title: String? = nil, tint: Float = 0) -> String {
        var lines = title.map { ["TITLE \"\($0)\""] } ?? []
        lines.append("LUT_3D_SIZE \(size)")
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let d = Float(size - 1)
            lines.append("\(min(Float(r) / d + tint, 1)) \(Float(g) / d) \(Float(b) / d)")
        } } }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private func write(_ text: String, as name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func storedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: Import

    func testImportStoresRegistersAndNamesContentAddressed() throws {
        let url = try write(cubeText(), as: "My Film Look.cube")
        let look = try store.importCube(from: url)
        XCTAssertEqual(look.name, "My Film Look")
        XCTAssertTrue(look.id.hasPrefix("user:"))
        XCTAssertEqual(storedFiles().count, 1)
        XCTAssertEqual(look.id, "user:" + LookStore.hashPrefix(of: Data(cubeText().utf8)), "the id is the hash only")
        XCTAssertEqual(storedFiles().first, "\(look.id.dropFirst(5))-My Film Look.cube", "the name lives in the file name only")
        XCTAssertEqual(library.cube(for: look.id)?.size, 2)
        XCTAssertEqual(library.displayName(for: look.id), "My Film Look")
    }

    func testReimportingIdenticalBytesIsIdempotentEvenUnderAnotherFileName() throws {
        let first = try store.importCube(from: try write(cubeText(), as: "a.cube"))
        let second = try store.importCube(from: try write(cubeText(), as: "completely different.cube"))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(storedFiles().count, 1)
        XCTAssertEqual(library.userLooks.count, 1)
    }

    func testSameBytesGetTheSameIDOnAnotherMacWhateverTheFileWasCalled() throws {
        let macA = try store.importCube(from: try write(cubeText(), as: "Film.cube"))
        let otherStore = LookStore(directory: directory.deletingLastPathComponent().appendingPathComponent("OtherMac"), library: LookLibrary())
        let macB = try otherStore.importCube(from: try write(cubeText(), as: "film_v2.cube"))
        XCTAssertEqual(macA.id, macB.id, "a sidecar naming this look must resolve on both machines")
        XCTAssertNotEqual(macA.name, macB.name, "only the display name differs")
    }

    func testRemoveThenReimportUnderAnotherNameRestoresTheSameID() throws {
        let original = try store.importCube(from: try write(cubeText(), as: "first.cube"))
        try store.remove(id: original.id)
        let again = try store.importCube(from: try write(cubeText(), as: "second.cube"))
        XCTAssertEqual(original.id, again.id, "photos that used the look recover when it is imported again")
    }

    func testDifferentBytesMakeADifferentLook() throws {
        let a = try store.importCube(from: try write(cubeText(tint: 0), as: "same.cube"))
        let b = try store.importCube(from: try write(cubeText(tint: 0.2), as: "same.cube"))
        XCTAssertNotEqual(a.id, b.id, "an edited file must be a NEW look, not silently change old edits")
        XCTAssertEqual(storedFiles().count, 2)
    }

    func testTitleLineBecomesTheDisplayName() throws {
        let look = try store.importCube(from: try write(cubeText(title: "Golden Hour!"), as: "x.cube"))
        XCTAssertEqual(look.name, "Golden Hour")
    }

    func testTitleWithADotKeepsItsFullName() throws {
        let look = try store.importCube(from: try write(cubeText(title: "Fuji v1.2"), as: "x.cube"))
        XCTAssertEqual(look.name, "Fuji v12", "dots are not in the allowed set, but the text after one must not be dropped as an 'extension'")
        XCTAssertEqual(LookStore.displayName(fromTitle: "a.b"), "ab")
    }

    func testRemoveNeverBuildsAPathFromTheID() throws {
        _ = try store.importCube(from: try write(cubeText(), as: "keep.cube"))
        try store.remove(id: "user:../../keep")
        try store.remove(id: "user:/etc/passwd")
        XCTAssertEqual(storedFiles().count, 1)
    }

    func testInvalidFilesThrowAndWriteNothing() throws {
        for (label, text) in [("empty", ""), ("1D", "LUT_1D_SIZE 4\n0 0 0\n"), ("short", "LUT_3D_SIZE 2\n0 0 0\n")] {
            XCTAssertThrowsError(try store.importCube(from: try write(text, as: "bad.cube")), label)
        }
        XCTAssertThrowsError(try store.importCube(from: sources.appendingPathComponent("missing.cube")))
        XCTAssertEqual(storedFiles(), [])
        XCTAssertTrue(library.userLooks.isEmpty)
    }

    func testOversizedFileIsRefused() throws {
        let url = sources.appendingPathComponent("huge.cube")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CubeLUTParser.maximumBytes + 1)) // sparse: nothing is actually written; the pre-read size guard itself is unobservable here
        try handle.close()
        XCTAssertThrowsError(try store.importCube(from: url)) { XCTAssertEqual($0 as? LookStore.StoreError, .tooLarge) }
    }

    func testUTF8ByteOrderMarkFilesImport() throws {
        let url = sources.appendingPathComponent("bom.cube")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(cubeText().utf8)).write(to: url)
        XCTAssertEqual(try store.importCube(from: url).name, "bom")
    }

    // MARK: Load / remove

    func testLoadAllRegistersStoredLooksInAFreshLibraryAndSkipsJunk() throws {
        let look = try store.importCube(from: try write(cubeText(), as: "kept.cube"))
        try Data("junk".utf8).write(to: directory.appendingPathComponent("0123456789ab-corrupt.cube"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data(cubeText().utf8).write(to: directory.appendingPathComponent("not-our-naming.cube"))
        // Renamed/edited file: valid text but its bytes do not hash to the name's prefix.
        try Data(cubeText(tint: 0.4).utf8).write(to: directory.appendingPathComponent("aaaaaaaaaaaa-liar.cube"))
        let fresh = LookLibrary()
        let skipped = LookStore(directory: directory, library: fresh).loadAll()
        XCTAssertEqual(fresh.userLooks.map(\.id), [look.id])
        XCTAssertEqual(Set(skipped), ["0123456789ab-corrupt.cube", "not-our-naming.cube", "aaaaaaaaaaaa-liar.cube"])
    }

    func testRemoveDeletesTheFileAndUnregisters() throws {
        let look = try store.importCube(from: try write(cubeText(), as: "gone.cube"))
        try store.remove(id: look.id)
        XCTAssertEqual(storedFiles(), [])
        XCTAssertNil(library.cube(for: look.id))
        try store.remove(id: look.id) // already gone: not an error
        try store.remove(id: "builtin:noir") // not ours: ignored
        XCTAssertNotNil(BuiltInLooks.look(id: "builtin:noir"))
    }

    func testLoadAllOnAMissingDirectoryIsEmptyNotAnError() {
        XCTAssertEqual(store.loadAll(), [])
    }

    // MARK: Naming helpers + isolation

    func testDisplayNameSanitizing() {
        XCTAssertEqual(LookStore.displayName(forFileName: "Teal & Orange (v2).cube"), "Teal  Orange v2")
        XCTAssertEqual(LookStore.displayName(forFileName: "../../etc/passwd.cube"), "etcpasswd")
        XCTAssertEqual(LookStore.displayName(forFileName: "....cube"), "Look")
        XCTAssertEqual(LookStore.displayName(forFileName: String(repeating: "a", count: 200) + ".cube").count, 60)
    }

    func testStoredFileNameParsing() {
        XCTAssertEqual(LookStore.parse(fileName: "0123456789ab-My Look.cube")?.name, "My Look")
        XCTAssertNil(LookStore.parse(fileName: "0123456789AB-upper.cube"))
        XCTAssertNil(LookStore.parse(fileName: "short-x.cube"))
        XCTAssertNil(LookStore.parse(fileName: "0123456789ab-x.txt"))
    }

    func testDefaultDirectoryNeverTouchesApplicationSupportUnderXCTest() {
        let underTest = LookStore.defaultDirectory(isRunningUnderXCTest: true)
        XCTAssertTrue(underTest.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let real = LookStore.defaultDirectory(isRunningUnderXCTest: false)
        XCTAssertTrue(real.path.hasSuffix("PhotoApp/Looks"))
        XCTAssertTrue(LookStore.shared.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "the shared store, created inside this test process, must be the temp one")
    }
}
