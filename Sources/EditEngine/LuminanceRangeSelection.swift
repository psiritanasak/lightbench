import CoreGraphics

/// Pure, `CoreGraphics`-only validation/mapping for the `.luminanceRange`
/// mask kind (Phase 7 slice 5) — the SELECTION-side sibling of
/// `RadialMaskGeometry`/`LinearMaskGeometry`/`BrushMaskGeometry`, but
/// deliberately named "Selection" rather than "…Geometry": this kind has
/// no shape at all. It selects pixels by their own TONE, not by position,
/// so there is no anchor point, no transform, no rect to resolve — only
/// four clamped scalar thresholds `EditPipeline.applyMasks`'s `.luminanceRange`
/// branch turns into a per-pixel tent via built-in Core Image filters.
///
/// Follows the same contract every sibling type already establishes: pure
/// math only (no CoreImage, no SwiftUI — `EditEngine` stays UI/rendering-
/// API-free), `resolve(...) -> Resolved?`, `nil` only for genuinely
/// degenerate input (never for a narrow/zero-feather window — that's a
/// legitimate, deliberate precise selection, matching `LinearMaskGeometry`'s
/// clamp-don't-skip contract for its own `width`), and every clamp bound
/// lives in a named constant `MaskDetailView`'s sliders cite directly.
enum LuminanceRangeSelection {
    /// `luminanceTarget` clamp bounds, in PERCEPTUAL tone units (0 = black,
    /// 1 = white, matching what the slider shows the user).
    static let minimumTarget: Double = 0
    static let maximumTarget: Double = 1

    /// `luminanceRange` (the FULL tone-window width) clamp bounds, same
    /// perceptual units. Mirrors `LinearMaskGeometry.minimumWidth`'s role:
    /// a very narrow window CLAMPS rather than making `resolve` return
    /// `nil` — a precise tonal selection is a real, deliberate use, not a
    /// degenerate one.
    static let minimumRange: Double = 0.01
    static let maximumRange: Double = 1.0

    /// Floor on each falloff edge's width, in SCENE-LINEAR luminance —
    /// deliberately in linear space, not tone space, because that's the
    /// domain `EditPipeline.applyMasks`'s ramp slope
    /// (`1 / (fullAt - zeroAt)`) actually divides in. At `feather == 0`
    /// (a legitimate hard tone edge — see `Mask.feather`'s own doc
    /// comment), the tone-space edge width collapses to exactly zero
    /// before this floor is applied, which would otherwise divide by
    /// zero; this floor keeps the rendered edge the steepest one
    /// expressible instead of undefined. Living in the SAME space the
    /// division happens in — not a second, upstream copy — is the exact
    /// lesson `LinearMaskGeometry.widthInPixels` was reviewer-corrected on
    /// for its own floor.
    ///
    /// Reviewer-flagged: this floor is correctly placed in the LINEAR
    /// space the division happens in, but it is NOT perceptually uniform
    /// across the tone range as a result — the sRGB EOTF's slope varies
    /// with tone, so the same linear floor maps back to a very different
    /// TONE width depending on where the edge sits. Near black (the
    /// EOTF's linear branch, slope `1/12.92`), `0.0001` linear is
    /// `≈0.0013` tone — a visible fraction of `minimumRange`'s own
    /// tone-space floor. Near white, the same linear floor is
    /// `≈0.00004` tone — negligible. A hard edge (`feather == 0`)
    /// targeting a dark tone will therefore render measurably softer
    /// than one targeting a bright tone, at the same nominal settings.
    /// Accepted: still the correct space for the floor to live in (it
    /// exists to keep a DIVISION finite, not to guarantee a constant
    /// on-screen edge width), just worth knowing before assuming a
    /// "hard edge" looks equally hard everywhere.
    static let minimumEdgeWidth: Double = 0.0001

    /// Rec.709 relative-luminance weights. Correct for LINEAR light
    /// specifically — the widely-copied 0.299/0.587/0.114 set is Rec.601
    /// and is meant for gamma-ENCODED values. `EditPipeline.applyMasks`
    /// runs in scene-linear, so these are the weights that actually apply.
    static let lumaRed: Double = 0.2126
    static let lumaGreen: Double = 0.7152
    static let lumaBlue: Double = 0.0722

    /// Resolved, ready-to-use thresholds for one mask against one extent,
    /// all in SCENE-LINEAR luminance.
    struct Resolved: Equatable {
        /// Selection reaches 0 on the dark side.
        let lowerZero: Double
        /// Selection first reaches 1 (the plateau's dark end).
        /// Guaranteed `lowerZero < lowerFull` (see `minimumEdgeWidth`).
        let lowerFull: Double
        /// Selection last holds 1 (the plateau's bright end).
        /// Guaranteed `lowerFull <= upperFull`.
        let upperFull: Double
        /// Selection falls back to 0 on the bright side. May exceed 1.0 —
        /// see `linearLuminance(forTone:)` on why that's deliberate (real
        /// HEADROOM pixels, linear > 1, exist in this pipeline and a
        /// target near white should be able to reach them). Guaranteed
        /// `upperFull < upperZero`.
        let upperZero: Double
        /// ALWAYS the full `extent` — unlike every other mask kind, there
        /// is no ROI-crop win available here: a pixel matching the target
        /// tone can be anywhere in frame, so the per-mask adjustment must
        /// be produced everywhere before compositing. Kept as an explicit
        /// field (rather than callers just using `extent` directly) so
        /// all four `ResolvedMaskGeometry` arms in `EditPipeline` stay
        /// structurally identical, and so this deliberate, accepted cost
        /// is documented in exactly one place.
        let regionOfInterest: CGRect
    }

    /// - Parameters:
    ///   - luminanceTarget/luminanceRange: `Mask`'s own stored fields, in
    ///     PERCEPTUAL tone units — see their own doc comments.
    ///   - feather: `Mask.feather`, REUSED from `.radial`/`.brush` — see
    ///     that field's own doc comment for the shared formula shape.
    ///
    /// Returns `nil` only for a degenerate `extent` or non-finite input —
    /// NEVER for a narrow window or `feather == 0`, both of which clamp
    /// instead (see `minimumRange`/`minimumEdgeWidth`).
    static func resolve(
        luminanceTarget: Double, luminanceRange: Double, feather: Double, extent: CGRect
    ) -> Resolved? {
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — finite by IEEE semantics — so `.isFinite` alone would NOT catch
        // it; `.isInfinite`/`.isNull` are the correct checks, the same trap
        // every sibling geometry type already documents.
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        guard luminanceTarget.isFinite, luminanceRange.isFinite, feather.isFinite else { return nil }

        let target = min(max(luminanceTarget, minimumTarget), maximumTarget)
        let range = min(max(luminanceRange, minimumRange), maximumRange)
        let clampedFeather = min(max(feather, 0), 1)

        let outerHalf = range / 2
        let innerHalf = outerHalf * (1 - clampedFeather)

        var lowerZero = linearLuminance(forTone: target - outerHalf)
        let lowerFull = linearLuminance(forTone: target - innerHalf)
        let upperFull = linearLuminance(forTone: target + innerHalf)
        var upperZero = linearLuminance(forTone: target + outerHalf)

        // `linearLuminance` is monotonically increasing, so the tone
        // ordering `lowerZeroTone <= lowerFullTone <= upperFullTone <=
        // upperZeroTone` is preserved after mapping — the two `<=` can
        // collapse to `==` at `feather == 0` (a legitimate hard edge,
        // zero-width in TONE space), which is exactly what the floor
        // below exists to widen back out in LINEAR space, where the
        // render's ramp slope actually divides by this width.
        if lowerFull - lowerZero < minimumEdgeWidth {
            lowerZero = lowerFull - minimumEdgeWidth
        }
        if upperZero - upperFull < minimumEdgeWidth {
            upperZero = upperFull + minimumEdgeWidth
        }

        return Resolved(
            lowerZero: lowerZero, lowerFull: lowerFull, upperFull: upperFull, upperZero: upperZero,
            regionOfInterest: extent
        )
    }

    /// Scene-linear luminance for a perceptual tone position — the SCALAR
    /// twin of the sRGB decoding transfer function `EditPipeline`'s own
    /// `decodeToLinear` already applies per-pixel (same curve, applied to
    /// one number on the CPU here instead of to every pixel on the GPU
    /// there). Exact bit-equality with that filter is NOT claimed or
    /// required — this maps a SLIDER value, it never round-trips image
    /// data.
    ///
    /// Deliberately NOT clamped to `0...1`, on either side:
    /// - The power branch (`tone > 0.04045`) is monotonically increasing
    ///   for `tone > 1` too, so a target of exactly 1.0 still produces an
    ///   `upperZero` genuinely above 1.0 — reachable HEADROOM (this
    ///   pipeline really does carry linear values > 1 past this point;
    ///   `applyExposure` runs upstream). Clamping here would make "target
    ///   the brightest tones" unable to select headroom at all.
    /// - The linear branch (`tone <= 0.04045`) extends naturally to
    ///   negative `tone`, so a target of exactly 0 still has a real,
    ///   non-collapsed falloff below it instead of a degenerate one-sided
    ///   edge.
    static func linearLuminance(forTone tone: Double) -> Double {
        if tone <= 0.04045 {
            return tone / 12.92
        }
        return pow((tone + 0.055) / 1.055, 2.4)
    }
}
