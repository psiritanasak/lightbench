import Foundation

/// The full set of non-destructive edit adjustments applied to a photo.
///
/// This is pure data — no image or rendering logic lives here. It is
/// `Codable` so it can eventually be serialized to the catalog DB (Phase 3/4)
/// without any changes to this type; no persistence is implemented yet.
struct EditState: Equatable, Codable {
    // MARK: - White Balance

    /// Apparent color temperature in Kelvin, `3500...9500`. `6500` (daylight)
    /// is neutral. Follows the same on-screen convention as Lightroom/Camera
    /// Raw: a HIGHER Kelvin value makes the image look WARMER (more
    /// orange), a lower value makes it look cooler (more blue) — the
    /// opposite of literal blackbody physics, but what every photographer
    /// expects from a "Temperature" slider. See `EditPipeline` for how this
    /// is mapped onto Core Image's filter, whose own raw semantics run the
    /// other direction.
    var whiteBalanceTemperature: Double = 6500

    /// Tint adjustment, relative, `0` is neutral, `-100...100`. Positive
    /// shifts magenta, negative shifts green — see `EditPipeline`.
    var whiteBalanceTint: Double = 0

    // MARK: - Exposure

    /// Exposure adjustment in stops (EV). `0` is identity (no change).
    /// Applied as a multiplicative gain of `2^exposureEV` to linear-light
    /// pixel values — see `EditPipeline`.
    var exposureEV: Double = 0

    // MARK: - Contrast

    /// Contrast adjustment. `0` is identity; positive increases contrast,
    /// negative flattens it. Maps to a `CIColorControls` contrast factor of
    /// `1 + contrast` (range -1...1 → factor 0...2), applied in the
    /// perceptual sRGB-gamma domain around a middle-gray pivot, NOT
    /// scene-linear — see `EditPipeline`. UI range: -1...1.
    var contrast: Double = 0

    // MARK: - Curves (parametric tone)

    /// Parametric shadow-tone adjustment, -1...1, 0 is identity. Positive
    /// lifts (brightens) shadows, negative crushes them. Applied in the
    /// perceptual sRGB-gamma domain, after contrast, by raising/lowering the
    /// shadow control point (x=0.25) of a `CIToneCurve` spline — see
    /// `EditPipeline`. The effect is weighted toward deep shadows and tapers
    /// through the midtones.
    var curvesShadows: Double = 0

    /// Parametric highlight-tone adjustment, -1...1, 0 is identity. Positive
    /// lifts (brightens) highlights, negative recovers (darkens) them.
    /// Applied in the perceptual sRGB-gamma domain, after contrast, by
    /// raising/lowering the highlight control point (x=0.75) of a
    /// `CIToneCurve` spline — see `EditPipeline`. NOTE: because `CIToneCurve`
    /// clamps its domain to [0,1], enabling any curve adjustment clips
    /// highlight headroom above linear 1.0 to white (measured, documented
    /// limitation — see `EditPipeline` and the curve headroom tests).
    var curvesHighlights: Double = 0

    // MARK: - HSL (global hue & saturation)

    /// Global hue rotation in degrees, -180...180, 0 is identity. Rotates all
    /// colors around the color wheel. Applied in the perceptual sRGB-gamma
    /// domain, after curves, via `CIHueAdjust` (whose angle is radians —
    /// `EditPipeline` maps degrees→radians). On-screen direction is measured
    /// against the real filter, not assumed — see `EditPipeline`.
    var hslHue: Double = 0

    /// Global saturation, -1...1, 0 is identity. -1 is fully desaturated
    /// (grayscale), positive increases saturation. Maps to `CIColorControls`'
    /// `saturation` factor of `1 + hslSaturation` (range -1...1 → factor
    /// 0...2), applied in the perceptual sRGB-gamma domain, after curves —
    /// see `EditPipeline`. NOT a Lightness slider: global lightness would
    /// duplicate exposure and the curves shadow/highlight controls, so it's
    /// intentionally omitted (same reasoning curves omitted a midtones
    /// slider). Unlike curves, HSL does NOT clamp highlight headroom
    /// (measured).
    var hslSaturation: Double = 0

    /// The no-op edit state: every adjustment at its default (identity) value.
    static let identity = EditState()
}
