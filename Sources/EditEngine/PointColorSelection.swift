import Foundation

/// Swift-side twin of `PointColor.cikernel`'s own `rgb2hsl` + headroom-
/// normalize, for the eyedropper: it has to compute hue/saturation the
/// EXACT SAME WAY the kernel does, on the exact same domain, or a validly-
/// picked color could land outside its own instance's narrow selection
/// window (`PointColorTuning`'s saturation window is 0.05...0.5).
///
/// Deliberately NOT `ColorRangeSelection.hueSaturation(forLinearRGB:)`:
/// that function operates on SCENE-LINEAR RGB and clamps negative channels
/// to 0 first (a correction `ColorRange.cikernel` needed but `PointColor
/// .cikernel` does not apply). `PointColor.cikernel` runs inside the
/// PERCEPTUAL sandwich and headroom-normalizes WITHOUT a negative clamp —
/// see that kernel's own `rgb2hsl`/header comment. Mirroring
/// `ColorRangeSelection`'s version here would silently diverge from what
/// the kernel actually computes at the picked pixel.
enum PointColorSelection {
    /// Matches GLSL's `mod()` (always non-negative for positive `y`),
    /// unlike Swift's `truncatingRemainder` — the same divergence point
    /// `ColorRangeSelection.flooredMod` exists to close, needed here for
    /// the same max-red hue branch.
    private static func flooredMod(_ x: Double, _ y: Double) -> Double {
        let remainder = x.truncatingRemainder(dividingBy: y)
        return remainder < 0 ? remainder + y : remainder
    }

    /// Exact Swift mirror of `PointColor.cikernel`'s headroom-normalize +
    /// `rgb2hsl`, given an already-unpremultiplied perceptual (sRGB-gamma-
    /// encoded) sample — the same domain `EditPipeline.apply(_:to:
    /// truncatingColorAt:)` leaves the image in for a `.pointColor` request.
    /// No negative-channel clamp, matching the kernel; a caller feeding in
    /// a genuinely negative channel (e.g. sampling error) gets whatever the
    /// kernel itself would compute, not a silently "corrected" answer.
    static func hueSaturation(forPerceptualRGB r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double) {
        let maxChannel = max(r, max(g, b))
        let scale = max(maxChannel, 1.0)
        let nr = r / scale
        let ng = g / scale
        let nb = b / scale

        let maxC = max(nr, max(ng, nb))
        let minC = min(nr, min(ng, nb))
        let chroma = maxC - minC
        let lightness = 0.5 * (maxC + minC)
        guard chroma != 0 else { return (0, 0) }
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
        return (hue, saturation)
    }

    /// Reconstructs a DISPLAY-ready swatch (sRGB, 0...1) from a picked
    /// instance's own stored `targetHue`/`targetSaturation` — never a
    /// redundant stored RGB field. Unlike `ColorRangeSelection.
    /// displaySRGB(hue:saturation:luminance:)`, there is no target
    /// luminance to bisect against (`PointColor` deliberately stores none —
    /// see IMPROVEMENTS.md D22), so this reconstructs at a fixed mid
    /// lightness: the swatch communicates the picked HUE and SATURATION
    /// only, not the picked pixel's own brightness. Guards non-finite
    /// input and wraps/clamps, matching `ColorRangeSelection.displaySRGB`'s
    /// own defensiveness against a hand-edited/corrupt sidecar.
    static func displaySRGB(hue: Double, saturation: Double) -> (r: Double, g: Double, b: Double) {
        guard hue.isFinite, saturation.isFinite else { return (0, 0, 0) }
        var wrappedHue = hue.truncatingRemainder(dividingBy: 360)
        if wrappedHue < 0 { wrappedHue += 360 }
        let clampedSaturation = min(max(saturation, 0), 1)
        return ColorRangeSelection.rgb(forHue: wrappedHue, saturation: clampedSaturation, lightness: 0.5)
    }
}
