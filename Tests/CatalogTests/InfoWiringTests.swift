import XCTest
@testable import PhotoApp

/// Slice B wired to slice A: export, XMP write and XMP read all reach the real `photo_info` table through the master.
@MainActor
final class InfoWiringTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("InfoWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "InfoWiringTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makePhoto(_ name: String) async throws -> Photo {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        _ = try await db.importPhotos(at: [url])
        await catalog.refresh()
        return try await db.allPhotos().first { $0.filename == name }!
    }

    private func rowCount() async throws -> Int {
        try await db.allInfo().count
    }

    private let sample = PhotoInfo(title: "Title", caption: "Cap", creator: "Jane", copyright: "(c) Jane")

    // MARK: export

    func testExportInfoIsKeyedByTheExportedPhotoAndACopyUsesItsMaster() async throws {
        let master = try await makePhoto("m.jpg")
        let copy = try await db.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        try await db.setInfo(sample, forPhotoIDs: [master.id!], fields: .all)
        await catalog.refresh()
        let map = CatalogModel.exportInfo(for: [copy], infoByPhotoID: try await db.allInfo())
        XCTAssertEqual(map, [copy.id!: sample], "keyed by the copy's own id, holding the master's info")
        XCTAssertTrue(CatalogModel.exportInfo(for: [master], infoByPhotoID: [:]).isEmpty)
        XCTAssertEqual(catalog.infoForExport([master, copy]), [master.id!: sample, copy.id!: sample])
    }

    // MARK: XMP write

    func testWriteSendsTheCatalogsInfoToTheSidecar() async throws {
        let photo = try await makePhoto("w.jpg")
        try await db.setInfo(sample, forPhotoIDs: [photo.id!], fields: .all)
        await catalog.refresh()
        let provided = catalog.infoForExport([photo])
        let outcome = XMPModel.writeAll(photos: [photo], allPaths: [photo.path], keywords: [:], info: provided)
        XCTAssertEqual(outcome.written, 1)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photo.path)) else { return XCTFail("no sidecar") }
        XCTAssertEqual(f.info, sample)
    }

    // MARK: XMP read

    func testReadReplaceUpdatesThePhotoInfoTableAndTheInMemoryMapAndNormalises() async throws {
        let photo = try await makePhoto("r.jpg")
        try await db.setInfo(PhotoInfo(title: "Old", caption: "Keep me", creator: "", copyright: ""), forPhotoIDs: [photo.id!], fields: .all)
        await catalog.refresh()
        let long = String(repeating: "x", count: 600) // title cap is 256
        let changed = try await catalog.applyXMPFields([(photo.id!, XMPLibraryFields(title: long, creator: "Cafe\u{0301}\u{200B}"))], mode: .replace)
        XCTAssertEqual(changed, [photo.id!])
        let stored = try await db.allInfo()[photo.id!]
        XCTAssertEqual(stored?.title.count, 256)
        XCTAssertEqual(stored?.creator, "Caf\u{00E9}", "NFC, zero-width stripped")
        XCTAssertEqual(stored?.caption, "Keep me", "a field the file lacks is kept")
        XCTAssertEqual(catalog.infoByPhotoID[photo.id!], stored, "the in-memory map is refreshed")
    }

    func testFillDefaultsDoesNotOverwriteCatalogValues() async throws {
        let photo = try await makePhoto("f.jpg")
        try await db.setInfo(PhotoInfo(title: "Mine", caption: "", creator: "", copyright: ""), forPhotoIDs: [photo.id!], fields: .all)
        _ = try await catalog.applyXMPFields([(photo.id!, XMPLibraryFields(title: "Theirs", copyright: "(c) Them"))], mode: .fillDefaults)
        let stored = try await db.allInfo()[photo.id!]
        XCTAssertEqual(stored?.title, "Mine")
        XCTAssertEqual(stored?.copyright, "(c) Them")
    }

    func testAVirtualCopyIsNeverGivenARowAndImportsLandOnTheMaster() async throws {
        let master = try await makePhoto("v.jpg")
        let copy = try await db.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        _ = try await catalog.applyXMPFields([(copy.id!, XMPLibraryFields(title: "From file"))], mode: .replace)
        let all = try await db.allInfo()
        XCTAssertEqual(Set(all.keys), [master.id!])
        XCTAssertEqual(all[master.id!]?.title, "From file")
    }

    func testAnAllEmptyResultDeletesTheRowAndNothingCreatesOneForNoText() async throws {
        let photo = try await makePhoto("e.jpg")
        _ = try await catalog.applyXMPFields([(photo.id!, XMPLibraryFields(title: "\u{2060}\u{FEFF}\u{0007}"))], mode: .replace)
        let rows = try await rowCount()
        XCTAssertEqual(rows, 0, "text that normalises to empty creates no row")
    }

    // MARK: source-scan pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testWiringPoints() throws {
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("infoByPhotoID: catalog.infoForExport(photosToExport)"))
        XCTAssertTrue(try source("Sources/UI/CatalogModel.swift").contains("info: CatalogDatabase.xmpInfoAccess"))
        XCTAssertTrue(try source("Sources/UI/XMPModel.swift").contains("catalog.infoForExport"))
    }
}
