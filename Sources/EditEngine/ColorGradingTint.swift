import Foundation

/// Converts one Color Grading wheel's (Hue, Saturation) into a signed RGB
/// tint delta — pure, `CoreImage`-free math, so it is plain-XCTest-testable
/// with exact numeric assertions, unlike a value only reachable by
/// rendering a kernel.
///
/// Reuses `ColorRangeSelection.rgb(forHue:saturation:lightness:)` (the
/// existing pure HSL→RGB reconstruction) at a fixed `lightness: 0.5` rather
/// than duplicating that math — this is the standard "symmetric shift
/// around neutral gray" idea real split-toning/color-grading tools use: at
/// lightness 0.5, HSL(hue, 0, 0.5) is exactly neutral gray (0.5, 0.5, 0.5),
/// so subtracting that neutral out gives a delta that is EXACTLY
/// `(0, 0, 0)` whenever `saturation == 0`, regardless of `hue` — matching
/// `EditState.shadowHue`'s own doc comment ("irrelevant at identity: with
/// Saturation 0, Hue's value has no visible effect").
///
/// `EditPipeline.applyColorGrading` calls this once per wheel per render
/// (not per pixel) and passes the resulting delta into
/// `ColorGrading.cikernel`, which does the per-pixel luminance-weighted
/// blend — this is why the kernel itself needs no `rgb2hsl`/`hsl2rgb` at
/// all, unlike `SelectiveColor.cikernel`.
enum ColorGradingTint {
    static func rgbDelta(hue: Double, saturation: Double) -> (r: Double, g: Double, b: Double) {
        var wrappedHue = hue.truncatingRemainder(dividingBy: 360)
        if wrappedHue < 0 { wrappedHue += 360 }
        let neutral = ColorRangeSelection.rgb(forHue: wrappedHue, saturation: saturation, lightness: 0.5)
        return (neutral.r - 0.5, neutral.g - 0.5, neutral.b - 0.5)
    }
}
