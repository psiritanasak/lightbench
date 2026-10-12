import Foundation

/// Maps the Vignette "Softness" slider to `CIVignetteEffect.falloff`.
///
/// Higher falloff reaches further in and darkens more of the frame; lower falloff confines the darkening to the edge. The
/// limits come from a MEASUREMENT (temporary spike on a solid 0.5 field, 400x300, strength 1, linear light; the centre pixel
/// is 0.4998 untouched): the centre stays pristine up to falloff 0.5 (0.4998), loses 0.0002 at 0.55, 0.0011 at 0.6, 0.0031
/// at 0.65, 0.015 at 0.8 and 0.040 at 1.0 — so the soft end stops at 0.6 (inside the suite's 0.002 tolerance), while the
/// hard end can go all the way down to 0.1 with the centre still untouched (falloff 0.0 is avoided: at the WIDE radius it
/// collapses the gradient to the extreme corners only — the mid-edge stays at 0.4897 against 0.4597 at 0.1). Asymmetric on purpose: -1...0 spans 0.1...0.5, 0...+1 spans 0.5...0.6.
///
/// Softness 0 returns the original fixed falloff 0.5 EXACTLY (by branching), so a default render is unchanged. Out-of-range or
/// non-finite input (a hand-edited sidecar) is clamped / read as 0.
enum VignetteMath {
    static let baseFalloff: Double = 0.5
    static let hardestFalloff: Double = 0.1
    static let softestFalloff: Double = 0.6

    static func falloff(softness: Double) -> Double {
        let s = softness.isFinite ? min(max(softness, -1), 1) : 0
        if s == 0 { return baseFalloff }
        return s < 0 ? baseFalloff + (baseFalloff - hardestFalloff) * s : baseFalloff + (softestFalloff - baseFalloff) * s
    }
}
