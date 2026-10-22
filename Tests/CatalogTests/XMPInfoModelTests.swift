import XCTest
import GRDB
@testable import PhotoApp

@MainActor
private final class GrantingAccess: SidecarFolderAccessing {
    var grant: URL?
    func resolvedURL(for folder: URL) -> URL? { nil }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
        if let grant { return .granted(grant) }
        return .declined
    }
}

/// An in-memory stand-in for slice A's `photo_info` table, reached through the `XMPInfoAccess` seam.
private final class InfoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Int64: PhotoInfo] = [:]
    private(set) var storeCalls = 0
    subscript(id: Int64) -> PhotoInfo? {
        get { lock.lock(); defer { lock.unlock() }; return rows[id] }
        set { lock.lock(); defer { lock.unlock() }; rows[id] = newValue }
    }
    var access: XMPInfoAccess {
        XMPInfoAccess(
            load: { [self] _, id in self[id] ?? PhotoInfo() },
            store: { [self] _, id, info in lock.lock(); storeCalls += 1; lock.unlock(); self[id] = info }
        )
    }
}

@MainActor
final class XMPInfoModelTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var access: GrantingAccess!
    private var model: XMPModel!
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("XMPInfoModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "XMPInfoModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        access = GrantingAccess()
        model = XMPModel(folderAccess: access)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makePhotos(_ names: [String]) async throws -> [Photo] {
        let urls = names.map { dir.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        _ = try await db.importPhotos(at: urls)
        await catalog.refresh()
        return try await db.allPhotos().filter { names.contains($0.filename) }.sorted { $0.filename < $1.filename }
    }

    private func run(_ kind: XMPModel.Kind, _ photos: [Photo]) async throws {
        model.request(kind, photos: photos, catalog: catalog)
        let request = try XCTUnwrap(model.pending)
        model.confirm(request, catalog: catalog)
        for _ in 0..<2000 where model.isWorking || catalog.xmpBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isWorking)
    }

    private let sample = PhotoInfo(title: "Title", caption: "Caption\nline 2", creator: "Jane", copyright: "(c) Jane")

    // MARK: libraryFields

    func testLibraryFieldsMapsInfoAndNeverSendsAnEmptyStringForAnEmptyField() {
        let photo = Photo(id: 1, path: "/tmp/a.jpg", filename: "a.jpg", fileSize: 1, importedAt: Date())
        XCTAssertNil(XMPModel.libraryFields(for: photo, keywords: []).info)
        let partial = XMPModel.libraryFields(for: photo, keywords: [], info: PhotoInfo(title: "T", caption: "", creator: "", copyright: "R"))
        XCTAssertEqual(partial.title, "T")
        XCTAssertNil(partial.caption)
        XCTAssertNil(partial.creator)
        XCTAssertEqual(partial.copyright, "R")
        XCTAssertNil(XMPModel.libraryFields(for: photo, keywords: [], info: PhotoInfo()).info)
    }

    // MARK: write

    func testWriteSendsTheProvidedInfoAndWithoutAProviderWritesNone() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        access.grant = dir
        try await db.setRating(3, for: photos[0].id!)
        try await db.setRating(3, for: photos[1].id!)
        let id = try XCTUnwrap(photos[0].id)
        model.infoProvider = { [sample] chosen in Dictionary(uniqueKeysWithValues: chosen.compactMap { $0.id == id ? ($0.id!, sample) : nil }) }
        try await run(.write, try await db.allPhotos().sorted { $0.filename < $1.filename })
        guard case .decoded(let a) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[0].path)),
              case .decoded(let b) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[1].path)) else { return XCTFail("missing sidecars") }
        XCTAssertEqual(a.info, sample)
        XCTAssertNil(b.info, "a photo with no Library info gets no info tags")
    }

    func testWriteWithTheDefaultProviderLeavesAnExistingFileTextAlone() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let url = URL(fileURLWithPath: photos[0].path)
        try XMPSidecarStore.write(XMPLibraryFields(title: "From elsewhere", copyright: "(c) Else"), forPhotoAt: url)
        access.grant = dir
        try await db.setRating(2, for: photos[0].id!)
        try await run(.write, try await db.allPhotos())
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.title, "From elsewhere")
        XCTAssertEqual(f.copyright, "(c) Else")
        XCTAssertEqual(f.rating, 2)
    }

    // MARK: database seam

    private func makeDatabase() async throws -> (CatalogDatabase, [Int64]) {
        let database = try CatalogDatabase(inMemory: true)
        _ = try await database.importPhotos(at: (0..<2).map { URL(fileURLWithPath: "/tmp/info\($0).jpg") })
        return (database, try await database.allPhotos().compactMap(\.id).sorted())
    }

    func testApplyStoresInfoThroughTheSeamAndReportsTheRowChangedOnlyForInfo() async throws {
        let (database, ids) = try await makeDatabase()
        let box = InfoBox()
        box[ids[1]] = PhotoInfo(title: "Same", caption: "", creator: "", copyright: "")
        let changed = try await database.applyLibraryFields([
            (ids[0], XMPLibraryFields(info: sample)),
            (ids[1], XMPLibraryFields(title: "Same", caption: "New caption")),
        ], mode: .replace, info: box.access)
        XCTAssertEqual(changed, Set(ids))
        XCTAssertEqual(box[ids[0]], sample)
        XCTAssertEqual(box[ids[1]], PhotoInfo(title: "Same", caption: "New caption", creator: "", copyright: ""), "unmentioned fields are kept")
        let again = try await database.applyLibraryFields([(ids[0], XMPLibraryFields(info: sample))], mode: .replace, info: box.access)
        XCTAssertTrue(again.isEmpty, "repeating a read changes nothing")
        XCTAssertEqual(box.storeCalls, 2)
    }

    func testFillDefaultsKeepsExistingInfoAndWithoutTheSeamInfoInFilesIsIgnored() async throws {
        let (database, ids) = try await makeDatabase()
        let box = InfoBox()
        box[ids[0]] = PhotoInfo(title: "Mine", caption: "", creator: "", copyright: "")
        let changed = try await database.applyLibraryFields([(ids[0], XMPLibraryFields(title: "Theirs", copyright: "(c) Them"))],
                                                            mode: .fillDefaults, info: box.access)
        XCTAssertEqual(changed, [ids[0]])
        XCTAssertEqual(box[ids[0]], PhotoInfo(title: "Mine", caption: "", creator: "", copyright: "(c) Them"))

        let ignored = try await database.applyLibraryFields([(ids[1], XMPLibraryFields(info: sample))], mode: .replace)
        XCTAssertTrue(ignored.isEmpty, "no seam: the file's text is not applied and does not count as a change")
        XCTAssertNil(box[ids[1]])
    }

    // MARK: confirmation text

    func testConfirmationTextNamesTheInfoFields() {
        let photo = Photo(id: 1, path: "/tmp/a.jpg", filename: "a.jpg", fileSize: 1, importedAt: Date())
        for kind in [XMPModel.Kind.write, .read] {
            let text = XMPModel.confirmationMessage(.init(kind: kind, photos: [photo]))
            XCTAssertTrue(text.contains("title, caption, creator and copyright"), "\(kind): \(text)")
        }
    }
}
