import GRDB
import XCTest
@testable import PhotoApp

final class PhotoMetadataTests: XCTestCase {
    private func makeDatabase(photos count: Int = 3) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/md\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id).sorted()
        return (db, ids)
    }

    private func row(_ id: Int64, size: Int64 = 100, mtime: Double = 1_700_000_000, iso: Int? = nil,
                     revision: Int = PhotoMetadata.currentReaderRevision) -> PhotoMetadata {
        PhotoMetadata(photoId: id, fileSize: size, mtime: mtime, readerRevision: revision, captureDate: nil, iso: iso,
                      cameraMake: nil, cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutter: nil,
                      pixelWidth: nil, pixelHeight: nil, scannedAt: Date())
    }

    // MARK: isCurrent

    func testIsCurrentRequiresSameSizeModificationTimeAndReaderRevision() {
        let r = row(1, size: 100, mtime: 1_700_000_000.123)
        XCTAssertTrue(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.123))
        XCTAssertTrue(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.1234), "sub-millisecond noise is tolerated")
        XCTAssertFalse(r.isCurrent(fileSize: 101, mtime: 1_700_000_000.123), "size changed")
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.133), "10 ms later is a different file state")
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 1_600_000_000), "an OLDER restored copy is stale too")
        let old = row(1, size: 100, mtime: 1_700_000_000.123, revision: PhotoMetadata.currentReaderRevision - 1)
        XCTAssertFalse(old.isCurrent(fileSize: 100, mtime: 1_700_000_000.123), "a row from an older reader is stale")
    }

    // MARK: cameraName

    func testCameraNameDoesNotRepeatTheMake() {
        var r = row(1)
        r.cameraMake = "NIKON CORPORATION"; r.cameraModel = "NIKON D610"
        XCTAssertEqual(r.cameraName, "NIKON D610")
        r.cameraMake = "Canon"; r.cameraModel = "Canon EOS R5"
        XCTAssertEqual(r.cameraName, "Canon EOS R5")
        r.cameraMake = "Apple"; r.cameraModel = "iPhone 17 Pro"
        XCTAssertEqual(r.cameraName, "Apple iPhone 17 Pro")
        r.cameraMake = nil; r.cameraModel = "X100V"
        XCTAssertEqual(r.cameraName, "X100V")
        r.cameraMake = "FUJIFILM"; r.cameraModel = nil
        XCTAssertEqual(r.cameraName, "FUJIFILM")
        r.cameraMake = nil
        XCTAssertNil(r.cameraName)
    }

    func testCameraNameEdgeCases() {
        var r = row(1)
        r.cameraMake = "Nikon"; r.cameraModel = "NIKON D610"
        XCTAssertEqual(r.cameraName, "NIKON D610", "make matching ignores case")
        r.cameraMake = "  Canon  "; r.cameraModel = "Canon EOS R5"
        XCTAssertEqual(r.cameraName, "Canon EOS R5", "padding is trimmed")
        r.cameraMake = "Sony"; r.cameraModel = "Sonyx 1"
        XCTAssertEqual(r.cameraName, "Sony Sonyx 1", "a make that is only a PREFIX of the model's first word is kept")
        r.cameraMake = ""; r.cameraModel = "  "
        XCTAssertNil(r.cameraName, "blank strings count as missing")
        r.cameraMake = "  "; r.cameraModel = "Z6"
        XCTAssertEqual(r.cameraName, "Z6")
        r.cameraMake = "Leica"; r.cameraModel = ""
        XCTAssertEqual(r.cameraName, "Leica")
    }

    // MARK: save / fetch

    func testSaveAndFetchRoundTripsEveryField() async throws {
        let (db, ids) = try await makeDatabase(photos: 1)
        var r = row(ids[0], size: 123, mtime: 1_700_000_000.5, iso: 800)
        r.captureDate = 1_678_788_000; r.cameraMake = "NIKON CORPORATION"; r.cameraModel = "NIKON D610"
        r.lens = "50.0 mm f/1.8"; r.focalLength = 50; r.aperture = 1.8; r.shutter = 0.004
        r.pixelWidth = 6016; r.pixelHeight = 4016
        try await db.saveMetadata([r])
        let fetched = try await db.metadata(forPhotoIDs: ids)
        let got = try XCTUnwrap(fetched[ids[0]])
        XCTAssertEqual(got.iso, 800)
        XCTAssertEqual(got.captureDate, 1_678_788_000)
        XCTAssertEqual(got.cameraModel, "NIKON D610")
        XCTAssertEqual(got.lens, "50.0 mm f/1.8")
        XCTAssertEqual(got.focalLength, 50)
        XCTAssertEqual(got.aperture, 1.8)
        XCTAssertEqual(got.shutter, 0.004)
        XCTAssertEqual(got.pixelWidth, 6016)
        XCTAssertEqual(got.pixelHeight, 4016)
        XCTAssertEqual(got.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(got.readerRevision, PhotoMetadata.currentReaderRevision)
        XCTAssertEqual(got.fileSize, 123)
        XCTAssertEqual(got.mtime, 1_700_000_000.5)
    }

    func testARowWithNoCameraDataIsStillStored() async throws {
        let (db, ids) = try await makeDatabase(photos: 1)
        try await db.saveMetadata([row(ids[0])])
        let fetched = try await db.metadata(forPhotoIDs: ids)
        let got = try XCTUnwrap(fetched[ids[0]])
        XCTAssertNil(got.iso)
        XCTAssertNil(got.captureDate)
    }

    func testSaveReplacesTheWholeRow() async throws {
        let (db, ids) = try await makeDatabase(photos: 1)
        try await db.saveMetadata([row(ids[0], size: 100, iso: 100)])
        try await db.saveMetadata([row(ids[0], size: 200, iso: nil)])
        let fetched = try await db.metadata(forPhotoIDs: ids)
        let got = try XCTUnwrap(fetched[ids[0]])
        XCTAssertEqual(got.fileSize, 200)
        XCTAssertNil(got.iso, "replaced, not merged")
    }

    func testSaveSkipsRowsForPhotosThatNoLongerExistInsteadOfAbortingTheBatch() async throws {
        let (db, ids) = try await makeDatabase(photos: 2)
        try await db.saveMetadata([row(ids[0], iso: 1), row(9_999, iso: 2), row(ids[1], iso: 3)])
        let got = try await db.metadata(forPhotoIDs: ids + [9_999])
        XCTAssertEqual(Set(got.keys), Set(ids))
    }

    func testDeletingAPhotoCascadesItsMetadata() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.saveMetadata(ids.map { row($0, iso: 100) })
        try await db.deletePhoto(id: ids[0])
        let all = try await db.allMetadata()
        XCTAssertEqual(Set(all.keys), Set(ids.dropFirst()))
    }

    func testFetchAndSaveWorkAcrossTheIDChunkBoundary() async throws {
        let (db, ids) = try await makeDatabase(photos: 1203)
        try await db.saveMetadata(ids.map { row($0, iso: Int($0)) })
        let got = try await db.metadata(forPhotoIDs: ids)
        XCTAssertEqual(got.count, 1203)
        XCTAssertEqual(got[ids[1202]]?.iso, Int(ids[1202]))
        let all = try await db.allMetadata()
        XCTAssertEqual(all.count, 1203)
    }

    func testAllMetadataIsEmptyForAFreshCatalog() async throws {
        let (db, _) = try await makeDatabase()
        let all = try await db.allMetadata()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: migration

    /// A catalog created through 013 (with an existing photo) upgrades in place and gains the empty metadata table.
    func testMigration014AddsTheMetadataTableToAnExistingCatalog() async throws {
        let path = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
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
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 0, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let empty = try await db.allMetadata()
        XCTAssertTrue(empty.isEmpty)
        try await db.saveMetadata([row(photoID, iso: 400)])
        let saved = try await db.metadata(forPhotoIDs: [photoID])
        XCTAssertEqual(saved[photoID]?.iso, 400)
    }
}
