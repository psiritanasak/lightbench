import XCTest
import CoreImage
@testable import PhotoApp

/// Exercises the REAL measure -> solve -> render -> re-measure loop through
/// actual `EditPipeline`/`ImageToneStatistics` machinery. `AutoToneSolverTests`
/// only tests the solver's own math against directly-constructed
/// `ToneStatistics` — per the lesson from Point Color's own round-1 reviewer
/// catch (see CLAUDE.md's Point Color entry: "every test there would still
/// pass if the pipeline truncation fed the kernel garbage"), that alone
/// would still pass even if the wiring AROUND the solver were broken. Not
/// exercised here (no test precedent exists for it — see PROGRESS.md's
/// "Process note"): `ImageDocumentModel.autoTone()` itself, which is
/// `@MainActor` glue with no unit-test precedent in this codebase, same
/// profile as `fixColorCast()`.
final class AutoToneEndToEndTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(gray: Double, size: Int = 256) -> CIImage {
        let color = CIColor(red: gray, green: gray, blue: gray, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func autoToneState(from result: AutoToneSolver.Result, geometry: EditState) -> EditState {
        var s = geometry
        s.exposureEV = result.exposureEV
        s.blackPoint = result.blackPoint
        s.curvesHighlights = result.curvesHighlights
        s.curvesShadows = result.curvesShadows
        s.contrast = result.contrast
        s.vibrance = result.vibrance
        return s
    }

    /// A dark synthetic photo, solved, rendered, and RE-measured — its
    /// log-average scene key should end up MEASURABLY closer to Auto Tone's
    /// own target than it started, not just "solve to something." A tight
    /// numeric target is deliberately NOT asserted: Contrast/Black Point's
    /// own render-time interaction with the solved Exposure shifts the
    /// final key away from a naive `logAverage * 2^ev` prediction (this is
    /// expected — see `AutoToneSolver`'s own doc comment on why only
    /// Exposure has a true closed-form solve), so "moved toward the target"
    /// is the honest, robust property to pin here.
    func testAutoToneMovesADarkImageCloserToTheTargetKey() {
        let image = solidColorImage(gray: 0.02)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let result = AutoToneSolver.solve(statsBefore)
        let solved = autoToneState(from: result, geometry: geometryState)

        guard let statsAfter = ImageToneStatistics.compute(of: EditPipeline.apply(solved, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }

        let targetKey = 0.18
        let distanceBefore = abs(statsBefore.logAverageLuma - targetKey)
        let distanceAfter = abs(statsAfter.logAverageLuma - targetKey)

        XCTAssertGreaterThan(statsAfter.logAverageLuma, statsBefore.logAverageLuma)
        XCTAssertLessThan(distanceAfter, distanceBefore)
    }

    /// Idempotence — the actual mechanism this pins is
    /// `EditState.geometryOnlySamplingState()`: `ImageDocumentModel.autoTone()`
    /// samples through it, which excludes every field Auto Tone itself
    /// writes, so re-solving from a state that already carries Auto Tone's
    /// own output measures the SAME underlying image and must produce the
    /// SAME result. This test builds that exact sampling state directly
    /// (not by driving `ImageDocumentModel`, which has no test precedent —
    /// see this file's own header comment) so it still exercises the real
    /// exclusion mechanism, not just the solver's own purity (which
    /// `AutoToneSolverTests.testDeterministic` already covers separately).
    /// Geometry-only, not geometry+WB (`autoTone()`'s own real sampling
    /// state also copies Temperature/Tint) — WB stays at its identity
    /// default throughout this fixture, so that difference doesn't affect
    /// the result here.
    func testSolvingTwiceInARowGivesTheSameResult() {
        let image = solidColorImage(gray: 0.05)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let firstResult = AutoToneSolver.solve(statsBefore)
        let afterFirstAuto = autoToneState(from: firstResult, geometry: geometryState)

        let secondSamplingState = afterFirstAuto.geometryOnlySamplingState()
        guard let statsForSecondRun = ImageToneStatistics.compute(of: EditPipeline.apply(secondSamplingState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let secondResult = AutoToneSolver.solve(statsForSecondRun)

        XCTAssertEqual(secondResult, firstResult)
    }

    /// Reviewer-caught (Auto Tone planning session): the dark-uniform-gray
    /// fixture above has ZERO percentile spread, so Highlights and Shadows
    /// never trigger at all (both solve to exactly 0) — a sign flip or
    /// deletion of EITHER field would still pass every assertion in this
    /// file up to this point.
    ///
    /// This test's fixture — a majority midtone region plus a SMALL
    /// (~1% of pixels), near-white-but-NOT-headroom (linear 0.99) region —
    /// specifically triggers Highlights recovery while the real rendered
    /// pixel stays inside the tone curve's own normal (non-extrapolated)
    /// domain. Both details are load-bearing, not arbitrary:
    ///
    /// - Genuine linear HEADROOM (>1.0) was tried FIRST and produced a
    ///   real, surprising discovery, worth recording: with a headroom
    ///   pixel, MORE NEGATIVE `curvesHighlights` INCREASES the rendered
    ///   linear value, the opposite of the intuitive "recovery" direction.
    ///   Mechanism (derived, not just observed): the curve's tail control
    ///   point (x=1, y=1) never moves — only point3 (x=0.75) does — and a
    ///   natural cubic's end-slope at a FIXED tail point STEEPENS as the
    ///   preceding point's y drops further below it. `ToneCurve.cikernel`
    ///   extrapolates LINEARLY along that end slope for any input past the
    ///   tail (the deliberate headroom-preservation design — see that
    ///   kernel's own header comment), so a steeper end slope means
    ///   genuinely-blown content renders BRIGHTER, not darker, the more
    ///   negative Highlights goes. This is a property of the EXISTING,
    ///   already-shipped Curves v2 kernel, not something this session
    ///   introduced — Highlights recovery, as designed, only ever shapes
    ///   content approaching 1.0 from below, not genuine >1.0 headroom
    ///   (which this pipeline deliberately preserves, by design, for a
    ///   DIFFERENT reason — see CLAUDE.md's Curves v2 slice 1 entry).
    /// - The fixture's ~1% area (not, say, 5%+) matters too: MEASURED, a
    ///   larger near-white region pulls the solved Exposure gain down
    ///   further (via the log-average), which can drop the predicted
    ///   perceptual value back BELOW `kHighlightClipStartPerceptual`
    ///   entirely — a real solver/fixture interaction, not a fixed
    ///   property of any single "near white" value in isolation.
    ///
    /// Isolates Highlights' OWN marginal contribution by rendering
    /// Exposure+Highlights ALONE against Exposure alone — NOT the full
    /// solved state with only Highlights zeroed. MEASURED (a second real
    /// finding, this one on the SHADOWS test below, but the same hazard
    /// applies here): Contrast's own simultaneous solve on a fixture with
    /// real percentile spread is large enough to dominate a field's own
    /// much smaller marginal effect, so comparing against a baseline that
    /// still carries Contrast (and Black Point) risks measuring THEIR
    /// interaction, not Highlights' own sign. Holding every other field at
    /// its true IDENTITY (not just "the solver's other fields, held fixed")
    /// removes that risk entirely, regardless of how those other fields
    /// happen to interact with this one in the full pipeline.
    func testAutoToneRecoversAClippedHighlight() {
        let midtone = solidColorImage(gray: 0.18, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 198, height: 200))
        let nearWhite = solidColorImage(gray: 0.99, size: 200).cropped(to: CGRect(x: 198, y: 0, width: 2, height: 200))
        let image = midtone.composited(over: nearWhite)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let result = AutoToneSolver.solve(statsBefore)
        XCTAssertLessThan(result.curvesHighlights, 0, "sanity: this fixture should trigger Highlights recovery")

        var withHighlights = geometryState
        withHighlights.exposureEV = result.exposureEV
        withHighlights.curvesHighlights = result.curvesHighlights

        var withoutHighlights = geometryState
        withoutHighlights.exposureEV = result.exposureEV

        guard let statsWith = ImageToneStatistics.compute(of: EditPipeline.apply(withHighlights, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        guard let statsWithout = ImageToneStatistics.compute(of: EditPipeline.apply(withoutHighlights, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }

        // Highlights' own job is to pull the near-white region DOWN — a
        // sign flip or deletion would leave `statsWith` at or above
        // `statsWithout` instead.
        XCTAssertLessThan(statsWith.percentile99_5, statsWithout.percentile99_5)
    }

    /// Mirrors `testAutoToneRecoversAClippedHighlight` for the shadow end —
    /// same reviewer-caught gap ("a sign flip here would go undetected"),
    /// same "isolate via Exposure+field alone" technique.
    ///
    /// This test's OWN first draft (isolating the same way) surfaced a
    /// second, genuinely serious bug, independent of the isolation
    /// technique itself: on THIS fixture, the FULL solved render (every
    /// field at its real solved value, not isolated) made `percentile5`
    /// come out LOWER than doing nothing at all — Auto Tone was making the
    /// very shadows it diagnosed as "crushed" even DARKER. MEASURED
    /// (temporary harness, deleted): Black Point (which almost always
    /// triggers alongside Shadows, given `kBlackTargetPerceptual` sits
    /// well below `kShadowFloorPerceptual`) independently crushed the floor
    /// via its own point0 clip, regardless of Shadows' own point1
    /// position — this is STAGE 1 of a two-stage bug; see
    /// `AutoToneSolver.solveContrast`'s own doc comment for the FULL
    /// two-stage story (a second, milder crush survived this stage's own
    /// first fix attempt, found on a DIFFERENT fixture) and the final,
    /// unified fix. FIXED at the solver level, not worked around here:
    /// `solveBlackPoint` suppresses itself whenever Shadows triggers, and
    /// `solveContrast`'s own cap keeps the post-Contrast value from ever
    /// dropping below `kShadowFloorPerceptual` (which also keeps it clear
    /// of Black Point's clip zone) rather than merely non-negative.
    /// `testFullSolveDoesNotCrushTheVeryShadowItDiagnoses` below, on this
    /// SAME fixture, is stage 1's own regression guard — this test alone
    /// (isolating just Shadows) would NOT have caught it, since the
    /// bug wasn't in Shadows' own sign.
    func testAutoToneLiftsACrushedShadow() {
        let midtone = solidColorImage(gray: 0.18, size: 256).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 256))
        let crushedShadow = solidColorImage(gray: 0.001, size: 256).cropped(to: CGRect(x: 240, y: 0, width: 16, height: 256))
        let image = midtone.composited(over: crushedShadow)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let result = AutoToneSolver.solve(statsBefore)
        XCTAssertGreaterThan(result.curvesShadows, 0, "sanity: this fixture should trigger Shadow lift")

        var withShadows = geometryState
        withShadows.exposureEV = result.exposureEV
        withShadows.curvesShadows = result.curvesShadows

        var withoutShadows = geometryState
        withoutShadows.exposureEV = result.exposureEV

        guard let statsWith = ImageToneStatistics.compute(of: EditPipeline.apply(withShadows, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        guard let statsWithout = ImageToneStatistics.compute(of: EditPipeline.apply(withoutShadows, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }

        // Shadows' own job is to lift the crushed region UP.
        XCTAssertGreaterThan(statsWith.percentile5, statsWithout.percentile5)
    }

    /// The regression guard for STAGE 1 of the bug
    /// `testAutoToneLiftsACrushedShadow`'s own doc comment describes in
    /// full (see `AutoToneSolver.solveContrast`'s own doc comment for the
    /// complete two-stage story): on the SAME fixture, the FULL solved
    /// render (every field, not isolated) must not leave the crushed
    /// shadow region DARKER than an Exposure-only baseline. Before the
    /// fix, `percentile5` was `4.96e-11`, essentially zero — DARKER than
    /// doing nothing at all.
    func testFullSolveDoesNotCrushTheVeryShadowItDiagnoses() {
        let midtone = solidColorImage(gray: 0.18, size: 256).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 256))
        let crushedShadow = solidColorImage(gray: 0.001, size: 256).cropped(to: CGRect(x: 240, y: 0, width: 16, height: 256))
        let image = midtone.composited(over: crushedShadow)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let result = AutoToneSolver.solve(statsBefore)
        XCTAssertGreaterThan(result.curvesShadows, 0, "sanity: this fixture should trigger Shadow lift")

        var exposureOnly = geometryState
        exposureOnly.exposureEV = result.exposureEV
        let solved = autoToneState(from: result, geometry: geometryState)

        guard let statsExposureOnly = ImageToneStatistics.compute(of: EditPipeline.apply(exposureOnly, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        guard let statsFull = ImageToneStatistics.compute(of: EditPipeline.apply(solved, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }

        XCTAssertGreaterThanOrEqual(statsFull.percentile5, statsExposureOnly.percentile5)
    }

    /// The regression guard for STAGE 2 of the SAME bug (see
    /// `AutoToneSolver.solveContrast`'s own doc comment for the full
    /// two-stage story): fixing stage 1 (a floor DEEP in Shadows' own
    /// trigger range) was not sufficient — a floor just ABOVE
    /// `kShadowFloorPerceptual` (where Shadows itself does not trigger,
    /// but Black Point still can) reproduced the IDENTICAL symptom via a
    /// different path: a Contrast solve capped to merely NON-NEGATIVE was
    /// still small enough to fall inside Black Point's own clip zone.
    /// MEASURED (reviewer's own re-derivation, this session): before this
    /// stage's fix, this exact fixture's `percentile5` was `4.96e-11`,
    /// bit-for-bit the same degenerate value stage 1's own fixture showed
    /// before ITS fix — the same underlying clip, reached a different way.
    ///
    /// Deliberately NOT compared against an Exposure-only baseline (unlike
    /// stage 1's own regression test): Contrast is SUPPOSED to darken this
    /// region somewhat — that is literally what positive Contrast does,
    /// not a bug — so `statsFull.percentile5 < statsExposureOnly
    /// .percentile5` is EXPECTED and does not, by itself, distinguish
    /// correct behavior from the crush this test exists to catch. A first
    /// draft of this test used that comparison and failed even after the
    /// real fix (measured full-solve value `0.0039`, legitimately below
    /// the exposure-only `0.0062` by design) — the actual distinguishing
    /// property is staying comfortably above the DEGENERATE clip value
    /// (`4.96e-11`, twelve orders of magnitude smaller), which this
    /// concrete threshold checks directly instead.
    func testFullSolveDoesNotCrushAFloorJustAboveTheShadowThreshold() {
        let midtone = solidColorImage(gray: 0.18, size: 256).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 256))
        // linear 0.005: predictedP5 lands just above kShadowFloorPerceptual
        // (0.05) after this fixture's own solved Exposure gain, so Shadows
        // itself does NOT trigger here — deliberately distinct from
        // `testFullSolveDoesNotCrushTheVeryShadowItDiagnoses`'s own linear
        // 0.001 fixture, which sits deep inside Shadows' trigger range.
        let liftedFloor = solidColorImage(gray: 0.005, size: 256).cropped(to: CGRect(x: 240, y: 0, width: 16, height: 256))
        let image = midtone.composited(over: liftedFloor)
        let geometryState = EditState()

        guard let statsBefore = ImageToneStatistics.compute(of: EditPipeline.apply(geometryState, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }
        let result = AutoToneSolver.solve(statsBefore)
        XCTAssertEqual(result.curvesShadows, 0, "sanity: this fixture should NOT trigger Shadow lift")
        XCTAssertLessThan(result.blackPoint, 0, "sanity: this fixture should trigger Black Point")

        let solved = autoToneState(from: result, geometry: geometryState)
        guard let statsFull = ImageToneStatistics.compute(of: EditPipeline.apply(solved, to: image)) else {
            XCTFail("expected non-nil statistics")
            return
        }

        // The degenerate pre-fix value was 4.96e-11; the expected post-fix
        // value is ~0.0039. 0.002 sits comfortably between the two.
        XCTAssertGreaterThan(statsFull.percentile5, 0.002)
    }
}
