import GRDB
import XCTest
@testable import PhotoApp

final class PhotoFingerprintTests: XCTestCase {
    private func makeDatabase(photos count: Int = 3) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/fp\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id).sorted()
        return (db, ids)
    }

    private func row(_ id: Int64, size: Int64 = 100, mtime: Double = 1_700_000_000, hash: String? = nil, print: Data? = nil) -> PhotoFingerprint {
        PhotoFingerprint(photoId: id, fileSize: size, mtime: mtime, contentHash: hash, featurePrint: print,
                         featurePrintRevision: print == nil ? nil : 2, computedAt: Date())
    }

    // MARK: isCurrent

    func testIsCurrentRequiresTheSameSizeAndModificationTime() {
        let r = row(1, size: 100, mtime: 1_700_000_000.123)
        XCTAssertTrue(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.123))
        XCTAssertTrue(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.1234), "sub-millisecond noise is tolerated")
        XCTAssertFalse(r.isCurrent(fileSize: 101, mtime: 1_700_000_000.123), "size changed")
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 1_700_000_000.133), "10 ms later is a different file state")
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 1_700_000_001), "touched/replaced file")
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 1_600_000_000), "an OLDER restored copy is stale too")
    }

    // MARK: save / fetch

    func testSaveThenFetchRoundTripsBothPayloads() async throws {
        let (db, ids) = try await makeDatabase()
        let print = Data((0..<3072).map { UInt8($0 % 251) })
        try await db.saveFingerprints([row(ids[0], hash: "abc", print: print), row(ids[1])])
        let got = try await db.fingerprints(forPhotoIDs: ids)
        XCTAssertEqual(got[ids[0]]?.contentHash, "abc")
        XCTAssertEqual(got[ids[0]]?.featurePrint, print)
        XCTAssertEqual(got[ids[0]]?.featurePrintRevision, 2)
        XCTAssertNil(got[ids[1]]?.contentHash)
        XCTAssertNil(got[ids[1]]?.featurePrint)
        XCTAssertNil(got[ids[2]], "no row for a photo that was never fingerprinted")
    }

    func testIsCurrentHoldsOnARowReadBackFromTheDatabase() async throws {
        let (db, ids) = try await makeDatabase(photos: 1)
        let mtime = 1_700_000_123.456789
        try await db.saveFingerprints([row(ids[0], size: 4_242, mtime: mtime, hash: "h")])
        let fetched = try await db.fingerprints(forPhotoIDs: ids)
        let got = try XCTUnwrap(fetched[ids[0]])
        XCTAssertTrue(got.isCurrent(fileSize: 4_242, mtime: mtime), "the stored mtime survives the round trip")
        XCTAssertFalse(got.isCurrent(fileSize: 4_242, mtime: mtime + 0.01))
    }

    func testSaveReplacesAnExistingRowWholeSoTheCallerOwnsTheMerge() async throws {
        let (db, ids) = try await makeDatabase(photos: 1)
        try await db.saveFingerprints([row(ids[0], hash: "old", print: Data([1, 2, 3]))])
        try await db.saveFingerprints([row(ids[0], size: 200, hash: "new")])
        let got = try await db.fingerprints(forPhotoIDs: ids)[ids[0]]
        XCTAssertEqual(got?.contentHash, "new")
        XCTAssertEqual(got?.fileSize, 200)
        XCTAssertNil(got?.featurePrint, "replaced, not merged")
    }

    func testSaveSkipsRowsForPhotosThatNoLongerExistInsteadOfAbortingTheBatch() async throws {
        let (db, ids) = try await makeDatabase(photos: 2)
        try await db.saveFingerprints([row(ids[0], hash: "a"), row(9_999, hash: "ghost"), row(ids[1], hash: "b")])
        let got = try await db.fingerprints(forPhotoIDs: ids + [9_999])
        XCTAssertEqual(Set(got.keys), Set(ids))
    }

    func testDeletingAPhotoCascadesItsFingerprint() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.saveFingerprints(ids.map { row($0, hash: "h") })
        try await db.deletePhoto(id: ids[0])
        let got = try await db.fingerprints(forPhotoIDs: ids)
        XCTAssertEqual(Set(got.keys), Set(ids.dropFirst()))
    }

    func testFetchAndSaveWorkAcrossTheIDChunkBoundary() async throws {
        let (db, ids) = try await makeDatabase(photos: 1203)
        try await db.saveFingerprints(ids.map { row($0, hash: "h\($0)") })
        let got = try await db.fingerprints(forPhotoIDs: ids)
        XCTAssertEqual(got.count, 1203)
        XCTAssertEqual(got[ids[1202]]?.contentHash, "h\(ids[1202])")
    }

    // MARK: batch flag

    func testBatchFlagUpdatesOnlyTheGivenPhotosAndReportsTheOnesThatExisted() async throws {
        let (db, ids) = try await makeDatabase()
        let changed = try await db.setFlagStatus(.rejected, forPhotoIDs: [ids[0], 9_999, ids[2]])
        XCTAssertEqual(changed, [ids[0], ids[2]], "the stale id is neither written nor reported")
        let all = try await db.allPhotos()
        let flags = Dictionary(uniqueKeysWithValues: all.map { ($0.id!, $0.flagStatus) })
        XCTAssertEqual(flags[ids[0]], .rejected)
        XCTAssertEqual(flags[ids[1]], FlagStatus.none)
        XCTAssertEqual(flags[ids[2]], .rejected)
    }

    func testBatchFlagWorksAcrossTheIDChunkBoundaryAndForAnEmptyList() async throws {
        let (db, ids) = try await makeDatabase(photos: 1203)
        let none = try await db.setFlagStatus(.picked, forPhotoIDs: [])
        XCTAssertTrue(none.isEmpty)
        let changed = try await db.setFlagStatus(.picked, forPhotoIDs: ids)
        XCTAssertEqual(changed.count, 1203)
        let picked = try await db.allPhotos().filter { $0.flagStatus == .picked }.count
        XCTAssertEqual(picked, 1203)
    }

    // MARK: migration

    /// A catalog created through 011 (with an existing photo) upgrades in place and gains the empty fingerprint table.
    func testMigration012AddsTheFingerprintTableToAnExistingCatalog() async throws {
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
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 0, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let empty = try await db.fingerprints(forPhotoIDs: [photoID])
        XCTAssertTrue(empty.isEmpty)
        try await db.saveFingerprints([row(photoID, hash: "x")])
        let saved = try await db.fingerprints(forPhotoIDs: [photoID])
        XCTAssertEqual(saved[photoID]?.contentHash, "x")
    }
}
