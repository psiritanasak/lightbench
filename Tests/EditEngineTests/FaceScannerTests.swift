import CoreGraphics
import XCTest
@testable import PhotoApp

final class FaceScannerTests: XCTestCase {
    private var db: CatalogDatabase!
    private var photos: [Photo] = []

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _detectCalls: [String] = []
        var mtimes: [String: Double] = [:]
        var missing: Set<String> = []
        var undecodable: Set<String> = []
        var facesPerPath: [String: Int] = [:]
        var cancelOnDetectNumber: Int?
        var cancelInStat = false
        var detectCalls: [String] { lock.lock(); defer { lock.unlock() }; return _detectCalls }
        func recordDetect(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; _detectCalls.append(path); return _detectCalls.count }
    }

    private func environment(_ probe: Probe) -> FaceScanner.Environment {
        FaceScanner.Environment(
            stat: { path in
                if probe.cancelInStat { withUnsafeCurrentTask { $0?.cancel() }; return nil }
                return probe.missing.contains(path) ? nil : (1000, probe.mtimes[path] ?? 1)
            },
            detect: { path in
                let number = probe.recordDetect(path)
                if probe.cancelOnDetectNumber == number { withUnsafeCurrentTask { $0?.cancel() } }
                if probe.undecodable.contains(path) { return nil }
                return (0..<(probe.facesPerPath[path] ?? 0)).map { i in
                    FaceDetector.DetectedFace(x: 0.1 * Double(i), y: 0.1, w: 0.2, h: 0.2, quality: 0.5, featurePrint: Data(repeating: 7, count: 8), crop: Data([1]))
                }
            })
    }

    private func makePhotos(_ n: Int) async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<n).map { URL(fileURLWithPath: "/tmp/fs\($0).jpg") })
        photos = try await db.allPhotos().sorted { $0.path < $1.path }
    }

    func testFirstScanFindsAndStoresFacesAndRecordsPhotosWithNone() async throws {
        try await makePhotos(3)
        let probe = Probe()
        probe.facesPerPath = [photos[0].path: 2, photos[1].path: 0, photos[2].path: 1]
        let result = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(result, FaceScanner.Result(scanned: 3, alreadyCurrent: 0, facesFound: 3, skipped: 0, undecodable: 0, wasCancelled: false))
        let first = try await db.faces(forPhotoID: try XCTUnwrap(photos[0].id))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].detectRevision, FaceDetector.detectRevision)
        XCTAssertEqual(first[0].printRevision, FeaturePrintGenerator.revision)
        XCTAssertNil(first[0].personId)
        let scans = try await db.faceScans(forPhotoIDs: photos.compactMap(\.id))
        XCTAssertEqual(scans.count, 3, "the zero-face photo is recorded too")
    }

    func testASecondScanSkipsCurrentRecordsAndRescansOnlyChangedFiles() async throws {
        try await makePhotos(3)
        let probe = Probe()
        probe.facesPerPath = [photos[0].path: 1, photos[1].path: 1, photos[2].path: 0]
        _ = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        let firstRunCalls = probe.detectCalls.count
        let again = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(again.alreadyCurrent, 3)
        XCTAssertEqual(probe.detectCalls.count, firstRunCalls, "nothing was detected again")
        probe.mtimes[photos[1].path] = 99                    // one file was edited
        let third = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(third.alreadyCurrent, 2)
        XCTAssertEqual(Array(probe.detectCalls.suffix(1)), [photos[1].path])
    }

    func testUnstattablePhotosAreSkippedAndUndecodableOnesRetriedNextTime() async throws {
        try await makePhotos(3)
        let probe = Probe()
        probe.missing = [photos[0].path]
        probe.undecodable = [photos[1].path]
        probe.facesPerPath = [photos[2].path: 1]
        let result = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.undecodable, 1)
        XCTAssertEqual(result.facesFound, 1)
        let scans = try await db.faceScans(forPhotoIDs: photos.compactMap(\.id))
        XCTAssertEqual(scans.count, 1, "only the decodable photo is recorded")
        probe.undecodable = []
        let retry = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(retry.alreadyCurrent, 1)
        XCTAssertEqual(retry.undecodable, 0, "the previously undecodable photo was tried again and now succeeds")
    }

    func testACancelledScanKeepsWhatItFinishedAndResumes() async throws {
        try await makePhotos(5)
        let probe = Probe()
        probe.facesPerPath = Dictionary(uniqueKeysWithValues: photos.map { ($0.path, 1) })
        probe.cancelOnDetectNumber = 3
        // Its own task, like the real scan (`DuplicatesModel` runs it detached): the detect closure cancels THAT task.
        let database = try XCTUnwrap(db), photoList = photos, env = environment(probe)
        let task = Task { try await FaceScanner.scan(photos: photoList, database: database, environment: env) }
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        let saved = try await db.faceScans(forPhotoIDs: photos.compactMap(\.id))
        XCTAssertEqual(saved.count, 3, "the three photos detected before the cancel are saved")
        probe.cancelOnDetectNumber = nil
        let resumed = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe))
        XCTAssertEqual(resumed.alreadyCurrent, 3)
        XCTAssertEqual(probe.detectCalls.count, 3 + 2, "only the two remaining photos were detected on resume")
    }

    /// Cancelled during the stat pass with nothing stat'ed: the cancel must still be reported (not "completed, nothing found").
    func testACancelDuringTheStatPassIsStillReported() async throws {
        try await makePhotos(3)
        let probe = Probe()
        probe.cancelInStat = true
        let database = try XCTUnwrap(db), photoList = photos, env = environment(probe)
        let task = Task { try await FaceScanner.scan(photos: photoList, database: database, environment: env) }
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.scanned, 0)
        XCTAssertTrue(probe.detectCalls.isEmpty)
    }

    func testResultsAreSavedInBatches() async throws {
        try await makePhotos(205)
        let probe = Probe()
        let sizes = Sizes()
        let database = try XCTUnwrap(db)
        let result = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe),
                                                persist: { batch in sizes.add(batch.count); try await FaceScanner.persistToDatabase(database)(batch) })
        XCTAssertEqual(result.scanned, 205)
        XCTAssertEqual(sizes.values, [100, 100, 5])
    }

    func testProgressCountsEveryStattablePhoto() async throws {
        try await makePhotos(4)
        let probe = Probe()
        probe.missing = [photos[0].path]
        let seen = Sizes()
        _ = try await FaceScanner.scan(photos: photos, database: db, environment: environment(probe), progress: { seen.add($0.completed * 100 + $0.total) })
        XCTAssertEqual(seen.values, [103, 203, 303])
    }

    private final class Sizes: @unchecked Sendable {
        private let lock = NSLock(); private var _values: [Int] = []
        func add(_ v: Int) { lock.lock(); _values.append(v); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return _values }
    }
}

final class FaceDetectorTests: XCTestCase {
    func testVisionBoxesAreFlippedToATopLeftOrigin() {
        let box = FaceDetector.topLeftBox(fromVision: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))   // Vision: 0.6...0.9 up from the bottom
        XCTAssertEqual(box.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box.y, 0.1, accuracy: 1e-9, "top-left y = 1 - maxY")
        XCTAssertEqual(box.w, 0.2, accuracy: 1e-9)
        XCTAssertEqual(box.h, 0.3, accuracy: 1e-9)
    }

    func testTheCropIsAPaddedSquareAroundTheFaceKeptInsideTheImage() {
        // A 200x300 px face centred at (500, 400) in a 1000x800 image, 40 % padding each side: side = 300 * 1.8 = 540.
        let box = (x: 0.4, y: 0.3125, w: 0.2, h: 0.375)
        let rect = FaceDetector.cropRect(box: box, imageWidth: 1000, imageHeight: 800)
        XCTAssertEqual(rect.width, 540, accuracy: 1)
        XCTAssertEqual(rect.height, 540, accuracy: 1)
        XCTAssertEqual(rect.midX, 500, accuracy: 1)
        XCTAssertEqual(rect.midY, 400, accuracy: 1)
        // A face at the very edge: the crop is clamped to the image.
        let edge = FaceDetector.cropRect(box: (x: 0, y: 0, w: 0.2, h: 0.25), imageWidth: 1000, imageHeight: 800)
        XCTAssertGreaterThanOrEqual(edge.minX, 0); XCTAssertGreaterThanOrEqual(edge.minY, 0)
        XCTAssertLessThanOrEqual(edge.maxX, 1000); XCTAssertLessThanOrEqual(edge.maxY, 800)
    }

    func testFacesAreKeptOnlyWhenBigEnoughAndSharpEnough() {
        XCTAssertTrue(FaceDetector.passesFilters(widthPixels: 40, quality: 0.15))
        XCTAssertFalse(FaceDetector.passesFilters(widthPixels: 39, quality: 0.9), "too small")
        XCTAssertFalse(FaceDetector.passesFilters(widthPixels: 300, quality: 0.14), "too blurred (the spike's crowd faces scored 0.08-0.11)")
    }

    /// Real Vision on a generated image with no face: the request runs and finds nothing (it says nothing about identity or accuracy —
    /// that was measured by hand on real photos, see docs/ROADMAP_HISTORY.md).
    /// A missing score is a FAILED detection (nil), never a quality of 0 that would drop the face and record the photo as faceless.
    func testAMissingQualityScoreFailsTheDetectionInsteadOfDroppingTheFace() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertNil(FaceDetector.scored([FaceDetector.ScoredBox(box: box, quality: 0.5), FaceDetector.ScoredBox(box: box, quality: nil)]))
        let ok = FaceDetector.scored([FaceDetector.ScoredBox(box: box, quality: 0.5)])
        XCTAssertEqual(ok?.count, 1)
        XCTAssertEqual(ok?.first?.quality ?? 0, 0.5, accuracy: 1e-6)
    }

    func testTheStoredRevisionCombinesBothPinnedRequests() {
        XCTAssertEqual(FaceDetector.detectRevision, FaceDetector.rectanglesRevision * 100 + FaceDetector.qualityRevision)
    }

    /// A crop near the frame edge is not square: it must be letterboxed on grey, never stretched.
    func testASquareFitKeepsTheAspectRatioAndLetterboxesOnGrey() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let wide = try XCTUnwrap(context.makeImage())
        let fitted = try XCTUnwrap(FaceDetector.squareFit(wide, side: 100))
        XCTAssertEqual(fitted.width, 100); XCTAssertEqual(fitted.height, 100)
        let data = try XCTUnwrap(fitted.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = y * fitted.bytesPerRow + x * 4
            return (data[i], data[i + 1], data[i + 2])
        }
        let centre = pixel(50, 50), top = pixel(50, 5)
        XCTAssertGreaterThan(centre.0, 200); XCTAssertLessThan(centre.1, 60)           // the red image in the middle
        // Grey bars above (and below), not stretched red: neutral (r = g = b) and mid-bright (the context's colour conversion makes it ~146).
        XCTAssertTrue(abs(Int(top.0) - Int(top.1)) < 4 && abs(Int(top.1) - Int(top.2)) < 4 && (100...200).contains(Int(top.0)), "top=\(top)")
    }

    func testAnImageWithoutFacesGivesNoFacesAndNoCrash() throws {
        let side = 600
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(FaceDetector.detect(in: image), [])
    }

    func testAnUnreadableFileIsNilNotAnEmptyResult() {
        XCTAssertNil(FaceDetector.detect(inFileAt: URL(fileURLWithPath: "/tmp/definitely-not-an-image-\(UUID().uuidString).jpg")))
    }
}
