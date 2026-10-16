import CoreImage
import XCTest
@testable import PhotoApp

/// D64: the parametric Shadows / Highlights / Black Point (/ Whites) curve is a natural cubic through five points, which for some slider
/// COMBINATIONS bends backwards (Shadows +1 with Highlights +1 gave the top an end slope of -0.0286; Highlights +1 with Black Point -1,
/// -0.0925), so the brightest tones and the headroom came out DARKER than slightly less bright ones. The fix eases the slider displacements
/// back, together, only for curves that really reverse; every other curve must be bit-identical to what it always was.
final class ParametricCurveMonotoneTests: XCTestCase {
    /// The app builds the parametric curve from THREE sliders — Shadows, Highlights, Black Point — as one curve, and renders Whites as its own
    /// separate curve with the other three at zero (global: `applyCurves(identityTone, 0, whitePoint:)`; per mask the same), so a curve combining
    /// Whites with the rest never reaches the kernel. The grids below are the real space.
    private let steps = stride(from: -1.0, through: 1.0, by: 0.25).map { $0 }

    private func raw(_ sh: Double, _ hi: Double, _ bp: Double, _ wh: Double = 0) -> [CGPoint] {
        EditPipeline.rawParametricControlPoints(shadows: sh, highlights: hi, blackPoint: bp, whitePoint: wh)
    }

    private func guarded(_ sh: Double, _ hi: Double, _ bp: Double, _ wh: Double = 0) -> [CGPoint] {
        EditPipeline.parametricControlPoints(shadows: sh, highlights: hi, blackPoint: bp, whitePoint: wh)
    }

    // MARK: the invariant that protects every saved edit

    func testACurveThatAlreadyDoesNotReverseIsBitIdenticalToTheRawOne() {
        // (This uses the same test as the guard's early return, so it is a consistency check; the two tests below are the independent protection.)
        var unchanged = 0
        for sh in steps { for hi in steps { for bp in steps {
            guard let spline = ToneCurveSpline(points: raw(sh, hi, bp)), spline.isEffectivelyMonotone else { continue }
            XCTAssertEqual(guarded(sh, hi, bp), raw(sh, hi, bp), "sh \(sh) hi \(hi) bp \(bp) must not change")
            unchanged += 1
        } } }
        XCTAssertEqual(unchanged, 573, accuracy: 15, "measured: 573 of the 729 grid points are untouched")
    }

    func testEveryCombinationWithinHalfARangeIsUntouched() {
        // The ordinary range of use: no slider beyond +/-0.5. Measured: the deepest reversal there is 0.0007, far under the tolerance.
        let half = stride(from: -0.5, through: 0.5, by: 0.125).map { $0 }
        for sh in half { for hi in half { for bp in half {
            XCTAssertEqual(guarded(sh, hi, bp), raw(sh, hi, bp), "sh \(sh) hi \(hi) bp \(bp)")
        } } }
    }

    func testTheIdentityAndEverySingleSliderAtAnyPositionIncludingItsLimitsAreUntouched() {
        // Single-slider curves are pinned against Apple's CIToneCurve measurements: Black Point -1 alone (a 0.0104 dip) must not move.
        XCTAssertEqual(guarded(0, 0, 0), raw(0, 0, 0))
        for value in stride(from: -1.0, through: 1.0, by: 0.125) {
            XCTAssertEqual(guarded(value, 0, 0), raw(value, 0, 0))
            XCTAssertEqual(guarded(0, value, 0), raw(0, value, 0))
            XCTAssertEqual(guarded(0, 0, value), raw(0, 0, value))
        }
    }

    func testWhitesIsAlwaysItsOwnCurveAndNeverReversesSoItIsUntouched() {
        // Whites reaches the kernel alone (the other three at 0): its curve is untouched at every position.
        for value in stride(from: -1.0, through: 1.0, by: 0.125) {
            XCTAssertTrue(ToneCurveSpline(points: raw(0, 0, 0, value))!.isEffectivelyMonotone, "whites \(value)")
            XCTAssertEqual(guarded(0, 0, 0, value), raw(0, 0, 0, value))
        }
    }

    // MARK: curves that do reverse are fixed, proportionally

    func testEveryReversingCombinationEndsUpMonotoneAndIsTheRawOneScaledByOneCommonFactor() {
        var fixed = 0
        for sh in steps { for hi in steps { for bp in steps {
            guard let rawSpline = ToneCurveSpline(points: raw(sh, hi, bp)), !rawSpline.isEffectivelyMonotone else { continue }
            fixed += 1
            let points = guarded(sh, hi, bp)
            XCTAssertTrue(ToneCurveSpline(points: points)!.isEffectivelyMonotone, "sh \(sh) hi \(hi) bp \(bp)")
            // One factor s for every slider: the guarded points are the raw construction at (sliders * s).
            let s = Self.scale(of: points, sh: sh, hi: hi, bp: bp)
            XCTAssertGreaterThan(s, 0.55, "never collapses toward the identity (measured smallest 0.592): sh \(sh) hi \(hi) bp \(bp)")
            XCTAssertLessThan(s, 1)
            let expected = raw(sh * s, hi * s, bp * s)
            for (a, b) in zip(points, expected) {
                XCTAssertEqual(Double(a.x), Double(b.x), accuracy: 1e-12, "sh \(sh) hi \(hi) bp \(bp)")
                XCTAssertEqual(Double(a.y), Double(b.y), accuracy: 1e-12, "sh \(sh) hi \(hi) bp \(bp)")
            }
        } } }
        XCTAssertEqual(fixed, 156, accuracy: 15, "measured: 156 of 729 — the combinations with two or more sliders well away from zero")
    }

    /// The factor that was applied, recovered from whichever slider is non-zero (point displacements are linear in the slider).
    private static func scale(of points: [CGPoint], sh: Double, hi: Double, bp: Double) -> Double {
        if abs(hi) > 1e-12 { return (Double(points[3].y) - 0.75) / (0.15 * hi) }
        if abs(sh) > 1e-12 { return (Double(points[1].y) - 0.25) / (0.15 * sh) }
        if abs(bp) > 1e-12 { return (Double(points[0].x) + Double(points[0].y)) / (0.20 * abs(bp)) }
        return 1
    }

    func testTheGuardEasesBackOnlyAsFarAsNeededAndTheSafeScalesFormAnInterval() {
        // For EVERY reversing grid point: any larger factor up to 1 still reverses (so the chosen one is the largest, and the scan+bisection
        // is sound because the monotone scales form an interval).
        for sh in steps { for hi in steps { for bp in steps {
            guard let rawSpline = ToneCurveSpline(points: raw(sh, hi, bp)), !rawSpline.isEffectivelyMonotone else { continue }
            let s = Self.scale(of: guarded(sh, hi, bp), sh: sh, hi: hi, bp: bp)
            var larger = s + 0.01
            while larger <= 1 {
                XCTAssertFalse(ToneCurveSpline(points: raw(sh * larger, hi * larger, bp * larger))!.isEffectivelyMonotone,
                               "sh \(sh) hi \(hi) bp \(bp): scale \(larger) > \(s) is still monotone, so \(s) is not the largest")
                larger += 0.01
            }
        } } }
    }

    func testTheGuardIsContinuousNoPopWhereAnEditStartsToBeEasedBack() {
        // Along a ray from the identity out to a corner, the control points never jump: a reversing curve starts at factor ~1 right at the boundary.
        // An unguarded ray step of 0.001 moves a point by at most 0.00015; the guarded one by 0.0002 (measured) — assert a generous 0.001.
        for (sh, hi, bp) in [(1.0, 1.0, 0.0), (0.0, 1.0, -1.0), (1.0, -1.0, -1.0), (-1.0, -1.0, 0.5), (1.0, 1.0, 1.0), (-1.0, 1.0, -1.0)] {
            var previous = guarded(0, 0, 0)
            for k in 1...1000 {
                let t = Double(k) / 1000
                let points = guarded(sh * t, hi * t, bp * t)
                for (a, b) in zip(points, previous) {
                    XCTAssertLessThan(abs(Double(a.x - b.x)), 0.001, "ray (\(sh), \(hi), \(bp)) at t \(t)")
                    XCTAssertLessThan(abs(Double(a.y - b.y)), 0.001, "ray (\(sh), \(hi), \(bp)) at t \(t)")
                }
                previous = points
            }
        }
    }

    // MARK: the named D64 cases, with the numbers recorded for them

    func testShadowsPlusOneWithHighlightsPlusOneNoLongerDarkensTheTop() {
        let rawSpline = ToneCurveSpline(points: raw(1, 1, 0))!
        XCTAssertEqual(rawSpline.endSlope, -0.0286, accuracy: 0.001, "the recorded defect")
        XCTAssertFalse(rawSpline.isEffectivelyMonotone)
        let fixed = ToneCurveSpline(points: guarded(1, 1, 0))!
        XCTAssertGreaterThanOrEqual(fixed.endSlope, 0)
        XCTAssertEqual(Self.scale(of: guarded(1, 1, 0), sh: 1, hi: 1, bp: 0), 0.972, accuracy: 0.01)
        // The headroom above white (encoded 1.0 and beyond) no longer falls: it used to.
        XCTAssertLessThan(rawSpline.splineValue(atEncoded: 1.3), rawSpline.splineValue(atEncoded: 1.0))
        XCTAssertGreaterThanOrEqual(fixed.splineValue(atEncoded: 1.3), fixed.splineValue(atEncoded: 1.0))
        // And the price is small: the whole curve moves by well under half a percent.
        var delta = 0.0
        for i in 0...200 { let u = Double(i) / 200; delta = max(delta, abs(rawSpline.splineValue(atEncoded: u) - fixed.splineValue(atEncoded: u))) }
        XCTAssertLessThan(delta, 0.006)
    }

    func testHighlightsPlusOneWithBlackPointMinusOneNoLongerDarkensTheTop() {
        let rawSpline = ToneCurveSpline(points: raw(0, 1, -1))!
        XCTAssertEqual(rawSpline.endSlope, -0.0925, accuracy: 0.001, "the recorded defect")
        let fixed = ToneCurveSpline(points: guarded(0, 1, -1))!
        XCTAssertTrue(fixed.isEffectivelyMonotone)
        XCTAssertGreaterThanOrEqual(fixed.endSlope, 0)
        XCTAssertLessThan(rawSpline.splineValue(atEncoded: 1.4), rawSpline.splineValue(atEncoded: 1.0))
        XCTAssertGreaterThanOrEqual(fixed.splineValue(atEncoded: 1.4), fixed.splineValue(atEncoded: 1.0))
    }

    func testTheTopOfARenderedRampNeverGetsDarkerNowThroughTheRealPipeline() throws {
        // Highlights +1 with Black Point -1, a ramp from black up to 1.5 (headroom above white), rendered through the real kernel.
        var state = EditState()
        state.curvesHighlights = 1
        state.blackPoint = -1
        let width = 96
        var pixels = [Float](repeating: 1, count: width * 4)
        for x in 0..<width { let v = Float(x) / Float(width - 1) * 1.5; pixels[x * 4] = v; pixels[x * 4 + 1] = v; pixels[x * 4 + 2] = v }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let input = CIImage(bitmapData: Data(bytes: pixels, count: pixels.count * 4), bytesPerRow: width * 16, size: CGSize(width: width, height: 1),
                            format: .RGBAf, colorSpace: linear)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        var out = [Float](repeating: 0, count: width * 4)
        context.render(EditPipeline.apply(state, to: input), toBitmap: &out, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1), format: .RGBAf, colorSpace: linear)
        // Only the TOP half of the ramp: shallow dips (up to 0.015) near black are deliberately left alone.
        for x in (width / 2)..<width {
            XCTAssertGreaterThanOrEqual(out[x * 4], out[(x - 1) * 4] - 1e-4, "column \(x): the top of the render must not get darker as the input rises")
        }
    }

    // MARK: the spline measures

    func testTheIdentityCurveHasNoReversalAndAPositiveEndSlope() {
        let spline = ToneCurveSpline(points: raw(0, 0, 0))!
        XCTAssertEqual(spline.deepestReversal, 0, accuracy: 1e-12)
        XCTAssertTrue(spline.isEffectivelyMonotone)
    }

    func testADeepDipIsReportedAndFailsTheCheckEvenWithAPositiveEndSlope() {
        // 0 -> 0.5 -> a dip back to 0.3 -> up to 1: clearly reversed in the middle.
        let spline = ToneCurveSpline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.75, y: 0.8), CGPoint(x: 1, y: 1)])!
        XCTAssertGreaterThan(spline.deepestReversal, 0.1)
        XCTAssertGreaterThan(spline.endSlope, 0)
        XCTAssertFalse(spline.isEffectivelyMonotone)
    }

    func testAShallowDipUnderTheToleranceIsIgnoredButANegativeEndSlopeIsNot() {
        XCTAssertLessThan(ToneCurveSpline(points: raw(1, 1, 0))!.deepestReversal, ToneCurveSpline.reversalTolerance, "the D64 top case is shallow")
        XCTAssertFalse(ToneCurveSpline(points: raw(1, 1, 0))!.isEffectivelyMonotone, "but its negative end slope still counts")
        XCTAssertTrue(ToneCurveSpline(points: raw(0, 0, 1))!.isEffectivelyMonotone, "Black Point +1 dips by 0.0004: left alone")
        let blackMinusOne = ToneCurveSpline(points: raw(0, 0, -1))!
        XCTAssertGreaterThan(blackMinusOne.deepestReversal, 0.01, "Black Point -1 alone really does dip (0.0104)…")
        XCTAssertTrue(blackMinusOne.isEffectivelyMonotone, "…and is left alone on purpose: its curve is pinned against CIToneCurve")
    }

    func testTheGenericGuardFindsTheLargestMonotoneScale() {
        // A synthetic family that is monotone up to scale 0.5 and reverses beyond.
        let build: (Double) -> [CGPoint] = { s in
            [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5 + max(0, s - 0.5) * 2), CGPoint(x: 0.75, y: 0.75 - max(0, s - 0.5) * 2), CGPoint(x: 1, y: 1)]
        }
        let result = ToneCurveSpline.monotonePoints(build: build)
        XCTAssertTrue(ToneCurveSpline(points: result)!.isEffectivelyMonotone)
        let reachedScale = Double(result[2].y - 0.5) / 2 + 0.5
        XCTAssertGreaterThan(reachedScale, 0.45)
        XCTAssertLessThan(reachedScale, 0.56)
    }

    func testNothingElseBuildsTheRawParametricPoints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pipeline = try String(contentsOf: root.appendingPathComponent("Sources/EditEngine/EditPipeline.swift"), encoding: .utf8)
        XCTAssertEqual(pipeline.components(separatedBy: "rawParametricControlPoints(").count - 1, 2, "the definition and the one call inside the guard")
        XCTAssertTrue(pipeline.contains("parametricControlPoints(shadows: effective.shadows, highlights: effective.highlights, blackPoint: blackPoint, whitePoint: whitePoint)"),
                      "the global stage AND the per-mask stages reach the curve through the guard")
    }
}
