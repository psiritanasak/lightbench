import CoreGraphics

/// Pure, `CoreGraphics`-only validation/mapping for the `.colorRange` mask
/// kind (Phase 7 slice 5, second half) — the SELECTION-side sibling of
/// `LuminanceRangeSelection`, following the exact same contract: pure math
/// only (no CoreImage, no SwiftUI — `EditEngine` stays UI/rendering-API-
/// free), `resolve(...) -> Resolved?`, every clamp bound lives in a named
/// constant `MaskDetailView`'s sliders cite directly.
///
/// Unlike `.luminanceRange` (one tonal axis), `.colorRange` selects by
/// THREE jointly-matched axes — hue, saturation, and luminance — so a
/// darker/lighter or more/less saturated version of the picked color is
/// treated as progressively less similar, not just "the same hue family."
/// `ColorRange.cikernel` is this type's GPU-side twin: the two conversion
/// functions below (`hueSaturation(forLinearRGB:_:_:)`/
/// `luminance(forLinearRGB:_:_:)`) MUST agree with the kernel's own
/// per-pixel math bit-for-bit in intent (see each function's own doc
/// comment for the specific Swift/GLSL divergence traps already closed) —
/// if they disagree, the mask doesn't center on the picked color.
enum ColorRangeSelection {
    // MARK: - Tuning constants (not measurements — retune during live verification)

    static let minimumTolerance: Double = 0
    static let maximumTolerance: Double = 1

    /// Half-window-controlling bounds, in degrees, for the hue axis at
    /// `tolerance == 0`/`1` respectively.
    static let minimumHueWindowDegrees: Double = 5
    static let maximumHueWindowDegrees: Double = 90

    /// Same shape, for the saturation axis (0...1 HSL saturation units).
    static let minimumSaturationWindow: Double = 0.05
    static let maximumSaturationWindow: Double = 0.75

    /// Same shape, for the luminance axis — in the PERCEPTUAL tone domain
    /// (matching `luminanceTarget`'s own convention: 0.5 reads as
    /// photographic middle gray), even though the per-pixel comparison
    /// itself happens in scene-linear light — see `resolve`'s own doc
    /// comment for the tone→linear split this mirrors from
    /// `LuminanceRangeSelection`.
    static let minimumToneWindow: Double = 0.03
    static let maximumToneWindow: Double = 0.60

    /// Floor on the falloff ramp's width, in NORMALIZED-DISTANCE units —
    /// the space `ColorRange.cikernel`'s own division (`(1-d)/falloff`)
    /// actually happens in, the same "floor lives in the space the
    /// division happens in" lesson `LuminanceRangeSelection.minimumEdgeWidth`
    /// was reviewer-corrected on for its own floor.
    static let minimumFalloffWidth: Double = 0.001

    /// Resolved, ready-to-use parameters for one mask against one extent.
    struct Resolved: Equatable {
        /// Degrees, 0..<360.
        let targetHue: Double
        /// 0...1, scene-linear HSL saturation.
        let targetSaturation: Double
        /// Scene-linear Rec.709 luma — a MEASURED pixel value, may exceed
        /// 1 (headroom), unlike `LuminanceRangeSelection`'s tone-domain
        /// target.
        let targetLuminance: Double
        /// > 0.
        let hueWindowDegrees: Double
        /// > 0.
        let saturationWindow: Double
        /// > 0. The scene-linear luminance span BELOW `targetLuminance`
        /// the selection's luminance axis tolerates (asymmetric from
        /// `upperLuminanceSpan` — see `resolve`'s own doc comment).
        let lowerLuminanceSpan: Double
        /// > 0. The scene-linear luminance span ABOVE `targetLuminance`.
        let upperLuminanceSpan: Double
        /// > 0, normalized-distance units — `ColorRange.cikernel`'s own
        /// `falloff` argument.
        let falloffWidth: Double
        /// ALWAYS the full `extent` — like `.luminanceRange`, there is no
        /// ROI-crop win available: a pixel matching the target color can
        /// be anywhere in frame.
        let regionOfInterest: CGRect
    }

    /// - Parameters:
    ///   - hasTarget/targetHue/targetSaturation/targetLuminance/tolerance:
    ///     `Mask`'s own stored fields — see their own doc comments.
    ///   - feather: `Mask.feather`, reused a fourth time.
    ///
    /// Returns `nil` for a degenerate `extent`, non-finite input, or
    /// `hasTarget == false` (mirrors `BrushMaskGeometry`'s
    /// `guard !points.isEmpty` for an unpainted stroke — an un-picked
    /// `.colorRange` mask selects NOTHING, never an arbitrary default
    /// color) — NEVER for a narrow tolerance or `feather == 0`, both of
    /// which clamp instead.
    static func resolve(
        hasTarget: Bool, targetHue: Double, targetSaturation: Double, targetLuminance: Double,
        tolerance: Double, feather: Double, extent: CGRect
    ) -> Resolved? {
        // `CGRect.infinite`'s width/height are finite by IEEE semantics —
        // `.isInfinite`/`.isNull` are the correct checks, the same trap
        // every sibling geometry/selection type already documents.
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        guard hasTarget else { return nil }
        guard targetHue.isFinite, targetSaturation.isFinite, targetLuminance.isFinite,
              tolerance.isFinite, feather.isFinite
        else { return nil }

        var hue = targetHue.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let saturation = min(max(targetSaturation, 0), 1)
        let t = min(max(tolerance, minimumTolerance), maximumTolerance)
        let clampedFeather = min(max(feather, 0), 1)

        let hueWindow = minimumHueWindowDegrees + t * (maximumHueWindowDegrees - minimumHueWindowDegrees)
        let saturationWindow =
            minimumSaturationWindow + t * (maximumSaturationWindow - minimumSaturationWindow)
        let toneWindow = minimumToneWindow + t * (maximumToneWindow - minimumToneWindow)

        // Convert the symmetric TONE-domain window into two ASYMMETRIC
        // SCENE-LINEAR spans — the same tone-window/scene-linear-comparison
        // split `LuminanceRangeSelection.resolve` already established,
        // deliberate here too: a fixed tone-domain window centered on a
        // near-black target maps to a much narrower linear span than the
        // same window centered on a near-white target (the sRGB EOTF's own
        // slope), which is the physically sensible behavior for "how
        // different a luminance still looks similar."
        let targetTone = ColorRangeSelection.tone(forLinearLuminance: targetLuminance)
        let halfToneWindow = toneWindow / 2
        let lowerLuminance = LuminanceRangeSelection.linearLuminance(forTone: targetTone - halfToneWindow)
        let upperLuminance = LuminanceRangeSelection.linearLuminance(forTone: targetTone + halfToneWindow)
        let lowerSpan = max(targetLuminance - lowerLuminance, LuminanceRangeSelection.minimumEdgeWidth)
        let upperSpan = max(upperLuminance - targetLuminance, LuminanceRangeSelection.minimumEdgeWidth)

        let falloffWidth = max(clampedFeather, minimumFalloffWidth)

        return Resolved(
            targetHue: hue, targetSaturation: saturation, targetLuminance: targetLuminance,
            hueWindowDegrees: hueWindow, saturationWindow: saturationWindow,
            lowerLuminanceSpan: lowerSpan, upperLuminanceSpan: upperSpan,
            falloffWidth: falloffWidth, regionOfInterest: extent
        )
    }

    // MARK: - Conversion functions (Swift/GLSL twin pair)

    /// A floored modulo (`x - y * floor(x/y)`, always non-negative for a
    /// positive `y`), matching GLSL's `mod()` — Swift's own
    /// `truncatingRemainder` is SYMMETRIC (can return a negative result
    /// for a negative `x`), the single likeliest Swift/GLSL divergence
    /// point this whole type exists to close: without this correction,
    /// every magenta-side red pixel (where `(g - b)` is negative) would
    /// disagree between the two implementations.
    private static func flooredMod(_ x: Double, _ y: Double) -> Double {
        let remainder = x.truncatingRemainder(dividingBy: y)
        return remainder < 0 ? remainder + y : remainder
    }

    /// Swift twin of `ColorRange.cikernel`'s own per-pixel HSL conversion
    /// (and byte-identical in intent to `SelectiveColor.cikernel`'s
    /// `rgb2hsl`, the project's only prior per-pixel hue math). Two
    /// corrections over that older kernel, both load-bearing here:
    /// - Negative channels are clamped to 0 FIRST — `SelectiveColor
    ///   .cikernel` normalizes headroom but never clamps negatives, an
    ///   existing gap logged as a follow-up on that file (not touched
    ///   here, see IMPROVEMENTS.md).
    /// - Headroom-normalized (`scale = max(maxChannel, 1.0)`) before HSL
    ///   conversion — the exact fix `SelectiveColor.cikernel:84-104`
    ///   already shipped for a real bug: HSL's `1-|2L-1|` saturation
    ///   denominator goes negative for `L > 1`, silently making hue/sat
    ///   math a no-op on bright saturated regions.
    /// - The hue branch for the max-red case uses `flooredMod`, not a
    ///   plain division — see that helper's own doc comment.
    ///
    /// Reviewer-caught nuance, worth stating explicitly: headroom
    /// normalization makes this function scale-invariant only WITHIN a
    /// fixed headroom regime (`maxChannel < 1` throughout, or `>= 1`
    /// throughout) — a real color genuinely CROSSING that boundary (e.g. a
    /// mid-tone pixel pushed past 1.0 by an earlier Exposure mask) sees its
    /// measured SATURATION shift too, not just its luminance, since `scale
    /// = max(maxChannel, 1.0)` flips from a no-op to a real division right
    /// at that boundary. This is a genuine, if narrow, behavioral
    /// consequence for `.colorRange`'s own "reads `img`, not `image`"
    /// mask-compounding — an earlier mask that brightens a color past
    /// headroom can shift what a LATER `.colorRange` mask measures on more
    /// than just the luminance axis.
    static func hueSaturation(forLinearRGB r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double) {
        let cr = max(r, 0)
        let cg = max(g, 0)
        let cb = max(b, 0)
        let scale = max(max(cr, max(cg, cb)), 1.0)
        let nr = cr / scale
        let ng = cg / scale
        let nb = cb / scale

        let maxC = max(nr, max(ng, nb))
        let minC = min(nr, min(ng, nb))
        let chroma = maxC - minC
        guard chroma > 0 else { return (0, 0) }
        let lightness = 0.5 * (maxC + minC)
        let saturation = chroma / (1 - abs(2 * lightness - 1))

        var hue: Double
        if maxC == nr {
            hue = flooredMod((ng - nb) / chroma, 6)
        } else if maxC == ng {
            hue = (nb - nr) / chroma + 2
        } else {
            hue = (nr - ng) / chroma + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(max(saturation, 0), 1))
    }

    /// Rec.709 luma, reusing `LuminanceRangeSelection`'s own named weights
    /// so both content-derived mask kinds can never drift on what
    /// "luminance" means. Computed on the ORIGINAL (negative-clamped, but
    /// NOT headroom-normalized) channel values — luma is well-defined for
    /// headroom (unlike HSL's lightness, whose saturation denominator goes
    /// negative above 1), so unlike `hueSaturation` above, no `scale`
    /// division is applied here.
    static func luminance(forLinearRGB r: Double, _ g: Double, _ b: Double) -> Double {
        let cr = max(r, 0)
        let cg = max(g, 0)
        let cb = max(b, 0)
        return LuminanceRangeSelection.lumaRed * cr
            + LuminanceRangeSelection.lumaGreen * cg
            + LuminanceRangeSelection.lumaBlue * cb
    }

    /// Exact inverse of `LuminanceRangeSelection.linearLuminance(forTone:)`
    /// — the sRGB EOTF's own breakpoint is derived by calling that
    /// function itself (rather than a second hardcoded `0.0031308`
    /// constant), guaranteeing continuity/exact invertibility at the
    /// boundary rather than merely asserting it holds by construction.
    /// Deliberately unclamped on either side, mirroring
    /// `linearLuminance(forTone:)`'s own unclamped domain: a scene-linear
    /// luminance genuinely above 1 (headroom) must map to a tone above
    /// 1.0, not be silently clipped before this function ever sees it.
    static func tone(forLinearLuminance y: Double) -> Double {
        let breakpoint = LuminanceRangeSelection.linearLuminance(forTone: 0.04045)
        if y <= breakpoint {
            return y * 12.92
        }
        return 1.055 * pow(y, 1 / 2.4) - 0.055
    }

    // MARK: - Swatch-only helpers (never used by the mask's own selection math)

    /// HSL→RGB, Swift twin of `SelectiveColor.cikernel`'s `hsl2rgb`. Used by
    /// `displaySRGB` below to reconstruct a swatch color from the three
    /// stored scalars (never by `resolve`'s own selection math), and by
    /// `ColorGradingTint.rgbDelta` for Color Grading's wheel-to-tint
    /// conversion — both need a pure, CoreImage-free HSL→RGB reconstruction,
    /// so this stays the one implementation rather than a second copy.
    /// Expects `hue` already wrapped to 0..<360 — callers outside this file
    /// wrap first, the same way `displaySRGB` does just below.
    static func rgb(forHue hue: Double, saturation: Double, lightness: Double) -> (r: Double, g: Double, b: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue / 60
        let x = chroma * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - 0.5 * chroma
        let base: (Double, Double, Double)
        switch hp {
        case ..<1: base = (chroma, x, 0)
        case ..<2: base = (x, chroma, 0)
        case ..<3: base = (0, chroma, x)
        case ..<4: base = (0, x, chroma)
        case ..<5: base = (x, 0, chroma)
        default: base = (chroma, 0, x)
        }
        return (base.0 + m, base.1 + m, base.2 + m)
    }

    /// Reconstructs a DISPLAY-ready (sRGB-gamma-encoded, 0...1) swatch
    /// color from the three stored scalars (hue/saturation/scene-linear
    /// luminance) — never a 4th/5th/6th redundant stored RGB field that
    /// could drift from what the mask's own selection math uses.
    ///
    /// HSL's own "lightness" parameter is NOT the same quantity as Rec.709
    /// luma, so a naive `rgb(forHue:saturation:lightness: targetLuminance)`
    /// would read visibly darker than the tapped pixel for a saturated
    /// color (HSL lightness 0.5 is "half-way between black and white,"
    /// not "matches this luma"). Bisects HSL lightness (~24 iterations,
    /// well past `Double` precision needs for a display swatch) until the
    /// reconstructed color's OWN measured luma matches the target —
    /// monotonic in lightness for a fixed hue/saturation, so bisection
    /// converges reliably.
    ///
    /// Headroom clamps to 1 before the search (`targetY = min(luminance,
    /// 1)`) — this is a DISPLAY swatch, which has no way to show a color
    /// brighter than white; the stored `luminance` scalar itself stays
    /// unclamped (see `Mask.colorRangeTargetLuminance`'s own doc comment).
    ///
    /// Reviewer-caught: unlike `resolve` (which guards non-finite input and
    /// returns `nil`), this function had NO such guard and no hue wrap —
    /// a hand-edited/corrupt sidecar's `.nan`/huge stored scalar propagated
    /// straight through to a SwiftUI `Color`, and a stored hue outside
    /// 0..<360 (e.g. a negative value) fed `rgb(forHue:...)` unwrapped,
    /// producing a swatch inconsistent with the hue the kernel actually
    /// uses. Guarded here — the one caller in `MaskDetailView` needing an
    /// ADDITIONAL guard of its own, on the `Int` conversion of `tone(...)
    /// * 100` (a merely-finite-but-astronomically-large tone would still
    /// trap `Int(_:)`), not fixable at this layer alone.
    static func displaySRGB(hue: Double, saturation: Double, luminance: Double) -> (r: Double, g: Double, b: Double) {
        guard hue.isFinite, saturation.isFinite, luminance.isFinite else { return (0, 0, 0) }
        var wrappedHue = hue.truncatingRemainder(dividingBy: 360)
        if wrappedHue < 0 { wrappedHue += 360 }
        let hue = wrappedHue
        let saturation = min(max(saturation, 0), 1)
        let targetY = min(max(luminance, 0), 1)
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let candidate = rgb(forHue: hue, saturation: saturation, lightness: mid)
            let y = ColorRangeSelection.luminance(forLinearRGB: candidate.r, candidate.g, candidate.b)
            if y < targetY {
                lo = mid
            } else {
                hi = mid
            }
        }
        let linear = rgb(forHue: hue, saturation: saturation, lightness: (lo + hi) / 2)
        return (
            tone(forLinearLuminance: max(linear.r, 0)),
            tone(forLinearLuminance: max(linear.g, 0)),
            tone(forLinearLuminance: max(linear.b, 0))
        )
    }
}
