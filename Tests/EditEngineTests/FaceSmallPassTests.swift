import CoreGraphics
import XCTest
@testable import PhotoApp

/// The pure helpers of the small-face pass (tiling, coordinate mapping, cut-face and duplicate removal) and the revision rules.
final class FaceSmallPassTests: XCTestCase {
    // MARK: tiles

    func testTilesCoverTheWholeImageAndOverlapByAtLeastTheOverlap() {
        for (w, h) in [(6016, 4016), (2400, 1600), (1500, 1000), (1024, 1024), (3000, 1025)] {
            let tiles = FaceDetector.tiles(imageWidth: w, imageHeight: h)
            XCTAssertEqual(tiles.map(\.minX).min(), 0); XCTAssertEqual(tiles.map(\.minY).min(), 0)
            XCTAssertEqual(tiles.map(\.maxX).max(), CGFloat(w), "\(w)x\(h): the last column ends exactly at the edge")
            XCTAssertEqual(tiles.map(\.maxY).max(), CGFloat(h))
            for t in tiles { XCTAssertTrue(t.width <= 1024 && t.height <= 1024 && t.minX >= 0 && t.minY >= 0 && Int(t.maxX) <= w && Int(t.maxY) <= h) }
            // Every pixel column and row is inside some tile (no gaps): sample the image on a coarse grid.
            for x in stride(from: 0, to: w, by: 37) { for y in stride(from: 0, to: h, by: 41) {
                XCTAssertTrue(tiles.contains { $0.contains(CGPoint(x: x, y: y)) }, "\(w)x\(h) pixel (\(x),\(y)) is uncovered")
            } }
        }
        let xs = Set(FaceDetector.tiles(imageWidth: 6016, imageHeight: 1024).map(\.minX)).sorted()
        for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(a + 1024 - b, CGFloat(FaceDetector.smallPassOverlap), "neighbouring tiles overlap by at least the overlap") }
    }

    func testAnImageSmallerThanATileIsOneTile() {
        XCTAssertEqual(FaceDetector.tiles(imageWidth: 800, imageHeight: 600), [CGRect(x: 0, y: 0, width: 800, height: 600)])
    }

    // MARK: coordinates

    func testAVisionBoxInATileMapsToTopLeftFractionsOfTheWholeImage() {
        // Tile at pixel (1000, 500), 1024 wide; Vision box (bottom-left origin) x 0.25..0.35, y 0.10..0.20 of the tile.
        let tile = CGRect(x: 1000, y: 500, width: 1024, height: 1024)
        let f = FaceDetector.imageFractions(visionBox: CGRect(x: 0.25, y: 0.10, width: 0.10, height: 0.10), tile: tile, imageWidth: 6000, imageHeight: 4000)
        XCTAssertEqual(f.x, (1000 + 0.25 * 1024) / 6000, accuracy: 1e-9)
        // The box's TOP is at 1 - 0.20 = 0.80 of the tile height from the tile's top.
        XCTAssertEqual(f.y, (500 + 0.80 * 1024) / 4000, accuracy: 1e-9)
        XCTAssertEqual(f.w, 0.10 * 1024 / 6000, accuracy: 1e-9)
        XCTAssertEqual(f.h, 0.10 * 1024 / 4000, accuracy: 1e-9)
    }

    // MARK: cut faces

    func testABoxTouchingAnInteriorTileEdgeIsCutButTheImageBorderIsNot() {
        let interior = CGRect(x: 1000, y: 500, width: 1024, height: 1024)   // not on any image border (image 6000x4000)
        XCTAssertTrue(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0, y: 0.4, width: 0.1, height: 0.1), tile: interior, imageWidth: 6000, imageHeight: 4000), "left edge")
        XCTAssertTrue(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0.9, y: 0.4, width: 0.1, height: 0.1), tile: interior, imageWidth: 6000, imageHeight: 4000), "right edge")
        XCTAssertTrue(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0.4, y: 0.9, width: 0.1, height: 0.1), tile: interior, imageWidth: 6000, imageHeight: 4000), "top edge (Vision y is bottom-left)")
        XCTAssertTrue(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0.4, y: 0, width: 0.1, height: 0.1), tile: interior, imageWidth: 6000, imageHeight: 4000), "bottom edge")
        XCTAssertFalse(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), tile: interior, imageWidth: 6000, imageHeight: 4000), "a box in the middle")
        let corner = CGRect(x: 0, y: 0, width: 1024, height: 1024)           // the image's own top-left corner
        XCTAssertFalse(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), tile: corner, imageWidth: 6000, imageHeight: 4000), "a face at the image's border is whole")
        XCTAssertTrue(FaceDetector.isCutByInteriorEdge(visionBox: CGRect(x: 0.9, y: 0.4, width: 0.1, height: 0.1), tile: corner, imageWidth: 6000, imageHeight: 4000), "but this tile's right edge is interior")
    }

    // MARK: duplicates

    private func candidate(_ x: Double, _ y: Double, q: Double, size: Double = 0.02) -> FaceDetector.SmallCandidate {
        FaceDetector.SmallCandidate(box: FaceMatching.Box(x: x, y: y, w: size, h: size), quality: q)
    }

    func testTheSameFaceSeenInTwoOverlappingTilesIsKeptOnceWithTheBetterScore() {
        let kept = FaceDetector.suppressDuplicates([candidate(0.300, 0.300, q: 0.30), candidate(0.301, 0.3005, q: 0.45), candidate(0.6, 0.6, q: 0.2)], existing: [])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first?.quality, 0.45)
    }

    func testAFaceTheFullFramePassAlreadyFoundIsNotReportedAgain() {
        let kept = FaceDetector.suppressDuplicates([candidate(0.30, 0.30, q: 0.4), candidate(0.7, 0.7, q: 0.4)],
                                                   existing: [FaceMatching.Box(x: 0.295, y: 0.295, w: 0.03, h: 0.03)])
        XCTAssertEqual(kept.map(\.box.x), [0.7])
    }

    func testNeighbouringFacesThatOnlyTouchAreBothKept() {
        let kept = FaceDetector.suppressDuplicates([candidate(0.30, 0.30, q: 0.4), candidate(0.322, 0.30, q: 0.4)], existing: [])
        XCTAssertEqual(kept.count, 2, "two side-by-side faces are not duplicates")
    }

    // MARK: revisions

    func testScanRevisionCarriesTheFlagOnlyWhenTheSmallPassRan() {
        XCTAssertEqual(FaceDetector.scanRevision(includeSmall: false), FaceDetector.detectRevision)
        XCTAssertEqual(FaceDetector.scanRevision(includeSmall: true), FaceDetector.detectRevision + FaceDetector.smallPassFlag)
        XCTAssertFalse(FaceDetector.includesSmallPass(revision: FaceDetector.detectRevision))
        XCTAssertTrue(FaceDetector.includesSmallPass(revision: FaceDetector.scanRevision(includeSmall: true)))
    }

    func testARecordWithoutTheSmallPassIsNotCurrentForAScanWithIt_ButTheReverseIsAccepted() {
        func record(_ revision: Int) -> FaceScanRecord {
            FaceScanRecord(photoId: 1, fileSize: 10, mtime: 2, detectRevision: revision, printRevision: 2, faceCount: 0, scannedAt: Date())
        }
        let base = FaceDetector.detectRevision, withSmall = base + FaceDetector.smallPassFlag
        func current(_ r: FaceScanRecord, small: Bool) -> Bool {
            r.isCurrent(fileSize: 10, mtime: 2, detectRevision: base, printRevision: 2, requiresSmallPass: small)
        }
        XCTAssertTrue(current(record(base), small: false), "unchanged behaviour with the option off")
        XCTAssertFalse(current(record(base), small: true), "switching the option on rescans once")
        XCTAssertTrue(current(record(withSmall), small: true))
        XCTAssertTrue(current(record(withSmall), small: false), "switching it off rescans nothing")
        XCTAssertFalse(current(record(base + 1), small: false), "a different detector revision is still stale")
        XCTAssertFalse(current(record(withSmall + 1), small: true))
    }

    // MARK: encoding stops at the cap

    func testFirstEncodedStopsAtTheCapSkipsFailuresAndKeepsOrder() {
        let candidates = (0..<10).map { FaceDetector.SmallCandidate(box: FaceMatching.Box(x: Double($0) / 20, y: 0, w: 0.01, h: 0.01), quality: 1 - Double($0) / 20) }
        var calls = 0
        let out = FaceDetector.firstEncoded(candidates, limit: 3) { c -> Int? in calls += 1; let index = Int((c.box.x * 20).rounded()); return index == 0 ? nil : index }   // #0 fails
        XCTAssertEqual(out, [1, 2, 3], "the failing first candidate is skipped and the next ones fill in, in order")
        XCTAssertEqual(calls, 4, "no candidate after the third success is encoded")
        var none = 0
        XCTAssertTrue(FaceDetector.firstEncoded(candidates, limit: 0) { _ -> Int? in none += 1; return 1 }.isEmpty)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(FaceDetector.firstEncoded(Array(candidates.prefix(2)), limit: 5) { _ -> Int? in 7 }.count, 2, "fewer candidates than the cap returns them all")
    }

    func testARecordFromTheFirstSmallPassVersionIsCurrentOnlyForAScanWithoutThePass() {
        func record(_ revision: Int) -> FaceScanRecord {
            FaceScanRecord(photoId: 1, fileSize: 10, mtime: 2, detectRevision: revision, printRevision: 2, faceCount: 0, scannedAt: Date())
        }
        let base = FaceDetector.detectRevision
        let legacy = base + FaceDetector.legacySmallPassFlag
        func current(_ r: FaceScanRecord, small: Bool) -> Bool { r.isCurrent(fileSize: 10, mtime: 2, detectRevision: base, printRevision: 2, requiresSmallPass: small) }
        XCTAssertEqual(FaceDetector.smallPassFlag, 20_000)
        XCTAssertTrue(current(record(legacy), small: false), "turning the option off rescans nothing")
        XCTAssertFalse(current(record(legacy), small: true), "the option on rescans once so print-less small faces get prints")
        XCTAssertTrue(FaceDetector.includesSmallPass(revision: legacy), "a legacy record still counts as having run the pass (keep-small rule)")
        XCTAssertTrue(FaceDetector.includesSmallPass(revision: FaceDetector.scanRevision(includeSmall: true)))
    }

    // MARK: printing small faces

    private func syntheticImage() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context.makeImage()!
    }

    private func smallCandidates(_ n: Int) -> [FaceDetector.SmallCandidate] {
        (0..<n).map { FaceDetector.SmallCandidate(box: FaceMatching.Box(x: 0.1 + Double($0) * 0.08, y: 0.4, w: 0.06, h: 0.08), quality: 0.5 - Double($0) * 0.01) }
    }

    func testSmallFacesCarryTheirPrintTheTileAndTheSmallFlag() throws {
        let faces = try XCTUnwrap(FaceDetector.smallFaces(from: smallCandidates(3), in: syntheticImage()) { _ in Data([7, 7]) })
        XCTAssertEqual(faces.count, 3)
        XCTAssertTrue(faces.allSatisfy { $0.isSmall && $0.featurePrint == Data([7, 7]) && ($0.crop?.isEmpty == false) })
        XCTAssertEqual(faces.map(\.quality), faces.map(\.quality).sorted(by: >), "quality order kept")
    }

    func testAPrintThatCannotBeMadeMakesTheWholePhotoUnreadableSoNothingStoredIsReplaced() {
        var calls = 0
        let result = FaceDetector.smallFaces(from: smallCandidates(5), in: syntheticImage()) { _ in calls += 1; return calls == 2 ? nil : Data([1]) }
        XCTAssertNil(result, "could not look: the photo is retried, never recorded as having fewer small faces")
        XCTAssertEqual(calls, 2, "it stops at the failure")
    }
}
