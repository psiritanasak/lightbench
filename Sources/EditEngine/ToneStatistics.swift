import Foundation

/// Standard sRGB transfer function (OETF), reimplemented in plain Swift (no
/// Core Image dependency) so `AutoToneSolver` (which must stay testable
/// without a `CIContext`) and `ImageToneStatistics` (which computes
/// `meanChroma` in the SAME render pass as everything else, rather than
/// paying for a second GPU render just to get perceptual-domain values) can
/// share ONE implementation instead of two independently-drifting copies.
///
/// An APPROXIMATION of what `EditPipeline`'s own `CILinearToSRGBToneCurve`
/// (`encodeToPerceptual`) actually does on the GPU — NOT verified against it
/// pixel-for-pixel, unlike `ToneCurveSpline`, which genuinely must match its
/// kernel exactly. Every consumer here only needs "plausibly perceptual"
/// (a heuristic trigger threshold, a chroma proxy for Vibrance), not
/// bit-exactness, so this documented gap is accepted rather than paying for
/// a real Core Image round-trip in a pure-math file.
enum PerceptualEncoding {
    static func srgbEncode(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

/// Whole-image tonal-distribution summary, computed by `ImageToneStatistics`
/// from a LINEAR-light render — the sampling half of Auto Tone
/// (`AutoToneSolver`, `ImageDocumentModel.autoTone`). Pure data, no Core
/// Image dependency, so the solver that consumes it stays independently
/// testable without a `CIContext` — the same separation `ToneCurveSpline`
/// already establishes between curve math and its Core Image kernel.
///
/// All luma values are LINEAR-light Rec. 709 luminance (the same weights and
/// domain `ImageAverageColor`'s own gray-world mean already uses), NOT
/// perceptual/gamma-encoded. `AutoToneSolver` is the one place that converts
/// a PREDICTED value (after its own solved Exposure gain) to perceptual via
/// `PerceptualEncoding.srgbEncode` before comparing it against a perceptual
/// threshold — Exposure is linear-light and runs before every
/// perceptual-domain stage Auto Tone solves for, so the gain must be applied
/// before the encode, not folded into this type's own measurement.
struct ToneStatistics: Equatable {
    /// Linear-luma percentile, qualifying (opaque, alpha >= 0.5) pixels
    /// only. Deliberately NOT excluding near-black/near-white pixels the
    /// way `ImageAverageColor`'s gray-world mean does — Auto Tone's whole
    /// job is to characterize exactly the shadows and highlights that
    /// exclusion exists to throw away for a DIFFERENT (WB neutrality)
    /// purpose, so applying it here would defeat the point.
    let percentile0_5: Double
    let percentile5: Double
    let percentile50: Double
    let percentile95: Double
    let percentile99_5: Double

    /// The Reinhard "log-average luminance" scene key —
    /// `exp(mean(log(epsilon + luma)))` — the standard tone-mapping-
    /// literature estimator, used in place of a plain arithmetic mean:
    /// an image with a few very bright pixels (a light source, a
    /// highlight) would otherwise skew a plain mean upward out of
    /// proportion to how dark the scene actually reads.
    let logAverageLuma: Double

    /// Mean, over qualifying pixels, of `max - min` of that pixel's own
    /// PERCEPTUAL (sRGB-encoded, not linear) RGB — a simple, standard
    /// chroma proxy. Perceptual, not linear, because `AutoToneSolver`'s
    /// Vibrance term compares it against a perceptual target — the same
    /// domain a viewer actually judges "how colorful is this photo" in.
    /// `PerceptualEncoding.srgbEncode` CLAMPS its input to 0...1 first, so a
    /// saturated highlight above linear 1.0 headroom (or an out-of-gamut
    /// negative channel) reports LESS chroma than it actually has — accepted
    /// for a Vibrance proxy (which only needs "roughly how colorful," not an
    /// exact figure), not a precision loss worth a second, unclamped
    /// computation.
    let meanChroma: Double

    let qualifyingPixelCount: Int
}
