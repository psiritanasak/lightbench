import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies an `EditState` to a `CIImage`.
///
/// The edit pipeline order is fixed (see CLAUDE.md):
/// decode → WB → exposure → contrast → curves → HSL → crop → output transform.
/// Decode already happened before this point (the caller loads the file);
/// output transform (display color space conversion) happens at render time,
/// outside this type. Every stage of the fixed order now exists: WB,
/// exposure, contrast, curves, HSL, and crop.
enum EditPipeline {
    static func apply(_ state: EditState, to input: CIImage) -> CIImage {
        var image = input
        image = applyWhiteBalance(state, to: image)           // scene-linear, first
        image = applyExposure(state.exposureEV, to: image)    // scene-linear
        image = applyPerceptualAdjustments(state, to: image)  // sRGB-gamma domain
        image = applyCrop(state, to: image)                   // geometric, last
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

        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: kNeutralTemp, y: 0)
        filter.targetNeutral = CIVector(
            x: 2 * kNeutralTemp - state.whiteBalanceTemperature,
            y: -(state.whiteBalanceTint / 100) * kTintSpan
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

    // MARK: - Perceptual domain (contrast, curves, HSL)

    /// Contrast, curves, and HSL are applied in the sRGB gamma-encoded
    /// (perceptual / display-referred) domain, not scene-linear light. This
    /// is a DOCUMENTED DEVIATION from CLAUDE.md's default "all image math in
    /// linear light" rule (which CLAUDE.md itself permits when documented).
    /// Rationale, verified empirically against Core Image's real behavior in
    /// this app's working space: a linear-light pivot of 0.5 sits at ~0.735
    /// perceptual brightness, so a linear-domain contrast pivot crushes
    /// photographic middle gray (linear ≈0.214) toward black — wrong, and
    /// unlike every real photo editor. Encoding to sRGB gamma first puts the
    /// pivot at perceptual middle gray instead. The encode/decode tone-curve
    /// filters (`encodeToPerceptual`/`decodeToLinear`) are exact inverses of
    /// each other and do NOT clamp values above 1.0, so highlight headroom
    /// created by exposure (which runs before this step) survives the
    /// round-trip back to linear — as long as no stage in between clamps it
    /// itself. `CIToneCurve` (used by `applyCurves` below) DOES clamp to
    /// [0,1] once active — see that method's comment; the headroom guarantee
    /// above is conditional on curves being inactive. HSL's filters
    /// (`CIHueAdjust`, `CIColorControls.saturation`), by contrast, do NOT
    /// clamp — measured: saturation +1 on a 1.4 linear channel reads back as
    /// 2.57770, not 1.0. Don't assume one adjustment's clamp behavior
    /// carries to another; each was verified independently.
    ///
    /// Order inside the sandwich matters and is NOT arbitrary: contrast runs
    /// before curves because the two do not commute (measured — the same
    /// inputs give different results depending on order), and HSL runs after
    /// curves for the same reason (measured non-commuting case). This
    /// matches the fixed pipeline (…→contrast→curves→HSL→…). Within HSL,
    /// hue and saturation ALSO do not commute in general — they only agree
    /// to within this project's 0.002 test tolerance at modest slider
    /// values; at wider (still in-range) settings they diverge measurably
    /// (e.g. hue -90°/saturation +1 on a saturated red gives (0.42335,
    /// 0.18309, 1.09968) hue-first vs (0.42582, 0.18283, 1.10397)
    /// saturation-first — a 0.0043 gap). hue-then-saturation is therefore a
    /// real, fixed requirement, not a discretionary clarity choice — see
    /// `testHueSaturationOrderIsFixed`.
    private static func applyPerceptualAdjustments(_ state: EditState, to image: CIImage) -> CIImage {
        guard state.contrast != 0 || curvesActive(state) || hslActive(state) else { return image }

        var img = encodeToPerceptual(image)
        if state.contrast != 0 { img = applyContrast(state.contrast, to: img) }
        if curvesActive(state) { img = applyCurves(state, to: img) }
        if hslActive(state) {
            if state.hslHue != 0 { img = applyHue(state.hslHue, to: img) }
            if state.hslSaturation != 0 { img = applySaturation(state.hslSaturation, to: img) }
        }
        img = decodeToLinear(img)
        return img
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

    // MARK: - Curves

    /// Slider-to-control-point span, measured to give a strong-but-monotone
    /// curve across the full -1...1 slider range.
    private static let kCurvePointSpan: Double = 0.15

    private static func curvesActive(_ state: EditState) -> Bool {
        state.curvesShadows != 0 || state.curvesHighlights != 0
    }

    /// A simplified, Lightroom-Basic-panel-style parametric tone curve: two
    /// sliders (Shadows, Highlights) each move one control point of a
    /// 5-point `CIToneCurve` spline, rather than exposing a full interactive
    /// point-based curve editor (out of scope for this feature; see
    /// EditState's doc comments for the field-level rationale).
    ///
    /// KNOWN, MEASURED, DOCUMENTED LIMITATION: `CIToneCurve` builds an
    /// internal LUT clamped to [0,1] the moment it's non-identity, so any
    /// active curve adjustment collapses linear values above 1.0 (e.g.
    /// highlight headroom created by a prior exposure boost) to white. This
    /// includes headroom contrast itself would otherwise have preserved (see
    /// `applyPerceptualAdjustments`'s comment) — enabling curves changes
    /// contrast's headroom guarantee. Accepted for this feature: it only
    /// affects already-very-bright pixels, only when a curve is actively
    /// engaged, and behaves like a defensible highlight-recovery clip rather
    /// than a visible artifact. A custom Metal kernel with linear
    /// extrapolation beyond x=1 (anticipated by CLAUDE.md's Stack note:
    /// "custom kernels for curves, HSL, WB") would remove this limitation
    /// and is explicitly deferred as future work, not built now.
    private static func applyCurves(_ state: EditState, to image: CIImage) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: 0)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 + state.curvesShadows * kCurvePointSpan)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 + state.curvesHighlights * kCurvePointSpan)
        filter.point4 = CGPoint(x: 1, y: 1)
        return filter.outputImage ?? image
    }

    // MARK: - HSL (global hue & saturation)

    private static func hslActive(_ state: EditState) -> Bool {
        state.hslHue != 0 || state.hslSaturation != 0
    }

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
}
