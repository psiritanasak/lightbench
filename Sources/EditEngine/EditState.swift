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

    // MARK: - Brightness

    /// Perceptual brightness offset, -1...1, 0 is identity. Unlike Exposure
    /// (a linear-light multiplicative stops gain), this is an additive
    /// offset applied in the perceptual sRGB-gamma domain — a documented
    /// deviation, same family as Contrast. A linear-domain additive offset
    /// was measured to be non-photographic (crushes shadows hard, barely
    /// moves highlights); the perceptual-domain version degrades gracefully
    /// near black and preserves highlight headroom — see `EditPipeline`.
    var brightness: Double = 0

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

    /// Black-point / shadow-clipping control, -1...1, 0 is identity.
    /// Negative deepens (crushes) the darkest tones toward pure black — the
    /// Levels black-point behavior — by moving point0 of the same
    /// `CIToneCurve` spline `curvesShadows`/`curvesHighlights` use, along
    /// its X (input) axis. Positive gently lifts/fades blacks (subtle by
    /// design). Applied in the perceptual domain, inside the curve stage.
    /// NOTE: like any active curve, clamps highlight headroom above 1.0
    /// when active, and `CIToneCurve`'s extrapolation (not hard clamping)
    /// near point0 gives a mild deep-shadow overshoot on the crush side —
    /// measured and documented in `EditPipeline`, a "soft" black point
    /// rather than a razor clip.
    var blackPoint: Double = 0

    // MARK: - Brilliance (composite)

    /// A single-slider "overall pop" control, -1...1, 0 is identity. THIS
    /// IS THIS APP'S OWN APPROXIMATION — Apple's actual Photos "Brilliance"
    /// algorithm is proprietary and undocumented; this is not a
    /// reproduction of it. Implemented as a pure render-time blend that
    /// nudges the *effective* contrast/shadow-lift/highlight-protection/
    /// saturation used during rendering, WITHOUT changing what the
    /// Contrast/Shadows/Highlights/Saturation sliders themselves display —
    /// see `EditPipeline` for the exact weights.
    var brilliance: Double = 0

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

    // MARK: - Vibrance

    /// Global vibrance, -1...1, 0 is identity. A "smart" saturation that
    /// boosts muted colors far more than already-saturated ones (and
    /// protects skin tones), as opposed to `hslSaturation`, which scales all
    /// colors uniformly — a genuinely different algorithm, not a rename.
    /// Maps 1:1 (no span constant) to Core Image's `CIVibrance.amount`,
    /// applied in the perceptual sRGB-gamma domain immediately BEFORE plain
    /// saturation — see `EditPipeline`. Measured selectivity at +0.5: a
    /// muted (0.40,0.34,0.30) gains +0.164 HSV-saturation while an
    /// already-saturated (0.80,0.05,0.05) gains only +0.018 (~9x less) — vs
    /// plain saturation's ~2.3x ratio. Unlike curves, does NOT clamp
    /// highlight headroom (measured: a 1.4 linear channel survives at
    /// 1.400). Independent of Brilliance by design — Brilliance already
    /// nudges plain saturation; also routing it into vibrance would
    /// double-count a single slider's "pop".
    var vibrance: Double = 0

    // MARK: - Crop

    /// Fractional inset from each edge, 0...0.45 (capped well below 0.5 per
    /// side so opposite insets can never cross into a zero/negative crop
    /// rect; 0.45+0.45 = 0.9, leaving a minimum 10% of each dimension). All
    /// 0 is identity (no crop). Expressed as fractions of the image's own
    /// extent, not absolute pixel coordinates, so crop is
    /// resolution-independent and serializes cleanly regardless of the
    /// source image's pixel dimensions — see `EditPipeline`. NOTE: this
    /// struct does not itself enforce the 0...0.45 range (e.g. a value
    /// decoded from a future corrupted/out-of-range save file could exceed
    /// it) — `EditPipeline.applyCrop` clamps on every use, so any future
    /// direct consumer of this property must not assume it's pre-clamped.
    var cropInsetTop: Double = 0
    var cropInsetBottom: Double = 0
    var cropInsetLeft: Double = 0
    var cropInsetRight: Double = 0

    // MARK: - Vignette

    /// Radial vignette strength, -1...1, 0 is identity. Positive DARKENS the
    /// frame corners (classic photographic vignette); negative brightens
    /// them (a "white"/high-key vignette). Applied as the pipeline's FINAL
    /// stage, AFTER crop, in scene-linear light, via Core Image's
    /// `CIVignetteEffect` centered on the CURRENT (post-crop) extent — see
    /// `EditPipeline`. The slider→filter mapping is deliberately ASYMMETRIC
    /// (measured): the filter's negative intensity brightens the corner
    /// ~8x harder than its positive intensity darkens it, so strength maps
    /// to `intensity` at 1.0 span on the darken side and 0.25 span on the
    /// lighten side, keeping both extremes strong-but-graceful. Unlike
    /// curves, does NOT clamp highlight headroom (measured: a 1.4 linear
    /// center survives at 1.399). This struct does not enforce the -1...1
    /// range; `EditPipeline` reads it directly.
    var vignetteStrength: Double = 0

    /// Vignette radius / reach, 0...1, default 0.5 (balanced). Controls how
    /// far the darkening extends inward: 0 is tight (strong, reaches toward
    /// center), 1 is wide (only the extreme corners). Maps to a scale of
    /// 0.7...1.3 on the frame's half-diagonal pixel radius — see
    /// `EditPipeline`. Has NO effect when `vignetteStrength` is 0 (the stage
    /// is guarded off on strength), so its non-zero default is intentional
    /// and not an identity violation.
    var vignetteRadius: Double = 0.5

    /// The no-op edit state: every adjustment at its default (identity) value.
    static let identity = EditState()
}
