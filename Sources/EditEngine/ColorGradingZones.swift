import Foundation

/// How the Color Grading "Blending" and "Balance" sliders change the three tonal ranges `ColorGrading.cikernel` selects by
/// each pixel's perceptual luminance (anchors 0 / 0.5 / 1, raised-cosine falloff).
///
/// - **Blending** (-1...1, 0 = the original look) widens or narrows the falloff of ALL three ranges, so they overlap more or
///   less. At 0 the width is exactly `baseWidth` (0.4, measured in the original slice: a mid-grey pixel gets zero shadow and
///   zero highlight weight). Positive Blending doubles it at +1 (0.8); negative Blending narrows it only to `minWidth` (0.33,
///   a factor of 0.825 at -1): at 0.2 the ranges stop touching and tones between them get NO grade (ungraded stripes on a
///   smooth sky, reviewer-found), and even at 0.33 the combined weight dips to about 0.28 halfway between two ranges
///   (0.617 at the default width) — a weaker, but never absent, grade there.
/// - **Balance** (-1...1, 0 = centred) is the `shift` the kernel uses to move the MIDPOINT of the tonal scale while keeping
///   both ends fixed (see the kernel header): up to `maxShift` (±0.25). Positive Balance favours the Highlights range.
///
/// Both mappings return their identity value (`baseWidth` / 0) EXACTLY at 0 — by branching, not by a formula that merely
/// rounds to it. (The kernel's weight normalisation still moves a default render by 1-2 ulp; see ColorGrading.cikernel.) Out-of-range input (a
/// hand-edited sidecar) is clamped, like every other field the pipeline reads.
enum ColorGradingZones {
    /// The original fixed falloff width (perceptual luminance units).
    static let baseWidth: Double = 0.4
    /// The narrowest width Blending -1 reaches.
    static let minWidth: Double = 0.33
    /// The largest midpoint shift Balance applies at ±1.
    static let maxShift: Double = 0.25

    static func width(blending: Double) -> Double {
        let b = clamped(blending)
        if b == 0 { return baseWidth }
        // Narrowing is gentler (0.4 -> 0.33 at -1); widening doubles per unit.
        return b < 0 ? baseWidth * pow(minWidth / baseWidth, -b) : baseWidth * pow(2, b)
    }

    static func shift(balance: Double) -> Double {
        let b = clamped(balance)
        return b == 0 ? 0 : maxShift * b
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, -1), 1) : 0
    }
}
