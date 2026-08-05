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
/// Vignette runs AFTER crop: it's a radial darkening tied to the final
/// on-screen framing, so it must see the post-crop extent, not the
/// fixed-order list's pre-crop stages. Definition (local-contrast/Clarity)
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

        let extent = image.extent
        let radius = kDefinitionRadiusFraction * Double(min(extent.width, extent.height))

        let encoded = encodeToPerceptual(image)
        let filter = CIFilter.unsharpMask()
        filter.inputImage = encoded
        filter.radius = Float(radius)
        filter.intensity = Float(state.definition * kDefinitionAmountSpan)
        let adjusted = filter.outputImage ?? encoded
        return decodeToLinear(adjusted)
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
