import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies an `EditState` to a `CIImage`.
///
/// The edit pipeline order is fixed (see CLAUDE.md):
/// decode → WB → exposure → contrast → curves → HSL → transform/distort →
/// crop → output transform. Decode already happened before this point (the
/// caller loads the file); output transform (display color space
/// conversion) happens at render time, outside this type. Every stage of the
/// fixed order now exists: WB, exposure, contrast, curves, HSL, crop — plus
/// four additional controls (Brightness, Black Point, Brilliance, Vibrance)
/// folded into the existing perceptual sandwich rather than the fixed order
/// list, since they're refinements of/companions to stages that already
/// exist there. Straighten, Perspective, Transform Scale/Aspect, and Flip
/// are "transform/distort" stages: pure geometry, run after the perceptual
/// sandwich and BEFORE crop, matching the fixed order — Straighten runs
/// first, then Perspective, then Transform Scale/Aspect, then Flip
/// (matching the Photos reference panel order for the first three; Scale/
/// Aspect's own position is NOT interchangeable with Perspective's — it
/// exists specifically to clean up wedges Perspective just created, see
/// `applyTransformScale`'s own doc comment and
/// `testTransformScaleClearsPerspectiveWedges` — but IS interchangeable
/// with Flip: a diagonal scale and a mirror about the SAME center
/// mathematically commute, unlike the other pairs in this group, which do
/// not commute with each other in general and are real, tested
/// requirements).
/// Red-Eye removal runs AFTER crop, BEFORE Vignette: like Vignette, its
/// stored normalized correction points must map against the CURRENT
/// (post-crop) extent, not the original frame. MEASURED to commute with
/// Vignette exactly (order between those two doesn't matter — confirmed at
/// both a frame-center and a frame-corner correction point, diff ≈ 0), but
/// it must run before Clarity/Texture/Noise Reduction/Sharpen: those "detail"
/// stages should refine the ALREADY-corrected pupil, not reshape a red one
/// that then gets corrected differently. Vignette runs AFTER crop: it's a
/// radial darkening tied to the final on-screen framing, so it must see
/// the post-crop extent, not the fixed-order list's pre-crop stages.
/// Clarity (wide local contrast)
/// runs AFTER Vignette: measured, it does NOT cleanly commute with
/// Vignette (unlike Sharpen) — its wide radius interacts with Vignette's
/// spatially-varying darkening, so this order is a real, measured
/// requirement, not arbitrary. Noise Reduction and Sharpen are a "detail"
/// pair at the pipeline's true end, after Clarity and Texture, in the standard
/// denoise-then-sharpen order (measured: NR-first leaves less residual
/// noise than the reverse) — all four (Clarity, Texture, NR, Sharpen) are
/// extent-preserving so none need to run before crop, and running them
/// last means they act on the actual final framed/stylized pixels, not
/// content that gets discarded (crop) or resampled (geometric stages)
/// afterward. Sharpen: measured to commute with Vignette (order between
/// those two specifically doesn't matter), but it must come after Noise
/// Reduction or it would re-amplify noise NR would otherwise have removed.
/// Defringe runs right after Sharpen (a CONVENTION backed by a real but
/// genuinely mixed measurement, NOT a requirement — a wider pixel sweep
/// shows the reversed order actually leaves LESS residual chroma in
/// aggregate; see `EditState.defringePurple`'s own doc comment for the
/// full story) and right before Grain (a real, MEASURED, unconditional
/// requirement: Grain's own noise, if it ran first, would fool Defringe's
/// edge gate into treating flat content as a real edge everywhere). Grain
/// is the true FINAL stage, after Sharpen and Defringe — both of Grain's own
/// orderings (grain-after-sharpen, grain-after-NR) are MEASURED
/// requirements, not conventions, being the pipeline's only stochastic
/// stage: sharpening grain would amplify/halo it, and NR running after
/// grain would eat it. See `applyGrain`'s own doc comment.
enum EditPipeline {
    /// A request to stop the pipeline early, mid-color-stage, for an
    /// eyedropper that must sample at a specific stage's OWN input rather
    /// than the final displayed pixel — `ImageDocumentModel.
    /// pickPointColorTarget`'s reason for existing. `.pointColor(index:)`
    /// stops just before the Point Color instance at `index` runs (so
    /// instances at `0..<index` still apply, matching what that instance's
    /// own kernel invocation actually sees), and leaves the image in the
    /// PERCEPTUAL domain — `applyPointColors` runs there, unlike
    /// `Mask.colorRange`'s scene-linear sampling.
    enum ColorSampleTruncation: Equatable {
        case pointColor(index: Int)
    }

    static func apply(
        _ state: EditState, to input: CIImage, truncatingColorAt truncation: ColorSampleTruncation? = nil
    ) -> CIImage {
        var image = input
        image = applyWhiteBalance(state, to: image)           // scene-linear, first
        image = applyExposure(state.exposureEV, to: image)    // scene-linear
        image = applyPerceptualAdjustments(state, to: image, truncatingColorAt: truncation)  // sRGB-gamma domain
        image = applyStraighten(state, to: image)             // geometric, before perspective
        image = applyPerspective(state, to: image)            // geometric, before transform scale/aspect
        image = applyTransformScale(state, to: image)         // geometric, before flip
        image = applyFlip(state, to: image)                   // geometric, before crop
        image = applyCrop(state, to: image)                   // geometric
        // Truncated color sampling stops HERE, after geometry but before
        // any further color stage — so the returned extent still matches
        // `ContentView.currentFitRect`'s (which is computed from a FULL,
        // untruncated render) and a normalized tap maps onto the identical
        // pixel grid. Every stage below is either localized/post-crop
        // color (Red-Eye onward) or itself geometric-adjacent; none of it
        // belongs to what a truncated color sample is answering.
        //
        // Reviewer-caught, worth stating rather than leaving implied: this
        // guarantees EXTENT-matching unconditionally, but VALUE-exactness
        // (the sampled pixel being bit-identical to what the real,
        // untruncated pipeline would show at this point) only holds when
        // geometry is at identity. Straighten/perspective/transform-scale/
        // crop resample — here, on GAMMA-ENCODED data (this truncated path
        // never reaches `decodeToLinear`), vs. LINEAR data on the normal
        // path — and the kernel itself evaluates PRE-geometry pixels while
        // the sample is taken POST-geometry. Same class of limitation the RAW WB
        // eyedropper's own `rawWhiteBalanceNeutralPoints` doc comment
        // already names ("identity-geometry only"), not newly introduced
        // here — just not yet re-measured for a non-identity case.
        guard truncation == nil else { return image }
        image = applyRedEye(state, to: image)                 // localized, scene-linear
        image = applyMasks(state, to: image)                  // local adjustments, own perceptual sandwich
        image = applyDehaze(state, to: image)                 // scene restoration, scene-linear, before vignette/local contrast
        image = applyVignette(state, to: image)               // radial, scene-linear
        image = applyClarity(state, to: image)                // wide local contrast, perceptual, before detail pair
        image = applyTexture(state, to: image)                // fine local contrast, perceptual, coarse->fine after clarity
        image = applyNoiseReduction(state, to: image)         // detail, scene-linear, before sharpen
        image = applySharpen(state, to: image)                // detail, perceptual, before defringe
        image = applyDefringe(state, to: image)               // fringe cleanup, perceptual, after sharpen (convention, not a requirement) and before grain (real measured requirement) — see EditState.defringePurple
        image = applyGrain(state, to: image)                  // stochastic, perceptual, truly last
        return image
    }

    // MARK: - White Balance

    /// Chromatic-adaptation white points, in Kelvin, for Core Image's
    /// temperature/tint filter. `kNeutralTemp` is the assumed neutral
    /// illuminant (6500K, "daylight") both `neutral` and `targetNeutral`
    /// default to. `kTintSpan` scales the UI's -100...100 tint slider to a
    /// visually strong-but-plausible shift; measured against the real filter
    /// (see the doc comment on `applyWhiteBalance`), not picked arbitrarily.
    private static let kNeutralTemp: Double = 6500
    private static let kTintSpan: Double = 100

    /// White balance is applied in scene-linear light — unlike contrast,
    /// this is NOT a deviation from CLAUDE.md's default rule, it's the
    /// straightforward case. `CITemperatureAndTint` performs a per-pixel
    /// chromatic-adaptation matrix multiply, which is physically a linear
    /// operation; empirically confirmed (identity round-trips exactly across
    /// a range of linear gray values, and values already >1.0 from a prior
    /// exposure boost stay finite and un-clamped through this filter).
    ///
    /// Two independent sign inversions are in play here, both MEASURED, not
    /// assumed:
    /// 1. Core Image's own filter: lowering `targetNeutral.x` below
    ///    `kNeutralTemp` warms the image; negative `targetNeutral.y` shifts
    ///    magenta. Both are the opposite of naive intuition about the raw
    ///    filter parameters.
    /// 2. `EditState.whiteBalanceTemperature` is deliberately exposed to the
    ///    UI using the OPPOSITE-of-the-raw-filter, Lightroom/Camera-Raw
    ///    convention: a HIGHER Kelvin value should look WARMER on screen
    ///    (matching what every photographer expects from a "Temperature"
    ///    slider), even though that's backwards from both blackbody physics
    ///    and this filter's own `targetNeutral.x` semantics. So the mapping
    ///    from `state.whiteBalanceTemperature` to `targetNeutral.x` here is a
    ///    reflection around `kNeutralTemp` (`2 * kNeutralTemp - temperature`),
    ///    not a direct pass-through — this is intentional, not a bug.
    ///
    /// This stage stays fully separate from, and runs before,
    /// `applyPerceptualAdjustments` — do NOT fold it into that guard, WB has
    /// no perceptual-domain requirement the way contrast/curves/HSL do.
    private static func applyWhiteBalance(_ state: EditState, to image: CIImage) -> CIImage {
        guard state.whiteBalanceTemperature != kNeutralTemp || state.whiteBalanceTint != 0 else { return image }
        return whiteBalanced(image, temperature: state.whiteBalanceTemperature, tint: state.whiteBalanceTint)
    }

    /// The exact filter construction `applyWhiteBalance` uses (including
    /// both measured sign inversions above), factored out so `WhiteBalance
    /// Solver` neutralizes against the SAME formula rather than a duplicated
    /// one that could silently drift from it. Internal (not `private`) so
    /// the solver, in this same module, can call it directly. Unlike
    /// `applyWhiteBalance`, this has no identity guard — callers that only
    /// care about the pipeline's real behavior should go through
    /// `applyWhiteBalance`; the solver calls this directly since it always
    /// wants the filter's actual output, including at values that happen to
    /// equal the identity.
    static func whiteBalanced(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: kNeutralTemp, y: 0)
        filter.targetNeutral = CIVector(
            x: 2 * kNeutralTemp - temperature,
            y: -(tint / 100) * kTintSpan
        )
        return filter.outputImage ?? image
    }

    // MARK: - Exposure

    /// Multiplies linear-light pixel values by `2^ev` (a camera-style
    /// exposure-stops gain), using Core Image's built-in exposure filter.
    private static func applyExposure(_ ev: Double, to image: CIImage) -> CIImage {
        guard ev != 0 else { return image }

        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(ev)
        return filter.outputImage ?? image
    }

    // MARK: - Perceptual domain (brightness, contrast, curves, HSL)

    /// Brightness, contrast, curves, and HSL are applied in the sRGB
    /// gamma-encoded (perceptual / display-referred) domain, not scene-linear
    /// light. This is a DOCUMENTED DEVIATION from CLAUDE.md's default "all
    /// image math in linear light" rule (which CLAUDE.md itself permits when
    /// documented). Rationale, verified empirically against Core Image's real
    /// behavior in this app's working space: a linear-light pivot of 0.5 sits
    /// at ~0.735 perceptual brightness, so a linear-domain contrast pivot
    /// crushes photographic middle gray (linear ≈0.214) toward black — wrong,
    /// and unlike every real photo editor. The same reasoning applies to
    /// Brightness: a linear-domain additive offset was measured to be
    /// non-photographic (crushes shadows hard, e.g. 0.05-0.25 = -0.20, barely
    /// moves highlights), while the perceptual-domain version degrades
    /// gracefully near black. Encoding to sRGB gamma first puts these
    /// operations where they behave like every real photo editor. The
    /// encode/decode tone-curve filters (`encodeToPerceptual`/
    /// `decodeToLinear`) are exact inverses of each other and do NOT clamp
    /// values above 1.0, so highlight headroom created by exposure (which
    /// runs before this step) survives the round-trip back to linear — as
    /// long as no stage in between clamps it itself. As of Curves v2 slice 1
    /// that guarantee is UNCONDITIONAL for every stage in this sandwich:
    /// `applyCurves` (which also implements Black Point, and which Brilliance
    /// and per-mask Shadows/Highlights route through) used to be the one
    /// exception, because `CIToneCurve` hard-clamped to [0,1] once active.
    /// It has been replaced by `ToneCurve.cikernel`, which extrapolates
    /// linearly above its last control point — see `applyCurves`.
    /// Brightness and HSL's filters (`CIColorControls.brightness`,
    /// `CIHueAdjust`, `CIColorControls.saturation`), by contrast, do NOT
    /// clamp — measured: saturation +1 on a 1.4 linear channel reads back as
    /// 2.57770, not 1.0, and brightness +1 on a 0.7 linear channel reads back
    /// as 1.25392. Don't assume one adjustment's clamp behavior carries to
    /// another; each was verified independently.
    ///
    /// Order inside the sandwich matters and is NOT arbitrary: brightness
    /// runs FIRST (right after encode) — measured non-commuting with contrast
    /// (brightness→contrast = 0.56524 vs contrast→brightness = 0.41565 for
    /// the same inputs) — placing it adjacent to Exposure in "overall
    /// lightness" role, before contrast/curves/HSL shape tones further.
    /// Contrast then runs before curves (measured non-commuting), and HSL
    /// runs after curves (measured non-commuting). This matches the fixed
    /// pipeline (…→contrast→curves→HSL→…) with brightness prepended. Within
    /// HSL, hue and saturation ALSO do not commute in general — they only
    /// agree to within this project's 0.002 test tolerance at modest slider
    /// values; at wider (still in-range) settings they diverge measurably
    /// (e.g. hue -90°/saturation +1 on a saturated red gives (0.42335,
    /// 0.18309, 1.09968) hue-first vs (0.42582, 0.18283, 1.10397)
    /// saturation-first — a 0.0043 gap). hue-then-saturation is therefore a
    /// real, fixed requirement, not a discretionary clarity choice — see
    /// `testHueSaturationOrderIsFixed`.
    ///
    /// Brilliance is NOT its own filter stage — it's a pure render-time blend
    /// that nudges the *effective* contrast/shadows/highlights/saturation
    /// computed by `effectiveTone(_:)` below, without ever mutating the
    /// user's own stored slider values. See that function's comment for the
    /// exact weights; it's this app's own approximation of the "brilliance"
    /// concept, not a reproduction of Apple's (undocumented, proprietary)
    /// Photos algorithm.
    private static func applyPerceptualAdjustments(
        _ state: EditState, to image: CIImage, truncatingColorAt truncation: ColorSampleTruncation? = nil
    ) -> CIImage {
        let effective = effectiveTone(state)
        // `truncation != nil` is its own term, not folded into an existing
        // one: without it, an otherwise-fully-identity state would take the
        // early-return branch below and hand a truncated caller back the
        // LINEAR input unchanged, while every other state takes the active
        // path and returns PERCEPTUAL — making the sampler's domain depend
        // on unrelated sliders instead of being unconditional.
        guard truncation != nil
            || levelsActive(state)
            || state.brightness != 0
            || effective.contrast != 0
            || curvesActive(effective, state.blackPoint)
            || pointCurveActive(state)
            || state.hslHue != 0
            || selectiveColorActive(state)
            || pointColorsActive(state)
            || state.vibrance != 0
            || effective.saturation != 0
            || state.blackAndWhite
            || colorGradingActive(state)
        else { return image }

        var img = encodeToPerceptual(image)
        // Levels runs FIRST — MEASURED non-commuting with Brightness (a
        // 0.0119 gap between levels-then-brightness and the reverse — real
        // and well above this file's 0.002 test tolerance, though smaller
        // than brightness/contrast's own 0.15 gap), so this order is a real
        // requirement, not a style choice. Levels is a corrective base-tone
        // remap (set the histogram's black/white/gamma reference points),
        // conceptually prior to the "creative" brightness/contrast/curves
        // adjustments that follow — the same rationale already used to
        // justify Brightness itself running before Contrast.
        if levelsActive(state) { img = applyLevels(state, to: img) }
        if state.brightness != 0 { img = applyBrightness(state.brightness, to: img) }
        if effective.contrast != 0 { img = applyContrast(effective.contrast, to: img) }
        if curvesActive(effective, state.blackPoint) { img = applyCurves(effective, state.blackPoint, to: img) }
        // The user's point curve(s) run immediately AFTER the parametric
        // one, keeping CLAUDE.md's fixed …→contrast→curves→HSL→… order with
        // "curves" as one contiguous multi-stage block. Parametric first
        // because it is corrective base shaping (the same rationale that
        // puts Levels before Brightness and Brightness before Contrast);
        // the freely-drawn curve(s) are the creative layer applied on top.
        //
        // MEASURED non-commuting, not assumed: swapping the parametric and
        // point-curve stages and re-rendering a 4-point S-curve over an
        // active parametric curve (shadows +0.7, highlights -0.5, black
        // point -0.4) moved the result by up to 0.07468 — at linear 0.214,
        // photographic middle gray — against this suite's 0.002 tolerance,
        // i.e. ~37x. So THAT order is a real REQUIREMENT, not a convention,
        // unlike Texture/Clarity's own 0.00215. See
        // testPointCurveOrderRelativeToTheParametricCurveIsFixed.
        //
        // Curves v2 slice 3: the composite (RGB-combined) curve runs FIRST
        // among the four point-curve passes, then Red, Green, Blue, each
        // only when its own array is non-empty and each touching ONLY its
        // own channel (`PointCurveChannelMask`, `PointToneCurve.cikernel`'s
        // `channelMask` argument). Composite-then-channels is the same
        // "corrective base shaping, then creative layer on top" reasoning
        // as above.
        //
        // MEASURED, not assumed, same method as the parametric-vs-point
        // number above (temporarily reversed the block order, rebuilt, and
        // re-rendered): composite-then-red vs. red-then-composite (a
        // 4-point composite S-curve plus a red-lifting curve, at linear
        // 0.214) gave 0.75570166 vs. 0.70867985 — a 0.04702 gap, ~23.5x
        // this suite's 0.002 tolerance. Composite-vs-channel order is a
        // real REQUIREMENT. See testCompositeAndChannelCurveOrderIsFixed.
        //
        // R/G/B mutual order does NOT need to be fixed and is not asserted
        // as a requirement: the same swap-and-remeasure method (red-then-
        // blue vs. blue-then-red, no composite/green active) rendered
        // BIT-IDENTICAL (r=0.70266026, g=0.21399991, b=0.036064126, delta
        // 0.0 on all three) — expected, since each pass writes only its
        // own channel, and confirmed rather than assumed. See
        // testPerChannelCurvesComposeIndependentlyOfTheirOwnOrder.
        if !state.toneCurvePoints.isEmpty {
            img = applyPointCurve(state.toneCurvePoints, channelMask: PointCurveChannelMask.all, to: img)
        }
        if !state.toneCurvePointsRed.isEmpty {
            img = applyPointCurve(state.toneCurvePointsRed, channelMask: PointCurveChannelMask.red, to: img)
        }
        if !state.toneCurvePointsGreen.isEmpty {
            img = applyPointCurve(state.toneCurvePointsGreen, channelMask: PointCurveChannelMask.green, to: img)
        }
        if !state.toneCurvePointsBlue.isEmpty {
            img = applyPointCurve(state.toneCurvePointsBlue, channelMask: PointCurveChannelMask.blue, to: img)
        }
        if state.hslHue != 0 { img = applyHue(state.hslHue, to: img) }
        // Selective Color runs right after global Hue (bands target hues as
        // the user currently SEES them, post global rotation — the WYSIWYG
        // choice) and before Vibrance/Saturation (those "final uniform
        // scalers" then act on the per-band-adjusted result). MEASURED
        // non-commuting with global Hue — see testSelectiveColorRunsAfterGlobalHue.
        if selectiveColorActive(state) { img = applySelectiveColor(state, to: img) }
        // Point Color runs immediately after Selective Color, before
        // Vibrance/Saturation — same WYSIWYG reasoning Selective Color
        // itself documents just above (targets the picked color as the
        // user currently SEES it, post global Hue AND post Selective
        // Color's own per-band adjustments), and the same "before B&W's
        // forced desaturation" placement, so a Point Color instance is
        // correctly erased by Black & White rather than needing special
        // interaction with it. MEASURED non-commuting with Selective
        // Color (temporary swap-rebuild-remeasure, reverted): with
        // Selective Color's `redHue: 1` (a HUE shift, not saturation —
        // chosen so Point Color's own saturation-window weight stays
        // nonzero regardless of order; an earlier `redSaturation`-based
        // measurement was reviewer-caught as gating Point Color's weight
        // to exactly zero in the shipped order, making that version of
        // this test unable to distinguish "after Selective Color" from
        // "absent entirely") and a matching Point Color `hue: -1` both
        // active on a red test pixel, this order gives
        // (0.6, 0.05756, 0.05); reversing the two stages gives
        // (0.6, 0.05, 0.18564) — a 0.13564 gap on blue, ~68x this suite's
        // 0.002 tolerance. See testPointColorRunsAfterSelectiveColor.
        // A truncation request stops exactly HERE, before this instance's
        // own kernel pass — `applyPointColors` below then runs only the
        // PREFIX of instances that precede it, matching what that
        // instance's own kernel invocation actually sees. Returns WITHOUT
        // `decodeToLinear`: staying in the perceptual domain is the whole
        // point of this mode (see `PointColor.cikernel`'s own domain note).
        if case .pointColor(let index) = truncation {
            // `max(0, index)`: `prefix(_:)` traps on a negative count.
            // Unreachable via the real caller (`ImageDocumentModel.
            // pickPointColorTarget` only ever constructs this from a real
            // `firstIndex(where:)`), but `ColorSampleTruncation` itself is
            // constructible with any `Int` from anywhere in this module —
            // defensive, not load-bearing for today's one call site.
            return applyPointColors(Array(state.pointColors.prefix(max(0, index))), to: img)
        }
        if pointColorsActive(state) { img = applyPointColors(state.pointColors, to: img) }
        if state.vibrance != 0 { img = applyVibrance(state.vibrance, to: img) }
        // `blackAndWhite` FORCES full desaturation (factor 0, i.e. the same
        // call `applySaturation` already makes at hslSaturation's own -1
        // extreme) regardless of what hslSaturation/vibrance/hslHue are
        // actually set to. Leaving Hue/Vibrance active above rather than
        // skipping them when B&W is on is deliberate, not an oversight —
        // but MEASURED, not just assumed harmless: Hue/Vibrance running
        // first does NOT change whether the final output is grayscale
        // (R=G=B always holds once saturation is forced to 0), but it DOES
        // change the resulting gray VALUE — CIColorControls computes
        // luminance from whatever RGB is present at that point in the
        // graph, and CIHueAdjust/CIVibrance do change those RGB values
        // even though the image ends up fully desaturated either way
        // (measured: Hue 45°+Vibrance 0.8 before forced desaturation shifts
        // the resulting gray by ~0.013 vs B&W alone, well past this file's
        // test tolerance). So "moot" would overclaim — the correct framing
        // is that Hue/Vibrance act as a de-facto color-filter-style
        // luminance mapping for the B&W conversion (a real, if incidental,
        // photographic technique — akin to shooting B&W film through a
        // colored filter), not that they have no effect at all.
        let saturationOverride = state.blackAndWhite ? -1.0 : effective.saturation
        if state.blackAndWhite || effective.saturation != 0 {
            img = applySaturation(saturationOverride, to: img)
        }
        // Color Grading runs LAST in this sandwich — see
        // EditState.shadowHue's own doc comment and applyColorGrading's
        // below for why this placement is load-bearing, not incidental:
        // it must run AFTER Black & White's forced desaturation so a
        // colored tint on a monochrome photo (sepia/split-tone) survives.
        // ALSO measured (not just the B&W case) to not commute with
        // Vibrance/Saturation on ordinary colored content — see
        // applyColorGrading's own doc comment for the real numbers.
        if colorGradingActive(state) { img = applyColorGrading(state, to: img) }
        img = decodeToLinear(img)
        return img
    }

    // MARK: - Levels

    /// Minimum enforced separation between `levelsBlackPoint` and
    /// `levelsWhitePoint`, so `scale = 1/(white-black)` can never divide by
    /// zero. MEASURED necessity: without this, `black == white` produces
    /// Inf, which the downstream clamp does not reliably neutralize. Same
    /// defense-in-depth pattern as `kMaxCropInset`/`kMaxPerspectiveShift` —
    /// `EditState` doesn't enforce `black < white` itself, this is where the
    /// real guarantee lives. MEASURED safe even in the degenerate case: a
    /// fully inverted `black > white` input (forced to the minimum gap by
    /// this constant) still produces a finite, if extreme, result — no
    /// NaN/Inf, just a very steep near-step response.
    private static let kMinLevelsGap: Double = 0.001

    private static func levelsActive(_ state: EditState) -> Bool {
        state.levelsBlackPoint != 0 || state.levelsWhitePoint != 1 || state.levelsGamma != 1
    }

    /// The classic Photoshop/Lightroom Levels remap: `linear = clamp((input
    /// - black) / (white - black), 0, 1)`, then `output = linear ^
    /// (1/gamma)`. Implemented as `CIColorMatrix` (global scale+bias,
    /// identical across R/G/B — a luminance-style remap, not per-channel
    /// RGB levels; `aVector = (0,0,0,1)` passes alpha through untouched) →
    /// `CIColorClamp` (0...1, BEFORE gamma) → `CIGammaAdjust`.
    ///
    /// MEASURED findings (this app's extendedLinearSRGB/RGBAf working
    /// space, not assumed):
    /// - Gamma sign: `CIGammaAdjust.power = 1/gamma` gives the classic
    ///   convention where `gamma > 1` BRIGHTENS midtones and `gamma < 1`
    ///   DARKENS them (verified at several inputs, monotonic both
    ///   directions — e.g. perceptual 0.5 -> 0.70711 at gamma 2.0, -> 0.25
    ///   at gamma 0.5). Getting this backwards would invert the slider.
    /// - NaN safety: the clamp MUST run BEFORE gamma, not after. A pixel
    ///   below the black point produces a NEGATIVE value from the
    ///   `CIColorMatrix` step; raising a negative number to a fractional
    ///   power (`gamma > 1` means `power < 1`) is undefined in IEEE float
    ///   and measured to actually surface as NaN if attempted directly.
    ///   Clamping to [0,1] first (this function's actual order) was
    ///   measured to produce an exact, finite `0.0` in that same case, both
    ///   before and after the surrounding encode/decode round-trip.
    /// - Headroom: Levels INTENTIONALLY clips highlight headroom once
    ///   active (measured: a 1.4 linear input with `levelsWhitePoint = 0.9`
    ///   clips to 1.0) — a deliberate deviation from the headroom-preserving
    ///   family (Brightness/HSL/Vibrance/Vignette/Sharpen/Clarity/Texture/Noise
    ///   Reduction), in the same accepted family as active Curves' own
    ///   clamp-to-[0,1]. Alpha is preserved exactly regardless (measured on
    ///   a semi-transparent pixel).
    /// - The `levelsActive` guard above is NOT just a performance
    ///   optimization here: MEASURED that calling this filter chain
    ///   unconditionally — even at the identity parameters (0, 1, 1) —
    ///   clips headroom anyway, because `CIColorClamp` runs regardless of
    ///   whether black/white/gamma are at their identity values. The guard
    ///   is what makes "identity" actually mean zero-effect, including
    ///   headroom preservation.
    private static func applyLevels(_ state: EditState, to image: CIImage) -> CIImage {
        let black = min(max(state.levelsBlackPoint, 0), 1)
        let white = max(min(max(state.levelsWhitePoint, 0), 1), black + kMinLevelsGap)
        let gamma = max(state.levelsGamma, 0.01)

        let scale = 1.0 / (white - black)
        let bias = -black * scale

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        var img = matrix.outputImage ?? image

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = img
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        img = clamp.outputImage ?? img

        if gamma != 1 {
            let gammaFilter = CIFilter.gammaAdjust()
            gammaFilter.inputImage = img
            gammaFilter.power = Float(1.0 / gamma)
            img = gammaFilter.outputImage ?? img
        }
        return img
    }

    // MARK: - Brightness

    /// Slider-to-filter-parameter span, measured to give a strong-but-graceful
    /// perceptual brightness shift across the full -1...1 slider range
    /// without visibly clipping shadows or losing highlight headroom.
    private static let kBrightnessSpan: Double = 0.25

    /// A raw additive offset in the perceptual domain via Core Image's
    /// color-controls filter — a SEPARATE instance from `applyContrast`'s
    /// and `applySaturation`'s, since fusing them would apply all three
    /// simultaneously rather than in the pipeline's required
    /// brightness-then-contrast-then-…-then-saturation order. Does NOT clamp
    /// highlight headroom (measured — as, since Curves v2 slice 1, neither
    /// does `applyCurves`).
    private static func applyBrightness(_ brightness: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(brightness * kBrightnessSpan)
        return filter.outputImage ?? image
    }

    // MARK: - Brilliance (composite)

    /// Weights for Brilliance's render-time blend into the effective tone
    /// values below. Chosen so that, STARTING FROM A BASE SLIDER AT 0, even
    /// brilliance = ±1 doesn't push any single underlying effect (contrast,
    /// shadow lift, highlight protection, saturation) to its own extreme —
    /// a tasteful "pop," not a maxed-out stack. This does NOT hold if the
    /// user has also independently dialed up the base slider (e.g.
    /// contrast=1 AND brilliance=1 together clamp effContrast to its own
    /// extreme via `clamped()`, correctly — the user asked for both). THIS
    /// IS THIS APP'S OWN APPROXIMATION of the "brilliance" concept, not a
    /// reproduction of Apple's proprietary, undocumented Photos algorithm —
    /// see `EditState.brilliance`.
    private static let kBrillianceContrastWeight: Double = 0.15
    private static let kBrillianceShadowWeight: Double = 0.40
    private static let kBrillianceHighlightWeight: Double = 0.30
    private static let kBrillianceSaturationWeight: Double = 0.10

    /// The tone values actually used for rendering, after blending in
    /// Brilliance's contribution. This is the ONLY place Brilliance has any
    /// effect — it never mutates `state.contrast`/`curvesShadows`/
    /// `curvesHighlights`/`hslSaturation` themselves, so those sliders keep
    /// displaying exactly what the user set them to; Brilliance's influence
    /// is purely a render-time blend. Each component is clamped to -1...1 so
    /// the downstream filters' native factors (e.g. contrast's `1 + x`)
    /// never go negative or unboundedly high.
    private struct EffectiveTone {
        let contrast: Double
        let shadows: Double
        let highlights: Double
        let saturation: Double
    }

    private static func effectiveTone(_ state: EditState) -> EffectiveTone {
        let b = state.brilliance
        return EffectiveTone(
            contrast: clamped(state.contrast + b * kBrillianceContrastWeight),
            shadows: clamped(state.curvesShadows + b * kBrillianceShadowWeight),
            highlights: clamped(state.curvesHighlights - b * kBrillianceHighlightWeight),
            saturation: clamped(state.hslSaturation + b * kBrillianceSaturationWeight)
        )
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double> = -1...1) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Contrast

    /// Adjusts contrast around a perceptual middle-gray pivot via Core
    /// Image's built-in color-controls filter. `contrast` (-1...1) maps to
    /// the filter's native `1 + contrast` factor (0...2); brightness and
    /// saturation are left at their identity defaults.
    private static func applyContrast(_ contrast: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = Float(1 + contrast)
        return filter.outputImage ?? image
    }

    // MARK: - Curves (also implements Black Point, via point0)

    /// Slider-to-control-point span, measured to give a strong-but-monotone
    /// curve across the full -1...1 slider range.
    private static let kCurvePointSpan: Double = 0.15

    /// Slider-to-control-point span for Black Point's point0 move, measured
    /// to give a strong-but-plausible Levels-style black-clip/lift range.
    private static let kBlackPointSpan: Double = 0.20

    private static func curvesActive(_ effective: EffectiveTone, _ blackPoint: Double) -> Bool {
        effective.shadows != 0 || effective.highlights != 0 || blackPoint != 0
    }

    /// A simplified, Lightroom-Basic-panel-style parametric tone curve:
    /// Shadows/Highlights (now driven by Brilliance-blended effective
    /// values, not the raw slider values directly) move `point1`/`point3` of
    /// a 5-point natural-cubic spline, and Black Point moves `point0` along
    /// its X (input) axis — reusing the same curve infrastructure rather
    /// than a separate stage. Axis verified empirically, not assumed: moving
    /// point0 on X produces the correct Levels-style "clip to black"
    /// behavior (measured: deep tones clip to 0, shadows darken/stretch).
    /// Rather than exposing a full interactive point-based curve editor
    /// (out of scope for this feature; see EditState's doc comments for the
    /// field-level rationale).
    ///
    /// HEADROOM (the one behaviour change in the Curves v2 slice-1 rewrite):
    /// values above linear 1.0 now SURVIVE an active curve, via linear
    /// extrapolation along the spline's own end slope. `CIToneCurve` used to
    /// hard-clamp them to white (measured: inputs 1.05/1.2/1.5/2.0/4.0 all
    /// returned exactly 1.0), which made curves the single stage in this
    /// pipeline that broke the headroom guarantee `applyPerceptualAdjustments`
    /// documents — enabling Shadows/Highlights silently discarded headroom
    /// Exposure had created. See `testCurvesPreserveHighlightHeadroom`.
    ///
    /// Below `point0.x` the value is still CLAMPED to `point0.y`, matching
    /// `CIToneCurve` exactly. That is deliberate and is not the same defect:
    /// `point0.x` IS the black point, so clamping is what makes Black Point
    /// genuinely clip to black (`testBlackPointDeepClip`); extrapolating
    /// there would drive values negative instead.
    ///
    /// A CORRECTION to what v1's comment claimed here: `CIToneCurve` does NOT
    /// "extrapolate rather than hard-clamp" below point0.x — it clamps at
    /// both ends (measured across five control configurations). The mild
    /// deep-shadow lift v1 described as a "soft black point" (black point -1
    /// leaving linear 0.01 at 0.03381 instead of 0) is not extrapolation at
    /// all: after the sandwich's encode AND the curve's own internal encode,
    /// linear 0.01 arrives at u = 0.349, comfortably inside [0.20, 1]. It is
    /// the spline's in-domain shape, and this rewrite leaves it unchanged.
    ///
    /// Everything else is byte-exact with the `CIToneCurve` it replaces —
    /// see `ToneCurveSpline` for the reverse-engineered recipe that makes
    /// that possible, and PROGRESS.md's "Curves v2 slice 1 — pre-work" for
    /// how it was measured (including the two probe designs that gave
    /// confidently wrong answers first).
    private static let toneCurveKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ToneCurve", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    /// The control points `applyCurves` drives, in the spline's own
    /// sRGB-encoded space. Split out from the render call so the spline maths
    /// can be tested directly against `ToneCurveSpline` without a CIContext.
    private static func curveControlPoints(_ effective: EffectiveTone, _ blackPoint: Double) -> [CGPoint] {
        [
            CGPoint(x: max(0, -blackPoint) * kBlackPointSpan, y: max(0, blackPoint) * kBlackPointSpan),
            CGPoint(x: 0.25, y: 0.25 + effective.shadows * kCurvePointSpan),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.75 + effective.highlights * kCurvePointSpan),
            CGPoint(x: 1, y: 1)
        ]
    }

    private static func applyCurves(_ effective: EffectiveTone, _ blackPoint: Double, to image: CIImage) -> CIImage {
        guard let kernel = toneCurveKernel,
              let spline = ToneCurveSpline(points: curveControlPoints(effective, blackPoint))
        else { return image }

        let points = spline.points
        let m = spline.secondDerivatives
        // Argument layout MUST match ToneCurve.cikernel's own header.
        let xs = CIVector(x: points[0].x, y: points[1].x, z: points[2].x, w: points[3].x)
        let ys = CIVector(x: points[0].y, y: points[1].y, z: points[2].y, w: points[3].y)
        let ms = CIVector(x: m[0], y: m[1], z: m[2], w: m[3])
        let tail = CIVector(x: points[4].x, y: points[4].y, z: m[4])

        return kernel.apply(
            extent: image.extent,
            arguments: [image, xs, ys, ms, tail, spline.endSlope]
        ) ?? image
    }

    // MARK: - Point Curve (Curves v2)

    /// Curves v2's user-placed point curve — a SEPARATE, ADDITIVE stage, not
    /// a replacement for `applyCurves` above. The parametric layer and
    /// everything routed through it (Brilliance, Black Point, per-mask
    /// Shadows/Highlights) is untouched and stays byte-exact; this composes
    /// on top. See `EditState.toneCurvePoints` and `MonotoneToneCurve`.
    ///
    /// Monotone cubic, unlike `applyCurves`' natural cubic — see
    /// `MonotoneToneCurve`'s doc comment for why the two evaluators coexist
    /// rather than one being a mode of the other, and
    /// `PointToneCurve.cikernel`'s header for the same note from the GPU
    /// side.
    private static let pointToneCurveKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "PointToneCurve", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    /// Which channel(s) one `applyPointCurve` pass touches — the Swift twin
    /// of `PointToneCurve.cikernel`'s `channelMask` argument (see that
    /// kernel's header for why this is a mask rather than a numeric
    /// selector, and why one kernel takes it rather than four kernels or
    /// one kernel carrying four curves' worth of uniforms). `.all` is the
    /// pre-slice-3 composite curve's own mask — passing it reproduces the
    /// unconditional per-channel call exactly, which is what keeps the
    /// composite curve's render byte-exact across this change.
    private enum PointCurveChannelMask {
        static let all = CIVector(x: 1, y: 1, z: 1)
        static let red = CIVector(x: 1, y: 0, z: 0)
        static let green = CIVector(x: 0, y: 1, z: 0)
        static let blue = CIVector(x: 0, y: 0, z: 1)
    }

    /// Kept deliberately cheap — emptiness IS the identity test, now across
    /// all four point-curve fields. No identity-SHAPE detection here (e.g.
    /// "are these points collinear?"): that would be a second source of
    /// truth that could disagree with the evaluator, and it would buy
    /// nothing, because `MonotoneToneCurve` already renders a collinear
    /// point list as exact identity by construction (see its collinearity
    /// identity).
    private static func pointCurveActive(_ state: EditState) -> Bool {
        !state.toneCurvePoints.isEmpty
            || !state.toneCurvePointsRed.isEmpty
            || !state.toneCurvePointsGreen.isEmpty
            || !state.toneCurvePointsBlue.isEmpty
    }

    /// Renders nothing (returns the image untouched) if the kernel is
    /// missing or the points are malformed — `MonotoneToneCurve.init?`
    /// rejects fewer than 2 points, non-increasing x, non-finite or absurd
    /// values, and more points than the kernel's fixed arity can carry.
    /// `channelMask` is Curves v2 slice 3's addition — see
    /// `PointCurveChannelMask`'s own doc comment.
    private static func applyPointCurve(_ points: [ToneCurvePoint], channelMask: CIVector, to image: CIImage) -> CIImage {
        guard let kernel = pointToneCurveKernel,
              let curve = MonotoneToneCurve(points: points)
        else { return image }

        // Padded to exactly `maximumPointCount` so the kernel can be
        // fixed-arity and fully unrolled — provably output-identical, see
        // `paddedForKernel()`.
        let padded = curve.paddedForKernel()
        let p = padded.points
        let m = padded.tangents
        // Argument layout MUST match PointToneCurve.cikernel's own header.
        let xa = CIVector(x: p[0].x, y: p[1].x, z: p[2].x, w: p[3].x)
        let xb = CIVector(x: p[4].x, y: p[5].x, z: p[6].x, w: p[7].x)
        let ya = CIVector(x: p[0].y, y: p[1].y, z: p[2].y, w: p[3].y)
        let yb = CIVector(x: p[4].y, y: p[5].y, z: p[6].y, w: p[7].y)
        let ma = CIVector(x: m[0], y: m[1], z: m[2], w: m[3])
        let mb = CIVector(x: m[4], y: m[5], z: m[6], w: m[7])

        return kernel.apply(extent: image.extent, arguments: [image, xa, xb, ya, yb, ma, mb, channelMask]) ?? image
    }

    // MARK: - HSL (global hue & saturation)

    /// Global hue rotation. `degrees` maps directly to `CIHueAdjust`'s
    /// `angle` (converted to radians) — no sign inversion needed, unlike
    /// white balance's filter parameters; the raw filter's rotation
    /// direction already matches on-screen expectation (measured).
    private static func applyHue(_ degrees: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.hueAdjust()
        filter.inputImage = image
        filter.angle = Float(degrees * .pi / 180)
        return filter.outputImage ?? image
    }

    // MARK: - Selective Color (HSL v2, per-band)

    /// The first custom Core Image kernel in this codebase (CLAUDE.md's
    /// Stack section anticipated "custom kernels for curves, HSL, WB" —
    /// this is that). Genuine per-hue-band selective adjustment has no
    /// built-in Core Image primitive: nothing exposes per-pixel hue, and no
    /// composition of built-in filters can produce a smooth 8-band mask
    /// without one. `CIColorCube` was considered and rejected — it clamps
    /// highlight headroom to [0,1] unconditionally (this app's HSL family
    /// otherwise preserves it), RGB-space trilinear interpolation mistracks
    /// hue near low-saturation cube nodes, and it would need CPU LUT
    /// recomputation on every slider drag.
    ///
    /// Loaded once, lazily, from the bundled kernel source — see
    /// `Sources/Rendering/Shaders/SelectiveColor.cikernel` for the exact
    /// per-pixel math (RGB<->HSL conversion, circular hue-distance
    /// falloff, why band weight is scaled by the pixel's own saturation,
    /// and why brightness is normalized before the HSL round-trip and
    /// restored after so a colored pixel's own headroom survives even once
    /// it's genuinely inside an active band). `CIColorKernel(source:)` is
    /// deprecated since macOS 10.14 but functional; a Metal `.ci.metal`
    /// migration (non-deprecated,
    /// needs new XcodeGen `-fcikernel`/`-cikernel` build rules this project
    /// doesn't have yet) is an explicitly deferred v2.
    private static let selectiveColorKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "SelectiveColor", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    private static func selectiveColorActive(_ state: EditState) -> Bool {
        state.redHue != 0 || state.redSaturation != 0 || state.redLuminance != 0
            || state.orangeHue != 0 || state.orangeSaturation != 0 || state.orangeLuminance != 0
            || state.yellowHue != 0 || state.yellowSaturation != 0 || state.yellowLuminance != 0
            || state.greenHue != 0 || state.greenSaturation != 0 || state.greenLuminance != 0
            || state.aquaHue != 0 || state.aquaSaturation != 0 || state.aquaLuminance != 0
            || state.blueHue != 0 || state.blueSaturation != 0 || state.blueLuminance != 0
            || state.purpleHue != 0 || state.purpleSaturation != 0 || state.purpleLuminance != 0
            || state.magentaHue != 0 || state.magentaSaturation != 0 || state.magentaLuminance != 0
    }

    /// Band argument layout matches the kernel exactly: hueA/satA/lumA =
    /// (Red, Orange, Yellow, Green), hueB/satB/lumB = (Aqua, Blue, Purple,
    /// Magenta) — MEASURED (real compiled kernel probe) against this exact
    /// argument order before shipping, including that a pixel with only
    /// `magentaHue` set (the 4th/`.w` component of `hueB`) is correctly,
    /// and ONLY, affected when it's actually magenta-hued.
    private static func applySelectiveColor(_ state: EditState, to image: CIImage) -> CIImage {
        guard let kernel = selectiveColorKernel else { return image }

        let hueA = CIVector(x: state.redHue, y: state.orangeHue, z: state.yellowHue, w: state.greenHue)
        let hueB = CIVector(x: state.aquaHue, y: state.blueHue, z: state.purpleHue, w: state.magentaHue)
        let satA = CIVector(
            x: state.redSaturation, y: state.orangeSaturation, z: state.yellowSaturation, w: state.greenSaturation
        )
        let satB = CIVector(
            x: state.aquaSaturation, y: state.blueSaturation, z: state.purpleSaturation, w: state.magentaSaturation
        )
        let lumA = CIVector(
            x: state.redLuminance, y: state.orangeLuminance, z: state.yellowLuminance, w: state.greenLuminance
        )
        let lumB = CIVector(
            x: state.aquaLuminance, y: state.blueLuminance, z: state.purpleLuminance, w: state.magentaLuminance
        )
        // NSNumber explicitly, not a raw Double — matches exactly what was
        // verified against the real compiled kernel before shipping.
        let arguments: [Any] = [image, hueA, hueB, satA, satB, lumA, lumB, NSNumber(value: state.selectiveColorRange)]
        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }

    // MARK: - Point Color (per-color eyedropper refinement)

    /// The 9th custom Core Image kernel in this codebase — Lightroom-style
    /// per-color refinement: unlike `SelectiveColor.cikernel`'s 8 FIXED
    /// named hue bands, each `PointColor` instance targets ONE arbitrary
    /// picked color (Slice B, not yet built, will populate `targetHue`/
    /// `targetSaturation` via an eyedropper — Slice A ships this stage
    /// settable only via a hand-edited sidecar or a preset).
    /// `CIColorKernel(source:)` is deprecated but functional, matching
    /// `selectiveColorKernel`/`colorGradingKernel`/`colorRangeKernel`
    /// above — see `selectiveColorKernel`'s own doc comment for the
    /// deferred Metal `.ci.metal` migration this shares.
    private static let pointColorKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "PointColor", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    /// Matches `applyPointColors`'s own per-instance guard exactly
    /// (`!isIdentity && hasTarget`) — reviewer-caught: these two
    /// predicates previously disagreed (this one omitted `hasTarget`),
    /// which was harmless today (an un-picked instance is a headroom-
    /// preserving no-op either way — see `testPointColorZeroIsExactNoOp`)
    /// but meant an un-picked instance with non-zero sliders needlessly
    /// entered the whole perceptual sandwich for a stage that then does
    /// nothing.
    private static func pointColorsActive(_ state: EditState) -> Bool {
        state.pointColors.contains { !$0.isIdentity && $0.hasTarget }
    }

    /// Sequential per-instance kernel passes (matching `PointToneCurve`'s
    /// own "N passes of one shared kernel for a variable/optional set of
    /// stages" precedent), NOT packed into fixed vec4 slots the way
    /// Selective Color's fixed 8 bands are — `pointColors` is genuinely
    /// unbounded, unlike Selective Color's always-exactly-8 bands. Each
    /// pass sees the PREVIOUS instances' output, so two instances
    /// targeting overlapping colors stack (the same `applyMasks`-style
    /// sequential accumulation, not `applyRedEye`'s union).
    private static func applyPointColors(_ instances: [PointColor], to image: CIImage) -> CIImage {
        guard let kernel = pointColorKernel else { return image }
        var img = image
        for pointColorInstance in instances {
            guard !pointColorInstance.isIdentity, pointColorInstance.hasTarget else { continue }
            let hueWindow = PointColorTuning.hueWindow(forRange: pointColorInstance.range)
            let saturationWindow = PointColorTuning.saturationWindow(forRange: pointColorInstance.range)
            let target = CIVector(
                x: pointColorInstance.targetHue, y: pointColorInstance.targetSaturation,
                z: hueWindow, w: saturationWindow
            )
            let arguments: [Any] = [
                img, target,
                NSNumber(value: pointColorInstance.hue),
                NSNumber(value: pointColorInstance.saturation),
                NSNumber(value: pointColorInstance.luminance),
            ]
            img = kernel.apply(extent: img.extent, arguments: arguments) ?? img
        }
        return img
    }

    // MARK: - Color Grading (3-way shadows/midtones/highlights)

    /// The 8th custom Core Image kernel in this codebase — Lightroom's
    /// successor to Split Toning: independent Hue/Saturation/Luminance for
    /// each of 3 tonal ranges (Shadows/Midtones/Highlights), selected by
    /// each pixel's own LUMINANCE rather than SelectiveColor's per-hue
    /// targeting. See `Sources/Rendering/Shaders/ColorGrading.cikernel` for
    /// the per-pixel math (raised-cosine falloff over PERCEPTUAL/gamma-
    /// encoded luma distance from 3 fixed anchors, NOT linear light — the
    /// same mathematical FORM `SelectiveColor.cikernel`'s `bandWeights`
    /// already uses over circular hue distance, just a different axis and
    /// domain) and `ColorGradingTint` for the
    /// Hue/Saturation → RGB delta conversion, done ONCE per wheel per
    /// render in Swift, not per pixel — this kernel therefore needs no
    /// `rgb2hsl`/`hsl2rgb` at all, a real simplification over
    /// `SelectiveColor.cikernel`.
    ///
    /// `kColorGradingWidth`/`kColorGradingTintStrength`/
    /// `kColorGradingLumStrength` are v1's PRINCIPLED DEFAULTS for what
    /// Lightroom exposes as an adjustable "Blending" control (deferred to a
    /// future slice, along with "Balance" and the 4th "Global" wheel) — not
    /// a claimed reproduction of Lightroom's own undisclosed algorithm,
    /// same disclaimer precedent as Brilliance. MEASURED (a temporary
    /// spike swept each in turn against solid patches, then deleted before
    /// this comment was written):
    /// - Width 0.4 (raised-cosine half-window, on the PERCEPTUAL/gamma-
    ///   encoded luma this stage actually operates on, since it runs
    ///   inside `applyPerceptualAdjustments`'s sandwich): gives a clean
    ///   partition where each anchor (perceptual 0.0/0.5/1.0) is the ONLY
    ///   active range at its own center (e.g. perceptual luma 0.5 gets
    ///   zero shadow AND zero highlight weight, only mid), with smooth
    ///   overlap at the boundaries (e.g. perceptual 0.3 carries both some
    ///   shadow and some mid weight) — the intended soft handoff, not a
    ///   bug. Narrower widths (0.2-0.3) left the highlight range with
    ///   almost no reach into upper-midtones; wider (0.6) let shadow leak
    ///   measurably into true midtones (perceptual 0.5).
    /// - Tint strength 0.8: at full Saturation (a shadow patch, linear
    ///   0.05 base, hue 210°), pushes b from 0.05 to 0.1157 and r down to
    ///   0.0136 — a strong, clearly visible tint without the runaway
    ///   distortion measured at 1.5 (b jumps to 0.2007, a
    ///   disproportionately larger step for the same slider increment).
    /// - Luminance strength 0.5: at full Luminance on a midtone patch
    ///   (linear 0.5), +1 lifts r to 0.821 and -1 drops it to 0.267 —
    ///   meaningfully strong without blowing a midtone past 1.0 the way
    ///   1.0 does (r reaches 1.238, a highlight already fully clipped
    ///   for what should be a mid-strength nudge).
    /// Not user-adjustable yet, so hardcoded inside the kernel as local
    /// constants rather than passed as arguments — same convention as
    /// `SelectiveColor.cikernel`'s own `Wmin`/`Wmax`/`kHue`/`kLum`.

    private static let colorGradingKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ColorGrading", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    private static func colorGradingActive(_ state: EditState) -> Bool {
        state.shadowSaturation != 0 || state.shadowLuminance != 0
            || state.midtoneSaturation != 0 || state.midtoneLuminance != 0
            || state.highlightSaturation != 0 || state.highlightLuminance != 0
    }

    /// MEASURED not to commute with Vibrance/Saturation (a temporary swap-
    /// rebuild-remeasure harness, matching this codebase's established
    /// method): on a dark, colored patch (linear r=0.10/g=0.05/b=0.02,
    /// `redHue`+`hslSaturation`+a shadow tint all active), running Color
    /// Grading BEFORE Vibrance/Saturation instead of after (its shipped
    /// position) moved the result by up to 0.0105 (red channel) — ~5.2x
    /// this suite's 0.002 tolerance. So the shipped position is a real
    /// REQUIREMENT here too, not just the Black & White case above.
    private static func applyColorGrading(_ state: EditState, to image: CIImage) -> CIImage {
        guard let kernel = colorGradingKernel else { return image }

        // Clamped here, not just trusted: this slice has no UI yet, so a
        // hand-edited sidecar or preset is the ONLY input path, and unlike
        // every slider-backed field there is no UI range enforcement to
        // rely on until Slice B ships.
        func clampedSaturation(_ value: Double) -> Double { min(max(value, 0), 1) }
        func clampedLuminance(_ value: Double) -> Double { min(max(value, -1), 1) }

        let shadowDelta = ColorGradingTint.rgbDelta(hue: state.shadowHue, saturation: clampedSaturation(state.shadowSaturation))
        let midtoneDelta = ColorGradingTint.rgbDelta(hue: state.midtoneHue, saturation: clampedSaturation(state.midtoneSaturation))
        let highlightDelta = ColorGradingTint.rgbDelta(
            hue: state.highlightHue, saturation: clampedSaturation(state.highlightSaturation)
        )

        let shadowTint = CIVector(
            x: shadowDelta.r, y: shadowDelta.g, z: shadowDelta.b, w: clampedLuminance(state.shadowLuminance)
        )
        let midtoneTint = CIVector(
            x: midtoneDelta.r, y: midtoneDelta.g, z: midtoneDelta.b, w: clampedLuminance(state.midtoneLuminance)
        )
        let highlightTint = CIVector(
            x: highlightDelta.r, y: highlightDelta.g, z: highlightDelta.b, w: clampedLuminance(state.highlightLuminance)
        )

        let arguments: [Any] = [image, shadowTint, midtoneTint, highlightTint]
        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }

    // MARK: - Vibrance

    /// A saturation that protects already-saturated tones and skin tones,
    /// via Core Image's `CIVibrance` — a distinct algorithm, NOT a rescaled
    /// `applySaturation`. Runs in the perceptual sRGB-gamma domain
    /// (measured: perceptual vs linear diverge up to ~0.05/channel, and
    /// vibrance must judge saturation on the same encoded values its
    /// neighbor `applySaturation` sees). `vibrance` (-1...1) maps 1:1 to the
    /// filter's native `amount` — no span constant needed; measured
    /// strong-but-graceful at ±1 (a saturated red stays at 0.914 vs plain
    /// saturation +1's runaway 2.253). Selective by design: +0.5 lifts a
    /// muted color's HSV-saturation by +0.164 but an already-saturated
    /// color by only +0.018. Does NOT clamp headroom (measured: a 1.4
    /// linear channel survives at 1.400). Runs immediately BEFORE
    /// `applySaturation`: the two do NOT commute (measured max delta 0.243
    /// on a saturated color, far past the 0.002 tolerance), so this order is
    /// a fixed requirement, with plain saturation kept as the final uniform
    /// global scaler. Deliberately independent of Brilliance — see
    /// `EditState.vibrance`.
    private static func applyVibrance(_ vibrance: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = Float(vibrance)
        return filter.outputImage ?? image
    }

    // MARK: - Saturation

    /// Global saturation via Core Image's color-controls filter — a
    /// SEPARATE instance from `applyContrast`'s, since fusing the two into
    /// one filter call would apply them simultaneously rather than in the
    /// pipeline's required contrast-then-HSL order. `hslSaturation` (-1...1)
    /// maps to the filter's native `1 + hslSaturation` factor (0...2),
    /// mirroring contrast's mapping. Unlike `applyCurves`, this does NOT
    /// clamp highlight headroom — measured: a 1.4 linear input at
    /// saturation +1 reads back as 2.57770, not clamped to 1.0.
    private static func applySaturation(_ saturation: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = Float(1 + saturation)
        return filter.outputImage ?? image
    }

    private static func encodeToPerceptual(_ image: CIImage) -> CIImage {
        let filter = CIFilter.linearToSRGBToneCurve()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    private static func decodeToLinear(_ image: CIImage) -> CIImage {
        let filter = CIFilter.sRGBToneCurveToLinear()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    // MARK: - Straighten

    /// Rotates the image around the CURRENT extent's own center via the
    /// standard "translate to origin → rotate → translate back" recipe.
    /// Positive `straightenAngle` rotates COUNTERCLOCKWISE — derived from
    /// `CGAffineTransform(rotationAngle:)`'s standard matrix
    /// `(x,y) ↦ (x·cosθ − y·sinθ, x·sinθ + y·cosθ)`, the CCW-positive form in
    /// a y-up coordinate system (which `CIImage`'s own space is) — verified,
    /// not just derived, by a 90° test against `quadrantImage`'s known
    /// layout. Rotating a rectangle around its own center always produces a
    /// bounding box centered at that SAME point (provable by symmetry, and
    /// pinned by a test) — so `applyFlip`, which runs next, still mirrors
    /// around the correct center even after this stage grows the extent.
    /// KNOWN, DOCUMENTED v1 LIMITATION: any nonzero angle grows the
    /// bounding-box extent (except at 0/90/180/270°); the corners of that
    /// box outside the actual rotated content are undefined/transparent,
    /// composited to black by `ImageRenderer`'s existing black background —
    /// the standard "rotate reveals corners" behavior, same tradeoff
    /// philosophy as curves' headroom clamp or black point's soft overshoot.
    /// No auto-fit-to-inscribed-rectangle in v1; the already-shipped Crop
    /// tool is the documented way to remove the resulting gaps.
    private static func applyStraighten(_ state: EditState, to image: CIImage) -> CIImage {
        guard state.straightenAngle != 0 else { return image }

        let extent = image.extent
        let radians = state.straightenAngle * .pi / 180
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
        return image.transformed(by: transform)
    }

    // MARK: - Perspective (keystone)

    /// Max fraction of the extent's width/height a single corner may move
    /// inward. 0.25 (MEASURED): single-axis max leaves a tapered edge at
    /// 50% width (strong keystone); the COMBINED dual-max case (both axes
    /// at ±1) shares the top-right corner and goes non-convex above ~0.34
    /// (measured: f=0.33 convex, f=0.35 blanks the center), so 0.25 keeps
    /// even the worst case safely convex with the center covered. No
    /// NaN/crash anywhere in range (measured).
    private static let kMaxPerspectiveShift: Double = 0.25

    private static func perspectiveActive(_ state: EditState) -> Bool {
        state.verticalPerspective != 0 || state.horizontalPerspective != 0
    }

    /// Manual vertical+horizontal keystone via `CIPerspectiveTransform`
    /// (NOT `CIPerspectiveCorrection`, which is the inverse rectify-a-quad-
    /// to-rect tool — measured to change a 100×100 extent to `(0,0,100,170)`
    /// for the same corners). One combined filter call maps the extent's 4
    /// corners to a trapezoid: positive vertical tapers the TOP edge
    /// inward, positive horizontal tapers the RIGHT edge inward (directions
    /// measured against `quadrantImage`; the filter's topLeft/topRight/
    /// bottomLeft/bottomRight corners align with `CIImage`'s y-up
    /// "top = high y" space — no inversion needed). Corners are moved
    /// INWARD only and clamped to `kMaxPerspectiveShift`, so the extent is
    /// preserved EXACTLY (measured) and the quad never self-intersects.
    /// Applying both axes in a SINGLE call, not two sequential
    /// `CIPerspectiveTransform` calls, avoids double-warping shared corners
    /// (measured to differ near corners). Pure geometry: no color/tone
    /// effect, no domain question, preserves highlight headroom and alpha
    /// (all measured). Revealed black corners are the accepted
    /// Straighten-style tradeoff, trimmed with Crop.
    private static func applyPerspective(_ state: EditState, to image: CIImage) -> CIImage {
        guard perspectiveActive(state) else { return image }

        let extent = image.extent
        let width = extent.width, height = extent.height
        let vertical = min(max(state.verticalPerspective, -1), 1)
        let horizontal = min(max(state.horizontalPerspective, -1), 1)

        var topLeft = CGPoint(x: extent.minX, y: extent.maxY)
        var topRight = CGPoint(x: extent.maxX, y: extent.maxY)
        var bottomLeft = CGPoint(x: extent.minX, y: extent.minY)
        var bottomRight = CGPoint(x: extent.maxX, y: extent.minY)

        let dv = vertical * kMaxPerspectiveShift * width
        let dh = horizontal * kMaxPerspectiveShift * height
        topLeft.x += max(dv, 0); topRight.x -= max(dv, 0)
        bottomLeft.x += max(-dv, 0); bottomRight.x -= max(-dv, 0)
        topRight.y -= max(dh, 0); bottomRight.y += max(dh, 0)
        topLeft.y -= max(-dh, 0); bottomLeft.y += max(-dh, 0)

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight
        return filter.outputImage ?? image
    }

    // MARK: - Transform Scale/Aspect

    /// Fractional stretch `transformAspect` applies at its `+1` extreme —
    /// e.g. `0.6` means the Y axis grows to `1.6x` at `transformAspect: 1`
    /// (and, by the log-symmetric formula below, X shrinks to `1/1.6 ≈
    /// 0.625x` at the same extreme). LIVE-TUNED (2026-09-21): shipped at
    /// `0.3`, then doubled to `0.6` after the user tried it in a Release
    /// build and reported the effect at ±100% felt weak — this is now a
    /// once-adjusted starting point, not a from-scratch guess, but still
    /// not claimed as a measured match to Lightroom's own (undocumented)
    /// curve — see `EditState.transformAspect`'s own doc comment. Retune
    /// again if it still doesn't feel right; do not treat as settled.
    ///
    /// REVIEWER-CAUGHT, self-corrected (this reasoning holds at ANY value
    /// of this constant, independent of the live-tune above): `aspectFactor`
    /// below is `pow(1 + kMaxTransformAspectStretch, aspect)`, NOT a linear
    /// `1 + aspect * kMaxTransformAspectStretch` (an earlier draft's
    /// formula). The linear version was measurably ASYMMETRIC — at the
    /// value shipped when this was caught (`0.3`), `aspect: -1` gave `sx =
    /// 1/0.7 ≈ 1.4286` (+42.9%), not the mirror of `aspect: +1`'s `sx =
    /// 1/1.3 ≈ 0.7692` (-23.1%) the "±30%" naming implied — and the
    /// asymmetry only gets WORSE at a larger constant (at the current
    /// `0.6`, the rejected linear form would give `-1`'s `sx = 1/0.4 = 2.5`
    /// vs. `+1`'s mirror `sx = 1/1.6 = 0.625`, a +150% vs. -37.5% split).
    /// The `pow` form is exactly symmetric in LOG space by construction —
    /// `aspectFactor` at `-1` is the exact reciprocal of `aspectFactor` at
    /// `+1` (`pow(1.6, -1) == 1/1.6` exactly, at whatever the constant
    /// currently is) — matching domain research's own best guess for
    /// Lightroom's real curve shape ("most likely exponential... so that
    /// +a and -a are exact inverses"), not just a bug patch.
    // `internal` (not `private`), not by convention here — D23,
    // reviewer-caught (review pass 3): `EditPipelineTests.rawTransformScaleNoClamp` needs
    // to reference this constant directly rather than keep its own
    // hardcoded copy, which had already drifted out of sync once (the
    // test's own doc comment said "1.6" instead of the constant's actual
    // `0.6` value — 1.6 is `1 + kMaxTransformAspectStretch`, not the
    // constant itself).
    static let kMaxTransformAspectStretch: Double = 0.6

    private static func transformScaleActive(_ state: EditState) -> Bool {
        state.transformScale != 1 || state.transformAspect != 0
    }

    /// Lightroom's own Transform-panel "Scale"/"Aspect" (Aspect labeled
    /// "Stretch" in this app's UI — see `EditState.transformAspect`'s own
    /// doc comment for why). Both are diagonal affine scales about the
    /// SAME center, so they're combined into ONE resample (a
    /// `CILanczosScaleTransform` call, see the PREFILTERED RESAMPLE
    /// paragraph below — no longer a raw `CGAffineTransform` as of
    /// 2026-09-29, though the "one combined resample, not two sequential
    /// ones" structure is unchanged) — diagonal matrices commute, so unlike
    /// this pipeline's non-commuting COLOR stages, no swap-and-remeasure is
    /// needed to justify combining them; it's a provable fact, not a
    /// measured one. For any FINITE `state.transformScale`/`transformAspect`
    /// (the only inputs this struct's fields can ever hold — a `NaN` could
    /// only arrive via a hand-corrupted sidecar `JSONDecoder` would already
    /// reject), `sx`/`sy` can never be zero: `aspectFactor` is bounded to
    /// `[1/(1 + kMaxTransformAspectStretch), 1 + kMaxTransformAspectStretch]`
    /// by the clamps below (now log-symmetric — see
    /// `kMaxTransformAspectStretch`'s own doc comment), so division is
    /// always safe regardless of that constant's current tuned value.
    ///
    /// Runs AFTER Perspective, not before: Scale exists specifically to
    /// zoom in and clear the empty corner wedges Perspective correction
    /// reveals, so it must operate on Perspective's OUTPUT — running it
    /// first would just be a pre-zoom that Perspective immediately re-warps,
    /// leaving the wedges it was meant to clear (see
    /// `testTransformScaleClearsPerspectiveWedges`). Runs BEFORE Crop, same
    /// as every other stage in this Transform/Distort group — a real,
    /// undocumented-until-now divergence from Lightroom (reviewer-caught):
    /// with an off-center crop, this stage still zooms about the FULL
    /// FRAME's center, not the visible crop's own center, so Scale/Stretch
    /// and an asymmetric crop interact by shifting content within the crop
    /// rather than zooming about what the user actually sees. Not fixed
    /// here — consistent with Straighten/Perspective's own pre-crop
    /// position, and a real design question (which stage's "center" should
    /// win) worth its own session, not a silent scope decision.
    ///
    /// PREFILTERED RESAMPLE (IMPROVEMENTS.md D23, fixed 2026-09-29): the
    /// scale/stretch step itself runs through `CILanczosScaleTransform`,
    /// not a plain `.transformed(by:)` affine resample — at the clamp
    /// extremes this stage can minify by up to ~3.2x on one axis
    /// (`transformScale: 0.5, transformAspect: 1` gives `sx =
    /// 0.5/(1 + kMaxTransformAspectStretch) = 0.3125` at the current
    /// `kMaxTransformAspectStretch = 0.6`), a real aliasing risk on
    /// high-frequency content a naive resample would not filter (a real
    /// measurement, IMPROVEMENTS.md's own D23 entry, found this roughly
    /// HALVES a fine-stripe aliasing signature vs. the old mechanism — a
    /// genuine improvement, not a complete elimination). `CILanczosScale
    /// Transform`'s `scale`/`aspectRatio` parameters were verified
    /// empirically (a throwaway probe against real `CIImage` extents, not
    /// assumed from documentation) to produce `outputWidth = inputWidth *
    /// scale * aspectRatio`, `outputHeight = inputHeight * scale` — so
    /// this function's own independently-derived `sx`/`sy` map onto the
    /// filter's parameters as `scale = sy`, `aspectRatio = sx / sy`, for
    /// ANY `sx`/`sy`, not just this function's own specific formula. The
    /// SAME probe also confirmed the filter scales about the ABSOLUTE
    /// ORIGIN `(0,0)`, exactly like a raw `CGAffineTransform(scaleX:y:)`
    /// would — so the translate-to-origin/translate-back sandwich below is
    /// unchanged from the pre-fix version; only the MIDDLE step's
    /// mechanism changed.
    ///
    /// REVIEWER-CAUGHT: `CILanczosScaleTransform`'s windowed-sinc kernel
    /// has NEGATIVE side lobes (unlike the old plain affine's bilinear-ish
    /// resample) — at a hard alpha/color edge (the transparent-margin
    /// boundary this stage's own shrink creates, or ANY hard edge in the
    /// source content) this genuinely RINGS, not just rounds. This figure
    /// needed reconciling TWICE before it stabilized: 3 disagreeing FIRST
    /// drafts (this comment, PROGRESS.md, and an independent reviewer
    /// probe each cited a DIFFERENT number, none naming the same fixture/
    /// sweep/scan-density) were followed by a first RECONCILIATION attempt
    /// (a single unified "1.0864/-0.0739" figure, from a sparse per-pixel-
    /// call scan) that ALSO turned out not to reproduce — a later dense
    /// (every-pixel) re-scan of the EXACT SAME fixtures/corners that
    /// reconciliation claimed to describe showed the sparse scan had
    /// silently missed the true extrema. The figure actually depends on
    /// the hard edge's own sub-pixel phase relative to
    /// the resample grid, which shifts with fixture size — so this is
    /// reported as a RANGE across 3 fixture sizes (64/100/200px), not one
    /// fixed number (`EditPipelineTests.testD23DenseRingingReconciliation`,
    /// a throwaway harness, densely scanning every pixel via
    /// `renderFullFrame`, not sparse per-pixel calls, run then deleted —
    /// its own reference check lives on permanently inside
    /// `testTransformScaleClampBoundsRingingAtHardEdges` below): WITHOUT
    /// the clamp, alpha overshoots as high as 1.06-1.10 and color
    /// undershoots as low as roughly -0.06 to -0.063 — both well past
    /// ordinary floating-point noise, and both magnify- as well as
    /// minify-side (this ISN'T only a minification-aliasing problem).
    /// Alpha above 1 breaks `over` compositing math (`src + bg*(1-a)`
    /// SUBTRACTS background when `a > 1`) and corrupts export clamping
    /// differently than the live preview; negative linear color feeds
    /// directly into every downstream perceptual stage (Dehaze/Vignette/
    /// Clarity/NR/Sharpen/Grain). Fixed with `CIFilter.colorClamp()`
    /// (min/max `(0,0,0,0)`/`(1e6,1e6,1e6,1)` — ASYMMETRIC, see this same
    /// clamp's own inline comment at its call site below for why color's
    /// upper bound is deliberately left open) immediately after the
    /// Lanczos filter, BEFORE the translate-back/crop/composite — measured
    /// (same harness) to reliably pull alpha's OVERSHOOT (the only
    /// direction actually observed on these fixtures — negative alpha
    /// never appeared, so alpha's lower bound is a defensive clamp, not
    /// one proven necessary by measurement) and color's undershoot EXACTLY
    /// back into range in every case tried, with NO effect on
    /// already-in-range pixels (an interior, fully-opaque, correctly-
    /// colored pixel read bit-identical before and after clamping). A
    /// residual IS left on purpose: the bright-side overshoot
    /// on COLOR (not alpha) can still read above 1.0 after the clamp —
    /// deliberately, to preserve highlight headroom. `CIColorClamp`
    /// operates on UNPREMULTIPLIED values (divide by alpha, clamp,
    /// multiply back), so clamping alpha to 1 also removes the PORTION of
    /// color's own overshoot that was riding on alpha's overshoot — what's
    /// left is only the color channel's own genuine ringing, measured
    /// (same harness) at a constant ~1.06 across all 3 fixture sizes tried
    /// (vs. 1.09-1.12 pre-clamp) — a real, smaller, but still faint Lanczos
    /// halo on SDR content; this is the accepted tradeoff, not a residual
    /// bug. This is NOT the same hazard `EditPipeline.kGrainZeroPoint`'s
    /// own doc comment documents for `CIColorClamp`/`CIColorMatrix`-family
    /// filters silently corrupting `CIRandomGenerator`'s NON-premultiplied
    /// synthetic noise via a hidden premultiply round-trip — this stage's
    /// own image data is genuinely, already premultiplied real image
    /// content, the exact case that round-trip is CORRECT for, confirmed
    /// by the same measurement finding no corruption on interior pixels.
    ///
    /// UNLIKE Perspective/Flip (which preserve extent by construction —
    /// corners move inward, or land back on the identical rect) and UNLIKE
    /// Straighten (which lets the extent grow), this stage explicitly forces
    /// its output back to its OWN INPUT extent after transforming — a scale
    /// transform otherwise grows/shrinks the bounding box, and the whole
    /// point of Scale/Aspect is to reshape content WITHIN the existing
    /// frame, not change the photo's own output dimensions (matching
    /// Lightroom's own behavior: the frame size never changes, only what's
    /// visible inside it). Scale below 1.0 therefore exposes transparent
    /// margin at the edges (composited black downstream, same as
    /// Straighten/Perspective's own revealed corners); Scale above 1.0 crops
    /// away the zoomed content's excess.
    ///
    /// REVIEWER-CAUGHT-CLASS BUG, self-caught before review: a lone
    /// `.cropped(to: extent)` is NOT enough to guarantee that — `CIImage
    /// .cropped(to:)`'s own extent is the INTERSECTION of its input's
    /// extent and the requested rect, not the requested rect unconditionally
    /// padded to. A shrink (`transformScale < 1`, or an aspect axis
    /// compressed below 1) produces a transformed image whose NATURAL
    /// extent is already smaller than `extent`, so cropping it to `extent`
    /// is a no-op intersection that leaves the SMALLER extent as-is — this
    /// was caught live by `testTransformScalePreservesExtentExactly`
    /// actually failing (measured `(25,25,50,50)` at scale 0.5 against an
    /// expected `(0,0,100,100)`), not reasoned about in advance. Fixed by
    /// compositing the cropped result OVER a fully transparent canvas of
    /// the exact `extent` size — `composited(over:)`'s own extent is the
    /// UNION of its two operands, so the result is unconditionally padded
    /// back out to `extent` regardless of how much the transform shrank the
    /// actual content, while genuinely uncovered pixels stay transparent
    /// (not opaque black — `ImageRenderer`'s own background composites that
    /// downstream, same as every other stage's revealed corners).
    private static func applyTransformScale(_ state: EditState, to image: CIImage) -> CIImage {
        guard transformScaleActive(state) else { return image }

        let extent = image.extent
        let scale = min(max(state.transformScale, 0.5), 1.5)
        let aspect = min(max(state.transformAspect, -1), 1)
        let aspectFactor = pow(1 + kMaxTransformAspectStretch, aspect)
        let sx = scale / aspectFactor
        let sy = scale * aspectFactor

        let centered = image.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        // Fallback matches the PRE-fix mechanism exactly (a raw affine
        // scale), not a silent "skip scaling entirely" no-op — `outputImage`
        // returning `nil` here is practically unreachable (no documented
        // failure mode for this filter with finite, in-range parameters),
        // but a real fallback is one line and costs nothing.
        let plainAffineFallback = centered.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = centered
        lanczos.scale = Float(sy)
        lanczos.aspectRatio = Float(sx / sy)
        let scaled = lanczos.outputImage ?? plainAffineFallback
        // `CIColorClamp`, not skippable — see this function's own
        // REVIEWER-CAUGHT paragraph above for the measured ringing this
        // closes (alpha up to 1.06-1.10, color down to roughly -0.06,
        // depending on fixture size — see that paragraph for why this is a
        // range, not one fixed number). ONLY the LOWER bound on color (no
        // negative linear light)
        // and BOTH bounds on alpha (0...1, since alpha above 1 breaks `over`
        // compositing) — self-caught, NOT reviewer-caught: an EARLIER draft
        // (before any reviewer saw this diff) clamped color's UPPER bound
        // to 1 too, which silently destroyed highlight
        // headroom this stage is explicitly required to preserve
        // (`testTransformScalePreservesHighlightHeadroom`'s own "should not
        // be clamped, unlike curves" — caught immediately by that existing
        // test failing, not reasoned about in advance). A large finite
        // upper bound on R/G/B (not `.infinity` — `CIColorClamp` documents
        // undefined behavior for a non-finite bound), no cap at all in
        // practice for any value this pipeline can produce.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = scaled
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)
        let clamped = clamp.outputImage ?? scaled
        let transformed = clamped
            .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
            .cropped(to: extent)
        let transparentCanvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        return transformed.composited(over: transparentCanvas)
    }

    // MARK: - Flip

    /// Mirrors the image around the CURRENT extent's own center — not
    /// assumed to be at `(0,0)` (same discipline `applyCrop` below already
    /// follows for its rect math). Runs BEFORE crop: `x ↦ (minX+maxX) - x`
    /// for horizontal, `y ↦ (minY+maxY) - y` for vertical, so the
    /// transformed extent lands back on the exact same rect — only the
    /// content mirrors, not the geometry. Pure geometry, no color-space
    /// concerns; no headroom/domain considerations the way color filters
    /// have.
    private static func applyFlip(_ state: EditState, to image: CIImage) -> CIImage {
        guard state.flipHorizontal || state.flipVertical else { return image }

        let extent = image.extent
        var transform = CGAffineTransform.identity
        if state.flipHorizontal {
            transform = transform
                .concatenating(CGAffineTransform(scaleX: -1, y: 1))
                .concatenating(CGAffineTransform(translationX: extent.minX + extent.maxX, y: 0))
        }
        if state.flipVertical {
            transform = transform
                .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                .concatenating(CGAffineTransform(translationX: 0, y: extent.minY + extent.maxY))
        }
        return image.transformed(by: transform)
    }

    // MARK: - Crop

    /// Pure geometry, not color — runs after the perceptual sandwich, at the
    /// very end of the pipeline, matching the fixed order. This is the only
    /// stage that changes extent; `ImageRenderer.draw(in:)` was deliberately
    /// built to fit/transform against the post-pipeline `edited.extent`
    /// (not the source image's) specifically so this stage would work
    /// without renderer changes.
    private static let kMaxCropInset: Double = 0.45

    private static func cropActive(_ state: EditState) -> Bool {
        state.cropInsetTop != 0 || state.cropInsetBottom != 0
            || state.cropInsetLeft != 0 || state.cropInsetRight != 0
    }

    /// Crops using `CIImage`'s own coordinate space directly: origin
    /// bottom-left, y increases upward (the standard Core Image/Cartesian
    /// convention — unrelated to the separate Metal-drawable-presentation
    /// y-flip already resolved in `ImageRenderer`, which was about texture
    /// storage order, not `CIImage`'s own semantics). So "top inset" trims
    /// the HIGH-y portion of the extent, "bottom inset" the LOW-y portion —
    /// verified live against a real photo, not just reasoned about (see
    /// `testCropTopInsetRemovesTopContent` and its siblings for the
    /// equivalent proof in a unit test). Insets are clamped to
    /// `kMaxCropInset` per side so opposite insets can never cross into a
    /// zero/negative-size rect.
    private static func applyCrop(_ state: EditState, to image: CIImage) -> CIImage {
        guard cropActive(state) else { return image }

        let extent = image.extent
        let top = min(max(state.cropInsetTop, 0), kMaxCropInset)
        let bottom = min(max(state.cropInsetBottom, 0), kMaxCropInset)
        let left = min(max(state.cropInsetLeft, 0), kMaxCropInset)
        let right = min(max(state.cropInsetRight, 0), kMaxCropInset)

        let cropRect = CGRect(
            x: extent.minX + extent.width * left,
            y: extent.minY + extent.height * bottom,
            width: extent.width * (1 - left - right),
            height: extent.height * (1 - top - bottom)
        )
        return image.cropped(to: cropRect)
    }

    // MARK: - Red-Eye Removal

    /// Size slider → pupil radius as a fraction of the CURRENT extent's MIN
    /// dimension — same resolution-independence rationale as Sharpen/
    /// Clarity/Texture (a fixed pixel radius would cover a wildly different
    /// real-world area on a 400px vs 4000px export). MEASURED plausible
    /// span for a pupil-scale correction: 1.5% (tight, ~15px on a 1000px
    /// min-dimension) to 8% (wide, ~80px).
    private static let kRedEyeRadiusMin: Double = 0.015
    private static let kRedEyeRadiusMax: Double = 0.08

    /// Fraction of the radius that stays FULLY corrected before the soft
    /// falloff begins — MEASURED (via `CIRadialGradient`'s own real
    /// interpolation, not assumed linear): the falloff is smooth and
    /// monotonic from `coreFraction * radius` (full correction) to
    /// `radius` (zero effect), with no visible ring/banding.
    private static let kRedEyeCoreFraction: Double = 0.5

    /// Darken factor for a fully-corrected (strength=1) pupil, in
    /// SCENE-LINEAR light. MEASURED against a synthetic red-pupil test
    /// color (0.7, 0.1, 0.1): 0.4 reads as a natural dark pupil (result
    /// ~0.04 on all channels — dark, not a crushed pure-black hole);
    /// smaller values (0.2) read closer to true black, larger (0.5)
    /// noticeably lighter — 0.4 is the measured middle ground.
    private static let kRedEyeDarken: Double = 0.4

    private static func redEyeActive(_ state: EditState) -> Bool {
        !state.redEyePoints.isEmpty && state.redEyeStrength != 0
    }

    /// Localized "suppress red + darken" correction inside a soft circle
    /// around each user-placed point. Built-ins only — no custom kernel
    /// needed here (unlike Selective Color): `CIRadialGradient` builds an
    /// arbitrarily-centered soft mask (`CIVignetteEffect` can't — it's
    /// pinned to the frame's own center), `CIColorMatrix` does the
    /// de-red/darken transform in one multiply, `CIBlendWithMask`
    /// composites. Applied in SCENE-LINEAR light (no perceptual sandwich —
    /// measured clean, no crushing artifacts, unlike a domain choice that
    /// would need one).
    ///
    /// Multiple points are combined via `CIMaximumCompositing` into ONE
    /// union mask, THEN the color matrix is applied ONCE — not by
    /// compositing N sequential single-point corrections. MEASURED, a real,
    /// substantial difference: on two overlapping correction circles,
    /// sequential double-application measurably OVER-corrects the overlap
    /// (0.061 red-channel result) versus the union mask's single-pass
    /// result (0.191, close to a lone circle's own 0.240) — the union
    /// approach is what makes an overlapping-points correction apply
    /// exactly once, not twice.
    ///
    /// MEASURED to commute exactly with Vignette (see this file's header
    /// doc comment) — placement relative to Vignette is a soft choice;
    /// placement BEFORE Clarity/Texture/Noise Reduction/Sharpen is a real
    /// requirement (those must refine the corrected pixels, not un-corrected
    /// ones). Preserves alpha and extent exactly (measured). Preserves
    /// headroom on pixels OUTSIDE every point's mask exactly (a 1.4 pixel
    /// far from any point reads back 1.4) — pixels INSIDE an active mask
    /// are, by design, reduced toward a dark, corrected value (that
    /// reduction IS the feature, not a headroom bug the way an unrelated
    /// slider crushing a bright pixel would be).
    private static func applyRedEye(_ state: EditState, to image: CIImage) -> CIImage {
        guard redEyeActive(state) else { return image }

        let extent = image.extent
        let strength = min(max(state.redEyeStrength, 0), 1)
        let radius = (kRedEyeRadiusMin + state.redEyeSize * (kRedEyeRadiusMax - kRedEyeRadiusMin))
            * Double(min(extent.width, extent.height))

        var mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        for point in state.redEyePoints {
            // y-flip: SwiftUI-local space is top-left-origin/y-down; the
            // stored point matches that convention (same as the WB
            // eyedropper's own capture) — flip into CIImage's bottom-left/
            // y-up space and map onto the CURRENT post-crop extent.
            let center = CGPoint(
                x: extent.minX + CGFloat(point.x) * extent.width,
                y: extent.minY + CGFloat(1 - point.y) * extent.height
            )
            let gradient = CIFilter.radialGradient()
            gradient.center = center
            gradient.radius0 = Float(radius * kRedEyeCoreFraction)
            gradient.radius1 = Float(radius)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let circle = gradient.outputImage?.cropped(to: extent) else { continue }

            let union = CIFilter.maximumCompositing()
            union.inputImage = circle
            union.backgroundImage = mask
            mask = union.outputImage ?? mask
        }

        let darken = kRedEyeDarken
        let keepGreenBlue = 1 - strength * (1 - darken)
        let mixRed = 0.5 * strength * darken
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 1 - strength, y: mixRed, z: mixRed, w: 0)
        matrix.gVector = CIVector(x: 0, y: keepGreenBlue, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: keepGreenBlue, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let corrected = matrix.outputImage ?? image

        let blend = CIFilter.blendWithMask()
        blend.inputImage = corrected
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    // MARK: - Local Adjustments (Masks)

    private static func masksActive(_ state: EditState) -> Bool {
        state.masks.contains { !$0.isIdentity }
    }

    /// Kind-dispatched geometry, resolved up front per mask (Phase 7
    /// slice 3) — carries whichever `Resolved` type matches `mask.kind`
    /// through the shared color/tone work below to the per-kind
    /// mask-image construction near the end of the loop. A local type
    /// (not a file-level one): used only inside `applyMasks`, exactly
    /// like a local `struct`/closure would be.
    private enum ResolvedMaskGeometry {
        case radial(RadialMaskGeometry.Resolved)
        case linear(LinearMaskGeometry.Resolved)
        case brush(BrushMaskGeometry.Resolved)
        case luminanceRange(LuminanceRangeSelection.Resolved)
        case colorRange(ColorRangeSelection.Resolved)
    }

    /// Local adjustments (Radial — Phase 7 slice 2 — Linear/graduated —
    /// slice 3 — and Brush/freehand — slice 4). Runs AFTER
    /// Red-Eye, BEFORE Vignette: like Red-Eye, mask geometry is stored as
    /// fractions of the CURRENT (post-crop) extent, so it must map against
    /// the image the user actually sees and draws on — the same argument
    /// this file already makes for Red-Eye/Vignette above. Placed after
    /// Red-Eye specifically because Red-Eye is corrective retouching and
    /// masks are creative local stylization: a mask drawn over an eye
    /// should adjust the ALREADY-corrected pupil, not a still-red one that
    /// then gets corrected differently underneath it (mirrors this file's
    /// existing "detail stages refine the already-corrected pupil"
    /// reasoning for why Red-Eye precedes Clarity/Texture/Noise Reduction/
    /// Sharpen). Placed before Vignette/Clarity/Texture/Noise Reduction/Sharpen
    /// because those are GLOBAL stages that should act on the final,
    /// already-locally-stylized image — masks-vs-Vignette and masks-vs-
    /// Red-Eye commutation were measured, not just argued, matching this
    /// file's own standard for adjacency claims. MEASURED (a solid 0.7/0.1/
    /// 0.1 red image, full-strength Red-Eye point + a fully-covering mask
    /// at saturation -1): the shipped Red-Eye-then-mask order gives r =
    /// 0.04000, the reverse (mask-then-Red-Eye) gives r = 0.07039 — a real,
    /// order-dependent difference, confirming Red-Eye must run first so the
    /// mask desaturates the ALREADY-corrected color, not the original red.
    /// MEASURED (masks-vs-Vignette, using Contrast specifically — a pure
    /// scalar op like Exposure commutes trivially with Vignette's own
    /// per-pixel multiply, the same reason Red-Eye/Sharpen were separately
    /// measured to commute with it, so that pair is NOT evidence masks
    /// commute with Vignette in general): a 0.7 gray, 0.8 vignette strength,
    /// 0.6 mask contrast, sampled near a corner (40,40) — shipped order
    /// gives r = 0.60159, the reverse (Vignette-then-mask) gives r =
    /// 0.47563. Real numbers, both directions, matching this file's own
    /// measured-adjacency convention for Red-Eye/Vignette and Clarity/
    /// Vignette above.
    ///
    /// Each mask applies via the SAME mask-then-composite shape
    /// `applyRedEye` already established: compute the correction over the
    /// FULL, untouched image, build a soft ellipse mask via
    /// `RadialMaskGeometry`, then `CIBlendWithMask`. UNLIKE Red-Eye,
    /// multiple masks are NOT unioned into one shared mask first — each
    /// mask is a SEPARATE, SEQUENTIAL blend pass in array order, so
    /// overlapping masks COMPOUND (mask 2's effect lands on top of mask
    /// 1's already-adjusted result). This is deliberate, not a missed
    /// optimization: Red-Eye's union exists specifically so overlapping
    /// placements of the SAME fixed correction don't double-apply; masks
    /// are independent, user-authored, and DIFFERENT adjustments that are
    /// meant to compound where they overlap, matching Lightroom's own
    /// behavior and this slice's user-confirmed "multiple independent
    /// masks" scope.
    ///
    /// Phase 7 slice 6: a mask's own selection can ADDITIONALLY be
    /// narrowed (`Mask.combineMode == .intersect`) or have another mask's
    /// shape removed from it (`.subtract`), via `Mask.combineWithMaskID`
    /// naming that OTHER mask. This is orthogonal to, not a replacement
    /// for, the sequential-compounding paragraph above — two UNRELATED
    /// masks still compound exactly as they always have; combine only
    /// changes ONE mask's own selection SHAPE before its adjustment is
    /// blended in. The operand mask is resolved via the exact same
    /// `resolveMaskGeometry`/`maskImageAndRegion` pair the consuming
    /// mask's own shape is (see those functions' own doc comments), with
    /// one deliberate rule: the operand is evaluated against the SAME
    /// running `img` the consuming mask's own content-derived selection
    /// would see at that loop position — i.e. an operand is not evaluated
    /// "as it looked wherever it happens to sit in the array," it's
    /// evaluated as it would select right now, at the point the consumer
    /// needs it. This keeps both operands of a boolean op looking at the
    /// same image, and it's free: the extraction already threads a
    /// `source` image through for exactly this reason. Combine is
    /// deliberately NON-transitive (an operand's OWN `combineMode` is
    /// never consulted — always its raw, pre-combine shape) and FAILS
    /// OPEN on any broken reference (self, dangling) — see
    /// `Mask.combineWithMaskID`'s own doc comment for the full reasoning
    /// on both.
    ///
    /// Per mask, adjustments run through their OWN local perceptual
    /// sandwich, mirroring the shape of `applyPerceptualAdjustments`
    /// itself: White Balance and Exposure reuse the global scene-linear
    /// stages verbatim (`whiteBalanced`/`applyExposure`); Contrast/
    /// Shadows/Highlights/Saturation/Clarity are folded into ONE shared
    /// `encodeToPerceptual`/`decodeToLinear` round-trip rather than each
    /// stage opening its own. This is a measured, documented requirement,
    /// not a style choice: `applyPerceptualAdjustments`'s own doc comment
    /// records that a scene-linear contrast pivot crushes photographic
    /// middle gray toward black, so running any of these scene-linear
    /// would both look wrong AND diverge from the identically-named
    /// global slider — the same "two mechanisms, numerically
    /// incompatible" trap Phase 6 slice 4's write-up documents. Shadows/
    /// Highlights reuse `applyCurves`'s SAME `EffectiveTone`/
    /// `kCurvePointSpan` machinery (not `CIHighlightShadowAdjust` —
    /// `EditState.clarity`'s own doc comment already records that
    /// filter as measured to be an ASYMMETRIC tone-mapper, rejected for
    /// exactly this reason). `localContrast` (Clarity) is the ONE
    /// extent-sensitive param in this set (CLAUDE.md Phase 7's "Hazard
    /// 1") — its radius is derived from `perceptual.extent`, so it MUST
    /// run on the FULL-image `corrected` built here, never on a subimage
    /// cropped to the mask's own bounding box, or the radius silently
    /// comes out wrong. Temperature/Tint are RELATIVE offsets from
    /// wherever white balance already left the image (`kNeutralTemp +
    /// mask.temperature`), not absolute Kelvin like the global field —
    /// this stage runs AFTER the global white-balance stage has already
    /// adapted the whole image, so an absolute per-mask value would
    /// double-apply chromatic adaptation with no way to undo the first
    /// pass (see `Mask.temperature`'s own doc comment).
    ///
    /// Per-param `if` guards below are correctness, not an optimization:
    /// an unguarded filter chain can perturb the image even at identity
    /// parameters (`applyLevels`'s own doc comment records this exact
    /// trap for a different filter) — the guards, plus the mask-level
    /// `isIdentity` skip and `RadialMaskGeometry`'s degenerate-geometry
    /// `nil`, are what make a geometry-only mask (or a mask that fails to
    /// resolve) render BYTE-IDENTICAL to no mask at all.
    ///
    /// The mask image itself is built the same defensive way `applyRedEye`
    /// builds its union mask: a fully-transparent-black base spanning the
    /// WHOLE extent, composited with the transformed circular gradient via
    /// `CIMaximumCompositing` — this guarantees a defined value of 0
    /// everywhere outside the ellipse, not just outside the gradient's own
    /// local bounding box. MEASURED (not assumed): with `color1` fully
    /// transparent (alpha 0, as used here), `CIRadialGradient.outputImage`
    /// already has a FINITE extent equal to `radius1`'s own bounding
    /// circle — Core Image recognizes the fully-transparent region beyond
    /// `radius1` can be clipped away, so `.transformed(by:)` never
    /// encounters `CGRect.infinite` in this configuration (verified by
    /// printing the actual extent before and after the transform on a real
    /// gradient; only an OPAQUE `color1` produces the infinite-extent case
    /// some Core Image filters are documented to have). The `.linear`
    /// branch needs no such base/union at all — see that branch's own
    /// comment below for why (`CILinearGradient` clamps rather than being
    /// undefined outside `point0`/`point1`, measured before this shipped).
    /// The `.brush` branch (slice 4) ALSO needs no such base/union — see
    /// that branch's own comment below: a `CGImage`-backed `CIImage` has a
    /// genuinely finite extent, so Core Image's sampling outside it is
    /// already transparent black, matching what the `.radial` branch's
    /// union exists to guarantee for an otherwise-undefined-outside-its-
    /// disc procedural gradient. The `.luminanceRange` branch (slice 5)
    /// needs no `CIMaximumCompositing` UNION either — its VALUES are
    /// well-defined everywhere by construction (verified: sampled far
    /// outside the tone window on both a synthetic test image and a real
    /// photo, values read sensibly near zero, never garbage). But it
    /// DOES need its own explicit `.cropped(to: extent)`, for a different
    /// and genuinely SURPRISING reason (measured, not assumed — see
    /// `luminanceRangeMaskImage`'s own comment): unlike `.linear`/`.brush`,
    /// whose mask images are naturally finite-extent by construction,
    /// `.luminanceRange`'s chain reports an effectively INFINITE extent
    /// regardless of `img`'s own finite extent — caused specifically by
    /// that chain's forced-opaque alpha bias, not by `CIColorMatrix` in
    /// general (see `luminanceRangeMaskImage`'s own comment for the full
    /// measured detail) — so that crop is load-bearing here, not
    /// belt-and-braces. This does NOT generalize to the OTHER
    /// content-derived kind, `.colorRange` (slice 5 second half): its
    /// custom-kernel chain has no `CIColorMatrix` forced-alpha-bias stage
    /// at all, and its output extent was separately MEASURED (the same
    /// throwaway-probe discipline) to be exactly the requested `extent:`,
    /// genuinely finite — see `colorRangeMaskImage`'s own comment for why
    /// its own crop is structural consistency only, not load-bearing.
    private static func applyMasks(_ state: EditState, to image: CIImage) -> CIImage {
        guard masksActive(state) else { return image }

        let extent = image.extent
        // Loop-invariant: only depends on `extent`, which is fixed for the
        // whole stage (unlike Red-Eye's per-point loop, no per-mask state
        // feeds this base). Radial-only (see the per-kind mask
        // construction below for why `.linear` needs no such base).
        let base = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        // Loop-invariant, same reasoning as `base` above: only depends on
        // `extent`, fed to `invertedMaskImage` below for every `.subtract`
        // combine rather than rebuilt per mask.
        let opaqueWhite = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        var img = image

        for mask in state.masks {
            guard !mask.isIdentity else { continue }

            // Geometry resolve, kind-dispatched — `nil` (via
            // `resolveMaskGeometry`) BEFORE any of the color/tone work
            // below, exactly preserving the pre-slice-3 early-exit
            // ordering (a degenerate mask must never pay for a perceptual
            // round-trip it can't use).
            guard let resolvedGeometry = resolveMaskGeometry(mask, extent: extent) else { continue }

            // Reviewer-caught (Phase 7 slice 2): these four MUST clamp to
            // -1...1 like the global path's own `effectiveTone(_:)` does
            // (see that function's doc comment) before reaching
            // `CIColorControls`/`CIToneCurve` — this slice ships with no UI
            // yet, so a hand-authored sidecar is the only input path and
            // nothing else bounds these values. An unclamped contrast/
            // saturation can drive the color-controls factor negative,
            // inverting hue/channels rather than "reading the same as the
            // identically-named global slider," which is this type's own
            // documented guarantee. Clarity needs no clamp, but the
            // REASON changed with the Texture/Clarity split and the old
            // one no longer applies: it used to be safe because
            // `CIUnsharpMask` clamped negative intensity to a no-op, so an
            // out-of-range negative `definition` was simply inert. The
            // blur path has no such accident. It is still safe, for a
            // different and MEASURED reason: `CIFilter.mix` saturates at
            // `amount` 1.0, so clarity -1.25 (1.25 * the 0.8 span) is
            // already the fully blurred image and -2, -5, -20 all render
            // BIT-IDENTICALLY to it rather than extrapolating past it.
            // Worst case from an out-of-range NEGATIVE value is therefore
            // a fully blurred region, not the channel inversion an
            // unclamped contrast/saturation would produce. See
            // `testOutOfRangeNegativeClaritySaturatesRatherThanExtrapolating`.
            // The POSITIVE half has no such ceiling and is genuinely
            // unbounded — MEASURED, `clarity = +20` (unsharp intensity 16)
            // renders a 0.2/0.5 edge to 9.84418 on the bright side and
            // -2.26088 on the dark, i.e. negative channel values. That is
            // INHERITED UNCHANGED from `definition`, which was equally
            // unbounded upward, so it is pre-existing rather than something
            // this split introduced — but it is why the sentence above is
            // scoped to the negative direction rather than claiming the
            // field is safe in general.
            let contrast = clamped(mask.contrast)
            let shadows = clamped(mask.shadows)
            let highlights = clamped(mask.highlights)
            let saturation = clamped(mask.saturation)
            // `whiteBalanced`'s `tint` term (`targetNeutral.y = -(tint/100)
            // * kTintSpan`) has no internal guard either — same clamp,
            // same reasoning, matching the documented -100...100 range
            // `Mask.tint`'s own doc comment already claims.
            let tint = clamped(mask.tint, to: -100...100)

            var corrected = img
            // Gated on `!blackAndWhite` too: `applyPerceptualAdjustments`
            // already forced full desaturation earlier in the pipeline, and
            // `whiteBalanced` is a per-channel color matrix — applying it to
            // an already-monochrome image would paint color back into a
            // black & white photo. Contrast/Saturation/Clarity are safe
            // without this guard (chroma is already zero, so they have
            // nothing to distort). Reviewer-noted exception to `Mask`'s own
            // "reads the same as the global slider" guarantee: the GLOBAL
            // white-balance stage runs BEFORE the forced desaturation, so it
            // genuinely still affects a B&W render (the documented
            // colored-filter effect above, see `applyPerceptualAdjustments`'s
            // own doc comment) — a mask's WB is silently dropped instead.
            // Deliberate: masks are local RETOUCHING/stylization applied to
            // an already-graded image, not a second global grading pass.
            if !state.blackAndWhite, mask.temperature != 0 || tint != 0 {
                corrected = whiteBalanced(corrected, temperature: kNeutralTemp + mask.temperature, tint: tint)
            }
            corrected = applyExposure(mask.exposureEV, to: corrected)

            if contrast != 0 || shadows != 0 || highlights != 0 || saturation != 0 || mask.clarity != 0 {
                var perceptual = encodeToPerceptual(corrected)
                if contrast != 0 {
                    perceptual = applyContrast(contrast, to: perceptual)
                }
                if shadows != 0 || highlights != 0 {
                    let effective = EffectiveTone(contrast: 0, shadows: shadows, highlights: highlights, saturation: 0)
                    perceptual = applyCurves(effective, 0, to: perceptual)
                }
                if saturation != 0 {
                    perceptual = applySaturation(saturation, to: perceptual)
                }
                if mask.clarity != 0 {
                    perceptual = localContrast(
                        mask.clarity,
                        radiusFraction: kClarityRadiusFraction,
                        amountSpan: kClarityAmountSpan,
                        to: perceptual
                    )
                }
                corrected = decodeToLinear(perceptual)
            }

            // Reviewer-suggested perf guard: on a B&W photo, a mask carrying
            // ONLY temperature/tint (no other param) skips the WB branch
            // above via the `!state.blackAndWhite` gate and has nothing
            // else to apply, so `corrected` is still reference-identical to
            // `img` here — skip the gradient/blend entirely rather than pay
            // for a guaranteed no-op composite. `mask.isIdentity` alone
            // doesn't catch this case (temperature/tint being non-zero
            // means the mask isn't "identity," just inert THIS time).
            guard corrected !== img else { continue }

            guard var (maskImage, correctedRegion) = maskImageAndRegion(
                for: resolvedGeometry, extent: extent, base: base, source: img
            ) else { continue }

            // Phase 7 slice 6: narrow (`.intersect`) or punch a hole in
            // (`.subtract`) this mask's own selection using ANOTHER mask's
            // shape — see this function's own doc comment above for the
            // full semantics (non-transitive, fail-open, operand evaluated
            // against the same `img` this mask's own content-derived
            // selection would see). Note this block runs AFTER `corrected`
            // (the per-mask perceptual sandwich) is already built above —
            // an `.intersect` that resolves to a fully disjoint/degenerate
            // region still pays for that work before this `continue`
            // fires, a deviation from this file's usual "never pay for a
            // round-trip it can't use" ordering. Harmless: Core Image
            // recipes are lazy (`corrected` is an unevaluated `CIImage`
            // graph, not rendered pixels, until something downstream
            // forces it), and reordering to resolve combine geometry
            // before the perceptual sandwich would need a second,
            // duplicate geometry-resolve call ahead of the existing one —
            // not worth it for a lazy no-op.
            if mask.combineMode != .none,
               let operandID = mask.combineWithMaskID, operandID != mask.id,
               let operand = state.masks.first(where: { $0.id == operandID }) {
                let operandMask = resolveMaskGeometry(operand, extent: extent).flatMap {
                    maskImageAndRegion(for: $0, extent: extent, base: base, source: img)
                }
                switch mask.combineMode {
                case .none:
                    break // unreachable (guarded above); exhaustive switch, no `default:`
                case .intersect:
                    // The operand selects NOTHING (unpicked Color Range,
                    // zero-radius Radial, unpainted Brush) -> M ∧ 0 = 0 ->
                    // this whole mask contributes nothing, matching the
                    // boolean algebra exactly, not an arbitrary choice.
                    guard let operandMask else { continue }
                    let region = correctedRegion.intersection(operandMask.region)
                    // Disjoint shapes -> exact no-op, and avoids handing
                    // `CIBlendWithMask` an empty crop rect below.
                    // `CGRect.isEmpty` already covers the null rect (`.null`
                    // is defined as having zero width/height), so a separate
                    // `!region.isNull` check would be redundant.
                    guard !region.isEmpty else { continue }
                    let meet = CIFilter.minimumCompositing()
                    meet.inputImage = maskImage
                    meet.backgroundImage = operandMask.image
                    maskImage = (meet.outputImage ?? maskImage).cropped(to: extent)
                    correctedRegion = region
                case .subtract:
                    // The operand selects nothing -> M ∧ ¬0 = M -> this
                    // mask is completely UNAFFECTED, not skipped.
                    guard let operandMask else { break }
                    guard let inverted = invertedMaskImage(operandMask.image, opaqueWhite: opaqueWhite, extent: extent) else { break }
                    let meet = CIFilter.minimumCompositing()
                    meet.inputImage = maskImage
                    meet.backgroundImage = inverted
                    maskImage = (meet.outputImage ?? maskImage).cropped(to: extent)
                    // `correctedRegion` deliberately UNCHANGED: punching a
                    // hole in a shape never shrinks its own outer bound,
                    // so there is no ROI win available here, unlike intersect.
                }
            }

            let blend = CIFilter.blendWithMask()
            blend.inputImage = corrected.cropped(to: correctedRegion)
            blend.backgroundImage = img
            blend.maskImage = maskImage
            img = (blend.outputImage ?? img).cropped(to: extent)
        }

        return img
    }

    /// Kind-dispatched geometry resolve, extracted (Phase 7 slice 6) from
    /// what was previously the first half of `applyMasks`'s own inline
    /// switch, so a COMBINE OPERAND — a second, independent `Mask` named
    /// by `Mask.combineWithMaskID` — can be resolved through the exact
    /// same path a primary mask is, via a second call. Pure aside from
    /// `extent`; behavior UNCHANGED from the inline switch it replaces for
    /// every existing call site (verified: the full pre-slice-6 mask test
    /// suite passes with ZERO test edits after this extraction — the
    /// actual proof this is behavior-preserving, not merely intended to
    /// be). `nil` on any kind's own degenerate-geometry case, exactly
    /// matching the `continue` each arm used when this lived inline.
    private static func resolveMaskGeometry(_ mask: Mask, extent: CGRect) -> ResolvedMaskGeometry? {
        switch mask.kind {
        case .radial:
            guard let geo = RadialMaskGeometry.resolve(
                centerX: mask.centerX, centerY: mask.centerY,
                radiusX: mask.radiusX, radiusY: mask.radiusY,
                rotationDegrees: mask.rotationDegrees, feather: mask.feather,
                extent: extent
            ) else { return nil }
            return .radial(geo)
        case .linear:
            guard let geo = LinearMaskGeometry.resolve(
                centerX: mask.centerX, centerY: mask.centerY,
                rotationDegrees: mask.rotationDegrees, width: mask.width,
                extent: extent
            ) else { return nil }
            return .linear(geo)
        case .brush:
            guard let geo = BrushMaskGeometry.resolve(
                points: mask.brushPoints, brushSize: mask.brushSize, feather: mask.feather,
                extent: extent
            ) else { return nil }
            return .brush(geo)
        case .luminanceRange:
            guard let sel = LuminanceRangeSelection.resolve(
                luminanceTarget: mask.luminanceTarget, luminanceRange: mask.luminanceRange,
                feather: mask.feather, extent: extent
            ) else { return nil }
            return .luminanceRange(sel)
        case .colorRange:
            guard let sel = ColorRangeSelection.resolve(
                hasTarget: mask.colorRangeHasTarget,
                targetHue: mask.colorRangeTargetHue, targetSaturation: mask.colorRangeTargetSaturation,
                targetLuminance: mask.colorRangeTargetLuminance, tolerance: mask.colorRangeTolerance,
                feather: mask.feather, extent: extent
            ) else { return nil }
            return .colorRange(sel)
        }
    }

    /// Per-kind mask-image construction, extracted (Phase 7 slice 6) from
    /// what was previously the second half of `applyMasks`'s own inline
    /// switch — the same "a combine operand needs the same construction a
    /// primary mask gets" reasoning as `resolveMaskGeometry` above.
    /// `source` is the image content-derived kinds (`.luminanceRange`/
    /// `.colorRange`) sample from — ALWAYS the running `img` at the call
    /// site (never the loop-invariant `image`), whether resolving the
    /// mask currently being applied or an operand it combines with (see
    /// `applyMasks`'s own doc comment for why an operand is evaluated
    /// against the SAME image the consumer's own selection would see).
    /// `base` is the loop-invariant transparent-black image, `.radial`-only.
    /// Behavior UNCHANGED from the inline switch this replaces for every
    /// existing call (verified: zero test edits, same as
    /// `resolveMaskGeometry` above) — every load-bearing crop/union/
    /// no-union decision documented per-kind below is copied verbatim,
    /// not re-derived.
    private static func maskImageAndRegion(
        for resolvedGeometry: ResolvedMaskGeometry, extent: CGRect, base: CIImage, source: CIImage
    ) -> (image: CIImage, region: CGRect)? {
        let maskImage: CIImage
        let correctedRegion: CGRect
        switch resolvedGeometry {
        case .radial(let geo):
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = Float(geo.innerRadius)
            gradient.radius1 = Float(geo.gradientRadius)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let disc = gradient.outputImage else { return nil }
            let placed = disc.transformed(by: geo.transform)

            let union = CIFilter.maximumCompositing()
            union.inputImage = placed
            union.backgroundImage = base
            maskImage = (union.outputImage ?? base).cropped(to: extent)

            // Reviewer-caught perf fix (Phase 7 slice 2, motivated by
            // the live-measured RAW-with-3-masks cost): `color1`'s
            // alpha is 0, so — MEASURED, not assumed — `disc`'s own
            // extent is already FINITE (bounded to `radius1`'s
            // circle), never `CGRect.infinite`; only an OPAQUE
            // `color1` produces that case. So `placed.extent` is a
            // real, usable rect, and the mask is exactly 0 everywhere
            // outside it (that's the whole point of the transparent
            // `base` above). Cropping `corrected` to that rect AFTER
            // computing it (not the INPUT before computing it —
            // Clarity's unsharp radius still needs the full image
            // visible to its own kernel) tells Core Image's lazy
            // evaluator it only ever needs to actually produce pixels
            // within the ellipse's own bounding box for the blend
            // below, not the whole extent — byte-identical output
            // (the blend already returns `img` unchanged wherever
            // mask is 0), but far less work per mask when the ellipse
            // is small relative to the full frame.
            correctedRegion = placed.extent.intersection(extent)
        case .linear(let geo):
            let gradient = CIFilter.linearGradient()
            gradient.point0 = geo.point0
            gradient.point1 = geo.point1
            // Same color0/color1 pair as the radial branch above —
            // the blend's premultiplication/alpha behavior is already
            // validated for this exact pair, so matching it means the
            // two kinds cannot diverge on that axis.
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let ramp = gradient.outputImage else { return nil }
            // NO transparent-`base` union here, unlike the radial
            // branch: `CILinearGradient` CLAMPS to `color0`/`color1`
            // beyond each point (MEASURED — see `LinearMaskGeometry`'s
            // own doc comment), so it already has a defined value
            // everywhere, unlike a radial gradient, which is
            // UNDEFINED outside its own bounding disc and needs
            // `base`/`CIMaximumCompositing` precisely because of that.
            maskImage = ramp.cropped(to: extent)
            correctedRegion = geo.regionOfInterest
        case .brush(let geo):
            // Same reasoning as the `.linear` branch above, not the
            // `.radial` one: `brushStrokeMaskImage` returns a
            // `CGImage`-backed `CIImage`, which has a genuinely FINITE
            // extent (the bitmap's own bounds) — Core Image's sampling
            // outside a finite extent is transparent black, exactly
            // what the `.radial` branch's transparent-`base` union
            // exists to guarantee for an otherwise-undefined-outside-
            // its-disc radial gradient. No union needed here.
            guard let stroke = brushStrokeMaskImage(geo) else { return nil }
            maskImage = stroke.cropped(to: extent)
            correctedRegion = geo.regionOfInterest
        case .luminanceRange(let sel):
            // Reads `source` (the RUNNING loop `img` at the call site),
            // not the loop-invariant `image` — deliberate: masks compound
            // sequentially in this loop by design (see `applyMasks`'s
            // own doc comment above), so "select the bright tones"
            // should mean the tones as they currently look on screen —
            // i.e. after any earlier mask's adjustments — not as they
            // were before this loop started. Gets its own test
            // (`testLuminanceRangeSelectionFollowsEarlierMasksResult`).
            // `luminanceRangeMaskImage` crops to `sel.regionOfInterest`
            // itself before returning (load-bearing — see its own doc
            // comment) — no second crop needed here.
            guard let selection = luminanceRangeMaskImage(source, sel) else { return nil }
            maskImage = selection
            // ALWAYS the whole extent — unlike every other kind, there
            // is no ROI-crop win available: a pixel matching the
            // target tone can be anywhere in frame, so `corrected`
            // must be produced everywhere. A deliberate, measured cost
            // (see `luminanceRangeMaskImage`'s own doc comment).
            correctedRegion = sel.regionOfInterest
        case .colorRange(let sel):
            // Same "reads `source`, not the loop-invariant `image`"
            // reasoning as the `.luminanceRange` branch above — masks
            // compound sequentially, so "select pixels like THIS color"
            // means as they currently look on screen, after any earlier
            // mask's own adjustments.
            guard let selection = colorRangeMaskImage(source, sel) else { return nil }
            maskImage = selection
            // ALWAYS the whole extent, same reasoning as
            // `.luminanceRange` — a pixel matching the target color
            // can be anywhere in frame, structurally no ROI-crop win.
            correctedRegion = sel.regionOfInterest
        }
        return (maskImage, correctedRegion)
    }

    /// Channel-inverted (`¬`) twin of an RGB==alpha soft mask image, used
    /// ONLY by `applyMasks`'s own `.subtract` combine branch above
    /// (`target ∧ ¬operand`). Built from Porter-Duff SOURCE-OUT
    /// compositing (`Src * (1 - Dst.alpha)`, applied per-channel including
    /// alpha, since Porter-Duff operators are ALWAYS defined in
    /// premultiplied space with no ambiguity to get wrong): `Src` is an
    /// opaque-white, extent-sized constant image (RGB==alpha==1
    /// UNIFORMLY, by construction — no per-pixel data to corrupt), `Dst`
    /// is the operand's own mask image. The result is `white * (1 -
    /// operandWeight)` everywhere — `(1-w, 1-w, 1-w, 1-w)` — RGB==alpha
    /// covariance preserved AUTOMATICALLY, since `Src` already has it and
    /// every output channel is `Src`'s own channel scaled by the SAME
    /// `(1 - Dst.alpha)` factor.
    ///
    /// A `CIColorMatrix`-based inversion (`r' = -r + 1`, `a' = -a + 1`,
    /// independently per channel) was the FIRST implementation shipped
    /// here, and is WRONG — a genuinely surprising, MEASURED (not
    /// theorized) finding via a throwaway probe, not merely "considered
    /// and rejected" on paper. It passes at the two degenerate extremes
    /// (`w = 0`, `w = 1` — where premultiplied and unpremultiplied
    /// representations coincide arithmetically for an RGB==alpha value)
    /// but silently FAILS at every PARTIAL weight: `CIColorMatrix`
    /// unpremultiplies its input before applying the matrix, and for an
    /// RGB==alpha pixel `(w,w,w,w)` with `w > 0`, unpremultiplied RGB is
    /// `w/w = 1` (white) regardless of `w`'s actual value — the matrix
    /// then computes `r' = -1 + 1 = 0` for EVERY `w > 0`, and the
    /// filter's own re-premultiply step by the (correctly-computed)
    /// inverted alpha still leaves `R = 0 * (1-w) = 0`, breaking
    /// RGB==alpha for every partial-weight pixel — measured directly:
    /// original weight `0.5248` inverted via `CIColorMatrix` gave
    /// `R=0, A=0.4752` (should be `R=A=0.4752`), which is why the FIRST
    /// version of `EditPipelineTests`' own soft-edge subtract tests
    /// failed with the falloff band reading as fully-unselected instead
    /// of a smooth partial value. `CIColorInvert` is ALSO wrong, for an
    /// unrelated, simpler reason: it inverts RGB but leaves alpha
    /// untouched entirely. Both false starts are recorded here so a
    /// future maintainer doesn't re-attempt either one — Porter-Duff
    /// Source-Out is the one construction actually measured correct
    /// across the full `0...1` weight range, not just its endpoints (see
    /// `EditPipelineTests`' own value-based
    /// `testSubtractWithAFullyCoveringMaskIsTheExactComplementOfIntersect`
    /// and
    /// `testIntersectAndSubtractAgainstTheSameOperandSumToBaseValuePlusCorrectedValue`,
    /// which sample INSIDE the falloff band and would fail under either
    /// false start above. An earlier third test here,
    /// `testSubtractInversionDoesNotTintTheMaskEdges`, only asserted
    /// `sample.r == sample.g == sample.b` on a neutral-gray input — this
    /// was reviewer-caught as TAUTOLOGICAL and deleted: `CIBlendWithMask`
    /// applies one scalar weight uniformly to every output channel
    /// regardless of which bug produced that weight, so R/G/B stay equal
    /// under BOTH false starts above too, and the test could never fail
    /// either way — confirmed by injecting each regression and observing
    /// it still passed. The two value-based tests above are the ones that
    /// actually caught the `CIColorMatrix` bug during development.
    ///
    /// Extent: MEASURED finite for two finite inputs (`opaqueWhite` is
    /// already extent-bounded by its own `.cropped(to: extent)` at its
    /// call site; the operand's own mask image is already finite by the
    /// time it reaches here) — unlike `luminanceRangeMaskImage`'s own
    /// forced-opaque-alpha-bias trap, Porter-Duff Source-Out never
    /// introduces an unbounded bias term, so this function's own
    /// `.cropped(to: extent)` is structural consistency, not
    /// load-bearing — still kept, matching every other per-kind
    /// mask-image builder in this file.
    ///
    /// `opaqueWhite` is a parameter, not rebuilt per call, since
    /// `applyMasks` already hoists its own extent-sized constant (`base`)
    /// once per `apply` invocation rather than once per mask — the same
    /// loop-invariant-hoisting discipline applies here.
    private static func invertedMaskImage(_ maskImage: CIImage, opaqueWhite: CIImage, extent: CGRect) -> CIImage? {
        let sourceOut = CIFilter.sourceOutCompositing()
        sourceOut.inputImage = opaqueWhite
        sourceOut.backgroundImage = maskImage
        return sourceOut.outputImage?.cropped(to: extent)
    }

    /// Rasterizes one Brush mask's stroke into a soft-edged `CIImage` mask
    /// — the `.brush` counterpart of the `.radial`/`.linear` branches'
    /// `CIFilter.radialGradient()`/`linearGradient()` calls above, but built
    /// from a small `CGContext` bitmap instead of a procedural gradient
    /// (no built-in Core Image filter draws an arbitrary polyline).
    ///
    /// F3 (mask bitmap must be unmanaged and RGB==alpha): draws OPAQUE WHITE
    /// on a zero-filled `premultipliedLast` RGBA8 bitmap, then loads it via
    /// `CIImage(cgImage:options: [.colorSpace: NSNull()])` so Core Image
    /// performs NO color management on it — this preserves the RGB==alpha
    /// co-variance `CIBlendWithMask`'s two existing call sites (`.radial`/
    /// `.linear` above) already rely on implicitly (their gradients are
    /// white-to-black/transparent, so R/G/B and A carry the same value by
    /// construction; a color-managed decode of this bitmap could otherwise
    /// perturb R/G/B relative to A).
    ///
    /// F2 (no `.clampedToExtent()` before the blur): the finite bitmap is
    /// blurred directly. Given `BrushMaskGeometry`'s own padding (sized for
    /// the blur's tail — see that type's `padding` doc comment), skipping
    /// `.clampedToExtent()` merely clips well under 0.3% of the Gaussian's
    /// tail at the raster rect's edge; ADDING it would instead FAIL OPEN —
    /// extending the stroke's opaque edge to infinity and flooding the
    /// whole frame if the padding ever proves insufficient, a strictly
    /// worse failure mode.
    /// Reviewer-caught (Phase 7 slice 4): unlike the `.radial`/`.linear`
    /// branches (pure lazy `CIImage` recipe-building — cheap to construct
    /// repeatedly), this stage does EAGER CPU rasterization at
    /// graph-construction time (`CGContext` alloc + stroke + `makeImage()`)
    /// — measured ~3.9ms for a modest multi-point stroke on a large
    /// extent. `EditPipeline.apply` runs on the main thread multiple times
    /// per SwiftUI body pass while a mask is selected (e.g.
    /// `ContentView.currentFitRect` re-running the whole pipeline just to
    /// read `.extent`), so an unmemoized rasterization here could cost
    /// several ms of main-thread work per frame. A single-entry cache
    /// keyed on `BrushMaskGeometry.Resolved` (already `Equatable`) turns
    /// every one of those repeat calls — same mask, same geometry — into a
    /// cache hit; a real drag naturally invalidates it every frame since
    /// `geo` itself changes. `NSLock`-guarded (not merely `@MainActor`-
    /// assumed) since `EditPipeline.apply` is also called from background
    /// contexts (`ThumbnailGenerator`, `PhotoExporter`).
    ///
    /// Known, accepted limitation (reviewer-flagged, not fixed this
    /// slice): a SINGLE entry means the hit rate drops to near-zero the
    /// moment 2+ `.brush` masks coexist on one photo (each `applyMasks`
    /// pass evicts the previous mask's entry before it can be reused) or
    /// the Editor's main-thread render races a background
    /// `ThumbnailGenerator`/`PhotoExporter` pass at a different extent —
    /// both degrade back to paying the full rasterization cost on every
    /// call. A small fixed-size ring (or keying by `Mask.id`) would hold
    /// the benefit across N masks; not done here since the single-mask
    /// case this doc comment's own measurement covers is what's been
    /// live-verified. The cached `CIImage` (up to
    /// `BrushMaskGeometry.maximumRasterPixels` × 4 bytes ≈ 16MB) also
    /// retains for the PROCESS lifetime, not just the current photo's —
    /// bounded, but not cleared on photo switch/mask deletion.
    private final class BrushStrokeImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var lastKey: BrushMaskGeometry.Resolved?
        private var lastValue: CIImage?

        func image(for key: BrushMaskGeometry.Resolved, compute: () -> CIImage?) -> CIImage? {
            lock.lock()
            if let lastKey, lastKey == key {
                let cached = lastValue
                lock.unlock()
                return cached
            }
            lock.unlock()
            let value = compute()
            lock.lock()
            lastKey = key
            lastValue = value
            lock.unlock()
            return value
        }
    }
    private static let brushStrokeImageCache = BrushStrokeImageCache()

    private static func brushStrokeMaskImage(_ geo: BrushMaskGeometry.Resolved) -> CIImage? {
        brushStrokeImageCache.image(for: geo) { computeBrushStrokeMaskImage(geo) }
    }

    private static func computeBrushStrokeMaskImage(_ geo: BrushMaskGeometry.Resolved) -> CIImage? {
        let width = Int(geo.bitmapSize.width)
        let height = Int(geo.bitmapSize.height)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Coordinates fed to `context` below are directly in EXTENT-pixel
        // units (matching `geo.points`/`geo.radiusPixels`) — this scale+
        // translate is what maps that space onto the bitmap's own
        // (possibly downscaled) pixel grid.
        context.scaleBy(x: geo.rasterScale, y: geo.rasterScale)
        context.translateBy(x: -geo.rasterRect.minX, y: -geo.rasterRect.minY)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        if geo.points.count == 1 {
            // A single click has no path to stroke — fill a circle instead.
            let point = geo.points[0]
            let rect = CGRect(
                x: point.x - geo.radiusPixels, y: point.y - geo.radiusPixels,
                width: geo.radiusPixels * 2, height: geo.radiusPixels * 2
            )
            context.fillEllipse(in: rect)
        } else {
            context.setLineWidth(geo.radiusPixels * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let path = CGMutablePath()
            path.move(to: geo.points[0])
            for point in geo.points.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        }

        guard let cgImage = context.makeImage() else { return nil }
        var strokeImage = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])

        let scaledBlurRadius = geo.blurRadiusPixels * geo.rasterScale
        if scaledBlurRadius >= BrushMaskGeometry.minimumBlurRadiusPixels {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = strokeImage
            blur.radius = Float(scaledBlurRadius)
            guard let blurred = blur.outputImage else { return nil }
            strokeImage = blurred
        }

        // Transform the (possibly downscaled) bitmap back up to extent-pixel
        // space and crop to the raster rect it was built for — the inverse
        // of the scale+translate applied to `context` above: undo the
        // downscale FIRST, then shift back to the raster rect's true
        // origin (`concatenating` composes in that order).
        let transform = CGAffineTransform(scaleX: 1 / geo.rasterScale, y: 1 / geo.rasterScale)
            .concatenating(CGAffineTransform(translationX: geo.rasterRect.minX, y: geo.rasterRect.minY))
        return strokeImage.transformed(by: transform).cropped(to: geo.rasterRect)
    }

    /// Builds a `.luminanceRange` mask's per-pixel selection weight as a
    /// premultiplied-white `CIImage` — the `.luminanceRange` counterpart of
    /// the `.radial`/`.linear` branches' procedural gradients and the
    /// `.brush` branch's rasterized bitmap, but built entirely from
    /// BUILT-IN Core Image filters over the image's OWN pixels (no shape,
    /// no custom kernel — a future Color Range kind is the natural home
    /// for a `.cikernel`, not this one).
    ///
    /// MEASURED (a throwaway probe, built and run before this function was
    /// written, then deleted — same "measure, don't assume" discipline
    /// this file's own Red-Eye/Vignette adjacency claims already use): a
    /// `CIToneCurve` tent (the originally-considered approach) was
    /// rejected instead of tried in shipped code, because
    /// `applyCurves`'s own doc comment already records a disqualifying
    /// fact about that filter: its LUT is built clamped to `0...1` the
    /// instant it's non-identity (which would collapse every HEADROOM
    /// pixel — linear > 1, genuinely present in this pipeline — into one
    /// bucket, making "target the brightest tones" unable to distinguish
    /// them). CORRECTION (Curves v2 slice 1): a SECOND reason recorded
    /// here — that the filter "extrapolates past its endpoints rather
    /// than clamping", leaking selection outside the tone window — was
    /// measured to be false; `CIToneCurve` clamps at both ends. The
    /// rejection still stands on the headroom ground alone, and the
    /// custom `ToneCurve.cikernel` that has since replaced the filter
    /// extrapolates only ABOVE its last point, so it would not have
    /// rescued a tent built to select a MIDDLE tone window either.
    /// The two-ramp form below has neither problem: it is
    /// piecewise-LINEAR, exactly zero outside `[lowerZero, upperZero]` by
    /// construction, and its `CIColorMatrix` scale/bias math is defined
    /// for any input, headroom included.
    ///
    /// The chain, in order:
    /// 1. `CIColorMatrix` collapses `img` to Rec.709 relative luminance in
    ///    R/G/B, with alpha forced fully OPAQUE (`biasVector.w = 1`,
    ///    `aVector = 0`) — every downstream node is then premultiply-
    ///    neutral (unpremultiply is the identity on an opaque image).
    ///    MEASURED: a solid pure-red `(1,0,0)` patch collapses to
    ///    `0.2126` in every channel, confirming the weights apply
    ///    correctly to this (already scene-linear at this point in the
    ///    pipeline) input.
    /// 2/3. Two independent clamped affine ramps (`toneRamp` below) — one
    ///    rising 0→1 across the dark edge (`lowerZero...lowerFull`), one
    ///    falling 1→0 across the bright edge (`upperFull...upperZero`).
    /// 4. `CIMinimumCompositing` of the two ramps is exactly the
    ///    trapezoid/tent shape those four thresholds describe — zero
    ///    overshoot anywhere, by construction rather than by clamping
    ///    after the fact.
    /// 5. `CIMaskToAlpha` turns the neutral (R==G==B) tent into a
    ///    premultiplied-white mask image — RGB==alpha by that filter's
    ///    own DOCUMENTED contract, not by relying on unpremultiply-then-
    ///    matrix behavior the way a single one-shot color matrix would
    ///    (which is provably fragile on any input with alpha < 1, e.g. a
    ///    transparent corner `applyStraighten` can reveal before crop).
    ///    MEASURED: an opaque neutral 0.5 fed directly to `CIMaskToAlpha`
    ///    reads back alpha 0.5, confirming no extra gamma is applied.
    ///
    /// No transparent-`base`/`CIMaximumCompositing` union is needed here,
    /// unlike the `.radial` branch: every node in this chain produces
    /// well-defined VALUES everywhere (MEASURED: sampled far outside the
    /// tone window, on both a synthetic solid-color test image and a real
    /// photo — reads sensibly near zero, never garbage; a union exists
    /// to fix genuinely UNDEFINED values, which is not this branch's
    /// problem).
    ///
    /// A SURPRISING measured fact this doc comment exists specifically to
    /// record, since it contradicts what the `.linear`/`.brush` branches'
    /// own "no union needed" reasoning might suggest by analogy: this
    /// chain's EXTENT is not naturally finite the way theirs is.
    /// Reviewer-corrected: the cause is NOT `CIColorMatrix` in general
    /// (a `CIColorMatrix` that passes its input's own alpha through
    /// reports a finite extent, confirmed by direct measurement) — it is
    /// specifically this function's own FORCED-OPAQUE alpha bias
    /// (`luma.biasVector.w = 1` below, needed so every downstream node
    /// stays premultiply-neutral). An opaque alpha bias makes Core Image
    /// treat the output as covering the whole plane, reported as an
    /// effectively INFINITE extent — confirmed on BOTH a synthetic
    /// solid-color image (finite input) AND the user's real 20.7MP
    /// JPEG — and every downstream node (`CIColorClamp`,
    /// `CIMinimumCompositing`, `CIMaskToAlpha`) preserves rather than
    /// fixes this. This is also WHY removing the crop would be actively
    /// dangerous, not merely untidy: outside `img`'s own extent, its
    /// unpremultiplied color reads as 0 (tone 0), so an uncropped
    /// shadow-targeted mask would select the ENTIRE infinite plane at
    /// full weight, not just leak an undefined edge. The
    /// `.cropped(to: sel.regionOfInterest)` THIS FUNCTION ITSELF applies
    /// before returning (see the `return` statement below) is therefore
    /// NOT optional or belt-and-braces the way it would be for a kind
    /// whose mask image is already finite — it is the ONLY thing that
    /// gives the returned image a finite extent at all before
    /// `CIBlendWithMask` uses it; `applyMasks`'s `.luminanceRange` arm
    /// deliberately does NOT re-crop, trusting this function's own crop.
    /// Do not remove that crop, do not remove the forced-opaque
    /// alpha bias, and do not assume a future change to this filter
    /// chain preserves finiteness without re-measuring — re-measure the
    /// ALPHA BIAS specifically, not just whether `CIColorMatrix` is
    /// still in the chain.
    ///
    /// No memoization, unlike `.brush`'s `BrushStrokeImageCache`: every
    /// node here is lazy `CIImage` recipe-building with ZERO eager CPU
    /// work (no `CGContext`, no `makeImage()`), so there is nothing
    /// expensive to cache.
    ///
    /// Accepted, structural cost (measured, but smaller than the design
    /// discussion originally assumed): unlike every other kind, this
    /// branch has NO region-of-interest win available in principle (a
    /// matching tone can be anywhere in frame, so `regionOfInterest` is
    /// always the whole extent, never a small cropped rect). MEASURED on
    /// the user's real 20.7MP JPEG and materialized 24MP RAW asset,
    /// rendered into the same 2268x1385 drawable size this codebase's
    /// other Phase 7 perf probes use: for a SINGLE mask, the difference
    /// between this branch and a small ROI-cropped `.radial` mask was at
    /// or below measurement noise on both assets (all three of no-mask/
    /// radial/`.luminanceRange` landed within ~1-2ms of each other) —
    /// the theoretical no-ROI cost this comment originally predicted a
    /// clearer penalty for did not clearly materialize at this scale,
    /// likely because Core Image's own lazy evaluation means the
    /// per-pixel filter chain here is still cheap relative to the
    /// drawable-resolution render cost that dominates every measurement
    /// in this file (see `BrushStrokeImageCache`'s own doc comment on
    /// that same "cost scales with drawable size, not source megapixels"
    /// finding). Reported honestly rather than the larger gap
    /// originally hypothesized; see PROGRESS.md for the exact numbers.
    /// Still comfortably inside the 16ms/60fps budget for a single mask.
    /// NOT re-measured for multiple simultaneous `.luminanceRange` masks
    /// — the no-ROI cost is expected to compound linearly per mask the
    /// way slice 2's own multi-mask RAW finding did for Clarity, so this
    /// is worth re-checking before assuming N masks scale as cheaply as
    /// one did here.
    private static func luminanceRangeMaskImage(_ img: CIImage, _ sel: LuminanceRangeSelection.Resolved) -> CIImage? {
        let lumaWeights = CIVector(
            x: LuminanceRangeSelection.lumaRed, y: LuminanceRangeSelection.lumaGreen,
            z: LuminanceRangeSelection.lumaBlue, w: 0
        )
        let luma = CIFilter.colorMatrix()
        luma.inputImage = img
        luma.rVector = lumaWeights
        luma.gVector = lumaWeights
        luma.bVector = lumaWeights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let lumaImage = luma.outputImage else { return nil }

        guard let rising = luminanceToneRamp(lumaImage, zeroAt: sel.lowerZero, fullAt: sel.lowerFull),
              let falling = luminanceToneRamp(lumaImage, zeroAt: sel.upperZero, fullAt: sel.upperFull)
        else { return nil }

        let tent = CIFilter.minimumCompositing()
        tent.inputImage = rising
        tent.backgroundImage = falling
        guard let weight = tent.outputImage else { return nil }

        let toAlpha = CIFilter.maskToAlpha()
        toAlpha.inputImage = weight
        // Reviewer-suggested: crop HERE, inside the function that owns the
        // forced-opaque-alpha bias responsible for the infinite extent
        // (see this function's own doc comment above), rather than relying
        // on the caller to remember it. Structurally impossible to misuse
        // going forward, not merely documented as required.
        return toAlpha.outputImage?.cropped(to: sel.regionOfInterest)
    }

    /// One clamped affine ramp from 0 (at `zeroAt`) to 1 (at `fullAt`) —
    /// negative `scale` (when `fullAt < zeroAt`, the falling/bright-edge
    /// case) handles both directions with the same formula, no second code
    /// path. `fullAt != zeroAt` is guaranteed by `LuminanceRangeSelection
    /// .minimumEdgeWidth`, so `scale` is always finite.
    private static func luminanceToneRamp(_ image: CIImage, zeroAt: Double, fullAt: Double) -> CIImage? {
        let scale = 1 / (fullAt - zeroAt)
        let bias = -zeroAt * scale
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        guard let scaled = matrix.outputImage else { return nil }
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = scaled
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage
    }

    // MARK: - Color Range mask

    /// The second custom Core Image kernel in this codebase (after
    /// `selectiveColorKernel` above) — mirrors that property's exact load
    /// shape (bundled source, lazy, fails soft to `nil`). No built-in
    /// Core Image filter exposes per-pixel hue, and none can express a
    /// joint 3-axis (hue/saturation/luminance) color distance — see
    /// `Sources/Rendering/Shaders/ColorRange.cikernel`'s own header for
    /// the exact per-pixel math, and `ColorRangeSelection`'s own doc
    /// comment for the Swift-side twin the kernel MUST agree with
    /// (measured via a throwaway probe before this shipped — a 12-color
    /// Swift/GLSL agreement sweep, hue wraparound, headroom selection,
    /// and output-extent finiteness all confirmed live before commit).
    private static let colorRangeKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ColorRange", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    /// Colocated with `colorRangeKernel` above (its only caller), not near
    /// `selectiveColorKernel`/`applySelectiveColor` — matches
    /// `luminanceRangeMaskImage`'s own placement precedent one section up.
    ///
    /// UNLIKE `luminanceRangeMaskImage`, the `.cropped(to:)` below is NOT
    /// load-bearing — MEASURED via the same throwaway probe referenced
    /// above: a `CIColorKernel`'s output extent is exactly the `extent:`
    /// passed to `apply`, genuinely finite, with none of
    /// `luminanceRangeMaskImage`'s forced-opaque-alpha-bias infinite-extent
    /// trap (that trap is specific to `CIColorMatrix`'s alpha bias, not
    /// inherent to any scene-linear chain — see that function's own doc
    /// comment). Kept anyway for structural consistency with every other
    /// per-kind mask-image builder, and so a future caller can't be the
    /// one place that forgets a real requirement if this kernel is ever
    /// rewritten to no longer emit its own `vec4(w,w,w,w)` directly.
    private static func colorRangeMaskImage(_ img: CIImage, _ sel: ColorRangeSelection.Resolved) -> CIImage? {
        guard let kernel = colorRangeKernel else { return nil }
        let target = CIVector(x: sel.targetHue, y: sel.targetSaturation, z: sel.targetLuminance, w: 0)
        let window = CIVector(
            x: sel.hueWindowDegrees, y: sel.saturationWindow, z: sel.lowerLuminanceSpan, w: sel.upperLuminanceSpan
        )
        let arguments: [Any] = [img, target, window, NSNumber(value: sel.falloffWidth)]
        return kernel.apply(extent: sel.regionOfInterest, arguments: arguments)?.cropped(to: sel.regionOfInterest)
    }

    // MARK: - Vignette

    /// Slider-to-filter spans, MEASURED against `CIVignetteEffect` in this
    /// app's linear working space. The darken and lighten spans DIFFER on
    /// purpose: the filter's negative intensity brightens the corner ~8x
    /// harder than its positive intensity darkens it (measured on solid
    /// 0.5: strength +1 → corner 0.130 (~0.26x), raw -1 → corner 4.13
    /// (~8x)), so the lighten side is scaled down to 0.25 to keep strength
    /// ±1 comparably strong-but-graceful. The filter's intensity also
    /// SATURATES at 1.0 (intensity 1 and 2 measure identical), so the
    /// darken span uses its full natural range.
    private static let kVignetteDarkenSpan: Double = 1.0
    private static let kVignetteLightenSpan: Double = 0.25

    /// Radius scale bounds on the frame's half-diagonal, and the fixed
    /// falloff. radius 0→0.7 (tight, corner 0.015), 0.5→1.0 (default, corner
    /// 0.130), 1→1.3 (wide, corner 0.254) — all measured on solid 0.5.
    /// Falloff 0.5 is a measured sweet spot: 0.0 confines darkening to the
    /// extreme corners, 1.0 begins darkening the CENTER itself (0.458 —
    /// wrong). Softness (a falloff slider) is deferred future work.
    private static let kVignetteRadiusMin: Double = 0.7
    private static let kVignetteRadiusMax: Double = 1.3
    private static let kVignetteFalloff: Double = 0.5

    private static func vignetteActive(_ state: EditState) -> Bool {
        state.vignetteStrength != 0
    }

    /// A radial corner darkening (or, for negative strength, brightening)
    /// tied to the FINAL framing — the classic photographic vignette. Runs
    /// dead last, after crop, so its center and radius derive from the
    /// CURRENT (post-crop) `image.extent`, not the original image: `center`
    /// is the extent's midpoint, radius is half the extent's diagonal
    /// scaled by the Radius slider. Verified on a cropped/offset extent
    /// (10,0,90,75): all four crop corners darken equally and the crop's
    /// own center stays pristine — the vignette follows the crop, not the
    /// original frame. Uses `CIVignetteEffect` (explicit center + pixel
    /// radius) rather than `CIVignette`: both auto-center correctly on an
    /// offset extent (measured), but `CIVignetteEffect`'s pixel radius maps
    /// deterministically to the crop geometry whereas `CIVignette`'s radius
    /// is an opaque normalized unit that saturates ~2.0. Applied in
    /// SCENE-LINEAR light, NOT wrapped in the perceptual encode/decode
    /// sandwich: measured, a perceptual-domain vignette crushes corners
    /// toward black (corner 0.030 vs linear's graceful 0.130). Does NOT
    /// clamp highlight headroom (measured: a 1.4 linear center survives at
    /// 1.399) and preserves alpha (measured). The strength→intensity map is
    /// asymmetric — see the span constants above.
    private static func applyVignette(_ state: EditState, to image: CIImage) -> CIImage {
        guard vignetteActive(state) else { return image }

        let extent = image.extent
        let radiusScale = kVignetteRadiusMin + state.vignetteRadius * (kVignetteRadiusMax - kVignetteRadiusMin)
        let intensity = state.vignetteStrength >= 0
            ? state.vignetteStrength * kVignetteDarkenSpan
            : state.vignetteStrength * kVignetteLightenSpan

        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(0.5 * hypot(extent.width, extent.height) * radiusScale)
        filter.intensity = Float(intensity)
        filter.falloff = Float(kVignetteFalloff)
        return filter.outputImage ?? image
    }

    // MARK: - Dehaze (dark channel prior)

    /// Patch radius for the dark channel's spatial minimum, as a fraction of
    /// `min(extent)`. `CIMorphologyMinimum`'s radius is in ABSOLUTE PIXELS —
    /// the same resolution trap `kClarityRadiusFraction` and
    /// `kSharpenRadiusFraction` already document — so it must scale with the
    /// image or a 24MP photo and its thumbnail would get different haze
    /// estimates and therefore different colour.
    /// MEASUREMENT: see `testDehazeRadiusScalesWithResolution`.
    private static let kDehazeRadiusFraction: Double = 0.0125

    /// Blur radius (fraction of `min(extent)`) applied before `CIAreaMaximum`
    /// estimates the atmospheric light. Blurring FIRST is the point: the raw
    /// maximum of a photo is whatever single brightest pixel exists — a
    /// specular highlight, a street lamp, a hot pixel — which is not the
    /// atmosphere. Blurring makes the estimate come from the brightest REGION
    /// instead, the cheap stand-in for the paper's own "brightest 0.1% of the
    /// dark channel" selection.
    private static let kDehazeAtmosphereBlurFraction: Double = 0.02

    /// How much haze the model is allowed to remove. The paper's own omega:
    /// deliberately below 1.0 so a little haze survives in the deepest
    /// distance, because a perfectly clear far field reads as unnatural
    /// (aerial perspective is a real depth cue).
    private static let kDehazeOmega: Double = 0.95

    /// Floor on transmission before dividing by it. Without it, the densest
    /// haze drives `t` toward 0 and `(I - A)/t` explodes into noise.
    private static let kDehazeTransmissionFloor: Double = 0.1

    /// Span for the NEGATIVE (add-haze) half: at -1 the image blends this far
    /// toward the atmospheric light. Below 1.0 on purpose — a full blend is a
    /// flat rectangle of A with no image left in it.
    private static let kDehazeAddHazeSpan: Double = 0.85

    /// The third and fourth custom Core Image kernels in this codebase —
    /// same lazy, bundled, fail-soft-to-`nil` load shape as
    /// `selectiveColorKernel`/`colorRangeKernel` above. Two kernels rather
    /// than one because the dark channel prior is inherently a NEIGHBOURHOOD
    /// operation and a `CIColorKernel` cannot sample neighbours: the
    /// per-pixel half runs here, the spatial minimum runs as
    /// `CIMorphologyMinimum` between them.
    private static let dehazeDarkChannelKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "DehazeDarkChannel", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    private static let dehazeRecoverKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "DehazeRecover", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    private static func dehazeActive(_ state: EditState) -> Bool {
        state.dehaze != 0
    }

    /// Single-image haze removal via the DARK CHANNEL PRIOR (He, Sun & Tang,
    /// CVPR 2009). Core Image has no dehaze filter, so this is assembled from
    /// two custom kernels plus `CIAreaMaximum` and `CIMorphologyMinimum`:
    ///
    ///   1. atmospheric light A  = area maximum of a blurred copy, spread from
    ///      1x1 to a constant field with `.clampedToExtent()`
    ///   2. dark channel d       = per-pixel `min(r,g,b)` of `I/A` (kernel 1)
    ///   3. spatial minimum      = `CIMorphologyMinimum` over a patch
    ///   4. recovery             = `J = (I - A)/max(1 - omega*amount*d, t0) + A`
    ///      (kernel 2)
    ///
    /// **Everything stays on the GPU.** Step 1 is the reason: A is reduced to
    /// a 1x1 image and then spread back out as a sampler, rather than rendered
    /// to the CPU and passed as a scalar. Do NOT "simplify" this by reusing
    /// `ImageAverageColor`'s readback — that is correct for Cast, a one-shot
    /// user action, and would stall every frame here.
    ///
    /// Runs in SCENE-LINEAR light with no perceptual sandwich, unlike
    /// Clarity/Texture. That is not a consistency lapse: the haze model is
    /// defined on RADIANCE, so the working space is already the right one.
    /// This is a PRINCIPLED choice, NOT a measured one — no perceptual A/B was
    /// run, and none is needed to justify using the domain the model is
    /// defined in.
    ///
    /// Placed AFTER masks and BEFORE Vignette, Clarity and Texture:
    /// - before Vignette because Vignette darkens corners, and A is estimated
    ///   from the frame's brightest region — letting Vignette run first would
    ///   feed the haze estimate a value the scene never had
    /// - before Clarity/Texture so local contrast refines the RESTORED scene
    ///   rather than sharpening haze, the same argument the pipeline header
    ///   already makes for Red-Eye preceding the detail stages
    ///
    /// Post-crop, with the rest of the Presence group. **Consequence worth
    /// knowing: A is estimated from the VISIBLE frame, so cropping changes the
    /// dehaze result.** Consistent with Vignette also tracking the post-crop
    /// frame, but more surprising, because a crop that excludes the brightest
    /// region shifts the whole haze estimate.
    ///
    /// Extent: `CIGaussianBlur` and `CIMorphologyMinimum` both expand their
    /// output and `CIAreaMaximum` collapses it to 1x1, so every step is
    /// clamped and cropped back. The dependents are DOWNSTREAM — Vignette's
    /// center and Clarity/Texture/Sharpen's `min(extent)` radius fractions all
    /// read whatever extent this stage emits. (An earlier draft said
    /// `applyMasks` depends on it; that is backwards — `applyMasks` runs one
    /// line ABOVE this stage and can never see its extent.)
    ///
    /// PERFORMANCE — this stage is the most expensive in the Presence group,
    /// and combining it with CLARITY specifically costs materially more than
    /// the sum of the two. Both of those hold under every methodology tried.
    ///
    /// **The absolute numbers do not reproduce, so no single figure is quoted
    /// as this stage's cost.** Three methodologies gave 78.9 / 116.5 / 148.7 ms for the SAME
    /// configuration at 4000x4000. The Dehaze+Clarity excess landed at 1.7x,
    /// 2.1x and 3.7x depending on method.
    ///
    /// The methodology trap, worth knowing before re-measuring: a harness that
    /// shares one `CIContext` across configurations lets later runs hit
    /// subgraphs earlier ones cached — every dehaze configuration shares the
    /// atmospheric-light blur. Interleaving does not fix that, it CAUSES it.
    /// THREE claims died this way and are recorded as withdrawn in
    /// IMPROVEMENTS.md D17 so they are not re-derived (the third,
    /// `.insertingIntermediate()` being "worse", is noted at the
    /// `areaMaximum` site below):
    ///
    /// - "negative is ~4x cheaper because Core Image prunes the dark-channel
    ///   chain as dead code" — FALSE. With a fresh context per measurement,
    ///   +1 and -1 are within 1% (148.7 vs 147.8 ms). No pruning happens.
    /// - "`CIAreaMaximum` is not the cost driver" — FALSE. Reviewer measured
    ///   the atmosphere chain at ~25% of this stage's total. The substitution
    ///   test behind the original claim was confounded: replacing the area
    ///   maximum with a constant necessarily also removes the 80px Gaussian
    ///   that feeds it, so it never isolated what it claimed to.
    ///
    /// Accepted rather than optimised, by explicit user decision when this
    /// slice was scoped: ship the correct algorithm, record the cost, and rely
    /// on `ProxyScale`'s interactive proxy, which already absorbs
    /// Clarity/Texture. The cost lands on export and the settled full-res
    /// frame, not on dragging. See IMPROVEMENTS.md D17.
    ///
    /// LIMITATION, an unrecorded deviation from the cited paper until now:
    /// there is no refinement of the transmission map (the paper's soft
    /// matting, or the usual guided-filter substitute). Transmission is
    /// therefore blocky at the patch scale and will halo at sharp depth
    /// discontinuities. Acceptable for v1, same scope-cut pattern as every
    /// other v1 feature here, but it is a real quality gap rather than a
    /// tuning choice.
    ///
    /// Fails soft to the unmodified image if either kernel is unavailable,
    /// matching `applySelectiveColor`'s own precedent.
    private static func applyDehaze(_ state: EditState, to image: CIImage) -> CIImage {
        guard dehazeActive(state) else { return image }
        guard let darkKernel = dehazeDarkChannelKernel,
              let recoverKernel = dehazeRecoverKernel else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let minDimension = Double(min(extent.width, extent.height))

        // 1. Atmospheric light: blur, reduce to 1x1, spread back to a field.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(kDehazeAtmosphereBlurFraction * minDimension)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }

        // `CIAreaMaximum` takes a PER-CHANNEL maximum, so max-RGB and
        // max-alpha can come from different pixels, making the unpremultiplied
        // `A = maxRGB / maxAlpha` an underestimate on mixed-alpha input.
        // Benign as shipped — any opaque interior pins max-alpha to 1 — but
        // `applyStraighten` upstream genuinely produces partial-alpha frames,
        // so it is not purely theoretical.
        let areaMax = CIFilter.areaMaximum()
        areaMax.inputImage = blurred
        areaMax.extent = extent
        guard let atmosphere1x1 = areaMax.outputImage else { return image }
        // No `.insertingIntermediate()` here — but NOT for the reason an
        // earlier version of this comment gave. Both of its claims are
        // WITHDRAWN (see IMPROVEMENTS.md D17): the "worse on the full-extent
        // field" number did not reproduce (re-measured neutral), and "the area
        // maximum is not this stage's cost driver" is FALSE — the atmosphere
        // chain measures ~25% of this stage's total, making it the single
        // largest removable cost here. Both came from a harness that shared
        // one `CIContext` across configurations.
        //
        // So: if you are optimising this stage, START HERE, at the blur +
        // area maximum above. `.insertingIntermediate()` was measured neutral
        // and is omitted on that basis alone.
        let atmosphere = atmosphere1x1.clampedToExtent().cropped(to: extent)

        // 2. Dark channel, then 3. its spatial minimum over a patch.
        guard let dark = darkKernel.apply(extent: extent, arguments: [image, atmosphere]) else { return image }
        let morphology = CIFilter.morphologyMinimum()
        morphology.inputImage = dark.clampedToExtent()
        morphology.radius = Float(kDehazeRadiusFraction * minDimension)
        guard let darkMinimum = morphology.outputImage?.cropped(to: extent) else { return image }

        // 4. Recover. The negative (add-haze) half is pre-scaled by its own
        //    span here so the kernel can simply read `-amount`.
        let amount = state.dehaze < 0 ? state.dehaze * kDehazeAddHazeSpan : state.dehaze
        let arguments: [Any] = [
            image, darkMinimum, atmosphere,
            NSNumber(value: amount),
            NSNumber(value: kDehazeOmega),
            NSNumber(value: kDehazeTransmissionFloor),
        ]
        return recoverKernel.apply(extent: extent, arguments: arguments)?.cropped(to: extent) ?? image
    }

    // MARK: - Texture & Clarity (local contrast)

    /// Slider-to-`CIUnsharpMask.intensity` span, MEASURED to give comparable
    /// PEAK punch to Sharpen's own full strength (0.66061 vs Sharpen's
    /// 0.63963 on the same 0.2/0.5 edge) but spread over a far wider band —
    /// still 0.50955 elevated 60px from the edge, where Sharpen has already
    /// decayed to baseline. That width, not the peak, is what makes this
    /// local CONTRAST rather than fine sharpening.
    private static let kClarityAmountSpan: Double = 0.8

    /// Radius as a fraction of the CURRENT extent's MIN dimension — MEASURED
    /// necessity, same as Sharpen's `kSharpenRadiusFraction`: the filter's
    /// radius is in absolute pixels (a fixed radius gives byte-identical
    /// halos regardless of image size), so it must scale with resolution.
    /// 16x Sharpen's own 0.0025 fraction — local contrast needs a far wider
    /// reach than fine-detail sharpening; a smaller fraction reads as more
    /// sharpening, a much larger one starts reading as a global contrast
    /// boost rather than "local" (measured at a 0.02...0.08 sweep).
    private static let kClarityRadiusFraction: Double = 0.04

    /// Texture reuses Clarity's span — the two controls differ ONLY in
    /// radius, which is the whole point of splitting them. Kept as its own
    /// named constant rather than aliasing `kClarityAmountSpan` so the two
    /// can be tuned independently later without a confusing rename.
    private static let kTextureAmountSpan: Double = 0.8

    /// Texture's radius fraction: 0.01, between Sharpen's fine 0.0025 and
    /// Clarity's wide 0.04. MEASURED by sweeping THIS constant and reading
    /// the overshoot profile off the same 0.2/0.5 step edge the Clarity and
    /// Sharpen constants were measured on (800px, amount 1.0), sampling the
    /// peak and 15/30/60px out from the edge:
    ///
    ///   fraction   peak(x=401)  +15px     +30px     +60px
    ///   0.0025     0.57154      0.49957   0.49957   0.49957
    ///   0.005      0.61530      0.50032   0.50032   0.50032
    ///   0.01       0.64124      0.50955   0.50060   0.50060   <- shipped
    ///   0.02       0.65435      0.55317   0.50955   0.50001
    ///   0.04       0.66061      0.60219   0.55443   0.50955   (Clarity's)
    ///
    /// 0.01 is where the halo is measurably wider than a fine sharpen yet
    /// still local: elevated at +15px (0.50955, vs 0.50032 at 0.005 — flat
    /// to three places) and essentially back to baseline by +30px, where
    /// Clarity is still 0.55443. At 0.02 and above it reads as a weak
    /// Clarity rather than a separate control; at 0.005 and below it is
    /// indistinguishable from a sharpen.
    ///
    /// For reference, Sharpen at 1.0 on the same edge measures 0.63963 /
    /// 0.50001 / 0.50001 / 0.50001 — a comparable PEAK to Texture's but
    /// flat by 15px, so peak height is NOT what separates these controls;
    /// the width is. (Sharpen's own 0.0025 is not comparable row-for-row
    /// with the 0.0025 row above: different filter path and span.)
    private static let kTextureRadiusFraction: Double = 0.01

    private static func clarityActive(_ state: EditState) -> Bool {
        state.clarity != 0
    }

    private static func textureActive(_ state: EditState) -> Bool {
        state.texture != 0
    }

    /// Clarity: wide local contrast via a LARGE-radius, low-
    /// amount `CIUnsharpMask` — the SAME filter Sharpen uses (already
    /// measured numerically identical to `CISharpenLuminance` there), here
    /// at a much larger radius. Runs AFTER Vignette, BEFORE the Noise
    /// Reduction + Sharpen detail pair: post-crop/post-geometry so its
    /// absolute-pixel radius tracks the final frame and nothing resamples
    /// its work; leads the detail region as its coarsest member so Noise
    /// Reduction then cleans up any noise it amplifies and Sharpen stays
    /// last among the detail stages. MEASURED: does NOT cleanly commute with Vignette (unlike
    /// Sharpen) — corner differences up to 0.0188 between orderings, so
    /// running AFTER Vignette is a real requirement, not an arbitrary
    /// choice. Applied in the PERCEPTUAL sRGB-gamma domain, in its own
    /// encode/decode sandwich, matching Sharpen — though MEASURED, domain
    /// barely mattered here (~1% relative difference between perceptual and
    /// scene-linear lift across shadow/mid/highlight test edges), unlike
    /// Sharpen (~5%) or Noise Reduction (~2x); perceptual is chosen for
    /// consistency with the sandwich pattern, not because it measurably
    /// wins here. Radius scales with `min(extent)` — see
    /// `kClarityRadiusFraction`. Does NOT clamp highlight headroom (a 1.4
    /// flat survives at 1.40127) and preserves alpha and extent exactly
    /// (measured). Guarded off at amount 0 (exact no-op, measured max diff
    /// 0.0). BIPOLAR: the positive half is the `CIUnsharpMask` above; the
    /// negative half is a blur blend, because `CIUnsharpMask` was measured
    /// to silently clamp negative `intensity` to a no-op in this working
    /// space. See `localContrast` for both halves and
    /// `EditState.clarity`'s doc comment for the original measurement.
    private static func applyClarity(_ state: EditState, to image: CIImage) -> CIImage {
        guard clarityActive(state) else { return image }
        return decodeToLinear(localContrast(
            state.clarity,
            radiusFraction: kClarityRadiusFraction,
            amountSpan: kClarityAmountSpan,
            to: encodeToPerceptual(image)
        ))
    }

    /// Texture: the SAME construction as Clarity at a much smaller radius —
    /// see `kTextureRadiusFraction` for the measured sweep that picked it.
    /// Runs immediately AFTER Clarity, coarse-to-fine, and BEFORE the Noise
    /// Reduction + Sharpen detail pair, so the pipeline's three local-
    /// contrast/detail stages descend in radius from Clarity (0.04) through
    /// Texture (0.01) to Sharpen (0.0025).
    ///
    /// MEASURED, and honestly a WEAK result: Texture and Clarity very nearly
    /// commute. On the 0.2/0.5 step edge with both at 1.0 (800px), swapping
    /// the two stages moves the profile by at most 0.00215 (at +15px;
    /// 0.00052 at the peak, 0.00025 at +30px, 0.00060 at +60px) — only
    /// marginally above this suite's own 0.002 `accuracy` tolerance. So
    /// unlike Clarity-vs-Vignette (0.0188, a real requirement), this
    /// adjacency is NOT forced by measurement. It is coarse-then-fine by
    /// CONVENTION, matching the existing Clarity->NR->Sharpen chain's
    /// descending radii. Recorded as a convention rather than dressed up as
    /// a measured necessity.
    ///
    /// Takes its own perceptual sandwich rather than sharing Clarity's: the
    /// two stages are independently guarded (either can be at 0), and
    /// folding them would either run a pointless encode/decode when only one
    /// is active or need a combined guard that obscures which stage did
    /// what.
    private static func applyTexture(_ state: EditState, to image: CIImage) -> CIImage {
        guard textureActive(state) else { return image }
        return decodeToLinear(localContrast(
            state.texture,
            radiusFraction: kTextureRadiusFraction,
            amountSpan: kTextureAmountSpan,
            to: encodeToPerceptual(image)
        ))
    }

    /// The local-contrast construction shared by Clarity, Texture, and each
    /// mask's own Clarity — factored out so a mask's Clarity at value X is
    /// numerically identical to the global Clarity slider at X, same span
    /// and radius fraction. Operates on ALREADY-PERCEPTUAL input — the
    /// caller owns the encode/decode sandwich (`applyClarity`/`applyTexture`
    /// each open their own; `applyMasks` folds this into the one sandwich it
    /// already opens for Contrast/Curves/Saturation, avoiding a second round
    /// trip per mask). Radius is derived from `extent`, so the caller must
    /// pass the FULL, untouched image — never a subimage cropped to some
    /// region's bounding box — or the radius silently comes out wrong (see
    /// `applyMasks`'s own doc comment on this exact hazard).
    ///
    /// BIPOLAR, via two different constructions — this is the whole reason
    /// the pre-split `definition` shipped one-directional:
    ///
    /// - `amount > 0` — `CIUnsharpMask`, unchanged from `definition`.
    /// - `amount < 0` — blend toward a `CIGaussianBlur` at the SAME radius.
    ///   `CIUnsharpMask` is MEASURED to silently clamp negative `intensity`
    ///   to a bit-identical no-op in this working space, so the negative
    ///   half cannot reuse it; blending toward the blur is what
    ///   local-contrast REDUCTION physically is. `EditState.clarity`'s doc
    ///   comment carries the original measurement.
    ///
    /// EXTENT HAZARD, handled here: `CIGaussianBlur` EXPANDS its output
    /// extent (by roughly 3x sigma on every side) and leaves the border
    /// undefined without help. Every stage in this pipeline is
    /// extent-preserving, and `applyMasks` feeds this helper the full image
    /// whose extent its mask geometry is resolved against — a silent extent
    /// change here would misalign masks, not merely look soft. So the blur
    /// runs on a `.clampedToExtent()` source (defined borders, no dark
    /// halo creeping in from outside the frame) and its result is cropped
    /// straight back to the input's own extent before blending.
    private static func localContrast(
        _ amount: Double,
        radiusFraction: Double,
        amountSpan: Double,
        to perceptual: CIImage
    ) -> CIImage {
        guard amount != 0 else { return perceptual }
        let extent = perceptual.extent
        let radius = radiusFraction * Double(min(extent.width, extent.height))

        if amount > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = perceptual
            filter.radius = Float(radius)
            filter.intensity = Float(amount * amountSpan)
            return filter.outputImage ?? perceptual
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = perceptual.clampedToExtent()
        blur.radius = Float(radius)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return perceptual }

        let mix = CIFilter.mix()
        mix.inputImage = blurred
        mix.backgroundImage = perceptual
        mix.amount = Float(-amount * amountSpan)
        return mix.outputImage?.cropped(to: extent) ?? perceptual
    }

    // MARK: - Noise Reduction

    /// Slider-to-`CINoiseReduction.noiseLevel` span, MEASURED at the
    /// filter's saturation onset: slider 1.0 → noiseLevel 0.15 drops a flat
    /// noisy patch to the ~23.8% residual floor (0.05781 → 0.01378) while a
    /// 0.2/0.5 step edge is preserved (softened over only ~4px). Beyond
    /// ~0.15 the filter saturates (noiseLevel 0.15 and 0.40 measure
    /// identical), so 0.15 is the useful maximum, not an arbitrary pick.
    /// NOTE: unlike Sharpen's radius there is deliberately NO
    /// `extent`-derived term here — noiseLevel is a per-pixel threshold and
    /// measured resolution-INDEPENDENT (near-identical residual std at
    /// 400/800/1600px, byte-identical edge ramps), which is correct
    /// because noise is inherently per-pixel, unlike Sharpen's frame-
    /// relative edge halo.
    private static let kNoiseReductionSpan: Double = 0.15

    private static func noiseReductionActive(_ state: EditState) -> Bool {
        state.noiseReduction != 0
    }

    /// Luminance noise reduction via `CINoiseReduction`, run just BEFORE
    /// Sharpen — the standard denoise-then-sharpen order (measured: NR
    /// first leaves less residual noise than the reverse, 0.01336 vs
    /// 0.01439 on a noisy edge). Applied in SCENE-LINEAR light, NOT the
    /// perceptual sandwich Sharpen uses: measured, linear denoises evenly
    /// across the tonal range (shadows/mids/highlights all ~24% residual)
    /// whereas a perceptual-domain pass under-denoises shadows (47%,
    /// because the sRGB encode lifts shadow noise above the threshold) —
    /// the opposite of Sharpen's domain choice, matching Vignette's.
    /// `inputSharpness` is PINNED to 0: the filter's own default (0.4) is a
    /// re-sharpen that ADDS noise back (measured flat-patch std 136% of
    /// baseline at that default), so this slider drives ONLY `noiseLevel`
    /// (= amount * `kNoiseReductionSpan`). Extent-preserving (measured
    /// exact, including on a cropped/offset extent), does NOT clamp
    /// highlight headroom (a noisy 1.4 flat survives at 1.39988), and
    /// preserves alpha (measured). Guarded off at amount 0 (exact no-op,
    /// measured max diff 0.0).
    private static func applyNoiseReduction(_ state: EditState, to image: CIImage) -> CIImage {
        guard noiseReductionActive(state) else { return image }

        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = Float(state.noiseReduction * kNoiseReductionSpan)
        filter.sharpness = 0
        return filter.outputImage ?? image
    }

    // MARK: - Sharpen

    /// Slider-to-`CISharpenLuminance.sharpness` span, MEASURED
    /// strong-but-graceful: slider 1.0 → sharpness 1.5 overshoots a
    /// 0.2/0.5 edge to 0.63963 and undershoots to 0.13242 (dark side stays
    /// positive; larger spans start driving grayscale edges toward
    /// clipping).
    private static let kSharpenAmountSpan: Double = 1.5

    /// Radius as a fraction of the CURRENT extent's MIN dimension —
    /// MEASURED necessity: the filter's radius is in absolute pixels
    /// (a fixed radius gives an identical pixel-halo on 400px vs 1600px
    /// images, peak 0.63963 both), so a fixed radius would look wildly
    /// different across resolutions. 0.0025 → 2.5px at a 1000px
    /// min-dimension (a conventional fine-detail radius); using
    /// `min(width,height)` makes portrait/landscape of equal pixel count
    /// sharpen identically. Mirrors vignette/perspective deriving geometry
    /// from `image.extent`.
    private static let kSharpenRadiusFraction: Double = 0.0025

    private static func sharpenActive(_ state: EditState) -> Bool {
        state.sharpness != 0
    }

    /// Detail/edge sharpening via `CISharpenLuminance` — after crop AND
    /// vignette, so it sharpens exactly the final framed, stylized pixels
    /// (resampling after sharpening would soften the halos; measured to
    /// commute with vignette to within 0.00100, below test tolerance, so
    /// ordering between those two specifically doesn't matter). No longer
    /// the pipeline's true final stage — Grain now runs after it (see
    /// `applyGrain`'s own doc comment for why: sharpening grain would
    /// amplify and halo it, silently turning this slider into a second
    /// Grain-intensity control). Applied in the PERCEPTUAL sRGB-gamma
    /// domain (measured more even edge response than scene-linear, and the
    /// conventional domain for unsharp masking), in its own encode/decode
    /// sandwich (self-contained; the encode/decode tone curves are exact
    /// inverses and do NOT clamp >1.0). `CISharpenLuminance` is measured
    /// NUMERICALLY IDENTICAL to `CIUnsharpMask` here and is NOT
    /// luminance-only in this working space (both fringe per-channel) —
    /// chosen only for its single `sharpness` param and exact sharpness=0
    /// no-op, not for any measured fringing benefit. Radius scales with
    /// `min(extent)` — see `kSharpenRadiusFraction`. Does NOT clamp
    /// highlight headroom (a 1.4 flat survives at 1.40238) and preserves
    /// alpha (measured). Guarded off at sharpness 0 (exact no-op,
    /// measured max diff 0.0).
    private static func applySharpen(_ state: EditState, to image: CIImage) -> CIImage {
        guard sharpenActive(state) else { return image }

        let extent = image.extent
        let radius = kSharpenRadiusFraction * Double(min(extent.width, extent.height))

        let encoded = encodeToPerceptual(image)
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = encoded
        filter.sharpness = Float(state.sharpness * kSharpenAmountSpan)
        filter.radius = Float(radius)
        let sharpened = filter.outputImage ?? encoded
        return decodeToLinear(sharpened)
    }

    // MARK: - Defringe (Chromatic Aberration)

    /// Patch radius for the local edge/contrast signal, as a fraction of
    /// `min(extent)` — the same resolution trap `kDehazeRadiusFraction`/
    /// `kSharpenRadiusFraction` already document (a fixed absolute-pixel
    /// radius would give a 24MP photo and its thumbnail different fringe
    /// estimates). PRINCIPLED STARTING CONSTANT (no UI existed yet to
    /// visually tune against when this shipped) — retune once checked
    /// against a real fringed photo, do not treat as settled.
    private static let kDefringeEdgeRadiusFraction: Double = 0.004

    /// Smoothstep gate on the local luma range (`localMax - localMin`):
    /// below `kDefringeEdgeThresholdLow` reads as flat content (ZERO
    /// desaturation regardless of amount — this is what structurally
    /// protects a genuinely purple/green flat subject, a real flower or
    /// lawn, from being touched), above `kDefringeEdgeThresholdHigh` reads
    /// as a full-strength edge. PRINCIPLED STARTING CONSTANTS, not measured.
    private static let kDefringeEdgeThresholdLow: Double = 0.05
    private static let kDefringeEdgeThresholdHigh: Double = 0.25

    /// Fixed hue centers (degrees, matching `rgb2hsl`'s own 0..<360 domain)
    /// for the two fringe colors Lightroom's own Defringe targets — violet/
    /// magenta for Purple, green for Green — plus the shared half-window
    /// width both bands use. FIXED, not user-positioned, matching
    /// `SelectiveColor.cikernel`'s own 8-fixed-band precedent (this is 2
    /// fixed bands, not a general color picker). PRINCIPLED STARTING
    /// CONSTANTS.
    private static let kDefringePurpleHueCenter: Double = 295
    private static let kDefringeGreenHueCenter: Double = 120
    private static let kDefringeHueWindow: Double = 40

    /// The tenth custom Core Image kernel in this codebase. Same lazy,
    /// bundled, fail-soft-to-`nil` load shape as `dehazeDarkChannelKernel`/
    /// `dehazeRecoverKernel` above.
    private static let defringeKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "Defringe", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    private static func defringeActive(_ state: EditState) -> Bool {
        state.defringePurple != 0 || state.defringeGreen != 0
    }

    /// Purple/Green fringe removal — Lightroom's own "Defringe" (see
    /// `EditState.defringePurple`'s own doc comment for why this app builds
    /// Defringe alone and deliberately not the OTHER, lens-profile-
    /// dependent chromatic-aberration mechanism). Core Image ships no
    /// defringe filter, so this is assembled the same TWO-PART way
    /// `applyDehaze` above is: a `CIColorKernel` cannot sample neighboring
    /// pixels, so the NEIGHBORHOOD half (a local edge/contrast signal) runs
    /// as built-in filters first, then one per-pixel kernel does the actual
    /// hue-selection + edge-gated desaturation.
    ///
    /// Runs AFTER Sharpen — a CONVENTION backed by a real but genuinely
    /// mixed measurement, NOT a requirement
    /// (`testSharpenBeforeDefringeIsAConventionNotARequirement`: a wider
    /// pixel sweep shows the reversed order actually leaves LESS residual
    /// chroma in aggregate on a real test fixture) — and BEFORE Grain, a
    /// real, MEASURED, unconditional requirement
    /// (`testDefringeMustRunBeforeGrainOrTheFlatGuardBreaks`: Grain's own
    /// high-frequency noise, if it ran first, would fool Defringe's edge
    /// gate into treating FLAT content as a real edge everywhere). See
    /// `EditState.defringePurple`'s own doc comment for the full story on
    /// both — they are NOT the same kind of claim, kept deliberately
    /// distinct here rather than bundled together the way an earlier draft
    /// of this comment wrongly did.
    ///
    /// Applied in the PERCEPTUAL sRGB-gamma
    /// domain — "what looks purple" is a display-referred hue judgment, matching
    /// `SelectiveColor`/`ColorGrading`/`PointColor`'s own domain, unlike
    /// `Dehaze`'s physically-modeled scene-linear one — in its OWN
    /// encode/decode sandwich (self-contained, matching `applySharpen`'s
    /// own precedent immediately above, NOT nested inside the early shared
    /// sandwich in `applyPerceptualAdjustments`).
    private static func applyDefringe(_ state: EditState, to image: CIImage) -> CIImage {
        guard defringeActive(state) else { return image }
        guard let kernel = defringeKernel else { return image }

        let encoded = encodeToPerceptual(image)
        let extent = encoded.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        let minDimension = Double(min(extent.width, extent.height))

        // Luma image — the EXACT construction `luminanceRangeMaskImage`
        // already uses, reused rather than reinvented.
        let lumaWeights = CIVector(
            x: LuminanceRangeSelection.lumaRed, y: LuminanceRangeSelection.lumaGreen,
            z: LuminanceRangeSelection.lumaBlue, w: 0
        )
        let luma = CIFilter.colorMatrix()
        luma.inputImage = encoded
        luma.rVector = lumaWeights
        luma.gVector = lumaWeights
        luma.bVector = lumaWeights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let lumaImageRaw = luma.outputImage else { return image }

        // `luma`'s own forced-opaque alpha bias (`biasVector.w = 1`, needed
        // so the morphology filters below stay premultiply-neutral) makes
        // Core Image report an INFINITE extent for `lumaImageRaw` — the
        // exact same hazard `luminanceRangeMaskImage`'s own doc comment
        // documents in detail (re-measure the ALPHA BIAS specifically, not
        // just whether `CIColorMatrix` is in the chain). Reviewer-caught:
        // `.clampedToExtent()` on an ALREADY-infinite image is a no-op, so
        // without this explicit `.cropped(to: extent)` FIRST, the
        // morphology filters below would read true zero just outside the
        // real frame, creating a spurious edge ring at the image border
        // (measured: a flat saturated color fully desaturated in a
        // radius-wide ring around every edge of the frame). Cropping to
        // `extent` first makes it finite, so `.clampedToExtent()` then
        // correctly edge-replicates the border pixels outward instead.
        let lumaImage = lumaImageRaw.cropped(to: extent)

        // Local max/min of luma over the patch — their difference is the
        // edge/contrast signal, near zero in flat regions, large at sharp
        // edges. Same `.clampedToExtent()` -> set radius -> `.cropped(to:)`
        // shape `applyDehaze`'s own `CIMorphologyMinimum` call uses (that
        // call clamps an already-finite kernel output, so its own clamp is
        // effective there; `lumaImage` needed the explicit crop above
        // first for the same clamp to do anything here).
        let radius = Float(kDefringeEdgeRadiusFraction * minDimension)
        let maxFilter = CIFilter.morphologyMaximum()
        maxFilter.inputImage = lumaImage.clampedToExtent()
        maxFilter.radius = radius
        guard let localMax = maxFilter.outputImage?.cropped(to: extent) else { return image }

        let minFilter = CIFilter.morphologyMinimum()
        minFilter.inputImage = lumaImage.clampedToExtent()
        minFilter.radius = radius
        guard let localMin = minFilter.outputImage?.cropped(to: extent) else { return image }

        let arguments: [Any] = [
            encoded, localMax, localMin,
            NSNumber(value: state.defringePurple),
            NSNumber(value: state.defringeGreen),
            NSNumber(value: kDefringeEdgeThresholdLow),
            NSNumber(value: kDefringeEdgeThresholdHigh),
            NSNumber(value: kDefringePurpleHueCenter),
            NSNumber(value: kDefringeGreenHueCenter),
            NSNumber(value: kDefringeHueWindow),
        ]
        guard let result = kernel.apply(extent: extent, arguments: arguments) else { return image }
        return decodeToLinear(result)
    }

    // MARK: - Grain

    private static let filmGrainKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "FilmGrain", withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }()

    /// The mean of `dot(n.rgb, vec3(1/3))` over `CIRandomGenerator`'s RAW
    /// output, sampled DIRECTLY by the kernel — MEASURED at 0.4994 over a
    /// 512x512 sample (a 0.12% deviation from the 0.5 a uniform-[0,1]
    /// distribution predicts, i.e. finite-sample noise, not a correction).
    /// Subtracted in the kernel so the noise field is zero-mean; a
    /// non-zero mean here would act as a hidden exposure shift wherever
    /// grain is active — confirmed by `testGrainPreservesMeanBrightness`.
    ///
    /// AN EARLIER VERSION OF THIS CONSTANT WAS WRONG (0.7439), caught by an
    /// adversarial reviewer re-measurement, not by this suite — worth
    /// recording exactly why, since the failure mode is subtle and could
    /// recur. That version routed the noise through `CIColorClamp` then
    /// `CIColorMatrix` (to force alpha to 1) before the kernel ever saw it.
    /// Both of those are members of Core Image's "color matrix" filter
    /// family, which — MEASURED, not documented anywhere found — treat
    /// their input as PREMULTIPLIED even though `CIRandomGenerator`'s r/g/b/a
    /// are independent per-channel randoms, not a true premultiplied
    /// quadruple. Routing through them performs an implicit unpremultiply/
    /// repremultiply round trip that reshapes the distribution: measured
    /// per-pixel output collapses to `min(r,a)/a` for each channel (r,a iid
    /// uniform 0...1) — mean 0.7439, with exactly 24.6% of pixels pinned at
    /// 1.0 (matching `∫(1-a)³da = 1/4`, the analytic probability all three
    /// of r/g/b independently exceed the SAME shared `a`). That distorted
    /// mean was then measured a SECOND time only at cell=1 (the 64px test
    /// fixture, where the bilinear resample of the later `.transformed`
    /// scale is a no-op) — real photos have `min(extent)` well above the
    /// 500px `cell > 1` threshold, where the bilinear resample shifted the
    /// mean further, to ~0.82. Net effect: mid-gray rendered at slider 1.0
    /// drifted to ~0.62 (~+0.31 EV) at real resolutions, not the documented
    /// +0.052 Jensen's-inequality artifact the 64px tests could see. FIXED
    /// by removing `CIColorClamp`/`CIColorMatrix` entirely — the kernel
    /// already reads `n.rgb` directly with no unpremultiply (verified: a
    /// passthrough kernel sampling the raw generator directly reproduces
    /// its true 0.4994 mean, undistorted) — and by forcing OPAQUE alpha
    /// via simply never reading `n.a` in the kernel, rather than by
    /// mutating the image. See `applyGrain`'s own doc comment for the
    /// `.samplingNearest()` fix this same investigation required.
    private static let kGrainZeroPoint: Double = 0.5

    /// Slider-to-kernel-amplitude span, MEASURED "strong but graceful" on a
    /// flat 64px 0.5-gray patch (1 identical to the raw kernel `amount`,
    /// the simplest possible correspondence): slider 0.5 -> std 0.09827,
    /// slider 1.0 -> std 0.19939, roughly linear in amount as expected.
    /// Across the tone range at slider 1.0 (see `EditPipelineTests`'
    /// `testGrainToneWeightAcrossRange`, 800px): shadows (0.05) -> std
    /// 0.05474, mids (0.214) -> std 0.16417, mids (0.5) -> std 0.20193,
    /// highlights (0.8) -> std 0.11419, near-white (0.95) -> std 0.03236.
    /// Headroom (1.4) -> exact mean-preserving identity (the tonal weight's
    /// clamp) is a separate assertion, in `testGrainPreservesHighlightHeadroom`
    /// (mean, not std, since a std-of-zero fixture can't distinguish "no
    /// grain" from "no test"). This is the measured shape of `w =
    /// 4*L*(1-L)`, not a separate claim — it peaks near mid-gray and
    /// vanishes at both tonal extremes, matching real film grain's
    /// visibility profile. These numbers reflect the CORRECTED noise
    /// construction (see `kGrainZeroPoint`'s doc comment) — re-measured
    /// after that fix.
    ///
    /// Currently a NO-OP multiplier (1.0) — kept as its own named constant
    /// anyway, matching every sibling span (`kSharpenAmountSpan`,
    /// `kNoiseReductionSpan`) that DOES rescale its slider, rather than
    /// writing `state.grain` directly into the kernel call. That keeps the
    /// call site uniform across every stage and gives a single place to
    /// change if "strong but graceful" is ever re-tuned, without implying
    /// 1.0 is somehow more measured or more final than any other value —
    /// it is exactly what direct correspondence between slider and kernel
    /// amplitude looks like, no more.
    private static let kGrainAmountSpan: Double = 1.0

    /// Noise cell size as a fraction of the CURRENT extent's MIN dimension —
    /// same mechanism as `kSharpenRadiusFraction`, for the same reason: a
    /// fixed pixel cell would make the interactive downscaled proxy show
    /// visibly larger grain than the settled full-res render (a flicker on
    /// every slider drag, unique to grain among this pipeline's stages,
    /// since grain is the only stage whose signal is visible at the pixel
    /// scale on flat content). MEASURED resolution behavior at slider 1.0,
    /// re-measured after the `kGrainZeroPoint` fix (see that constant's own
    /// doc comment — the ORIGINAL bilinear-sampled construction showed a
    /// much worse drift than this): 400px (cell 0.8px, floored to 1px) ->
    /// std 0.19946, 800px (cell 1.6px) -> std 0.20453, 1600px (cell 3.2px)
    /// -> std 0.21236 — genuinely stable (< 7% spread) across a 4x
    /// resolution range now that `.samplingNearest()` avoids the bilinear
    /// resample's own distortion.
    private static let kGrainCellFraction: Double = 0.002

    private static func grainActive(_ state: EditState) -> Bool {
        state.grain != 0
    }

    /// Film grain via a custom kernel (`FilmGrain.cikernel`) blending a
    /// `CIRandomGenerator` noise field, run as the pipeline's new TRUE FINAL
    /// stage — after Sharpen (see that stage's own updated doc comment) and
    /// after Noise Reduction. Both orderings are MEASURED requirements, not
    /// conventions (800px flat 0.5 gray patch, grain 0.5, region std over a
    /// 256px sample, temporary swap-rebuild-measure-revert, not assumed —
    /// re-measured after the `kGrainZeroPoint`/`.samplingNearest()` fixes,
    /// see that constant's own doc comment; the ordering conclusions did
    /// not change, only the exact figures):
    /// - grain-then-sharpen (sharpness 1.0) measured std 0.23888 vs. the
    ///   shipped sharpen-then-grain order's 0.09936 — sharpening AFTER grain
    ///   is added amplifies/haloes it ~2.4x, so grain must come after
    ///   Sharpen.
    /// - grain-then-NR (noiseReduction 1.0) measured std 0.06439 vs. the
    ///   shipped NR-then-grain order's 0.09936 — Noise Reduction silently
    ///   ate ~35% of the grain's std when grain ran before it, so grain
    ///   must come after Noise Reduction too.
    /// See `EditPipelineTests`' `testGrainSharpenOrderIsFixed`/
    /// `testGrainNoiseReductionOrderIsFixed` for these exact figures pinned
    /// as regression tests.
    ///
    /// Applied in the PERCEPTUAL sRGB-gamma domain (same domain as Sharpen,
    /// opposite of Noise Reduction/Vignette/Dehaze) — a PRINCIPLED choice,
    /// not a measured one (no scene-linear-vs-perceptual comparison was
    /// run, unlike Noise Reduction's own domain choice): grain is a print/
    /// density phenomenon, and a fixed-amplitude perturbation applied in
    /// LINEAR light would scale wrong relative to how a viewer perceives
    /// shadow/highlight detail. The measured tonal-weight response ACROSS
    /// the perceptual-domain range (see `kGrainAmountSpan`'s own doc
    /// comment) confirms the result behaves as intended — peaking near
    /// mid-gray, vanishing at both extremes — without that by itself
    /// proving the linear domain would behave worse.
    ///
    /// Adding zero-mean noise before a NONLINEAR encode/decode round trip
    /// is not perfectly mean-preserving — MEASURED, not assumed, at 800px
    /// (this drift is genuinely resolution-INDEPENDENT, unlike the
    /// pre-fix bug — see `kGrainZeroPoint`'s own doc comment — so a small
    /// fixture is not hiding anything here): at slider 1.0 the rendered
    /// mean drifts from the input by up to +0.031 (at linear 0.214;
    /// +0.021 at 0.5, +0.014 at 0.05, ~0 at 0.95). This is the expected
    /// signature of averaging a symmetric perturbation through a convex
    /// decode curve (Jensen's inequality), not a bug in the zero-centering
    /// — `testGrainPreservesMeanBrightness` pins a tolerance wide enough to
    /// accommodate it.
    ///
    /// `CIRandomGenerator`'s raw per-channel output IS genuinely bounded to
    /// 0...1 (MEASURED: min 0.0, max 1.0, mean 0.4994 over a 512x512
    /// sample) — do NOT route it through `CIColorClamp`/`CIColorMatrix`
    /// first, even though that looks like the obvious way to force the
    /// noise image opaque before the kernel. Both of those are Core
    /// Image's "color matrix" family and, MEASURED, treat their input as
    /// PREMULTIPLIED regardless of the actual data — `CIRandomGenerator`'s
    /// r/g/b/a are independent per-channel randoms, not a true
    /// premultiplied quadruple, so routing through them performs an
    /// unwanted implicit unpremultiply/repremultiply that reshapes the
    /// distribution into `min(channel,alpha)/alpha` (measured mean 0.7439,
    /// not 0.5) — see `kGrainZeroPoint`'s own doc comment for the full
    /// story of the bug this caused and how an adversarial re-review
    /// caught it. Instead, this stage never forces the noise opaque at
    /// all: the kernel simply never reads `n.a`, so the generator's
    /// independent random alpha is irrelevant, and `n.rgb` is sampled
    /// exactly as `CIRandomGenerator` produced it (MEASURED: a kernel that
    /// samples the raw generator directly reproduces its true 0.4994 mean,
    /// undistorted).
    ///
    /// `CIRandomGenerator`'s output has infinite extent, so the noise image
    /// is explicitly `.cropped(to: extent)` before reaching the kernel —
    /// the kernel's own `extent:` argument would clip the OUTPUT
    /// regardless, but cropping the input keeps the render graph honest.
    ///
    /// `.samplingNearest()` runs BEFORE the affine scale — MEASURED, not
    /// decoration, on the CURRENT (raw-generator, no clamp/matrix)
    /// construction: the default bilinear sampler leaves the noise's MEAN
    /// alone — measured within 0.006 of the true 0.4994 mean either way,
    /// across cell 1.0 -> 12.0, well inside ordinary sampling noise for
    /// these fixture sizes — the mean-drift bug documented in
    /// `kGrainZeroPoint`'s own doc comment was entirely a `CIColorClamp`/
    /// `CIColorMatrix` artifact, not a bilinear-resampling one. It DOES
    /// measurably shrink the STD once `cell`
    /// (see `kGrainCellFraction`) exceeds 1 pixel, i.e. on every real photo
    /// (`min(extent)` > 500px): bilinear std drops from 0.1674 at cell 1.0
    /// to ~0.111 for cell 1.2 and up (adjacent random samples get averaged
    /// together by the resample, which is a real amplitude loss, not just
    /// the "narrows toward Gaussian" shaping the kernel's own header
    /// comment already credits to channel-averaging). Nearest-neighbor
    /// holds std to within 0.006 of 0.1674 across the same cell range.
    ///
    /// Guarded off at grain 0 (exact identity) — NOT a cheap early-out: the
    /// perceptual encode/decode round-trip plus the kernel's own
    /// unpremultiply/repremultiply is not bit-exact in float32, the same
    /// reasoning `dehazeActive`'s gate documents for Dehaze.
    private static func applyGrain(_ state: EditState, to image: CIImage) -> CIImage {
        guard grainActive(state), let kernel = filmGrainKernel else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }

        let cell = max(1.0, kGrainCellFraction * Double(min(extent.width, extent.height)))
        guard let rawNoise = CIFilter.randomGenerator().outputImage else { return image }
        let noise = rawNoise
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .cropped(to: extent)

        let encoded = encodeToPerceptual(image)
        let amount = Float(state.grain * kGrainAmountSpan)
        let zeroPoint = Float(kGrainZeroPoint)
        let grained = kernel.apply(extent: extent, arguments: [encoded, noise, amount, zeroPoint]) ?? encoded
        return decodeToLinear(grained)
    }
}
