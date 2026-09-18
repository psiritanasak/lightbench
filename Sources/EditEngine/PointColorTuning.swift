import Foundation

/// Pure math mapping `PointColor.range` (0...1) to the hue/saturation
/// falloff windows `PointColor.cikernel` actually uses — the same
/// `Wmin + range*(Wmax-Wmin)` lerp shape `SelectiveColor.cikernel` already
/// uses for its own shared `range` parameter, but with independent Min/Max
/// constants for each axis (NOT assumed to be the same numbers Selective
/// Color's fixed 8 bands use — a single arbitrary target behaves
/// differently from 8 blended bands).
///
/// No CoreImage dependency (`EditEngine` stays UI/rendering-API-free,
/// matching `ColorRangeSelection`'s own convention) — every bound is a
/// named constant so Slice B's future UI sliders can cite them directly,
/// the same "clamp bounds live in named constants, never literals"
/// contract `ColorRangeSelection` already establishes.
///
/// **These constants are a PRINCIPLED STARTING POINT, not a measured
/// result** — Slice A ships with no UI, so there is no way to visually
/// verify "does this window feel right" against a real photo yet. Chosen
/// as a narrower version of `SelectiveColor.cikernel`'s own `20...80`
/// degree hue range: a Point Color instance targets one exact picked
/// color rather than blending across a whole named hue family, so a
/// tighter default window is the more defensible guess. Retune once
/// Slice B's UI makes live measurement possible — do not treat these as
/// settled.
enum PointColorTuning {
    static let minimumHueWindowDegrees: Double = 10
    static let maximumHueWindowDegrees: Double = 60
    static let minimumSaturationWindow: Double = 0.05
    static let maximumSaturationWindow: Double = 0.5

    /// `range` is clamped to 0...1 here — reviewer-caught: `PointColor.range`
    /// has no UI yet to enforce that bound (Slice A's only input path is a
    /// hand-edited sidecar or a preset), and an out-of-range value wasn't
    /// just cosmetically wrong: `range: 5` produced a 260° hue window and a
    /// 2.3 saturation window, both far past this file's own documented
    /// maxima, and a negative `range` produced a negative window (no NaN —
    /// `raisedCosine`'s own `d >= W` guard short-circuits — but a silently
    /// always-zero selection with no explanation).
    static func hueWindow(forRange range: Double) -> Double {
        let clamped = min(max(range, 0), 1)
        return minimumHueWindowDegrees + clamped * (maximumHueWindowDegrees - minimumHueWindowDegrees)
    }

    static func saturationWindow(forRange range: Double) -> Double {
        let clamped = min(max(range, 0), 1)
        return minimumSaturationWindow + clamped * (maximumSaturationWindow - minimumSaturationWindow)
    }
}
