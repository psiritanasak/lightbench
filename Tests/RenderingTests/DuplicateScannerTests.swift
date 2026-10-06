import XCTest
@testable import PhotoApp

final class DuplicateScannerTests: XCTestCase {
    /// Counts every environment call per path, so tests can assert what was (not) recomputed.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        var stats: [String: (size: Int64, mtime: Double)] = [:]
        var hashes: [String: String] = [:]
        var prints: [String: Data] = [:]
        private(set) var hashCalls: [String] = []
        private(set) var printCalls: [String] = []
        var onPrint: (@Sendable (String) -> Void)?

        var environment: DuplicateScanner.Environment {
            DuplicateScanner.Environment(
                stat: { [self] path in lock.withLock { stats[path] } },
                hash: { [self] path in lock.withLock { hashCalls.append(path); return hashes[path] } },
                featurePrint: { [self] path in
                    onPrint?(path)
                    return lock.withLock { printCalls.append(path); return prints[path] }
                }
            )
        }
        func reset() { lock.withLock { hashCalls = []; printCalls = [] } }
    }

    private func blob(angle: Float = 0) -> Data {
        var v = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        v[0] = cos(angle); v[1] = sin(angle)
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func makeDatabase(_ count: Int) async throws -> (CatalogDatabase, [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/ds\($0).jpg") })
        let photos = try await db.allPhotos().sorted { $0.path < $1.path }
        return (db, photos)
    }

    private func seed(_ probe: Probe, _ photos: [Photo], sizes: [Int64], mtime: Double = 1_000) {
        for (photo, size) in zip(photos, sizes) {
            probe.stats[photo.path] = (size, mtime)
            probe.hashes[photo.path] = "hash-\(size)"
            probe.prints[photo.path] = blob()
        }
    }

    func testOnlyFilesThatShareASizeAreHashedButEveryFileGetsAPrint() async throws {
        let (db, photos) = try await makeDatabase(4)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 10, 20, 30])
        let result = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertEqual(Set(probe.hashCalls), [photos[0].path, photos[1].path])
        XCTAssertEqual(probe.printCalls.count, 4)
        XCTAssertEqual(result.candidates.count, 4)
        XCTAssertEqual(result.candidates.filter { $0.contentHash != nil }.count, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertFalse(result.wasCancelled)
    }

    func testASecondScanReusesTheCacheAndComputesNothing() async throws {
        let (db, photos) = try await makeDatabase(3)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 10, 30])
        let first = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        probe.reset()
        let second = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertTrue(probe.hashCalls.isEmpty)
        XCTAssertTrue(probe.printCalls.isEmpty)
        XCTAssertEqual(second.candidates, first.candidates)
    }

    func testAChangedModificationTimeOrSizeInvalidatesThatPhotoOnly() async throws {
        let (db, photos) = try await makeDatabase(3)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 10, 30])
        _ = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        probe.reset()
        probe.stats[photos[1].path] = (10, 2_000)      // touched, same size
        probe.stats[photos[2].path] = (31, 1_000)      // grew
        probe.hashes[photos[1].path] = "hash-new"
        _ = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertEqual(Set(probe.printCalls), [photos[1].path, photos[2].path])
        XCTAssertEqual(probe.hashCalls, [photos[1].path], "the grown file is now unique-size, so it needs no hash")
    }

    func testAHashIsComputedLaterWhenASecondPhotoJoinsTheSizeGroup() async throws {
        let (db, photos) = try await makeDatabase(2)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 20])
        _ = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertTrue(probe.hashCalls.isEmpty)
        probe.stats[photos[1].path] = (10, 1_000)
        probe.reset()
        let result = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertEqual(Set(probe.hashCalls), [photos[0].path, photos[1].path], "photo 0's cached row had no hash, so it is filled in")
        XCTAssertEqual(result.candidates.compactMap(\.contentHash).count, 2)
    }

    func testAPrintFromAnOtherRevisionOrOfTheWrongSizeIsRecomputed() async throws {
        let (db, photos) = try await makeDatabase(2)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 20])
        let ids = photos.compactMap(\.id)
        try await db.saveFingerprints([
            PhotoFingerprint(photoId: ids[0], fileSize: 10, mtime: 1_000, contentHash: nil, featurePrint: blob(),
                             featurePrintRevision: FeaturePrintGenerator.revision + 1, computedAt: Date()),
            PhotoFingerprint(photoId: ids[1], fileSize: 20, mtime: 1_000, contentHash: nil, featurePrint: Data([1, 2, 3]),
                             featurePrintRevision: FeaturePrintGenerator.revision, computedAt: Date()),
        ])
        let result = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertEqual(Set(probe.printCalls), Set(photos.map(\.path)))
        XCTAssertEqual(result.withoutFeaturePrint, 0)
        let stored = try await db.fingerprints(forPhotoIDs: ids)
        XCTAssertEqual(stored[ids[0]]?.featurePrintRevision, FeaturePrintGenerator.revision)
    }

    func testAFileThatCannotBeStatedIsSkippedAndAnUndecodableImageCountsAsWithoutAPrint() async throws {
        let (db, photos) = try await makeDatabase(3)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 20, 30])
        probe.stats[photos[0].path] = nil
        probe.prints[photos[1].path] = nil
        let result = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.withoutFeaturePrint, 1)
        XCTAssertEqual(result.candidates.count, 2, "the skipped photo is not a candidate at all")
        XCTAssertNil(result.candidates.first { $0.id == photos[1].id }?.featurePrint)
    }

    func testProgressCountsEveryScannedPhotoInOrder() async throws {
        let (db, photos) = try await makeDatabase(3)
        let probe = Probe()
        seed(probe, photos, sizes: [10, 20, 30])
        let seen = LockedBox<[DuplicateScanner.Progress]>([])
        _ = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment, progress: { p in seen.mutate { $0.append(p) } })
        XCTAssertEqual(seen.value, [.init(completed: 1, total: 3), .init(completed: 2, total: 3), .init(completed: 3, total: 3)])
    }

    func testCancellingStopsEarlyKeepsTheRowsAlreadyComputedAndALaterScanResumes() async throws {
        let (db, photos) = try await makeDatabase(6)
        let probe = Probe()
        seed(probe, photos, sizes: [1, 2, 3, 4, 5, 6])
        // The hook is installed BEFORE the task exists and waits for the task handle, so the cancel can never be missed.
        let box = LockedBox<Task<DuplicateScanner.Result, Error>?>(nil)
        probe.onPrint = { path in
            if path == photos[2].path { while box.value == nil { Thread.sleep(forTimeInterval: 0.001) }; box.value?.cancel() }
        }
        let task = Task { () -> DuplicateScanner.Result in
            try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        }
        box.mutate { $0 = task }
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.candidates.count, 6)
        let ids = photos.compactMap(\.id)
        let stored = try await db.fingerprints(forPhotoIDs: ids)
        XCTAssertEqual(stored.count, result.candidates.count, "everything computed before the cancel was saved")
        probe.onPrint = nil
        probe.reset()
        let resumed = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        XCTAssertFalse(resumed.wasCancelled)
        XCTAssertEqual(resumed.candidates.count, 6)
        XCTAssertEqual(probe.printCalls.count, 6 - stored.count, "only the photos the cancelled scan never reached are computed")
    }

    /// A kill mid-scan (no cancel, no final flush) must lose at most one batch: rows are written as the scan goes.
    func testRowsAreSavedInBatchesAsTheScanGoesNotOnlyAtTheEnd() async throws {
        let n = DuplicateScanner.saveBatch + 20
        let (db, photos) = try await makeDatabase(n)
        let probe = Probe()
        seed(probe, photos, sizes: (0..<Int64(n)).map { $0 + 1 })
        let batches = LockedBox<[Int]>([])
        _ = try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment, persist: { rows in
            batches.mutate { $0.append(rows.count) }
            try await db.saveFingerprints(rows)
        })
        XCTAssertEqual(batches.value, [DuplicateScanner.saveBatch, 20], "one full batch mid-scan, the remainder at the end")
    }

    /// The cancel lands while the FIRST batch is filling, so the in-loop batch save itself runs on a cancelled task: it must
    /// still persist (a direct GRDB call from a cancelled task throws CancellationError and would lose the rows).
    func testTheBatchSaveStillWritesWhenTheTaskIsCancelledWhileItFills() async throws {
        let n = DuplicateScanner.saveBatch + 20
        let (db, photos) = try await makeDatabase(n)
        let probe = Probe()
        seed(probe, photos, sizes: (0..<Int64(n)).map { $0 + 1 })
        let box = LockedBox<Task<DuplicateScanner.Result, Error>?>(nil)
        probe.onPrint = { path in
            if path == photos[DuplicateScanner.saveBatch - 1].path { while box.value == nil { Thread.sleep(forTimeInterval: 0.001) }; box.value?.cancel() }
        }
        let task = Task { () -> DuplicateScanner.Result in
            try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        }
        box.mutate { $0 = task }
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        let stored = try await db.fingerprints(forPhotoIDs: photos.compactMap(\.id))
        XCTAssertEqual(result.candidates.count, DuplicateScanner.saveBatch)
        XCTAssertEqual(stored.count, DuplicateScanner.saveBatch, "the full batch reached the database")
    }

    func testAScanCancelledBeforeItStartsReturnsACancelledResultInsteadOfThrowing() async throws {
        let (db, photos) = try await makeDatabase(2)
        let probe = Probe()
        seed(probe, photos, sizes: [1, 2])
        let task = Task { () -> DuplicateScanner.Result in
            while !Task.isCancelled { await Task.yield() }
            return try await DuplicateScanner.scan(photos: photos, database: db, environment: probe.environment)
        }
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.candidates.isEmpty)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
