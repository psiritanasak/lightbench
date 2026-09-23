import XCTest
@testable import PhotoApp

/// Mirrors `WhiteBalanceSolverTests`'s style — see `AutoToneSolver` for what
/// this is used for. Every fixture here is a directly-constructed
/// `ToneStatistics`, not a rendered image — this suite is purely about the
/// solver's own math; `AutoToneEndToEndTests` (RenderingTests) exercises the
/// real measure -> solve -> render -> re-measure loop through actual images.
final class AutoToneSolverTests: XCTestCase {
    private func stats(
        p0_5: Double = 0.18, p5: Double = 0.18, p50: Double = 0.18, p95: Double = 0.18, p99_5: Double = 0.18,
        logAverageLuma: Double = 0.18, meanChroma: Double = 0.25, qualifyingPixelCount: Int = 65536
    ) -> ToneStatistics {
        ToneStatistics(
            percentile0_5: p0_5, percentile5: p5, percentile50: p50, percentile95: p95, percentile99_5: p99_5,
            logAverageLuma: logAverageLuma, meanChroma: meanChroma, qualifyingPixelCount: qualifyingPixelCount
        )
    }

    // MARK: - Exposure

    func testUnderexposedImageGivesPositiveEV() {
        let result = AutoToneSolver.solve(stats(logAverageLuma: 0.02))
        XCTAssertGreaterThan(result.exposureEV, 0)
    }

    func testOverexposedImageGivesNegativeEV() {
        let result = AutoToneSolver.solve(stats(logAverageLuma: 0.8))
        XCTAssertLessThan(result.exposureEV, 0)
    }

    func testWellExposedImageGivesZeroEV() {
        // logAverageLuma already AT the target key — no correction needed.
        let result = AutoToneSolver.solve(stats(logAverageLuma: 0.18))
        XCTAssertEqual(result.exposureEV, 0, accuracy: 0.001)
    }

    func testExposureEVIsClampedAtExtremes() {
        let veryDark = AutoToneSolver.solve(stats(logAverageLuma: 0.0001))
        XCTAssertEqual(veryDark.exposureEV, 3.0, accuracy: 0.001)

        let veryBright = AutoToneSolver.solve(stats(logAverageLuma: 5.0))
        XCTAssertEqual(veryBright.exposureEV, -3.0, accuracy: 0.001)
    }

    // MARK: - Black Point

    func testLiftedBlacksGiveNegativeBlackPoint() {
        // A linear 0.1 floor with no Exposure correction (logAverageLuma at
        // the target key, so EV ~= 0) encodes to a clearly-non-black
        // perceptual value — a real "no true black" image.
        let result = AutoToneSolver.solve(stats(p0_5: 0.1, logAverageLuma: 0.18))
        XCTAssertLessThan(result.blackPoint, 0)
    }

    func testTrueBlacksGiveZeroBlackPoint() {
        let result = AutoToneSolver.solve(stats(p0_5: 0.0001, logAverageLuma: 0.18))
        XCTAssertEqual(result.blackPoint, 0)
    }

    func testBlackPointSaturatesForAnyFloorNotVeryCloseToBlack() {
        // MEASURED (see `solveBlackPoint`'s own doc comment): given the
        // double-encode-corrected math, the mechanism's own reach is so
        // narrow that essentially any triggering floor beyond a razor-thin
        // near-black window already saturates the clamp — this is the
        // HONEST, common case, not the exception.
        let moderatelyLifted = AutoToneSolver.solve(stats(p0_5: 0.01, logAverageLuma: 0.18))
        XCTAssertEqual(moderatelyLifted.blackPoint, -0.5, accuracy: 0.001)

        let veryLifted = AutoToneSolver.solve(stats(p0_5: 0.9, logAverageLuma: 0.18))
        XCTAssertEqual(veryLifted.blackPoint, -0.5, accuracy: 0.001)
    }

    func testBlackPointGraduatesOnlyWithinItsNarrowNonSaturatingWindow() {
        // A floor MEASURED (see `solveBlackPoint`'s own doc comment) to sit
        // inside the mechanism's own narrow non-saturating window — this
        // pins that a real graduated response exists at all, not just the
        // saturated common case `testBlackPointSaturatesForAnyFloorNot
        // VeryCloseToBlack` covers.
        let barelyLifted = AutoToneSolver.solve(stats(p0_5: 0.00065, logAverageLuma: 0.18))
        XCTAssertLessThan(barelyLifted.blackPoint, 0)
        XCTAssertGreaterThan(barelyLifted.blackPoint, -0.5)
    }

    /// Reviewer-caught (Auto Tone planning session): `solveBlackPoint`'s
    /// FIRST draft assumed `point0.x` lives in the same single-encoded
    /// space as `predictedP0_5`, which is wrong (see that function's own
    /// doc comment for the full story) — this is the regression guard,
    /// run through the REAL `ToneCurveSpline` (the kernel's own Swift
    /// twin, including its own double `srgbEncode`), not just the
    /// solver's own math in isolation, which would still pass even if the
    /// solved `blackPoint` never actually reached the curve stage's own
    /// clip zone.
    func testBlackPointCurveActuallyClipsALiftedFloor() {
        // Inside the narrow non-saturating window (see the graduated test
        // above) — chosen so the fix's OWN claim ("the corrected curve
        // genuinely clips this exact floor level") is checked at a point
        // where clipping is neither trivially guaranteed (deep saturation)
        // nor trivially impossible.
        let liftedFloorLinear = 0.0005
        let predictedFloor = ToneCurveSpline.srgbEncode(liftedFloorLinear)
        let result = AutoToneSolver.solve(stats(p0_5: liftedFloorLinear, logAverageLuma: 0.18))
        XCTAssertLessThan(result.blackPoint, 0, "sanity: this floor should trigger Black Point")

        // Mirrors `EditPipeline.curveControlPoints`'s own 5-point
        // construction with Shadows/Highlights held at identity, isolating
        // Black Point's own contribution — `0.20` mirrors
        // `EditPipeline.kBlackPointSpan` (private there, duplicated both
        // here and in `AutoToneSolver` per this codebase's established
        // cross-reference pattern).
        let points = [
            CGPoint(x: max(0, -result.blackPoint) * 0.20, y: max(0, result.blackPoint) * 0.20),
            CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.75),
            CGPoint(x: 1, y: 1)
        ]
        guard let spline = ToneCurveSpline(points: points) else {
            XCTFail("expected a valid spline")
            return
        }

        // Feed the SAME single-encoded value the real kernel would see at
        // this pipeline stage (`predictedFloor`, matching `AutoToneSolver
        // .solve`'s own `predictedP0_5`) — `value(at:)` performs its OWN
        // encode/decode round trip on top, exactly like the kernel's own
        // SECOND encode.
        let curvedFloor = spline.value(at: predictedFloor)

        // The real regression: pre-fix, this comparison showed almost no
        // difference (undershooting by several times, never reaching the
        // clip zone at all). Post-fix, the curve genuinely pulls this
        // floor down toward black.
        XCTAssertLessThan(curvedFloor, predictedFloor * 0.5)
    }

    /// Reviewer-caught (Auto Tone planning session), found via the
    /// end-to-end tests, not this file: `kBlackTargetPerceptual` (0.005)
    /// sits far below `kShadowFloorPerceptual` (0.05), so almost any floor
    /// that triggers Shadows ALSO triggers Black Point — two fields with
    /// directly contradictory goals (lift vs. crush further) on the same
    /// pixels. `solveBlackPoint` now takes a `shadowsTriggered` flag and
    /// suppresses itself entirely when set. This pins that suppression
    /// directly: a floor low enough to trigger BOTH still yields
    /// `blackPoint == 0`, not its usual negative/saturated value.
    func testBlackPointIsSuppressedWhenShadowsAlsoTrigger() {
        // Both raw-linear values are chosen (and kept monotonic, p0_5 <=
        // p5, matching a real distribution) so their SINGLE-encoded
        // perceptual counterparts individually cross both thresholds:
        // `srgbEncode(0.001) ≈ 0.013` (> kBlackTargetPerceptual, 0.005) and
        // `srgbEncode(0.003) ≈ 0.039` (< kShadowFloorPerceptual, 0.05) —
        // i.e. Black Point would clearly trigger on its own (per
        // `testLiftedBlacksGiveNegativeBlackPoint`'s own pattern), but
        // Shadows triggering too must suppress it.
        let result = AutoToneSolver.solve(stats(p0_5: 0.001, p5: 0.003, logAverageLuma: 0.18))
        XCTAssertGreaterThan(result.curvesShadows, 0, "sanity: this fixture should trigger Shadows")
        XCTAssertEqual(result.blackPoint, 0)
    }

    // MARK: - Highlights

    func testClippingHighlightsGiveNegativeHighlights() {
        let result = AutoToneSolver.solve(stats(p99_5: 1.0, logAverageLuma: 0.18))
        XCTAssertLessThan(result.curvesHighlights, 0)
    }

    func testNonClippingHighlightsGiveZeroHighlights() {
        let result = AutoToneSolver.solve(stats(p99_5: 0.5, logAverageLuma: 0.18))
        XCTAssertEqual(result.curvesHighlights, 0)
    }

    // MARK: - Shadows

    func testCrushedShadowsGivePositiveShadows() {
        let result = AutoToneSolver.solve(stats(p5: 0.0001, logAverageLuma: 0.18))
        XCTAssertGreaterThan(result.curvesShadows, 0)
    }

    func testUncrushedShadowsGiveZeroShadows() {
        let result = AutoToneSolver.solve(stats(p5: 0.15, logAverageLuma: 0.18))
        XCTAssertEqual(result.curvesShadows, 0)
    }

    // MARK: - Contrast

    func testFlatLowSpreadImageGivesPositiveContrast() {
        let result = AutoToneSolver.solve(stats(p5: 0.15, p95: 0.22, logAverageLuma: 0.18))
        XCTAssertGreaterThan(result.contrast, 0)
    }

    func testPunchyHighSpreadImageGivesNegativeContrast() {
        let result = AutoToneSolver.solve(stats(p5: 0.001, p95: 1.0, logAverageLuma: 0.18))
        XCTAssertLessThan(result.contrast, 0)
    }

    func testContrastIsClampedAtItsMaximum() {
        // Zero spread (p5 == p95) is the most extreme "flat image" input
        // possible, so this pins the clamp being reached, not just approached.
        let veryFlat = AutoToneSolver.solve(stats(p5: 0.18, p95: 0.18, logAverageLuma: 0.18))
        XCTAssertEqual(veryFlat.contrast, 0.5, accuracy: 0.001)
    }

    func testContrastNeverExceedsItsClampOnThePunchySide() {
        // NOTE: the punchy-side clamp (-0.5) is mathematically UNREACHABLE
        // given `kTargetSpreadPerceptual = 0.7` and the domain guarantee that
        // a predicted perceptual percentile never leaves 0...1 (so spread
        // never exceeds 1, and the punchiest possible error is 0.7 - 1.0 =
        // -0.3) — this test pins that observed bound, not the clamp's own
        // nominal one, so a future re-tune of `kTargetSpreadPerceptual` that
        // makes the clamp reachable doesn't silently go untested either way.
        let mostExtreme = AutoToneSolver.solve(stats(p5: 0.0001, p95: 1.0, logAverageLuma: 0.18))
        XCTAssertEqual(mostExtreme.contrast, -0.3, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(mostExtreme.contrast, -0.5)
    }

    /// Reviewer-caught (Auto Tone planning session), a genuinely serious
    /// full-pipeline bug found via the end-to-end tests, in TWO STAGES —
    /// see `solveContrast`'s own doc comment for the full two-stage story
    /// and the measured numbers. A LOW `p5` paired with a SMALL spread
    /// makes the spread-based formula alone want strong positive contrast
    /// (a "flat image"), but `EditPipeline`'s `CIColorControls` Contrast
    /// stage applies that around a 0.5 pivot — `(input - 0.5) * (1 +
    /// contrast) + 0.5` — which can crush an already-low `predictedP5`
    /// toward black regardless of Shadows' own lift. This fixture is
    /// exactly that shape: pins the cap actually reduces the result well
    /// below the uncapped spread-based value (which would clamp to 0.5).
    func testContrastIsCappedToAvoidCrushingALowFloor() {
        // p5 = 0.01 gives predictedP5 ≈ 0.0999 — deliberately ABOVE
        // `kShadowFloorPerceptual` (0.05, see the Shadows tests above), so
        // the cap here binds to a small POSITIVE value (its formula's own
        // floor target), not to the `max(0, ...)` == 0 case Shadows'
        // own trigger produces (see `testPositiveContrastIsClampedToZero
        // WhenShadowsTriggers` below) — a first draft of this test used a
        // lower p5 that accidentally landed in that other case, which made
        // the assertions below trivially true for the wrong reason.
        let result = AutoToneSolver.solve(stats(p5: 0.01, p95: 0.05, logAverageLuma: 0.18))
        XCTAssertGreaterThan(result.contrast, 0)
        XCTAssertLessThan(result.contrast, 0.3)
    }

    /// Directly verifies the cap's own PURPOSE, not just that it reduces
    /// the value: applying the solved Contrast to `predictedP5` via the
    /// SAME formula `EditPipeline.applyContrast`'s own `CIColorControls`
    /// call implements must land AT OR ABOVE `kShadowFloorPerceptual` —
    /// not just non-negative, which a reviewer round caught as an
    /// insufficient property (a result can be positive yet still small
    /// enough to fall inside Black Point's own clip zone; see
    /// `solveContrast`'s own doc comment for the measured "stage 2" bug
    /// this exact assertion is the regression guard for). Same fixture and
    /// same Shadows-not-triggered reasoning as the test above.
    func testContrastCapKeepsThePredictedFloorAtOrAboveTheShadowFloor() {
        let result = AutoToneSolver.solve(stats(p5: 0.01, p95: 0.05, logAverageLuma: 0.18))
        let predictedP5 = PerceptualEncoding.srgbEncode(0.01) // gain == 1 here (logAverageLuma is already at the target key)
        let afterContrast = (predictedP5 - 0.5) * (1 + result.contrast) + 0.5
        // `XCTAssertGreaterThanOrEqual` has no `accuracy:` overload — a
        // tiny epsilon below the exact target absorbs floating-point noise
        // from the formula's own division, without weakening the
        // assertion's actual intent (landing meaningfully below 0.05 would
        // still fail this).
        XCTAssertGreaterThanOrEqual(afterContrast, 0.05 - 1e-9)
    }

    /// Companion to the two tests above: pins the OTHER half of
    /// `solveContrast`'s own cap — once Shadows DOES trigger
    /// (`predictedP5 < kShadowFloorPerceptual`), the cap's own formula
    /// goes negative and `max(0, ...)` turns that into a hard 0, so a
    /// Contrast solve that would otherwise be POSITIVE (crushing) lands at
    /// exactly 0 instead. This fixture's own uncapped solve is positive (a
    /// small p5 with a small spread, per `solveContrast`'s "flat image"
    /// formula), so this pins the clamp actually reaching 0, not just
    /// reducing it.
    func testPositiveContrastIsClampedToZeroWhenShadowsTriggers() {
        let result = AutoToneSolver.solve(stats(p5: 0.001, p95: 0.005, logAverageLuma: 0.18))
        XCTAssertGreaterThan(result.curvesShadows, 0, "sanity: this fixture should trigger Shadows")
        XCTAssertEqual(result.contrast, 0)
    }

    // MARK: - Vibrance

    func testAlreadySaturatedImageGivesZeroVibrance() {
        let result = AutoToneSolver.solve(stats(meanChroma: 0.4))
        XCTAssertEqual(result.vibrance, 0)
    }

    func testDesaturatedImageGivesPositiveVibrance() {
        let result = AutoToneSolver.solve(stats(meanChroma: 0))
        XCTAssertEqual(result.vibrance, 0.25, accuracy: 0.001)
    }

    func testVibranceNeverGoesNegative() {
        // meanChroma can't exceed 1 by construction, but a defensively
        // out-of-range value should still clamp rather than go negative.
        let result = AutoToneSolver.solve(stats(meanChroma: 2.0))
        XCTAssertEqual(result.vibrance, 0)
    }

    // MARK: - General

    func testAllOutputsAreFiniteAndWithinSliderRangesForDegenerateStats() {
        let degenerate = ToneStatistics(
            percentile0_5: 0, percentile5: 0, percentile50: 0, percentile95: 0, percentile99_5: 0,
            logAverageLuma: 0, meanChroma: 0, qualifyingPixelCount: 0
        )
        let result = AutoToneSolver.solve(degenerate)

        for value in [
            result.exposureEV, result.blackPoint, result.curvesHighlights,
            result.curvesShadows, result.contrast, result.vibrance
        ] {
            XCTAssertTrue(value.isFinite)
        }
        XCTAssertTrue((-5...5).contains(result.exposureEV))
        XCTAssertTrue((-1...1).contains(result.blackPoint))
        XCTAssertTrue((-1...1).contains(result.curvesHighlights))
        XCTAssertTrue((-1...1).contains(result.curvesShadows))
        XCTAssertTrue((-1...1).contains(result.contrast))
        XCTAssertTrue((-1...1).contains(result.vibrance))
    }

    func testDeterministic() {
        let input = stats(p0_5: 0.1, p5: 0.15, p95: 0.85, p99_5: 0.95, logAverageLuma: 0.1, meanChroma: 0.1)
        XCTAssertEqual(AutoToneSolver.solve(input), AutoToneSolver.solve(input))
    }

    /// Reviewer-caught (Auto Tone planning session): nothing structurally
    /// guaranteed a non-finite `ToneStatistics` field couldn't reach
    /// `solve(_:)`'s arithmetic — Swift's `min`/`max` don't reliably filter
    /// NaN — and a NaN written into `EditState` fails every subsequent
    /// sidecar/catalog write, the exact failure class Point Color's own
    /// round-1 reviewer catch fixed once already. Every field is tried
    /// independently, not just one, so a guard covering only SOME of them
    /// can't hide behind another.
    func testNonFiniteStatisticsGiveAnIdentityResult() {
        let identity = AutoToneSolver.Result(
            exposureEV: 0, blackPoint: 0, curvesHighlights: 0, curvesShadows: 0, contrast: 0, vibrance: 0
        )
        XCTAssertEqual(AutoToneSolver.solve(stats(p0_5: .nan)), identity)
        XCTAssertEqual(AutoToneSolver.solve(stats(p5: .nan)), identity)
        XCTAssertEqual(AutoToneSolver.solve(stats(p50: .nan)), identity)
        XCTAssertEqual(AutoToneSolver.solve(stats(p95: .nan)), identity)
        XCTAssertEqual(AutoToneSolver.solve(stats(p99_5: .nan)), identity)
        XCTAssertEqual(AutoToneSolver.solve(stats(meanChroma: .nan)), identity)
    }
}
