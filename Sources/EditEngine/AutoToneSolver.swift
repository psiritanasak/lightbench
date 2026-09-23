import Foundation

/// Solves Auto Tone's 6 `EditState` fields (Exposure, Black Point,
/// Highlights, Shadows, Contrast, Vibrance) from a `ToneStatistics`
/// summary — the analysis half of `ImageDocumentModel.autoTone()`. Pure, no
/// Core Image dependency, independently testable — the same separation
/// `ToneStatistics`'s own doc comment establishes.
///
/// UNLIKE `WhiteBalanceSolver` (a real numerical search against the actual
/// compiled filter, needed because `CITemperatureAndTint` has no
/// closed-form inverse), this is a HEURISTIC v1 — matching CLAUDE.md's own
/// Auto Tone roadmap entry ("a heuristic v1... not assumed to need ML").
/// Exposure and Black Point both have genuine closed-form solves (a pure
/// linear-light multiplicative gain; an inverse of the parametric curve's
/// own `point0.x` move — see `solveBlackPoint`'s own doc comment for a real
/// bug a first draft of that inverse had, reviewer-caught, and what fixing
/// it correctly revealed about the mechanism's own narrow reach); every
/// OTHER field is a proportional-error response against a target, clamped
/// to a conservative maximum so an extreme measurement can't push a slider
/// to its own extreme. Every tuning constant below is an honestly-labeled
/// STARTING POINT — not yet live-tuned, matching `PointColorTuning`'s own
/// precedent for a v1 with no UI yet to visually tune against — not a
/// measured necessity.
///
/// Deliberately does NOT write Brilliance or White Balance: Brilliance
/// isn't solved for at all (it would double-count with Contrast/Shadows/
/// Highlights via `EditPipeline.effectiveTone`'s own render-time blend —
/// solving for both at once would fight itself), and White Balance stays
/// Fix Color Cast's own separate button, matching Lightroom's own
/// Auto/WB-Auto split (user-confirmed scope decision).
enum AutoToneSolver {
    struct Result: Equatable {
        var exposureEV: Double
        var blackPoint: Double
        var curvesHighlights: Double
        var curvesShadows: Double
        var contrast: Double
        var vibrance: Double
    }

    // MARK: - Exposure

    /// The standard 18%-reflectance "middle gray" target for the log-average
    /// scene key — the same constant a spot meter/gray card reading uses,
    /// not a value unique to this app.
    private static let kTargetKey = 0.18
    /// Clamp on the solved EV — roughly two-thirds of the Exposure slider's
    /// own -5...5 range, a principled "Auto shouldn't max out the slider"
    /// starting choice.
    private static let kMaxAutoEV = 3.0

    // MARK: - Black Point

    /// Mirrors `EditPipeline.kBlackPointSpan` (private there, so duplicated
    /// here per this codebase's established cross-reference pattern — see
    /// `CropOverlayView.maxInset`).
    private static let kBlackPointSpan = 0.20
    /// Trigger, RE-DERIVED (reviewer-caught, Auto Tone planning session —
    /// see `solveBlackPoint`'s own doc comment for the full story) to sit
    /// BELOW the mechanism's own reachable ceiling, not just "a small dead
    /// zone." A naive `0.02` (this constant's first-draft value) is already
    /// PAST the point where `kMaxAutoBlackPoint`'s own maximum `point0.x`
    /// could ever reach — every triggering case would saturate immediately,
    /// with no real graduated response. `0.005`, by contrast, MEASURED
    /// (temporary harness, deleted) to leave a genuine non-saturating
    /// window (a linear floor of ~0.000387 [the trigger] to ~0.000776 [full
    /// saturation] solves to a `blackPoint` between 0 and the clamp, and
    /// the resulting curve DOES clip that exact floor level — verified
    /// against `ToneCurveSpline`, the real kernel's own Swift twin). A
    /// prior version of this comment gave a looser, reviewer-caught-wrong
    /// "~0.0005-0.001" figure — replaced with the precise re-derivation.
    private static let kBlackTargetPerceptual = 0.005
    private static let kMaxAutoBlackPoint = 0.5

    // MARK: - Highlights

    private static let kHighlightClipStartPerceptual = 0.98
    private static let kMaxAutoHighlights = 0.6

    // MARK: - Shadows

    private static let kShadowFloorPerceptual = 0.05
    private static let kMaxAutoShadows = 0.6

    // MARK: - Contrast

    private static let kTargetSpreadPerceptual = 0.7
    private static let kMaxAutoContrast = 0.5

    // MARK: - Vibrance

    private static let kTargetChroma = 0.25
    private static let kMaxAutoVibrance = 0.5

    static func solve(_ stats: ToneStatistics) -> Result {
        // Reviewer-caught (Auto Tone planning session): `ToneStatistics`'
        // percentiles/log-average/chroma are always finite in practice (a
        // real render+sort can't produce NaN), but nothing STRUCTURALLY
        // guarantees that — a future caller, a corrupted intermediate, or a
        // future field addition could hand this a non-finite value.
        // `solveExposureEV`'s own guard already catches a non-finite
        // `logAverageLuma`; this catches the rest BEFORE they reach
        // `srgbEncode`/arithmetic below (whose `min`/`max`-based clamps do
        // NOT reliably filter NaN — Swift's `min`/`max` are not guaranteed
        // to discard a NaN operand). Matches the exact failure class Point
        // Color's own round-1 reviewer catch fixed (a non-finite target
        // reaching `EditState` and failing every subsequent sidecar/catalog
        // write) — guarded HERE, at the boundary, same reasoning as that
        // fix's own guard placement.
        guard stats.percentile0_5.isFinite, stats.percentile5.isFinite, stats.percentile50.isFinite,
              stats.percentile95.isFinite, stats.percentile99_5.isFinite, stats.meanChroma.isFinite
        else {
            return Result(exposureEV: 0, blackPoint: 0, curvesHighlights: 0, curvesShadows: 0, contrast: 0, vibrance: 0)
        }

        let ev = solveExposureEV(stats.logAverageLuma)
        let gain = pow(2, ev)

        // Every OTHER field is solved against what the image will look
        // like AFTER this solved Exposure gain — Exposure runs first,
        // scene-linear, in `EditPipeline.apply`, so predicting the
        // perceptual-domain percentiles it feeds forward (rather than the
        // raw, pre-Exposure measurement) is what makes Black Point/
        // Highlights/Shadows/Contrast's own thresholds meaningful.
        let predictedP0_5 = PerceptualEncoding.srgbEncode(stats.percentile0_5 * gain)
        let predictedP5 = PerceptualEncoding.srgbEncode(stats.percentile5 * gain)
        let predictedP95 = PerceptualEncoding.srgbEncode(stats.percentile95 * gain)
        let predictedP99_5 = PerceptualEncoding.srgbEncode(stats.percentile99_5 * gain)

        // Reviewer-caught (Auto Tone planning session), a genuinely serious
        // full-pipeline bug found by the end-to-end tests, not the pure
        // solver tests, and found in TWO STAGES — see `solveContrast`'s own
        // doc comment for the full derivation and measured numbers of both.
        // `solveBlackPoint` needs to know whether Shadows is about to lift
        // this same pixel range (to avoid contradicting it — see that
        // function's own doc comment), computed once here.
        let shadowsTriggered = predictedP5 < kShadowFloorPerceptual

        return Result(
            exposureEV: ev,
            blackPoint: solveBlackPoint(predictedP0_5, shadowsTriggered: shadowsTriggered),
            curvesHighlights: solveHighlights(predictedP99_5),
            curvesShadows: solveShadows(predictedP5),
            contrast: solveContrast(predictedP5: predictedP5, predictedP95: predictedP95),
            vibrance: solveVibrance(stats.meanChroma)
        )
    }

    /// Exposure is the one field with a genuine closed-form solve: it's a
    /// pure multiplicative `2^EV` gain in linear light (see
    /// `EditState.exposureEV`'s own doc comment), so the EV that moves the
    /// measured scene key to `kTargetKey` is exactly `log2(target / key)` —
    /// no search needed, unlike `WhiteBalanceSolver`.
    private static func solveExposureEV(_ logAverageLuma: Double) -> Double {
        guard logAverageLuma.isFinite, logAverageLuma > 0 else { return 0 }
        let ev = log2(kTargetKey / logAverageLuma)
        guard ev.isFinite else { return 0 }
        return min(max(ev, -kMaxAutoEV), kMaxAutoEV)
    }

    /// Inverts `EditPipeline.curveControlPoints`'s own `point0.x = max(0,
    /// -blackPoint) * kBlackPointSpan` — CORRECTED (reviewer-caught, Auto
    /// Tone planning session) from a first draft that set `point0.x =
    /// predictedP0_5 / kBlackPointSpan` directly. That was wrong:
    /// `ToneCurve.cikernel`'s own `toneCurveValue` re-encodes its input a
    /// SECOND time (`float u = srgbEncode(v)` — see that kernel's own
    /// header comment, "the encode here is the filter's OWN and is a
    /// SECOND encode") before comparing against `point0.x`, so `point0.x`
    /// lives in DOUBLE-encoded space while `predictedP0_5` is only
    /// SINGLE-encoded. MEASURED (a temporary harness, since deleted): the
    /// first draft's `point0.x` undershot the pixel's own double-encoded
    /// position by 3-7x across several realistic floors, never actually
    /// clipping the level it claimed to target. Fixed by encoding
    /// `predictedP0_5` a SECOND time here too, matching the kernel exactly.
    ///
    /// The correctly-derived math reveals a real, accepted STRUCTURAL
    /// limit, not a further bug: `kBlackPointSpan`'s own 0.20 reach (tuned
    /// for the Black Point SLIDER's own feel, not for this solver) means
    /// `point0.x`'s own maximum — even at `blackPoint = -1`, the slider's
    /// own extreme — maps back through the double encode to only linear
    /// ~0.003. So this mechanism can only ever clip a floor that's ALREADY
    /// very close to true black; `kBlackTargetPerceptual` was RE-DERIVED
    /// (see its own doc comment) to sit inside that narrow reachable
    /// window rather than past it. Even so, most triggering floors still
    /// saturate `kMaxAutoBlackPoint` (MEASURED: the non-saturating window
    /// is only about linear 0.000387-0.000776 — see `kBlackTargetPerceptual`'s
    /// own doc comment for the precise re-derivation) rather than responding
    /// gradually across the slider's full range — an honest v1
    /// characteristic of what this mechanism can do, not hidden behind a
    /// formula that looks more graduated than it really is.
    /// `AutoToneSolverTests.testBlackPointCurveActuallyClipsALiftedFloor`
    /// runs the real `ToneCurveSpline` (the kernel's own Swift twin,
    /// including its double encode) as this bug's regression guard.
    ///
    /// `shadowsTriggered` SUPPRESSES this function entirely — a SEPARATE,
    /// later reviewer-caught bug, found via the end-to-end tests (which
    /// exercise the REAL pipeline, not just this function in isolation):
    /// `kBlackTargetPerceptual` (0.005) sits far below `kShadowFloorPerceptual`
    /// (0.05), so almost every floor that triggers Shadows ALSO triggers
    /// Black Point — two fields with directly CONTRADICTORY goals on the
    /// very same pixels (Shadows wants to LIFT this floor; Black Point
    /// wants to CRUSH it further). MEASURED (temporary harness, deleted):
    /// without this guard, Black Point's own point0 clip silently won that
    /// fight outright — a floor Shadows correctly diagnosed as "needs
    /// lifting" instead rendered EVEN DARKER than doing nothing at all.
    /// Shadows' own diagnosis (a floor worth lifting, not crushing further)
    /// is treated as authoritative for this pixel range.
    private static func solveBlackPoint(_ predictedP0_5: Double, shadowsTriggered: Bool) -> Double {
        guard !shadowsTriggered, predictedP0_5 > kBlackTargetPerceptual else { return 0 }
        let doubleEncodedFloor = PerceptualEncoding.srgbEncode(predictedP0_5)
        return -min(doubleEncodedFloor / kBlackPointSpan, kMaxAutoBlackPoint)
    }

    /// A HEURISTIC proportional response, NOT a closed-form curve inverse
    /// like Black Point's: Highlights moves point3 of a 5-point natural-
    /// cubic spline (see `ToneCurveSpline`), which has no simple analytic
    /// inverse for "move this one point to pull that percentile down by X".
    /// `excess` ranges 0 (at the trigger threshold) to 1 (`predictedP99_5`
    /// at its own maximum of exactly 1.0, guaranteed by
    /// `PerceptualEncoding.srgbEncode`'s clamp — no further clamp needed
    /// here), scaled by `kMaxAutoHighlights` so a fully blown-out image
    /// gets the full clamp, not more.
    private static func solveHighlights(_ predictedP99_5: Double) -> Double {
        guard predictedP99_5 > kHighlightClipStartPerceptual else { return 0 }
        let excess = (predictedP99_5 - kHighlightClipStartPerceptual) / (1 - kHighlightClipStartPerceptual)
        return -excess * kMaxAutoHighlights
    }

    /// Same heuristic shape as `solveHighlights`, mirrored for the shadow
    /// end — positive `curvesShadows` LIFTS shadows (see
    /// `EditState.curvesShadows`'s own doc comment), so a crushed shadow
    /// floor gets a POSITIVE result. `excess` is bounded to 0...1 the same
    /// way (`predictedP5`'s own minimum of 0 is guaranteed by the same
    /// clamp).
    private static func solveShadows(_ predictedP5: Double) -> Double {
        guard predictedP5 < kShadowFloorPerceptual else { return 0 }
        let excess = (kShadowFloorPerceptual - predictedP5) / kShadowFloorPerceptual
        return excess * kMaxAutoShadows
    }

    /// A flat (low p95-p5 spread) image gets MORE contrast; an
    /// already-punchy one gets slightly LESS — a proportional response
    /// around `kTargetSpreadPerceptual`, clamped both directions.
    ///
    /// ALSO capped, separately, to keep Contrast from crushing the shadow
    /// range — a genuinely serious reviewer-caught bug, found via the
    /// end-to-end tests, in TWO STAGES (a first fix caught and fixed the
    /// worse of the two; re-review then found the second, milder one
    /// still crushing a DIFFERENT part of the same range):
    ///
    /// `EditPipeline`'s `CIColorControls` Contrast stage runs BEFORE Curves
    /// (where Shadows/Black Point actually operate — see `EditPipeline`'s
    /// own stage-order doc comment), around a 0.5 pivot: `output = (input -
    /// 0.5) * (1 + contrast) + 0.5`. MEASURED (temporary harness, deleted):
    /// STAGE 1 — on a real crushed-shadow fixture (`predictedP5` far below
    /// `kShadowFloorPerceptual`), an uncapped Contrast solve pushed
    /// `predictedP5` NEGATIVE, and any negative value clips HARD to 0 in
    /// the curve stage (`point0.x` is never negative), erasing Shadows' own
    /// lift entirely. STAGE 2 — capping the result to stay merely
    /// NON-NEGATIVE was NOT enough: for a floor just ABOVE
    /// `kShadowFloorPerceptual` (so Shadows itself does NOT trigger, but
    /// Black Point still can — see `solveBlackPoint`'s own doc comment), a
    /// naive "cap to exactly 0" formula crushes the post-Contrast value to
    /// essentially nothing BY CONSTRUCTION (a value capped to land AT 0 is,
    /// definitionally, a ~100% reduction, not a partial one — MEASURED, the
    /// reverted formula gave a post-Contrast value of `5.55e-17` on this
    /// exact fixture) — landing inside Black Point's OWN double-encoded
    /// clip zone, reproducing the identical symptom (`percentile5` measured
    /// at the SAME `4.96e-11` as the original bug) on a fixture where
    /// Shadows never even ran.
    ///
    /// FIXED by capping to `kShadowFloorPerceptual` instead of to 0:
    /// solving `(predictedP5 - 0.5) * (1 + contrast) + 0.5 =
    /// kShadowFloorPerceptual` for `contrast` gives `(predictedP5 -
    /// kShadowFloorPerceptual) / (0.5 - predictedP5)`. This guarantees the
    /// POST-CONTRAST value never drops below `kShadowFloorPerceptual`
    /// (0.05 single-encoded) — MEASURED, `srgbEncode(0.05) ≈ 0.248`,
    /// comfortably clear of `point0.x`'s own maximum possible reach (0.10
    /// double-encoded, at `blackPoint = -kMaxAutoBlackPoint`), so this one
    /// cap protects against BOTH stages' failure mode at once, for any
    /// `predictedP5` up to 0.5. `max(0, ...)` handles the region where
    /// Shadows itself triggers (`predictedP5 < kShadowFloorPerceptual`):
    /// the raw formula would go negative there, which `max(0, ...)` turns
    /// into a HARD 0 for positive/crushing solves while leaving a
    /// genuinely NEGATIVE (beneficial, pivot-ward) solve from the spread
    /// formula above completely untouched — `min(contrast, 0)` when the
    /// cap is exactly 0 is a no-op for anything already `<= 0`.
    /// `AutoToneEndToEndTests.testFullSolveDoesNotCrushTheVeryShadowItDiagnoses`
    /// and `testFullSolveDoesNotCrushAFloorJustAboveTheShadowThreshold`
    /// are this bug's two regression guards, one per stage.
    private static func solveContrast(predictedP5: Double, predictedP95: Double) -> Double {
        let spread = predictedP95 - predictedP5
        let error = kTargetSpreadPerceptual - spread
        var contrast = min(max(error, -kMaxAutoContrast), kMaxAutoContrast)

        if predictedP5 < 0.5 {
            let maxSafeContrast = max(0, (predictedP5 - kShadowFloorPerceptual) / (0.5 - predictedP5))
            contrast = min(contrast, maxSafeContrast)
        }
        return contrast
    }

    /// Vibrance only ever ADDS — an already-colorful image (`meanChroma` at
    /// or above target) gets none, matching this field's own "protects
    /// already-saturated tones, boosts flat ones" character (`CIVibrance`,
    /// see `EditState.vibrance`'s own doc comment) rather than ever pulling
    /// saturation down automatically.
    private static func solveVibrance(_ meanChroma: Double) -> Double {
        let error = kTargetChroma - meanChroma
        return min(max(error, 0), kMaxAutoVibrance)
    }
}
