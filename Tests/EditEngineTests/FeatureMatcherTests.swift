import simd
import XCTest
@testable import PhotoApp

final class FeatureMatcherTests: XCTestCase {
    // MARK: Fixtures

    /// A continuous textured "world" (seeded Gaussian blobs); `render` samples it through an affine map so truth is exact:
    /// target(p) = world(A p + t), reference(p) = world(p)  =>  the TARGET -> REFERENCE map is p -> A p + t.
    private struct World {
        let blobs: [(x: Float, y: Float, size: Float, value: Float)]
        init(seed: UInt64 = 0xFEEDFACE, extent: Float = 700) {
            var s = seed
            func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 33) & 0xFFFF) / 65535 }
            blobs = (0..<400).map { _ in (next() * extent, next() * extent, 3 + next() * 8, next()) }
        }
        func value(_ x: Float, _ y: Float) -> Float {
            var v: Float = 0.2
            for b in blobs {
                let q = ((x - b.x) * (x - b.x) + (y - b.y) * (y - b.y)) / (b.size * b.size)
                if q < 9 { v += (b.value - 0.2) * exp(-q) }
            }
            return min(max(v, 0), 1)
        }
        func render(width: Int = 320, height: Int = 240, a: simd_float2x2 = matrix_identity_float2x2, t: SIMD2<Float> = .zero) -> FeatureMatcher.GrayImage {
            var px = [Float](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width {
                let w = a * SIMD2(Float(x), Float(y)) + t
                px[y * width + x] = value(w.x, w.y)
            } }
            return FeatureMatcher.GrayImage(width: width, height: height, pixels: px)!
        }
    }

    private func homography(a: simd_float2x2, t: SIMD2<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(a.columns.0.x, a.columns.0.y, 0), SIMD3(a.columns.1.x, a.columns.1.y, 0), SIMD3(t.x, t.y, 1)))
    }

    private func meanError(_ h: simd_float3x3, truth: simd_float3x3, width: Int = 320, height: Int = 240) -> Float {
        var errors: [Float] = []
        for y in stride(from: 30, to: height - 30, by: 30) { for x in stride(from: 30, to: width - 30, by: 30) {
            let p = SIMD2(Float(x), Float(y))
            errors.append(simd_distance(FeatureMatcher.apply(h, to: p), FeatureMatcher.apply(truth, to: p)))
        } }
        return errors.reduce(0, +) / Float(errors.count)
    }

    private func rotation(_ degrees: Float, scale: Float = 1) -> simd_float2x2 {
        let t = degrees * .pi / 180
        return simd_float2x2(columns: (SIMD2(cos(t), sin(t)) * scale, SIMD2(-sin(t), cos(t)) * scale))
    }

    // MARK: Linear algebra and fitting

    func testSolveRecoversAKnownSolutionAndRejectsASingularSystem() throws {
        let solution = try XCTUnwrap(FeatureMatcher.solve([[2, 1, -1], [-3, -1, 2], [-2, 1, 2]], [8, -11, -3]))
        XCTAssertEqual(solution[0], 2, accuracy: 1e-9)
        XCTAssertEqual(solution[1], 3, accuracy: 1e-9)
        XCTAssertEqual(solution[2], -1, accuracy: 1e-9)
        XCTAssertNil(FeatureMatcher.solve([[1, 2], [2, 4]], [1, 2]), "linearly dependent rows")
    }

    private func matches(under h: simd_float3x3, count: Int = 30) -> [FeatureMatcher.Match] {
        (0..<count).map { i in
            let p = SIMD2(Float((i * 37) % 300) + 10, Float((i * 53) % 220) + 10)
            return FeatureMatcher.Match(target: p, reference: FeatureMatcher.apply(h, to: p))
        }
    }

    func testFitHomographyRecoversAnExactProjectiveTransform() throws {
        let truth = simd_float3x3(columns: (SIMD3(1.05, 0.04, 0.0002), SIMD3(-0.03, 0.98, -0.0001), SIMD3(25, -12, 1)))
        let fitted = try XCTUnwrap(FeatureMatcher.fitHomography(matches(under: truth)))
        XCTAssertLessThan(meanError(fitted, truth: truth), 0.01)
    }

    func testFitHomographyNeedsFourCorrespondences() {
        XCTAssertNil(FeatureMatcher.fitHomography(Array(matches(under: matrix_identity_float3x3).prefix(3))))
    }

    func testRansacRecoversTheModelDespiteGrossOutliers() throws {
        let truth = homography(a: rotation(4), t: SIMD2(30, -8))
        var all = matches(under: truth, count: 60)
        for i in 0..<30 { // outliers: right target positions, wrong reference positions
            all.append(.init(target: SIMD2(Float(20 + (i * 41) % 280), Float(20 + (i * 29) % 200)), reference: SIMD2(Float((i * 97) % 320), Float((i * 71) % 240))))
        }
        let (h, inliers) = try XCTUnwrap(FeatureMatcher.ransac(all))
        XCTAssertGreaterThanOrEqual(inliers, 58)
        XCTAssertLessThan(meanError(h, truth: truth), 0.05)
    }

    func testRansacReturnsNilWithTooFewMatchesOrNoConsistentModel() {
        XCTAssertNil(FeatureMatcher.ransac(Array(matches(under: matrix_identity_float3x3, count: FeatureMatcher.minimumInliers - 1))))
        var noise: [FeatureMatcher.Match] = []
        for i in 0..<40 {
            let target = SIMD2<Float>(Float((i * 37) % 300), Float((i * 53) % 220))
            let reference = SIMD2<Float>(Float((i * 131) % 317), Float((i * 89) % 233))
            noise.append(FeatureMatcher.Match(target: target, reference: reference))
        }
        XCTAssertNil(FeatureMatcher.ransac(noise), "unrelated point pairs must not produce a model")
    }

    // MARK: Plausibility and scaling

    func testPlausibilityRejectsMirroringCollapseAndRunawayPerspective() {
        XCTAssertTrue(FeatureMatcher.isPlausible(matrix_identity_float3x3, width: 320, height: 240))
        let mirrored = simd_float3x3(columns: (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(320, 0, 1)))
        let collapsed = simd_float3x3(columns: (SIMD3(0.05, 0, 0), SIMD3(0, 0.05, 0), SIMD3(0, 0, 1)))
        let perspective = simd_float3x3(columns: (SIMD3(1, 0, 0.01), SIMD3(0, 1, 0), SIMD3(0, 0, 1))) // w = 1 + 0.01x: negative-ish near x = -100 only; corner x=320 gives 4.2
        let runaway = simd_float3x3(columns: (SIMD3(1, 0, -0.004), SIMD3(0, 1, 0), SIMD3(0, 0, 1))) // w = 1 - 0.004*320 = -0.28 at the far corner
        XCTAssertFalse(FeatureMatcher.isPlausible(mirrored, width: 320, height: 240))
        XCTAssertFalse(FeatureMatcher.isPlausible(collapsed, width: 320, height: 240))
        XCTAssertTrue(FeatureMatcher.isPlausible(perspective, width: 320, height: 240))
        XCTAssertFalse(FeatureMatcher.isPlausible(runaway, width: 320, height: 240))
    }

    func testScaledHomographyMapsScaledPointsConsistently() {
        let h = simd_float3x3(columns: (SIMD3(1.02, 0.03, 0.0001), SIMD3(-0.02, 1.01, 0), SIMD3(15, -6, 1)))
        let p = SIMD2<Float>(100, 70)
        let direct = FeatureMatcher.apply(h, to: p) * 2
        let viaScaled = FeatureMatcher.apply(FeatureMatcher.scaled(h, by: 2), to: p * 2)
        XCTAssertEqual(direct.x, viaScaled.x, accuracy: 1e-3)
        XCTAssertEqual(direct.y, viaScaled.y, accuracy: 1e-3)
    }

    func testGrayImageRejectsAMismatchedBuffer() {
        XCTAssertNil(FeatureMatcher.GrayImage(width: 4, height: 4, pixels: [Float](repeating: 0, count: 15)))
        XCTAssertNil(FeatureMatcher.GrayImage(width: 0, height: 4, pixels: []))
    }

    // MARK: End to end on textured synthetic images (exact truth)

    func testRegisterRecoversATranslation() throws {
        let world = World()
        let t = SIMD2<Float>(70, 18)
        let reference = world.render(), target = world.render(t: t)
        let r = try XCTUnwrap(FeatureMatcher.register(target: target, reference: reference))
        XCTAssertGreaterThanOrEqual(r.inlierCount, FeatureMatcher.minimumInliers)
        XCTAssertLessThan(meanError(r.homography, truth: homography(a: matrix_identity_float2x2, t: t)), 0.75)
    }

    func testRegisterRecoversRotationAndScale() throws {
        let world = World()
        let a = rotation(8, scale: 1.05), t = SIMD2<Float>(40, 10)
        let reference = world.render(), target = world.render(a: a, t: t)
        let r = try XCTUnwrap(FeatureMatcher.register(target: target, reference: reference))
        XCTAssertLessThan(meanError(r.homography, truth: homography(a: a, t: t)), 1.0)
    }

    func testRegisterReturnsNilForAFlatImageAndForUnrelatedContent() {
        let flat = FeatureMatcher.GrayImage(width: 200, height: 150, pixels: [Float](repeating: 0.5, count: 200 * 150))!
        XCTAssertNil(FeatureMatcher.register(target: flat, reference: flat))
        let a = World(seed: 1).render(), b = World(seed: 2).render()
        XCTAssertNil(FeatureMatcher.register(target: a, reference: b), "two different scenes must not register")
    }

    func testKeypointCapAndTinyImages() {
        let image = World().render()
        let set = FeatureMatcher.keypoints(in: image, maxCount: 25)
        XCTAssertEqual(set.count, 25, "a textured 320x240 image has far more than 25 corners, so the cap must be reached exactly")
        for i in 0..<set.count { for j in (i + 1)..<max(set.count, i + 1) {
            let d = set.points[i] - set.points[j]
            XCTAssertTrue(abs(d.x) > 8 || abs(d.y) > 8, "non-max suppression must keep accepted corners more than 8 px apart")
        } }
        XCTAssertEqual(set.descriptors.count, set.count * FeatureMatcher.descriptorLength)
        XCTAssertEqual(FeatureMatcher.keypoints(in: World().render(width: 20, height: 20), maxCount: 10).count, 0, "a textured image too small for a descriptor patch must yield nothing, not read out of bounds")
    }
}
