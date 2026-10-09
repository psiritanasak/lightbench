import simd
import XCTest
@testable import PhotoApp

final class PanoramaPlanTests: XCTestCase {
    private func translation(_ dx: Float, _ dy: Float = 0) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(dx, dy, 1)))
    }
    private func apply(_ m: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float> { let q = m * SIMD3(p.x, p.y, 1); return SIMD2(q.x / q.z, q.y / q.z) }

    // MARK: Chaining

    /// Three frames each panned 800 px right of the previous (frame k+1 content sits 800 px to the right in frame k's coordinates, so frame k+1 pixel
    /// x maps to frame k pixel x + 800). The middle frame is the reference.
    func testThreeFrameTranslationChainPlacesEveryFrameOnOneCanvas() throws {
        let plan = try PanoramaPlan.plan(pairs: [translation(800), translation(800)], frameWidth: 1000, frameHeight: 600).get()
        XCTAssertEqual(plan.referenceIndex, 1)
        XCTAssertEqual(plan.canvasWidth, 2600, "800 + 800 + 1000")
        XCTAssertEqual(plan.canvasHeight, 600)
        // Frame 0's origin is the canvas origin; the reference is 800 px in; frame 2 is 1600 px in.
        XCTAssertEqual(apply(plan.placements[0].toCanvas, SIMD2(0, 0)).x, 0, accuracy: 1e-3)
        XCTAssertEqual(apply(plan.placements[1].toCanvas, SIMD2(0, 0)).x, 800, accuracy: 1e-3, "the reference sits 800 px in")
        XCTAssertEqual(apply(plan.placements[2].toCanvas, SIMD2(0, 0)).x, 1600, accuracy: 1e-3)
    }

    func testPlacementsMatchTheTrueGeometryForTranslations() throws {
        // frame1 -> frame0: +800; frame2 -> frame1: +700 (so frame2 -> frame0: +1500). Reference = frame 1.
        let plan = try PanoramaPlan.plan(pairs: [translation(800, 10), translation(700, -5)], frameWidth: 1000, frameHeight: 600).get()
        let ref = plan.referenceIndex
        XCTAssertEqual(ref, 1)
        // A point of the scene that frame 0 sees at (900, 300) is seen by frame 1 at (100, 290) and by frame 2 at (-600, 295): all three must land on ONE canvas point.
        let c0 = apply(plan.placements[0].toCanvas, SIMD2(900, 300))
        let c1 = apply(plan.placements[1].toCanvas, SIMD2(100, 290))
        let c2 = apply(plan.placements[2].toCanvas, SIMD2(-600, 295))
        XCTAssertEqual(c0.x, c1.x, accuracy: 1e-3); XCTAssertEqual(c0.y, c1.y, accuracy: 1e-3)
        XCTAssertEqual(c0.x, c2.x, accuracy: 1e-3); XCTAssertEqual(c0.y, c2.y, accuracy: 1e-3)
    }

    /// Translations commute, so they cannot reveal a wrong multiplication ORDER. With rotation, scale and shear pairs and chains of length two on both
    /// sides of the reference (5 frames, reference 2), every frame must reach the canvas exactly as composing the pairs by hand says.
    func testNonCommutingPairsAreComposedInTheRightOrderOnBothSides() throws {
        func rot(_ deg: Float, _ dx: Float, _ dy: Float) -> simd_float3x3 {
            let t = deg * .pi / 180
            return simd_float3x3(columns: (SIMD3(cos(t), sin(t), 0), SIMD3(-sin(t), cos(t), 0), SIMD3(dx, dy, 1)))
        }
        let scale = simd_float3x3(columns: (SIMD3(1.15, 0, 0), SIMD3(0, 1.15, 0), SIMD3(400, 20, 1)))
        let shear = simd_float3x3(columns: (SIMD3(1, 0.05, 0), SIMD3(0.04, 1, 0), SIMD3(450, -30, 1)))
        let pairs = [rot(4, 500, 30), scale, shear, rot(-3, 380, -20)] // pair k: frame k+1 -> frame k
        let plan = try PanoramaPlan.plan(pairs: pairs, frameWidth: 1000, frameHeight: 600).get()
        XCTAssertEqual(plan.referenceIndex, 2)
        let p = SIMD2<Float>(310, 240)
        let ref = plan.placements[2].toCanvas
        // Right side: frame 4 -> 3 -> 2 and frame 3 -> 2.
        let from3 = apply(pairs[2], p)
        let from4 = apply(pairs[2], apply(pairs[3], p))
        // Left side: frame 1 -> 2 is the INVERSE of pair 1, frame 0 -> 1 -> 2 is inverse(pair 0) then inverse(pair 1).
        let from1 = apply(pairs[1].inverse, p)
        let from0 = apply(pairs[1].inverse, apply(pairs[0].inverse, p))
        for (index, expected) in [(3, from3), (4, from4), (1, from1), (0, from0)] {
            let got = apply(plan.placements[index].toCanvas, p), want = apply(ref, expected)
            XCTAssertEqual(got.x, want.x, accuracy: 0.05, "frame \(index) x")
            XCTAssertEqual(got.y, want.y, accuracy: 0.05, "frame \(index) y")
        }
    }

    func testTwoFramesAndFourFramesPickTheExpectedReference() throws {
        XCTAssertEqual(try PanoramaPlan.plan(pairs: [translation(500)], frameWidth: 1000, frameHeight: 600).get().referenceIndex, 0)
        XCTAssertEqual(try PanoramaPlan.plan(pairs: [translation(500), translation(500), translation(500)], frameWidth: 1000, frameHeight: 600).get().referenceIndex, 1)
    }

    func testRotationInThePairsIsChainedNotJustTranslation() throws {
        let t = Float(3 * Double.pi / 180)
        let rot = simd_float3x3(columns: (SIMD3(cos(t), sin(t), 0), SIMD3(-sin(t), cos(t), 0), SIMD3(600, 0, 1)))
        let plan = try PanoramaPlan.plan(pairs: [rot, rot], frameWidth: 1000, frameHeight: 600).get()
        // Frame 2 -> reference is `rot`; frame 0 -> reference is rot^-1. A point and its image through each pair must meet on the canvas.
        let p = SIMD2<Float>(250, 120)
        let viaChain = apply(plan.placements[2].toCanvas, p)
        let viaReference = apply(plan.placements[1].toCanvas, apply(rot, p))
        XCTAssertEqual(viaChain.x, viaReference.x, accuracy: 1e-2)
        XCTAssertEqual(viaChain.y, viaReference.y, accuracy: 1e-2)
    }

    // MARK: Refusals

    func testRefusesTooFewTooManyFramesAndImplausibleGeometry() {
        XCTAssertEqual(PanoramaPlan.plan(pairs: [], frameWidth: 100, frameHeight: 100), .failure(.tooFewFrames))
        let many = [simd_float3x3](repeating: translation(100), count: PanoramaPlan.maxFrames)
        XCTAssertEqual(PanoramaPlan.plan(pairs: many, frameWidth: 1000, frameHeight: 600), .failure(.tooManyFrames(limit: PanoramaPlan.maxFrames)))
        // A mirrored pair (x flipped) is not a photo-to-photo map.
        let mirrored = simd_float3x3(columns: (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(900, 0, 1)))
        XCTAssertEqual(PanoramaPlan.plan(pairs: [mirrored], frameWidth: 1000, frameHeight: 600), .failure(.implausibleFrame(index: 1)))
        // A pair whose perspective term sends the far corner behind the camera.
        let runaway = simd_float3x3(columns: (SIMD3(1, 0, -0.002), SIMD3(0, 1, 0), SIMD3(0, 0, 1)))
        XCTAssertEqual(PanoramaPlan.plan(pairs: [runaway], frameWidth: 1000, frameHeight: 600), .failure(.implausibleFrame(index: 1)))
        // A collapsed frame (scale 0.1).
        let collapsed = simd_float3x3(columns: (SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(0, 0, 1)))
        XCTAssertEqual(PanoramaPlan.plan(pairs: [collapsed], frameWidth: 1000, frameHeight: 600), .failure(.implausibleFrame(index: 1)))
    }

    func testRefusesACanvasBeyondTheLimit() {
        // Two frames 30000 px apart at 20000 x 20000 each: 50000 x 20000 = 1 Gpx.
        XCTAssertEqual(PanoramaPlan.plan(pairs: [translation(30_000)], frameWidth: 20_000, frameHeight: 20_000), .failure(.canvasTooLarge))
    }

    func testNormalizationKeepsTheBottomRightEntryAtOne() {
        let m = simd_float3x3(columns: (SIMD3(2, 0, 0), SIMD3(0, 2, 0), SIMD3(10, 20, 2)))
        XCTAssertEqual(PanoramaPlan.normalized(m).columns.2.z, 1, accuracy: 1e-6)
        XCTAssertEqual(PanoramaPlan.normalized(m).columns.2.x, 5, accuracy: 1e-6)
    }

    // MARK: Exposure chain and ordering

    func testExposureGainsAreChainedFromTheReferenceInBothDirections() {
        // Frame brightness 0.8, 1.0, 1.25, 1.5 relative to frame 1... pairs: f1/f0 = 1.25, f2/f1 = 1.25, f3/f2 = 1.2; reference 1.
        let g = PanoramaPlan.exposureGains(pairGains: [1.25, 1.25, 1.2], referenceIndex: 1)
        XCTAssertEqual(g[1], 1)
        XCTAssertEqual(g[0], 1 / 1.25, accuracy: 1e-6, "frame 0 is darker than the reference by the first pair's ratio")
        XCTAssertEqual(g[2], 1.25, accuracy: 1e-6)
        XCTAssertEqual(g[3], 1.5, accuracy: 1e-6, "1.25 * 1.2")
        // Five frames, reference 2, ratios on both sides of two steps each.
        let h = PanoramaPlan.exposureGains(pairGains: [1.1, 1.2, 0.9, 0.8], referenceIndex: 2)
        XCTAssertEqual(h[0], 1 / (1.2 * 1.1), accuracy: 1e-6)
        XCTAssertEqual(h[1], 1 / 1.2, accuracy: 1e-6)
        XCTAssertEqual(h[3], 0.9, accuracy: 1e-6)
        XCTAssertEqual(h[4], 0.9 * 0.8, accuracy: 1e-6)
        XCTAssertEqual(PanoramaPlan.exposureGains(pairGains: [1.1], referenceIndex: 7), [1, 1], "a bad reference index leaves everything at 1")
    }

    func testShootingOrderUsesCaptureDatesThenNames() {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 1005), t2 = Date(timeIntervalSince1970: 1010)
        XCTAssertEqual(PanoramaPlan.shootingOrder(dates: [t2, t0, t1], names: ["a", "b", "c"]), [1, 2, 0])
        // One frame without a date: dates cannot be trusted at all, so file names decide.
        XCTAssertEqual(PanoramaPlan.shootingOrder(dates: [t2, nil, t0], names: ["IMG_2", "IMG_10", "IMG_1"]), [2, 0, 1], "natural name order: 1, 2, 10")
        // Equal dates (a burst within one second) fall back to names.
        XCTAssertEqual(PanoramaPlan.shootingOrder(dates: [t0, t0, t0], names: ["IMG_3", "IMG_1", "IMG_2"]), [1, 2, 0])
        XCTAssertEqual(PanoramaPlan.shootingOrder(dates: [nil], names: ["a", "b"]), [0, 1], "mismatched input is returned in order")
    }

    // MARK: Auto-crop and EXIF dates

    func testAutoCropOfAVerticallyStaggeredPairIsTheCommonBand() throws {
        // Frame B sits 800 px right and 40 px DOWN of A (B -> A: +800, -40 in A's coordinates would put B above; here +800, +40 puts B lower).
        let plan = try PanoramaPlan.plan(pairs: [translation(800, 40)], frameWidth: 1000, frameHeight: 600).get()
        XCTAssertEqual(plan.canvasWidth, 1800)
        XCTAssertEqual(plan.canvasHeight, 640)
        let crop = try XCTUnwrap(PanoramaPlan.autoCropRectangle(plan: plan, frameWidth: 1000, frameHeight: 600))
        // The full-width valid band is the rows both frames cover: 40...600 of the 640-high canvas (560 rows) over all 1800 columns, less the margin.
        XCTAssertEqual(Double(crop.width), 1800, accuracy: 30)
        XCTAssertEqual(Double(crop.height), 560, accuracy: 30)
        XCTAssertEqual(Double(crop.y), 44, accuracy: 30)
        // Every pixel of the crop is inside the canvas.
        XCTAssertGreaterThanOrEqual(crop.x, 0); XCTAssertGreaterThanOrEqual(crop.y, 0)
        XCTAssertLessThanOrEqual(crop.x + crop.width, plan.canvasWidth); XCTAssertLessThanOrEqual(crop.y + crop.height, plan.canvasHeight)
    }

    func testAutoCropOfARotatedFrameExcludesTheEmptyWedges() throws {
        let t = Float(4 * Double.pi / 180)
        let rotated = simd_float3x3(columns: (SIMD3(cos(t), sin(t), 0), SIMD3(-sin(t), cos(t), 0), SIMD3(850, 0, 1)))
        let plan = try PanoramaPlan.plan(pairs: [rotated], frameWidth: 1000, frameHeight: 600).get()
        let crop = try XCTUnwrap(PanoramaPlan.autoCropRectangle(plan: plan, frameWidth: 1000, frameHeight: 600))
        // The rectangle must lie inside the union of the two quads: sample its corners and edge midpoints against both.
        let quads = plan.placements.map { PanoramaPlan.mappedCorners($0.toCanvas, 1000, 600)! }
        func inside(_ quad: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
            let poly = [quad[0], quad[1], quad[3], quad[2]]
            return (0..<4).allSatisfy { k in let a = poly[k], b = poly[(k + 1) % 4]; return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -0.5 }
        }
        let xs = [Float(crop.x), Float(crop.x + crop.width / 2), Float(crop.x + crop.width)], ys = [Float(crop.y), Float(crop.y + crop.height / 2), Float(crop.y + crop.height)]
        for x in xs { for y in ys { XCTAssertTrue(quads.contains { inside($0, SIMD2(x, y)) }, "(\(x), \(y)) is outside every frame") } }
        XCTAssertLessThan(crop.width * crop.height, plan.canvasWidth * plan.canvasHeight, "the crop is smaller than the ragged canvas")
        XCTAssertGreaterThan(crop.width * crop.height, plan.canvasWidth * plan.canvasHeight / 2)
    }

    /// Coarse mask cells are many full-resolution pixels wide on a real panorama (an 18000 px canvas at an 800 px mask is 22 px per cell). Every
    /// pixel of the returned rectangle must still lie inside a frame: forced here with a tiny mask (long edge 40) on a slanted plan.
    func testAutoCropNeverIncludesAnUncoveredPixelEvenWithCoarseMaskCells() throws {
        let t = Float(3 * Double.pi / 180)
        let tilted = simd_float3x3(columns: (SIMD3(cos(t), sin(t), 0.00002), SIMD3(-sin(t), cos(t), 0), SIMD3(2400, 90, 1)))
        let plan = try PanoramaPlan.plan(pairs: [tilted, tilted], frameWidth: 4000, frameHeight: 3000).get()
        let quads = plan.placements.map { PanoramaPlan.mappedCorners($0.toCanvas, 4000, 3000)! }
        func covered(_ p: SIMD2<Float>) -> Bool {
            quads.contains { quad in
                let poly = [quad[0], quad[1], quad[3], quad[2]]
                return (0..<4).allSatisfy { k in let a = poly[k], b = poly[(k + 1) % 4]; return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-3 }
            }
        }
        for maskLongEdge in [40, 100, 800] {
            let crop = try XCTUnwrap(PanoramaPlan.autoCropRectangle(plan: plan, frameWidth: 4000, frameHeight: 3000, maskLongEdge: maskLongEdge))
            XCTAssertGreaterThan(crop.width * crop.height, 0)
            // Every pixel centre on the rectangle's border and on a dense grid inside it.
            var points: [SIMD2<Float>] = []
            for i in 0...40 {
                let fx = Float(crop.x) + (Float(crop.width) - 1) * Float(i) / 40, fy = Float(crop.y) + (Float(crop.height) - 1) * Float(i) / 40
                points += [SIMD2(fx, Float(crop.y)), SIMD2(fx, Float(crop.y + crop.height - 1)), SIMD2(Float(crop.x), fy), SIMD2(Float(crop.x + crop.width - 1), fy)]
            }
            for p in points { XCTAssertTrue(covered(p + SIMD2(0.5, 0.5)), "mask \(maskLongEdge): (\(p.x), \(p.y)) of crop \(crop) is outside every frame") }
        }
    }

    func testParsingExifDatesWithAndWithoutSubseconds() throws {
        let a = try XCTUnwrap(PanoramaPlan.parseExifDate("2023:03:18 10:27:31", subsecond: nil))
        let b = try XCTUnwrap(PanoramaPlan.parseExifDate("2023:03:18 10:27:31", subsecond: "37"))
        let c = try XCTUnwrap(PanoramaPlan.parseExifDate("2023:03:18 10:27:32", subsecond: nil))
        XCTAssertEqual(b.timeIntervalSince(a), 0.37, accuracy: 1e-6)
        XCTAssertEqual(c.timeIntervalSince(a), 1, accuracy: 1e-6)
        XCTAssertNil(PanoramaPlan.parseExifDate("garbage", subsecond: nil))
        XCTAssertNil(PanoramaPlan.parseExifDate("2023:13:45 99:99:99", subsecond: nil), "an impossible date is rejected")
        XCTAssertEqual(PanoramaPlan.parseExifDate("2023:03:18 10:27:31", subsecond: "x1")?.timeIntervalSince(a), 0, "a non-numeric sub-second field is ignored")
    }

    // MARK: Largest rectangle

    private func mask(_ rows: [String]) -> (mask: [Bool], width: Int, height: Int) {
        (rows.flatMap { $0.map { $0 == "#" } }, rows[0].count, rows.count)
    }

    func testLargestRectangleFindsTheBestBlockInARaggedMask() {
        let m = mask(["..####..",
                      ".#####..",
                      "########",
                      "########",
                      ".#######",
                      "..######"])
        let r = LargestRectangle.find(mask: m.mask, width: m.width, height: m.height)
        // Two blocks tie at area 24 (columns 2..5 x rows 0..5, and columns 2..7 x rows 2..5); the first found wins, and it must be fully valid.
        let found = try? XCTUnwrap(r)
        XCTAssertEqual(found?.area, 24)
        if let found {
            for y in found.y..<(found.y + found.height) { for x in found.x..<(found.x + found.width) { XCTAssertTrue(m.mask[y * m.width + x], "(\(x), \(y)) is not valid") } }
        }
    }

    func testLargestRectangleEdgeCases() {
        XCTAssertNil(LargestRectangle.find(mask: [], width: 0, height: 0))
        XCTAssertNil(LargestRectangle.find(mask: [true, true], width: 3, height: 1), "size mismatch")
        XCTAssertNil(LargestRectangle.find(mask: [false, false, false, false], width: 2, height: 2), "nothing valid")
        XCTAssertEqual(LargestRectangle.find(mask: [Bool](repeating: true, count: 12), width: 4, height: 3), .init(x: 0, y: 0, width: 4, height: 3))
        XCTAssertEqual(LargestRectangle.find(mask: [false, true, false], width: 3, height: 1), .init(x: 1, y: 0, width: 1, height: 1))
    }

    func testLargestRectangleMatchesABruteForceSearchOnRandomMasks() {
        var state: UInt64 = 7
        func next() -> Bool { state = state &* 6364136223846793005 &+ 1442695040888963407; return (state >> 33) % 100 < 80 }
        for trial in 0..<30 {
            let w = 3 + trial % 9, h = 2 + trial % 7
            let m = (0..<(w * h)).map { _ in next() }
            var bestArea = 0
            for y0 in 0..<h { for x0 in 0..<w { for y1 in y0..<h { for x1 in x0..<w {
                var ok = true
                for y in y0...y1 { for x in x0...x1 where !m[y * w + x] { ok = false } }
                if ok { bestArea = max(bestArea, (y1 - y0 + 1) * (x1 - x0 + 1)) }
            } } } }
            XCTAssertEqual(LargestRectangle.find(mask: m, width: w, height: h)?.area ?? 0, bestArea, "trial \(trial)")
        }
    }
}
