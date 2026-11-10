import XCTest
import GRDB
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// Migration 020, the reader's orientation field, and `PhotoMetadata.displayAspect` (what the justified-rows grid uses instead of decoding).
final class PhotoMetadataOrientationTests: XCTestCase {
    private func row(width: Int?, height: Int?, orientation: Int?) -> PhotoMetadata {
        PhotoMetadata(photoId: 1, fileSize: 1, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision,
                      pixelWidth: width, pixelHeight: height, orientation: orientation, scannedAt: Date())
    }

    func testDisplayAspectSwapsForTheQuarterTurnOrientations() throws {
        XCTAssertEqual(try XCTUnwrap(row(width: 6000, height: 4000, orientation: nil).displayAspect), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(row(width: 6000, height: 4000, orientation: 1).displayAspect), 1.5, accuracy: 1e-9)
        for turned in 5...8 {
            XCTAssertEqual(try XCTUnwrap(row(width: 6000, height: 4000, orientation: turned).displayAspect), 4000.0 / 6000.0, accuracy: 1e-9, "orientation \(turned)")
        }
        for flipped in [2, 3, 4] {
            XCTAssertEqual(try XCTUnwrap(row(width: 6000, height: 4000, orientation: flipped).displayAspect), 1.5, accuracy: 1e-9, "orientation \(flipped) does not turn the picture")
        }
    }

    func testNoUsableSizeGivesNoAspect() {
        XCTAssertNil(row(width: nil, height: 100, orientation: 1).displayAspect)
        XCTAssertNil(row(width: 100, height: nil, orientation: 1).displayAspect)
        XCTAssertNil(row(width: 0, height: 100, orientation: 1).displayAspect)
    }

    func testTheReaderReadsTheOrientationOfARealFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PMO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let fields = try XCTUnwrap(PhotoMetadataReader.read(from: url))
        XCTAssertEqual(fields.orientation, 6)
        XCTAssertEqual(fields.pixelWidth, 120)
        XCTAssertEqual(fields.pixelHeight, 80)
    }

    func testAnOutOfRangeOrientationIsIgnored() {
        XCTAssertNil(PhotoMetadataReader.fields(from: [kCGImagePropertyOrientation: 9]).orientation)
        XCTAssertNil(PhotoMetadataReader.fields(from: [kCGImagePropertyOrientation: 0]).orientation)
        XCTAssertEqual(PhotoMetadataReader.fields(from: [kCGImagePropertyOrientation: 8]).orientation, 8)
    }

    func testMigrationAddsANullableColumnAndRoundTrips() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/pmo/a.jpg")])
        let allPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(allPhotos.first?.id)
        var old = row(width: 100, height: 50, orientation: nil)
        old.photoId = id
        try await db.saveMetadata([old])
        var turned = row(width: 100, height: 50, orientation: 6)
        turned.photoId = id
        try await db.saveMetadata([turned])
        let back = try await db.metadata(forPhotoIDs: [id])[id]
        XCTAssertEqual(back?.orientation, 6)
        XCTAssertEqual(back?.displayAspect ?? 0, 0.5, accuracy: 1e-9)
    }

    /// A row written by an older build (schema up to migration 019, no `orientation` column) must survive migration 020 and read back with orientation nil.
    func testARowWrittenBeforeMigration020SurvivesWithANilOrientation() async throws {
        let file = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let queue = try DatabaseQueue(path: file)
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
            Migration015VirtualCopies.register(in: &migrator)
            Migration016PhotoInfo.register(in: &migrator)
            Migration017PhotoStacks.register(in: &migrator)
            Migration018DeletedPhoto.register(in: &migrator)
            Migration019FaceSmall.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt) VALUES ('/tmp/pmo/old.jpg', 'old.jpg', '2026-01-01 00:00:00')")
                try db.execute(sql: """
                    INSERT INTO photo_metadata (photoId, fileSize, mtime, readerRevision, iso, pixelWidth, pixelHeight, scannedAt)
                    VALUES (1, 10, 5, 1, 400, 6000, 4000, '2026-01-01 00:00:00')
                    """)
            }
        }
        let upgraded = try CatalogDatabase(path: file)
        let back = try await upgraded.metadata(forPhotoIDs: [1])[1]
        let row = try XCTUnwrap(back)
        XCTAssertNil(row.orientation)
        XCTAssertEqual(row.iso, 400)
        XCTAssertEqual(row.pixelWidth, 6000)
        XCTAssertEqual(row.displayAspect ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertFalse(row.isCurrent(fileSize: 10, mtime: 5), "revision 1 is stale, so the scanner re-reads it once")
    }

    func testReaderRevisionTwoMakesOldRowsStale() {
        let old = PhotoMetadata(photoId: 1, fileSize: 10, mtime: 5, readerRevision: 1, scannedAt: Date())
        XCTAssertFalse(old.isCurrent(fileSize: 10, mtime: 5), "a row read before orientation existed is re-read once")
        let fresh = PhotoMetadata(photoId: 1, fileSize: 10, mtime: 5, readerRevision: PhotoMetadata.currentReaderRevision, scannedAt: Date())
        XCTAssertTrue(fresh.isCurrent(fileSize: 10, mtime: 5))
        XCTAssertEqual(PhotoMetadata.currentReaderRevision, 2)
    }
}
