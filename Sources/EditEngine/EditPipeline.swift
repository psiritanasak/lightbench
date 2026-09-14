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
/// exist there. Straighten, Perspective, and Flip are "transform/distort"
/// stages: pure geometry, run after the perceptual sandwich and BEFORE crop,
/// matching the fixed order — Straighten runs first, then Perspective, then
/// Flip (matching the Photos reference panel order; none of these commute
/// with each other in general, so this order is a real, tested requirement).
/// Red-Eye removal runs AFTER crop, BEFORE Vignette: like Vignette, its
/// stored normalized correction points must map against the CURRENT
/// (post-crop) extent, not the original frame. MEASURED to commute with
/// Vignette exactly (order between those two doesn't matter — confirmed at
/// both a frame-center and a frame-corner correction point, diff ≈ 0), but
/// it must run before Definition/Noise Reduction/Sharpen: those "detail"
/// stages should refine the ALREADY-corrected pupil, not reshape a red one
/// that then gets corrected differently. Vignette runs AFTER crop: it's a
/// radial darkening tied to the final on-screen framing, so it must see
/// the post-crop extent, not the fixed-order list's pre-crop stages.
/// Definition (local-contrast/Clarity)
/// runs AFTER Vignette: measured, it does NOT cleanly commute with
/// Vignette (unlike Sharpen) — its wide radius interacts with Vignette's
/// spatially-varying darkening, so this order is a real, measured
/// requirement, not arbitrary. Noise Reduction and Sharpen are a "detail"
/// pair at the pipeline's true end, after Definition, in the standard
/// denoise-then-sharpen order (measured: NR-first leaves less residual
/// noise than the reverse) — all three (Definition, NR, Sharpen) are
/// extent-preserving so none need to run before crop, and running them
/// last means they act on the actual final framed/stylized pixels, not
/// content that gets discarded (crop) or resampled (geometric stages)
/// afterward. Sharpen is the true FINAL stage: measured to commute with
/// Vignette (order between those two specifically doesn't matter), but
/// running dead last overall does, and it must come after Noise Reduction
/// or it would re-amplify noise NR would otherwise have removed.
enum EditPipeline {
    static func apply(_ state: EditState, to input: CIImage) -> CIImage {
        var image = input
        image = applyWhiteBalance(state, to: image)           // scene-linear, first
        image = applyExposure(state.exposureEV, to: image)    // scene-linear
        image = applyPerceptualAdjustments(state, to: image)  // sRGB-gamma domain
        image = applyStraighten(state, to: image)             // geometric, before perspective
        image = applyPerspective(state, to: image)            // geometric, before flip
        image = applyFlip(state, to: image)                   // geometric, before crop
        image = applyCrop(state, to: image)                   // geometric
        image = applyRedEye(state, to: image)                 // localized, scene-linear
        image = applyMasks(state, to: image)                  // local adjustments, own perceptual sandwich
        image = applyVignette(state, to: image)               // radial, scene-linear
        image = applyDefinition(state, to: image)             // local contrast, perceptual, before detail pair
        image = applyNoiseReduction(state, to: image)         // detail, scene-linear, before sharpen
        image = applySharpen(state, to: image)                // detail, perceptual, truly last
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
    /// long as no stage in between clamps it itself. `CIToneCurve` (used by
    /// `applyCurves` below, which now also implements Black Point) DOES clamp
    /// to [0,1] once active — see that method's comment; the headroom
    /// guarantee above is conditional on curves/black point being inactive.
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
    private static func applyPerceptualAdjustments(_ state: EditState, to image: CIImage) -> CIImage {
        let effective = effectiveTone(state)
        guard levelsActive(state)
            || state.brightness != 0
            || effective.contrast != 0
            || curvesActive(effective, state.blackPoint)
            || state.hslHue != 0
            || selectiveColorActive(state)
            || state.vibrance != 0
            || effective.saturation != 0
            || state.blackAndWhite
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
        if state.hslHue != 0 { img = applyHue(state.hslHue, to: img) }
        // Selective Color runs right after global Hue (bands target hues as
        // the user currently SEES them, post global rotation — the WYSIWYG
        // choice) and before Vibrance/Saturation (those "final uniform
        // scalers" then act on the per-band-adjusted result). MEASURED
        // non-commuting with global Hue — see testSelectiveColorRunsAfterGlobalHue.
        if selectiveColorActive(state) { img = applySelectiveColor(state, to: img) }
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
    ///   family (Brightness/HSL/Vibrance/Vignette/Sharpen/Definition/Noise
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
    /// highlight headroom (measured, unlike `applyCurves`).
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
    /// a 5-point `CIToneCurve` spline, and Black Point moves `point0` along
    /// its X (input) axis — reusing the same curve infrastructure rather
    /// than a separate stage. Axis verified empirically, not assumed: moving
    /// point0 on X produces the correct Levels-style "clip to black"
    /// behavior (measured: deep tones clip to 0, shadows darken/stretch).
    /// Rather than exposing a full interactive point-based curve editor
    /// (out of scope for this feature; see EditState's doc comments for the
    /// field-level rationale).
    ///
    /// KNOWN, MEASURED, DOCUMENTED LIMITATIONS:
    /// 1. `CIToneCurve` builds an internal LUT clamped to [0,1] the moment
    ///    it's non-identity, so any active curve/black-point adjustment
    ///    collapses linear values above 1.0 (e.g. highlight headroom created
    ///    by a prior exposure/brightness boost) to white. This includes
    ///    headroom contrast itself would otherwise have preserved (see
    ///    `applyPerceptualAdjustments`'s comment) — enabling curves changes
    ///    contrast's headroom guarantee. Accepted: it only affects
    ///    already-very-bright pixels, only when a curve is actively engaged,
    ///    and behaves like a defensible highlight-recovery clip rather than
    ///    a visible artifact.
    /// 2. `CIToneCurve` extrapolates (does not hard-clamp) inputs just below
    ///    point0.x, producing a mild deep-shadow spline OVERSHOOT on Black
    ///    Point's crush side (measured: point0=(0.20,0), a very dark input
    ///    lifts slightly instead of stepping straight to 0). Net effect is a
    ///    "soft" black point, not a razor clip.
    /// A custom Metal kernel with linear extrapolation beyond x=1 (anticipated
    /// by CLAUDE.md's Stack note: "custom kernels for curves, HSL, WB") would
    /// remove both limitations and is explicitly deferred as future work.
    private static func applyCurves(_ effective: EffectiveTone, _ blackPoint: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: max(0, -blackPoint) * kBlackPointSpan, y: max(0, blackPoint) * kBlackPointSpan)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 + effective.shadows * kCurvePointSpan)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 + effective.highlights * kCurvePointSpan)
        filter.point4 = CGPoint(x: 1, y: 1)
        return filter.outputImage ?? image
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
    /// Definition (a fixed pixel radius would cover a wildly different
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
    /// placement BEFORE Definition/Noise Reduction/Sharpen is a real
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
    /// reasoning for why Red-Eye precedes Definition/Noise Reduction/
    /// Sharpen). Placed before Vignette/Definition/Noise Reduction/Sharpen
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
    /// measured-adjacency convention for Red-Eye/Vignette and Definition/
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
    /// `EditState.definition`'s own doc comment already records that
    /// filter as measured to be an ASYMMETRIC tone-mapper, rejected for
    /// exactly this reason). `unsharpDefinition` (Clarity) is the ONE
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
            // documented guarantee. Clarity needs no clamp — global
            // `definition` is unclamped too (one-directional, see
            // `EditState.definition`'s doc comment), so this is
            // precedent-consistent, not an oversight.
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
                    perceptual = unsharpDefinition(mask.clarity, to: perceptual)
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
            // selection would see).
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
                    // `CIBlendWithMask` a null/empty crop rect below.
                    guard !region.isNull, !region.isEmpty else { continue }
                    let meet = CIFilter.minimumCompositing()
                    meet.inputImage = maskImage
                    meet.backgroundImage = operandMask.image
                    maskImage = (meet.outputImage ?? maskImage).cropped(to: extent)
                    correctedRegion = region
                case .subtract:
                    // The operand selects nothing -> M ∧ ¬0 = M -> this
                    // mask is completely UNAFFECTED, not skipped.
                    guard let operandMask else { break }
                    guard let inverted = invertedMaskImage(operandMask.image, extent: extent) else { break }
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
    /// `EditPipelineTests`' own
    /// `testSubtractInversionDoesNotTintTheMaskEdges`, which samples
    /// INSIDE the falloff band specifically because that's where this
    /// class of bug hides).
    ///
    /// Extent: MEASURED finite for two finite inputs (opaque white is
    /// already extent-bounded by its own `.cropped(to: extent)` below;
    /// the operand's own mask image is already finite by the time it
    /// reaches here) — unlike `luminanceRangeMaskImage`'s own forced-
    /// opaque-alpha-bias trap, Porter-Duff Source-Out never introduces an
    /// unbounded bias term, so this function's own `.cropped(to: extent)`
    /// is structural consistency, not load-bearing — still kept, matching
    /// every other per-kind mask-image builder in this file.
    private static func invertedMaskImage(_ maskImage: CIImage, extent: CGRect) -> CIImage? {
        let opaqueWhite = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
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
    /// `applyCurves`'s own doc comment already records two disqualifying
    /// facts about that filter — it EXTRAPOLATES past its endpoints
    /// rather than clamping (which would leak spurious selection outside
    /// the tone window), and its LUT is built clamped to `0...1` the
    /// instant it's non-identity (which would collapse every HEADROOM
    /// pixel — linear > 1, genuinely present in this pipeline — into one
    /// bucket, making "target the brightest tones" unable to distinguish
    /// them). The two-ramp form below has neither problem: it is
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

    // MARK: - Definition (Clarity)

    /// Slider-to-`CIUnsharpMask.intensity` span, MEASURED to give comparable
    /// PEAK punch to Sharpen's own full strength (0.66061 vs Sharpen's
    /// 0.63963 on the same 0.2/0.5 edge) but spread over a far wider band —
    /// still 0.50955 elevated 60px from the edge, where Sharpen has already
    /// decayed to baseline. That width, not the peak, is what makes this
    /// local CONTRAST rather than fine sharpening.
    private static let kDefinitionAmountSpan: Double = 0.8

    /// Radius as a fraction of the CURRENT extent's MIN dimension — MEASURED
    /// necessity, same as Sharpen's `kSharpenRadiusFraction`: the filter's
    /// radius is in absolute pixels (a fixed radius gives byte-identical
    /// halos regardless of image size), so it must scale with resolution.
    /// 16x Sharpen's own 0.0025 fraction — local contrast needs a far wider
    /// reach than fine-detail sharpening; a smaller fraction reads as more
    /// sharpening, a much larger one starts reading as a global contrast
    /// boost rather than "local" (measured at a 0.02...0.08 sweep).
    private static let kDefinitionRadiusFraction: Double = 0.04

    private static func definitionActive(_ state: EditState) -> Bool {
        state.definition != 0
    }

    /// Local-contrast ("Definition"/"Clarity") via a LARGE-radius, low-
    /// amount `CIUnsharpMask` — the SAME filter Sharpen uses (already
    /// measured numerically identical to `CISharpenLuminance` there), here
    /// at a much larger radius. Runs AFTER Vignette, BEFORE the Noise
    /// Reduction + Sharpen detail pair: post-crop/post-geometry so its
    /// absolute-pixel radius tracks the final frame and nothing resamples
    /// its work; leads the detail region as its coarsest member so Noise
    /// Reduction then cleans up any noise it amplifies and Sharpen stays
    /// truly last. MEASURED: does NOT cleanly commute with Vignette (unlike
    /// Sharpen) — corner differences up to 0.0188 between orderings, so
    /// running AFTER Vignette is a real requirement, not an arbitrary
    /// choice. Applied in the PERCEPTUAL sRGB-gamma domain, in its own
    /// encode/decode sandwich, matching Sharpen — though MEASURED, domain
    /// barely mattered here (~1% relative difference between perceptual and
    /// scene-linear lift across shadow/mid/highlight test edges), unlike
    /// Sharpen (~5%) or Noise Reduction (~2x); perceptual is chosen for
    /// consistency with the sandwich pattern, not because it measurably
    /// wins here. Radius scales with `min(extent)` — see
    /// `kDefinitionRadiusFraction`. Does NOT clamp highlight headroom (a 1.4
    /// flat survives at 1.40127) and preserves alpha and extent exactly
    /// (measured). Guarded off at amount 0 (exact no-op, measured max diff
    /// 0.0). One-directional (0...1), NOT bipolar: `CIUnsharpMask` was
    /// measured to silently clamp negative `intensity` to a no-op in this
    /// working space (a dead half of a would-be bipolar slider range) — see
    /// `EditState.definition`'s doc comment for the measurement.
    private static func applyDefinition(_ state: EditState, to image: CIImage) -> CIImage {
        guard definitionActive(state) else { return image }
        return decodeToLinear(unsharpDefinition(state.definition, to: encodeToPerceptual(image)))
    }

    /// The unsharp construction itself, factored out of `applyDefinition` so
    /// Phase 7 slice 2's per-mask Clarity can reuse the EXACT same filter
    /// technique — a mask's Clarity at value X is numerically identical to
    /// this global Definition slider at value X, same `kDefinitionAmountSpan`/
    /// `kDefinitionRadiusFraction`. Operates on ALREADY-PERCEPTUAL input —
    /// the caller owns the encode/decode sandwich (`applyDefinition` opens
    /// its own; `applyMasks` folds this into the one sandwich it already
    /// opens for Contrast/Curves/Saturation, avoiding a second round trip
    /// per mask). Radius is derived from `extent`, so the caller must pass
    /// the FULL, untouched image — never a subimage cropped to some
    /// region's bounding box — or the radius silently comes out wrong (see
    /// `applyMasks`'s own doc comment on this exact hazard).
    private static func unsharpDefinition(_ amount: Double, to perceptual: CIImage) -> CIImage {
        let extent = perceptual.extent
        let radius = kDefinitionRadiusFraction * Double(min(extent.width, extent.height))

        let filter = CIFilter.unsharpMask()
        filter.inputImage = perceptual
        filter.radius = Float(radius)
        filter.intensity = Float(amount * kDefinitionAmountSpan)
        return filter.outputImage ?? perceptual
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

    /// Detail/edge sharpening via `CISharpenLuminance`, the pipeline's
    /// TRUE FINAL stage — after crop AND vignette, so it sharpens exactly
    /// the final framed, stylized pixels (resampling after sharpening
    /// would soften the halos; measured to commute with vignette to
    /// within 0.00100, below test tolerance, so ordering between those two
    /// specifically doesn't matter). Applied in the PERCEPTUAL sRGB-gamma
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
}
