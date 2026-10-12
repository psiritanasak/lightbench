import XCTest
@testable import PhotoApp

final class MetadataScannerTests: XCTestCase {
    /// Thread-safe counter for the injected closures.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeDatabase(photos count: Int = 3) async throws -> (CatalogDatabase, [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/ms\($0).jpg") })
        return (db, try await db.allPhotos().sorted { ($0.id ?? 0) < ($1.id ?? 0) })
    }

    private func environment(
        sizes: [String: Int64] = [:], defaultSize: Int64? = 100, mtime: Double = 1_700_000_000,
        reads: Counter = Counter(), iso: Int = 400
    ) -> MetadataScanner.Environment {
        .init(
            stat: { path in (sizes[path] ?? defaultSize).map { ($0, mtime) } },
            read: { _ in
                reads.bump()
                var f = PhotoMetadataReader.Fields(); f.iso = iso
                return f
            }
        )
    }

    func testScansEveryPhotoAndStoresRowsWithTheStatValues() async throws {
        let (db, photos) = try await makeDatabase()
        let result = try await MetadataScanner.scan(photos: photos, database: db, environment: environment(defaultSize: 123, iso: 800))
        XCTAssertEqual(result, .init(scanned: 3, reused: 0, skipped: 0, wasCancelled: false))
        let rows = try await db.allMetadata()
        XCTAssertEqual(rows.count, 3)
        let first = try XCTUnwrap(rows[photos[0].id!])
        XCTAssertEqual(first.iso, 800)
        XCTAssertEqual(first.fileSize, 123)
        XCTAssertEqual(first.mtime, 1_700_000_000)
        XCTAssertEqual(first.readerRevision, PhotoMetadata.currentReaderRevision)
    }

    func testASecondScanReusesCurrentRowsWithoutReadingAnyFile() async throws {
        let (db, photos) = try await makeDatabase()
        _ = try await MetadataScanner.scan(photos: photos, database: db, environment: environment())
        let reads = Counter()
        let again = try await MetadataScanner.scan(photos: photos, database: db, environment: environment(reads: reads))
        XCTAssertEqual(again, .init(scanned: 0, reused: 3, skipped: 0, wasCancelled: false))
        XCTAssertEqual(reads.value, 0)
    }

    func testAChangedSizeOrModificationTimeIsReReadAndOnlyThatPhoto() async throws {
        let (db, photos) = try await makeDatabase()
        _ = try await MetadataScanner.scan(photos: photos, database: db, environment: environment())
        let reads = Counter()
        let bigger = try await MetadataScanner.scan(
            photos: photos, database: db,
            environment: environment(sizes: [photos[1].path: 999], reads: reads, iso: 100)
        )
        XCTAssertEqual(bigger.scanned, 1)
        XCTAssertEqual(bigger.reused, 2)
        XCTAssertEqual(reads.value, 1)
        let rows = try await db.allMetadata()
        XCTAssertEqual(rows[photos[1].id!]?.iso, 100)
        XCTAssertEqual(rows[photos[1].id!]?.fileSize, 999)
        XCTAssertEqual(rows[photos[0].id!]?.iso, 400, "untouched rows keep their data")
        let touched = try await MetadataScanner.scan(photos: photos, database: db, environment: environment(sizes: [photos[1].path: 999], mtime: 1_700_000_500))
        XCTAssertEqual(touched.scanned, 3, "a new modification time invalidates every row")
    }

    func testUnreadableFilesAreSkippedAndNeverStored() async throws {
        let (db, photos) = try await makeDatabase()
        let env = MetadataScanner.Environment(
            stat: { path in path == photos[0].path ? nil : (100, 1) }, read: { _ in .empty }
        )
        let result = try await MetadataScanner.scan(photos: photos, database: db, environment: env)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.scanned, 2)
        let rows = try await db.allMetadata()
        XCTAssertNil(rows[photos[0].id!], "a skipped photo is retried next time, not stored as empty")
    }

    func testAFileImageIOCannotOpenIsSkippedAndRetriedNotRememberedAsEmpty() async throws {
        // A sandbox/permission failure looks exactly like this (stat works, the open fails): it must be retried later.
        let (db, photos) = try await makeDatabase(photos: 1)
        let unreadable = MetadataScanner.Environment(stat: { _ in (100, 1) }, read: { _ in nil })
        let first = try await MetadataScanner.scan(photos: photos, database: db, environment: unreadable)
        XCTAssertEqual(first.skipped, 1)
        XCTAssertEqual(first.scanned, 0)
        let none = try await db.allMetadata()
        XCTAssertTrue(none.isEmpty, "nothing is stored for a file that could not be opened")
        let reads = Counter()
        let readable = MetadataScanner.Environment(stat: { _ in (100, 1) }, read: { _ in reads.bump(); return .empty })
        let second = try await MetadataScanner.scan(photos: photos, database: db, environment: readable)
        XCTAssertEqual(second.scanned, 1, "once it opens, it is read")
        XCTAssertEqual(reads.value, 1)
    }

    func testAnImageWithNoEXIFGetsAnAllNilRowAndIsNotReReadEveryLaunch() async throws {
        let (db, photos) = try await makeDatabase(photos: 1)
        let env = MetadataScanner.Environment(stat: { _ in (100, 1) }, read: { _ in .empty })
        _ = try await MetadataScanner.scan(photos: photos, database: db, environment: env)
        let stored = try await db.allMetadata()
        let row = try XCTUnwrap(stored[photos[0].id!])
        XCTAssertNil(row.iso)
        let reads = Counter()
        let again = try await MetadataScanner.scan(photos: photos, database: db, environment: .init(stat: { _ in (100, 1) }, read: { _ in reads.bump(); return .empty }))
        XCTAssertEqual(again.reused, 1)
        XCTAssertEqual(reads.value, 0)
    }

    func testRowsAreSavedInBatchesAndAFinalFlush() async throws {
        let (db, photos) = try await makeDatabase(photos: 250)
        let batches = BatchLog()
        let persist: @Sendable ([PhotoMetadata]) async throws -> Void = { rows in
            await batches.add(rows.count)
            try await db.saveMetadata(rows)
        }
        _ = try await MetadataScanner.scan(photos: photos, database: db, environment: environment(), persist: persist)
        let sizes = await batches.sizes
        XCTAssertEqual(sizes, [100, 100, 50])
        let count = try await db.allMetadata().count
        XCTAssertEqual(count, 250)
    }

    func testCancellationKeepsTheRowsAlreadyReadAndReportsCancelled() async throws {
        let (db, photos) = try await makeDatabase(photos: 10)
        let reads = Counter()
        let task = Task.detached { () -> MetadataScanner.Result in
            // Cancel from inside the 4th read: the loop notices before the 5th photo.
            let env = MetadataScanner.Environment(stat: { _ in (100, 1) }, read: { _ in
                reads.bump()
                if reads.value == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                return .empty
            })
            return try await MetadataScanner.scan(photos: photos, database: db, environment: env)
        }
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.scanned, 4)
        let saved = try await db.allMetadata().count
        XCTAssertEqual(saved, 4, "rows read before the cancel are persisted so the next run resumes")
    }

    func testProgressReachesTheTotalEvenWhenAPhotoIsSkipped() async throws {
        let (db, photos) = try await makeDatabase(photos: 4)
        let seen = Reports()
        let env = MetadataScanner.Environment(stat: { path in path == photos[1].path ? nil : (100, 1) }, read: { _ in .empty })
        let result = try await MetadataScanner.scan(photos: photos, database: db, environment: env, progress: { seen.add($0) })
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(seen.values.map(\.completed), [1, 2, 3, 4], "one report per photo, skipped or not")
        XCTAssertEqual(seen.values.last, MetadataScanner.Progress(completed: 4, total: 4))
    }

    func testPhotosNeedingScanFindsMissingAndOldRevisionRowsButNotSizeDifferences() throws {
        func photo(_ id: Int64, size: Int64? = 100) -> Photo {
            Photo(id: id, path: "/tmp/p\(id).jpg", filename: "p\(id).jpg", fileSize: size, importedAt: Date())
        }
        func row(_ id: Int64, size: Int64 = 100, revision: Int = PhotoMetadata.currentReaderRevision) -> PhotoMetadata {
            PhotoMetadata(photoId: id, fileSize: size, mtime: 1, readerRevision: revision, captureDate: nil, iso: nil, cameraMake: nil,
                          cameraModel: nil, lens: nil, focalLength: nil, aperture: nil, shutter: nil, pixelWidth: nil,
                          pixelHeight: nil, scannedAt: Date())
        }
        let photos = [photo(1), photo(2), photo(3), photo(4), photo(5, size: nil)]
        let cached = [1: row(1), 3: row(3, revision: 0), 4: row(4, size: 50), 5: row(5)].reduce(into: [Int64: PhotoMetadata]()) { $0[Int64($1.key)] = $1.value }
        // 4's row size differs from photo.fileSize, which proves nothing (photo.fileSize is only written at import):
        // the scan's own stat pass catches changed files, so it must not make this photo "need a scan" forever.
        XCTAssertEqual(MetadataScanner.photosNeedingScan(photos, cached: cached).compactMap(\.id), [2, 3])
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MetadataScanner.Progress] = []
    func add(_ p: MetadataScanner.Progress) { lock.lock(); items.append(p); lock.unlock() }
    var values: [MetadataScanner.Progress] { lock.lock(); defer { lock.unlock() }; return items }
}

private actor BatchLog {
    private(set) var sizes: [Int] = []
    func add(_ n: Int) { sizes.append(n) }
}
