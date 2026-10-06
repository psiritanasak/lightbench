import CoreImage
import XCTest
@testable import PhotoApp

/// `DuplicatesModel` + `CatalogModel.setFlagStatus(_:forPhotoIDs:)` against real (tiny) files, the real scanner and an
/// in-memory catalog. Exact copies are byte-identical files, so these need Vision for nothing but a harmless print.
@MainActor
final class DuplicatesModelTests: XCTestCase {
    private var dir: URL!
    private var database: CatalogDatabase!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicatesModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        database = try CatalogDatabase(inMemory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        database = nil
    }

    private func writeImage(_ name: String, color: CIColor) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    private func importAndFetch(_ urls: [URL]) async throws -> [Photo] {
        _ = try await database.importPhotos(at: urls)
        return try await database.allPhotos().sorted { $0.path < $1.path }
    }

    private func waitUntilIdle(_ model: DuplicatesModel) async throws {
        for _ in 0..<400 where model.isScanning || !model.hasScanned { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isScanning)
    }

    func testScanFindsAnExactCopyAndLeavesTheFilesAndFlagsAlone() async throws {
        let a = try writeImage("a.png", color: CIColor(red: 1, green: 0, blue: 0))
        let b = dir.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: a, to: b)
        let c = try writeImage("c.png", color: CIColor(red: 0, green: 0, blue: 1))
        let before = try [a, b, c].map { try Data(contentsOf: $0) }
        let photos = try await importAndFetch([a, b, c])

        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        XCTAssertTrue(model.isScanning)
        try await waitUntilIdle(model)

        let exact = model.groups.filter { $0.kind == .exact }
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(Set(exact[0].photoIDs), Set(photos.filter { $0.filename != "c.png" }.compactMap(\.id)))
        XCTAssertEqual(try [a, b, c].map { try Data(contentsOf: $0) }, before, "a scan never modifies a photo file")
        let flags = try await database.allPhotos().map(\.flagStatus)
        XCTAssertTrue(flags.allSatisfy { $0 == FlagStatus.none }, "a scan flags nothing")
        XCTAssertTrue(model.summary?.contains("Scanned 3 photos") ?? false)
    }

    func testAnEmptyScopeSaysSoAndASecondScanWhileRunningIsIgnored() async throws {
        let model = DuplicatesModel()
        model.scan(photos: [], database: database)
        XCTAssertEqual(model.statusMessage, "There are no photos to scan.")
        XCTAssertFalse(model.isScanning)

        let both = try await importAndFetch([try writeImage("a.png", color: CIColor(red: 1, green: 0, blue: 0)),
                                             try writeImage("z.png", color: CIColor(red: 0, green: 1, blue: 1))])
        let photos = [both[0]], other = [both[1]]
        model.scan(photos: photos, database: database)
        XCTAssertEqual(model.progress?.total, 1)
        model.scan(photos: photos + other, database: database)   // ignored while running: must not restart or swap the scope
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.progress?.total, 1)
        XCTAssertEqual(model.photosByID.count, 1)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.photosByID.count, 1)
    }

    func testMissingFilesAreSkippedAndReportedNotTreatedAsDuplicates() async throws {
        let a = try writeImage("a.png", color: CIColor(red: 1, green: 0, blue: 0))
        let b = try writeImage("b.png", color: CIColor(red: 0, green: 1, blue: 0))
        let photos = try await importAndFetch([a, b])
        try FileManager.default.removeItem(at: b)
        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        try await waitUntilIdle(model)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.summary?.contains("1 skipped") ?? false, model.summary ?? "nil")
    }

    /// Cancelling right after starting races the (fast) scan, so only the invariant that holds either way is asserted: the
    /// scan ends cleanly, the sheet can show a result, and the summary is honest (cancelled, or complete). The exact
    /// cancelled path is pinned in `DuplicateScannerTests`.
    func testCancelEndsTheScanCleanlyWithAnHonestSummary() async throws {
        var urls: [URL] = []
        for i in 0..<40 { urls.append(try writeImage("p\(i).png", color: CIColor(red: CGFloat(i) / 40, green: 0.5, blue: 0.5))) }
        let photos = try await importAndFetch(urls)
        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        model.cancel()
        try await waitUntilIdle(model)
        XCTAssertFalse(model.isScanning)
        XCTAssertTrue(model.hasScanned)
        XCTAssertTrue(model.summary?.contains("Cancelled") ?? false || model.summary?.contains("Scanned 40") ?? false)
    }

    func testBatchRejectFlagsOnlyTheGivenPhotosLocallyAndInTheDatabase() async throws {
        let urls = [try writeImage("a.png", color: CIColor(red: 1, green: 0, blue: 0)),
                    try writeImage("b.png", color: CIColor(red: 0, green: 1, blue: 0)),
                    try writeImage("c.png", color: CIColor(red: 0, green: 0, blue: 1))]
        _ = try await importAndFetch(urls)
        let catalog = CatalogModel(database: database, defaults: UserDefaults(suiteName: "DuplicatesModelTests-\(UUID().uuidString)")!)
        await catalog.refresh()
        let ids = catalog.photos.filter { $0.path.hasPrefix(dir.path) }.sorted { $0.path < $1.path }.compactMap(\.id)
        let changed = await catalog.setFlagStatus(.rejected, forPhotoIDs: [ids[1], ids[2], 9_999])
        XCTAssertEqual(changed, [ids[1], ids[2]])
        let none = await catalog.setFlagStatus(.rejected, forPhotoIDs: [])
        XCTAssertEqual(none, [], "an empty list is success, not failure")
        XCTAssertEqual(catalog.photos.first { $0.id == ids[1] }?.flagStatus, .rejected, "local state updated")
        XCTAssertEqual(catalog.photos.first { $0.id == ids[0] }?.flagStatus, FlagStatus.none)
        let stored = try await database.allPhotos()
        XCTAssertEqual(stored.first { $0.id == ids[2] }?.flagStatus, .rejected)
        XCTAssertEqual(stored.first { $0.id == ids[0] }?.flagStatus, FlagStatus.none)
    }

    func testNoteRejectedUpdatesTheModelsOwnCopies() async throws {
        let photos = try await importAndFetch([try writeImage("a.png", color: CIColor(red: 1, green: 0, blue: 0))])
        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        try await waitUntilIdle(model)
        let id = try XCTUnwrap(photos[0].id)
        model.noteRejected([id])
        XCTAssertEqual(model.photosByID[id]?.flagStatus, .rejected)
    }

    // MARK: safety of the reject action

    private func scanned(_ names: [(String, CIColor)]) async throws -> (DuplicatesModel, [Photo]) {
        let photos = try await importAndFetch(try names.map { try writeImage($0.0, color: $0.1) })
        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        try await waitUntilIdle(model)
        return (model, photos)
    }

    func testRejectableSkipsPickedAlreadyRejectedAndUnseenPhotos() async throws {
        let red = CIColor(red: 1, green: 0, blue: 0)
        let (model, photos) = try await scanned([("a.png", red), ("b.png", red), ("c.png", red), ("d.png", red)])
        let ids = photos.compactMap(\.id)
        var live = photos
        live[1].flagStatus = .picked
        live[2].flagStatus = .rejected
        model.syncFlags(from: live)
        let plan = model.rejectable(ids + [9_999])
        XCTAssertEqual(plan.reject, [ids[0], ids[3]])
        XCTAssertEqual(plan.leftPicked, 1)
        XCTAssertFalse(plan.reject.contains(9_999), "an id this scan never saw is never rejected unseen")
    }

    func testSyncFlagsPicksUpChangesMadeSinceTheScan() async throws {
        let (model, photos) = try await scanned([("a.png", CIColor(red: 1, green: 0, blue: 0))])
        var live = photos
        live[0].flagStatus = .picked
        live[0].rating = 4
        model.syncFlags(from: live)
        XCTAssertEqual(model.photosByID[photos[0].id!]?.flagStatus, .picked)
        XCTAssertEqual(model.photosByID[photos[0].id!]?.rating, 4)
    }

    func testClearWhileScanningDropsTheOldScansResultsAndAllowsANewScan() async throws {
        var urls: [URL] = []
        for i in 0..<30 { urls.append(try writeImage("p\(i).png", color: CIColor(red: CGFloat(i) / 30, green: 0.3, blue: 0.6))) }
        let photos = try await importAndFetch(urls)
        let model = DuplicatesModel()
        model.scan(photos: photos, database: database)
        model.clear()
        XCTAssertFalse(model.isScanning)
        XCTAssertFalse(model.hasScanned)
        XCTAssertTrue(model.photosByID.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)   // let the dropped scan settle
        XCTAssertFalse(model.hasScanned, "the superseded scan's finish() must not land")
        XCTAssertTrue(model.groups.isEmpty)
        model.scan(photos: Array(photos.prefix(2)), database: database)
        XCTAssertTrue(model.isScanning)
        try await waitUntilIdle(model)
        XCTAssertEqual(model.photosByID.count, 2)
    }
}
