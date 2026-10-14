import Foundation

/// A single user-placed Red-Eye correction point, normalized 0...1 in
/// SwiftUI-local (top-left-origin, y-DOWN) fractions of the displayed
/// image — the SAME convention `ImageDocumentModel.pickWhiteBalance`
/// already established for point capture, so `EditPipeline.applyRedEye`
/// reuses that exact y-flip mapping rather than inventing a new one.
struct RedEyePoint: Equatable, Codable {
    var x: Double
    var y: Double
}

/// A single normalized (0...1) point in the RAW's OWN native, un-rotated
/// pixel grid — seeds `CIRAWFilter.neutralLocation`, Core Image's true
/// (no-search) white-balance neutralization. `x`/`y` follow the same
/// bottom-left-origin, y-UP convention `ImageDocumentModel.pickWhiteBalance`'s
/// existing sampling-point math already uses. See
/// `EditState.rawWhiteBalanceNeutralPoints`'s own doc comment.
struct RawNeutralPoint: Equatable, Codable {
    var x: Double
    var y: Double
}

/// A single user-placed control point of the Curves v2 point curve.
///
/// `x` (input) and `y` (output) BOTH live in the tone curve's own
/// sRGB-encoded domain — the same space `EditPipeline.curveControlPoints`'
/// five parametric points live in, and NOT scene-linear light. That is not
/// a fresh convention: `applyCurves` already runs inside
/// `applyPerceptualAdjustments`' encode/decode sandwich AND encodes a second
/// time internally (see `ToneCurveSpline`), and the point curve stage does
/// exactly the same, so both curves' control points are directly comparable
/// and an editor can draw them on one canvas.
///
/// Note `y` is an output VALUE, y-UP — unlike `RedEyePoint`, whose `y` is a
/// y-DOWN screen position. A curve's y is not a screen coordinate, and
/// storing it y-down would both invert the render and make a sidecar
/// unreadable by eye. Any y-flip belongs in the editor, once.
struct ToneCurvePoint: Equatable, Codable {
    var x: Double
    var y: Double
}

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

    // MARK: - Levels

    /// Levels black input point, 0...1, default 0 (identity). Pixels at or
    /// below this PERCEPTUAL-domain value crush to 0. DISTINCT from
    /// `blackPoint` below (an unrelated, already-shipped Curves `point0`
    /// control, -1...1) — this is the classic Photoshop/Lightroom Levels
    /// black slider, a direct input-level threshold in histogram X units,
    /// not a curve-point move. This struct does NOT itself enforce
    /// `levelsBlackPoint < levelsWhitePoint` — same defense-in-depth
    /// contract as `cropInsetTop`'s documented pattern: `EditPipeline`
    /// guarantees a minimum separation on every use, so a future direct
    /// consumer must not assume this is pre-validated.
    var levelsBlackPoint: Double = 0

    /// Levels white input point, 0...1, default 1 (identity — a non-zero
    /// identity, same accepted pattern as `vignetteRadius`). Pixels at or
    /// above this perceptual-domain value clip to 1.0 — Levels
    /// INTENTIONALLY clips highlight headroom when active (that is what a
    /// white point does; see `EditPipeline` for how this differs from every
    /// other headroom-preserving adjustment in this app).
    var levelsWhitePoint: Double = 1

    /// Levels midtone gamma, default 1 (identity). MEASURED (not assumed):
    /// values >1 brighten midtones, <1 darken them (verified against
    /// `CIGammaAdjust` — see `EditPipeline`). This struct does not clamp
    /// `levelsGamma` to a positive value; `EditPipeline` guards against a
    /// non-positive gamma before computing its reciprocal power.
    var levelsGamma: Double = 1

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
    /// shadow control point (x=0.25) of the tone-curve spline — see
    /// `EditPipeline`. The effect is weighted toward deep shadows and tapers
    /// through the midtones.
    var curvesShadows: Double = 0

    /// Parametric highlight-tone adjustment, -1...1, 0 is identity. Positive
    /// lifts (brightens) highlights, negative recovers (darkens) them.
    /// Applied in the perceptual sRGB-gamma domain, after contrast, by
    /// raising/lowering the highlight control point (x=0.75) of the
    /// tone-curve spline — see `EditPipeline`. Highlight headroom above
    /// linear 1.0 SURVIVES an active curve as of Curves v2 slice 1; until
    /// then the underlying `CIToneCurve` clamped it to white. Existing
    /// sidecars and presets are unaffected — every in-domain value renders
    /// identically (see `ToneCurveSpline`).
    var curvesHighlights: Double = 0

    /// Black-point / shadow-clipping control, -1...1, 0 is identity.
    /// Negative deepens (crushes) the darkest tones toward pure black — the
    /// Levels black-point behavior — by moving point0 of the same tone-curve
    /// spline `curvesShadows`/`curvesHighlights` use, along its X (input)
    /// axis. Positive gently lifts/fades blacks (subtle by design). Applied
    /// in the perceptual domain, inside the curve stage. Below point0 the
    /// curve CLAMPS, which is what makes the crush actually clip to black.
    /// The mild deep-shadow lift on the crush side (a "soft" black point
    /// rather than a razor clip) is real, but it is the spline's in-domain
    /// shape, NOT the "extrapolation past point0" this comment used to
    /// claim — corrected by measurement in Curves v2 slice 1; the rendered
    /// values are unchanged. Highlight headroom now survives — see
    /// `curvesHighlights`.
    var blackPoint: Double = 0

    /// The white end of the tone range, -1...1, identity 0 (2026-10-14): the global twin of per-mask Whites (`Mask.whites`). Its own curve pass
    /// right after the parametric curve (`EditPipeline.applyCurves(... whitePoint:)`, the same call the mask path makes), NOT a moved control
    /// point of the Shadows/Highlights curve — that reversed the top tones (see the per-mask Whites entry in docs/ROADMAP_HISTORY.md). Brilliance
    /// and Styles do not feed it. Decodes `?? 0`.
    var whites: Double = 0

    // MARK: - Point Curve (Curves v2)

    /// The user's own freely-placed tone curve — Curves v2's point curve,
    /// EMPTY BY DEFAULT, where empty means identity and the whole stage is
    /// skipped (`EditPipeline.pointCurveActive`).
    ///
    /// ADDITIVE, NOT A REPLACEMENT. The parametric layer above
    /// (`curvesShadows`/`curvesHighlights`/`blackPoint`, plus Brilliance's
    /// render-time blend into them and the per-mask Shadows/Highlights that
    /// reuse the same machinery) is completely untouched by this field and
    /// stays byte-exact with everything ever saved. The two curve stages
    /// compose deliberately: parametric first as corrective base shaping,
    /// this one second as the creative layer on top. That choice is also
    /// why Curves v2 needs NO `LegacyCodingKeys` migration — no shipped
    /// field changes meaning, so old sidecars and presets simply decode
    /// with this at `[]`.
    ///
    /// The THIRD variable-length field in this struct, after `redEyePoints`
    /// and `masks`, and the simplest of the three: N points sharing no
    /// per-point parameters at all.
    ///
    /// Uses a MONOTONE cubic (Fritsch-Carlson) between points, unlike the
    /// parametric layer's natural cubic — see `MonotoneToneCurve` for why
    /// the two evaluators coexist rather than one being a mode of the other.
    ///
    /// RENDERING CAP: at most `MonotoneToneCurve.maximumPointCount` points.
    /// The kernel passes the curve as fixed-arity `vec4` uniforms, so this
    /// is a real limit, not a soft one. A hand-authored sidecar carrying
    /// more renders IDENTITY (visibly wrong) rather than silently dropping
    /// points — see `MonotoneToneCurve.init?`.
    ///
    /// Deliberately NOT part of `requiresRawRedecode` — same reasoning as
    /// `masks`: this is an `EditPipeline` stage, not a `CIRAWFilter`
    /// setting, so including it would fire a multi-second RAW re-decode on
    /// every point drag.
    var toneCurvePoints: [ToneCurvePoint] = []

    /// Curves v2 slice 3: the per-channel companions to `toneCurvePoints`
    /// above — Red/Green/Blue color-grading curves, distinct from that
    /// composite (applied identically to all three channels) curve. Each
    /// is its own independent stage: `EditPipeline` applies the composite
    /// curve first, then whichever of these three are non-empty, each
    /// touching ONLY its own channel (see `EditPipeline.applyPointCurve`'s
    /// `channelMask` argument). Same EMPTY-MEANS-IDENTITY,
    /// `MonotoneToneCurve.maximumPointCount`-capped,
    /// `requiresRawRedecode`-excluded, no-`LegacyCodingKeys`-needed
    /// contract as `toneCurvePoints` — see that field's own doc comment
    /// for the reasoning, not repeated three times here. The 5th-7th
    /// variable-length fields in this struct (after `toneCurvePoints`,
    /// `redEyePoints`, `masks`, and `rawWhiteBalanceNeutralPoints`).
    var toneCurvePointsRed: [ToneCurvePoint] = []
    var toneCurvePointsGreen: [ToneCurvePoint] = []
    var toneCurvePointsBlue: [ToneCurvePoint] = []

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

    // MARK: - Selective Color (HSL v2, per-band)

    /// 8 fixed color bands (Red/Orange/Yellow/Green/Aqua/Blue/Purple/
    /// Magenta) × Hue/Saturation/Luminance, each -1...1, 0 = identity — this
    /// app's own name for what Lightroom calls the HSL panel (CLAUDE.md
    /// calls it "Selective Color... HSL v2"). Flat named fields, NOT an
    /// array/dictionary — matches this codebase's established per-slider
    /// convention even at this scale (crop's 4 insets are 4 separate named
    /// fields, not a struct), keeping the memberwise initializer, `Codable`/
    /// `Equatable` identity, and per-slider key-path binding all trivial.
    /// Declared here (between global `hslSaturation` and `vibrance`) to
    /// match pipeline order: applied via a custom Core Image kernel — the
    /// first one in this codebase — right after global Hue, before
    /// Vibrance. See `EditPipeline.applySelectiveColor` and
    /// `Sources/Rendering/Shaders/SelectiveColor.cikernel` for the exact,
    /// MEASURED (real compiled kernel probe, not assumed) math: band
    /// centers, circular hue-distance falloff shaped by
    /// `selectiveColorRange`, why band weight is scaled by the pixel's own
    /// saturation (an achromatic pixel has no real hue and must not
    /// register as belonging to any band), and why the pixel's own
    /// brightness is normalized before the HSL round-trip and restored
    /// after — so a bright, colored pixel's own headroom survives even
    /// once it's genuinely inside an active band (unlike Curves/Levels,
    /// which do clamp).
    var redHue: Double = 0
    var redSaturation: Double = 0
    var redLuminance: Double = 0
    var orangeHue: Double = 0
    var orangeSaturation: Double = 0
    var orangeLuminance: Double = 0
    var yellowHue: Double = 0
    var yellowSaturation: Double = 0
    var yellowLuminance: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var greenLuminance: Double = 0
    var aquaHue: Double = 0
    var aquaSaturation: Double = 0
    var aquaLuminance: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0
    var blueLuminance: Double = 0
    var purpleHue: Double = 0
    var purpleSaturation: Double = 0
    var purpleLuminance: Double = 0
    var magentaHue: Double = 0
    var magentaSaturation: Double = 0
    var magentaLuminance: Double = 0

    /// Falloff width shared by all 8 bands, 0...1, default 0.5 (balanced —
    /// a non-zero identity, same accepted pattern as `vignetteRadius`: the
    /// stage is guarded off by the 24 band params above, not by this field
    /// itself). Higher widens/softens every band's reach (more overlap
    /// between neighbors); lower narrows it to a more surgical selection.
    var selectiveColorRange: Double = 0.5

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

    // MARK: - Black & White

    /// Monochrome mode, `false` is identity. Forces FULL desaturation
    /// regardless of `hslSaturation`/`vibrance`/`hslHue`'s own values —
    /// reuses the exact same `CIColorControls` saturation-zero mechanism
    /// `hslSaturation` itself uses at its own -1 extreme (proven to produce
    /// true R=G=B grayscale by `testSaturationMinusOneIsGrayscale`), just
    /// forced on unconditionally rather than driven by the slider — see
    /// `EditPipeline`. Does NOT affect contrast/tone controls (Contrast,
    /// Highlights, Shadows, Black Point, Brilliance's non-saturation
    /// nudges) — those still meaningfully apply to a monochrome image, a
    /// deliberate choice matching how professional B&W conversions work.
    /// v1 scope: on/off only, no Intensity/Neutrals/Tone/Grain sliders
    /// (Photos' real B&W panel has several; documented scope cut, same
    /// pattern as every other v1 feature in this project).
    var blackAndWhite: Bool = false

    /// B&W Mix: per-colour darken/lighten of the grey a colour becomes under `blackAndWhite` (-1...1, 0 = identity), the 8
    /// Selective Color hue bands. No effect while `blackAndWhite` is off. Rendered by `GrayMix.cikernel` as a multiplier on the
    /// PERCEPTUAL (sRGB-encoded) B&W grey (see `EditPipeline.kGrayMixStops`; not linear-light stops), so all-zero is exactly today's B&W. See `EditPipeline.applyGrayMix`.
    var grayMixRed: Double = 0
    var grayMixOrange: Double = 0
    var grayMixYellow: Double = 0
    var grayMixGreen: Double = 0
    var grayMixAqua: Double = 0
    var grayMixBlue: Double = 0
    var grayMixPurple: Double = 0
    var grayMixMagenta: Double = 0

    /// B&W extras (2026-10-14), all identity 0 and rendered ONLY while `blackAndWhite` is on:
    /// - `bwIntensity` (-1...1): scales the B&W Mix — the mix's stop strength becomes `kGrayMixStops * (1 + intensity)`, so -1 switches the mix off and +1 doubles it.
    ///   With all Mix sliders at 0 it has nothing to scale (documented in the UI hint), because the Mix is the only "colour filter" in this pipeline.
    /// - `bwNeutrals` (-1...1): lightens / darkens the mid-greys (a mid-point move of a monotone curve on the grey).
    /// - `bwTone` (-1...1): a B&W contrast S-curve on the grey (darkens the shadow quarter-point, lightens the highlight quarter-point); one curve pass with Neutrals.
    /// - `bwGrain` (0...1): film grain added through the existing Grain stage (`EditPipeline.effectiveDetail`), so Export's deferred grain follows it.
    /// The curve constants are by-eye conventions the RENDERER owns (`EditPipeline.kBWToneSpan`/`kBWNeutralsSpan`): retuning restyles old edits.
    var bwIntensity: Double = 0
    var bwNeutrals: Double = 0
    var bwTone: Double = 0
    var bwGrain: Double = 0

    /// A copy with EVERY grain source switched off: the Grain slider, the Style's Grain toggle and B&W Grain. The one place that lists them, used
    /// by Export (which holds grain back to add it after output sharpening) and the Color Range eyedropper (which must not sample noise), so a
    /// fourth grain source cannot be missed at one call site and not the other.
    func zeroingGrain() -> EditState {
        var s = self
        s.grain = 0
        s.styleGrain = false
        s.bwGrain = 0
        return s
    }

    // MARK: - Color Grading (3-way shadows/midtones/highlights)

    /// 3 tonal ranges (Shadows/Midtones/Highlights) × Hue/Saturation/
    /// Luminance, matching Lightroom's Color Grading color wheels (the
    /// successor to Split Toning) — flat named fields, same established
    /// per-slider convention as Selective Color's 24 fields (see that
    /// section's own doc comment for why: trivial memberwise init,
    /// `Codable`/`Equatable` identity, per-slider key-path binding).
    /// Declared here, immediately after Black & White, to match pipeline
    /// order: `EditPipeline.applyColorGrading` runs last of the user's own stages inside (the style's tint pass follows it, still inside
    /// `applyPerceptualAdjustments`'s sandwich — AFTER Selective Color,
    /// Vibrance, Saturation, and Black & White's forced desaturation, not
    /// adjacent to Selective Color. That placement is load-bearing, not
    /// incidental: a colored tint applied before the B&W override would be
    /// silently erased by it, breaking the single most common real-world
    /// use of this feature — tinting a monochrome photo (sepia, cross-
    /// process/split-tone looks). See `EditPipeline.applyColorGrading`'s own
    /// doc comment for the exact math (per-pixel luminance-weighted tint
    /// blend, no on-GPU HSL round-trip) and `ColorGradingTint` for how
    /// Hue/Saturation become a signed RGB delta.
    ///
    /// Hue: degrees, -180...180, 0 is identity — same convention as
    /// `hslHue` (a real rotation angle, unlike Selective Color's `xHue`
    /// fields, which are -1...1 AMOUNT shifts of a fixed band, not angles).
    /// Irrelevant at identity: with Saturation 0, Hue's value has no visible
    /// effect regardless of what it's set to (mirrors `ToneCurvePoint`'s
    /// empty-array-at-identity reasoning).
    /// Saturation: 0...1, 0 is identity — the wheel puck's radial distance
    /// from center, a magnitude, NOT bipolar like `hslSaturation` (there is
    /// no "negative" direction for a puck's distance from center).
    /// Luminance: -1...1, 0 is identity — a per-range lightness offset,
    /// bipolar like `clarity`/`texture`.
    var shadowHue: Double = 0
    var shadowSaturation: Double = 0
    var shadowLuminance: Double = 0
    var midtoneHue: Double = 0
    var midtoneSaturation: Double = 0
    var midtoneLuminance: Double = 0
    var highlightHue: Double = 0
    var highlightSaturation: Double = 0
    var highlightLuminance: Double = 0
    /// Color Grading's 4th "Global" wheel: Hue (-180...180), Saturation (0...1) and Luminance (-1...1), all 0 = identity. Unlike
    /// the three luminance-selected ranges its weight is exactly 1 at EVERY pixel (a uniform wash), added after the
    /// Shadows/Midtones/Highlights sum, so `colorGradingBlending`/`colorGradingBalance` never reshape it. Hue alone does
    /// nothing at Saturation 0 (same rule as the other wheels). Named `global*` to stay distinct from `hslHue`, the older
    /// whole-image hue rotation.
    var globalHue: Double = 0
    var globalSaturation: Double = 0
    var globalLuminance: Double = 0
    /// Color Grading Blending (-1...1, 0 = the original look): how much the three ranges overlap (falloff width 0.33 ... 0.8
    /// around the original 0.4, see `ColorGradingZones`; a narrower limit would leave tones between the ranges ungraded). Global, not per range. Identity is 0 on purpose (a 0.5-style
    /// default would silently narrow old sidecars on a missing key). Does nothing while every Shadows/Midtones/Highlights tint/luminance is zero (the Global wheel ignores it).
    var colorGradingBlending: Double = 0
    /// Color Grading Balance (-1...1, 0 = centred): positive favours the Highlights range, negative the Shadows (the
    /// midpoint of the tonal scale moves by up to ±0.25 while black and white stay fixed). Global; see `ColorGradingZones`.
    var colorGradingBalance: Double = 0

    // MARK: - Straighten

    /// Rotation angle in degrees, 0 is identity. Positive rotates the image
    /// COUNTERCLOCKWISE (derived from `CGAffineTransform(rotationAngle:)`'s
    /// standard matrix in `CIImage`'s y-up coordinate space, verified with a
    /// 90° test against `quadrantImage` — not assumed). Rotates around the
    /// CURRENT image extent's own center, so it works regardless of the
    /// extent's origin — see `EditPipeline`. Runs BEFORE Flip in the
    /// Transform/Distort group (matching the Photos reference panel order),
    /// still before crop. KNOWN, DOCUMENTED v1 LIMITATION: any nonzero angle
    /// grows the image's bounding-box extent (except at 0/90/180/270°); the
    /// resulting corners outside the actual rotated content render as black
    /// (the existing renderer's black background composite) — this is the
    /// standard "rotate reveals corners" behavior every photo editor
    /// produces before cropping. No auto-fit-to-inscribed-rectangle in v1;
    /// use the already-shipped Crop tool to remove the gaps. Not
    /// runtime-clamped (matches `exposureEV`/`hslHue`'s convention — only
    /// crop's insets and factor-style color params are clamped where
    /// mathematically required).
    var straightenAngle: Double = 0

    // MARK: - Perspective (keystone)

    /// Vertical keystone correction, -1...1, 0 is identity. Positive TAPERS
    /// THE TOP edge inward (top edge narrows relative to the bottom);
    /// negative tapers the BOTTOM edge inward. Simulates correcting
    /// vertical-line convergence (e.g. a building shot from below). Pure
    /// geometry via `CIPerspectiveTransform`, applied as ONE combined quad
    /// together with the Horizontal axis (measured: two sequential filter
    /// calls double-warp content near shared corners — see `EditPipeline`).
    /// Runs after Straighten, before Flip (matching the Photos panel order;
    /// measured non-commuting with Flip, so the order is a real
    /// requirement). Corners move INWARD only, so the image extent is
    /// preserved EXACTLY (measured: unchanged, unlike Straighten's growth);
    /// black corners revealed by the taper are composited by the renderer's
    /// existing black background (same accepted tradeoff as Straighten —
    /// trim with Crop). Direction is measured against `quadrantImage`, not
    /// assumed. Clamped to `kMaxPerspectiveShift` in the pipeline; this
    /// struct does not itself enforce range (matches crop/vignette).
    var verticalPerspective: Double = 0

    /// Horizontal keystone correction, -1...1, 0 is identity. Positive
    /// TAPERS THE RIGHT edge inward (right edge shortens relative to the
    /// left); negative tapers the LEFT edge inward. Simulates correcting
    /// horizontal-line convergence (e.g. a document photographed
    /// off-axis). Same mechanism/domain/extent/black-corner notes as
    /// `verticalPerspective`; combined with it into a single
    /// `CIPerspectiveTransform` call — see `EditPipeline`.
    var horizontalPerspective: Double = 0

    // MARK: - Transform Scale/Aspect

    /// Manual uniform zoom, 0.5...1.5 (50%...150%), 1.0 is identity. Applied
    /// about the CURRENT extent's own center, AFTER Perspective — Lightroom's
    /// own Transform-panel "Scale": exists specifically to zoom in and clear
    /// the empty corner wedges Perspective correction reveals, WITHOUT
    /// changing the photo's own output dimensions (the transformed content
    /// is cropped back to its pre-transform extent — see `EditPipeline.
    /// applyTransformScale`). Values below 1.0 also legal — the content
    /// shrinks and letterboxes within the SAME frame size, exposing
    /// transparent margin at the edges (this stage runs after Straighten/
    /// Perspective, whose own corner-revealing already happened; a value
    /// below 1.0 here doesn't "reveal" anything new about the source photo,
    /// it just shrinks what's already been placed in the frame). Clamped to
    /// this range in the pipeline; this struct does not itself enforce it
    /// (matches crop insets/perspective's own convention).
    var transformScale: Double = 1.0

    /// Manual anisotropic stretch, -1...1, 0 is identity. Applied as an
    /// independent X/Y scale about the CURRENT extent's own center, composed
    /// into the SAME transform as `transformScale` (diagonal scales commute,
    /// so both are combined into one `CGAffineTransform` — see
    /// `EditPipeline.applyTransformScale`). Lightroom's own Transform-panel
    /// "Aspect" — deliberately labeled "Stretch" in this app's UI instead:
    /// `CropTabView`'s existing "Aspect" section is the unrelated crop
    /// aspect-RATIO preset list (Freeform/Square/16:9/...), and reusing the
    /// word here would collide. Positive stretches TALLER/narrower, negative
    /// stretches WIDER/shorter — this app's own v1 mapping
    /// (`EditPipeline.kMaxTransformAspectStretch`, area-preserving), NOT a
    /// reverse-engineered match to Lightroom's own undocumented curve/sign
    /// convention (domain research was only moderately confident on
    /// Lightroom's own sign and not confident at all on its exact formula).
    /// Clamped to this range in the pipeline; this struct does not itself
    /// enforce it.
    var transformAspect: Double = 0

    // MARK: - Flip

    /// Mirror the image horizontally (left-right) / vertically (top-bottom).
    /// Pure geometry, no color-space concerns — reflects around the CURRENT
    /// image extent's own center, so it works regardless of the extent's
    /// origin. Runs BEFORE crop in the pipeline (grouped with Transform/
    /// Distort in the fixed pipeline order), so crop's insets always apply
    /// to the already-flipped framing — "visual top/bottom/left/right"
    /// stays anchored to whatever is currently on screen — see
    /// `EditPipeline`.
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

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

    // MARK: - Red-Eye Removal

    /// User-placed correction points. UNLIKE every other adjustment in this
    /// app (including Selective Color's 24 fixed-band fields), this is
    /// VARIABLE-LENGTH — red-eye spots are inherently unbounded (0 to N per
    /// photo, wherever the user taps), so a flat-named-field convention
    /// doesn't fit; an array is the deliberate, justified departure here,
    /// not an inconsistency with the rest of this struct.
    var redEyePoints: [RedEyePoint] = []

    // MARK: - Spot removal (Heal / Clone)

    /// Spot-removal spots (`RetouchSpot`), to be applied by `EditPipeline.applyRetouch` (a later commit) as the very FIRST stage, in the
    /// UNEDITED source frame (see `RetouchSpot`). VARIABLE-LENGTH, capped at `maxRetouchSpots`. Photo-specific
    /// PLACEMENT, so — like `redEyePoints`/`masks` — NOT copied by `applyingPreset(onto:)`, and cleared by
    /// `comparisonOriginal()` (a "before" view must show no retouching). `Reset Adjustments` leaves them alone,
    /// as it does red-eye points.
    var retouchSpots: [RetouchSpot] = []
    static let maxRetouchSpots = 50

    /// Correction radius, 0...1, default 0.5 — shared by every placed point
    /// (not per-point), same non-zero-identity pattern as `vignetteRadius`:
    /// guarded off by `redEyePoints`/`redEyeStrength`, not by this field.
    var redEyeSize: Double = 0.5

    /// Correction strength, 0...1, default 0.7 — deliberately NOT 0, unlike
    /// most sliders: tapping to place a point should immediately produce a
    /// visible correction without also requiring the user to raise a
    /// second slider first; Size/Strength are for fine-tuning afterward,
    /// not a required second step. `EditPipeline`'s guard still makes the
    /// whole stage an exact no-op whenever `redEyePoints` is empty, so this
    /// non-zero default has no effect until at least one point exists.
    var redEyeStrength: Double = 0.7

    // MARK: - Local Adjustments (Masks)

    /// Per-photo local adjustments — Phase 7 slice 2. Each `Mask` is a
    /// radial (ellipse) region carrying its OWN full curated parameter set,
    /// applied SEQUENTIALLY in array order (later masks' effects stack on
    /// top of earlier ones' where they overlap — unlike `redEyePoints`,
    /// which union their masks so overlapping corrections apply exactly
    /// once; see `EditPipeline.applyMasks`'s own doc comment for why the
    /// two are deliberately different).
    ///
    /// The SECOND variable-length field in this struct, after
    /// `redEyePoints` — and a bigger step up than that precedent: red-eye
    /// is N points sharing ONE shared param pair (`redEyeSize`/
    /// `redEyeStrength`), whereas each mask owns a full independent
    /// parameter set. Same underlying justification as `redEyePoints`
    /// (above): masks are inherently unbounded (0 to N per photo, wherever
    /// the user drags one), so the flat-named-field convention this struct
    /// otherwise follows genuinely doesn't fit.
    ///
    /// NOT included in `requiresRawRedecode` — masks are an `EditPipeline`
    /// stage, not a `CIRAWFilter` setting, so adding them there would fire
    /// a spurious multi-second RAW re-decode on every mask drag. CLEARED by
    /// `comparisonOriginal()` (masks are retouching/stylization, same as
    /// `redEyePoints`) but NOT copied by `applyingPreset(onto:)` (a mask's
    /// placement is specific to ONE photo's composition, never part of a
    /// reusable look) — see both methods' own doc comments.
    var masks: [Mask] = []

    // MARK: - Point Color

    /// Per-photo Lightroom-style per-color eyedropper refinement — a
    /// picked target color plus a Hue/Saturation/Luminance adjustment,
    /// applied SEQUENTIALLY in array order (each instance's effect stacks
    /// on the previous instances' output, the same `applyMasks`-style
    /// accumulation `EditPipeline.applyPointColors` uses, not `redEyePoints`'
    /// union). The THIRD variable-length field in this struct, after
    /// `redEyePoints` and `masks` — same underlying justification: an
    /// unbounded, per-photo, user-added collection the flat-named-field
    /// convention doesn't fit. Deliberately much smaller than `Mask`
    /// (`PointColor`'s own doc comment): no kind polymorphism, no
    /// geometry, no combine mode.
    ///
    /// NOT included in `requiresRawRedecode` — an `EditPipeline` stage,
    /// not a `CIRAWFilter` setting, matching `masks`. CLEARED by
    /// `comparisonOriginal()` (retouching/stylization, same as `masks`)
    /// but NOT copied by `applyingPreset(onto:)` (a picked color is this
    /// photo's own composition, not part of a portable reusable look) —
    /// see both methods' own doc comments.
    var pointColors: [PointColor] = []

    // MARK: - Vignette

    /// Radial vignette strength, -1...1, 0 is identity. Positive DARKENS the
    /// frame corners (classic photographic vignette); negative brightens
    /// them (a "white"/high-key vignette). Applied AFTER crop, in
    /// scene-linear light, via Core Image's
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
    /// Vignette Softness, -1...1, 0 is identity (the original look): how far the darkening reaches in from the edge. Negative =
    /// harder (confined to the edge), positive = softer (reaches further in). Mapped to `CIVignetteEffect.falloff` by
    /// `VignetteMath` (0.1 ... 0.5 ... 0.6, limits MEASURED so the centre loses at most 0.0011). Identity 0 on purpose (an offset
    /// rather than a 0.5 default). No effect while `vignetteStrength` is 0.
    var vignetteSoftness: Double = 0

    // MARK: - Texture & Clarity (Lightroom "Presence")

    /// Fine/mid-frequency local contrast, -1...1, default 0 (identity).
    /// Positive brings out surface detail (skin pores, fabric weave, foliage);
    /// negative smooths it while leaving broad tonal structure alone.
    ///
    /// Same `CIUnsharpMask` construction as `clarity` below, at a MUCH
    /// smaller radius — `kTextureRadiusFraction` vs `kClarityRadiusFraction`
    /// — which is the entire difference between the two controls. Sits
    /// between Sharpen's fine `kSharpenRadiusFraction` and Clarity's wide
    /// one; see `EditPipeline` for the measured sweep behind the value.
    ///
    /// Bipolar, unlike the one-directional `definition` this and `clarity`
    /// replaced — see `clarity`'s doc comment for why that took a second
    /// construction rather than just a wider range.
    var texture: Double = 0

    /// Large-radius local contrast, -1...1, default 0 (identity). Positive
    /// adds midtone "punch"; negative softens local contrast for a hazier,
    /// flatter rendering.
    ///
    /// **Replaces the shipped `definition` field** (Phase 8 / Lightroom
    /// Presence split). Old sidecars and presets written before the split
    /// decode their `definition` value into THIS field — see this type's
    /// `LegacyCodingKeys` in the custom-decoding extension below. Positive
    /// `clarity` at value X is byte-identical to the old `definition` at X:
    /// same filter, same `kClarityAmountSpan`, same
    /// `kClarityRadiusFraction`, same pipeline position. Only the name and
    /// the newly-live negative half changed.
    ///
    /// BIPOLAR, and this took real work rather than widening a range.
    /// MEASURED (this app's extendedLinearSRGB/RGBAf working space, not
    /// assumed): `CIUnsharpMask` silently clamps negative `intensity` to a
    /// no-op — intensity -0.2 through -1.0 all produced output
    /// BIT-IDENTICAL to the unfiltered baseline, a dead half of the slider
    /// range. That measurement is why `definition` originally shipped
    /// one-directional and named for Apple Photos' convention rather than
    /// Lightroom's. The negative half is therefore a DIFFERENT
    /// construction: blend toward a `CIGaussianBlur` at the same radius,
    /// which is what local-contrast REDUCTION physically is. See
    /// `EditPipeline.localContrast(amount:radiusFraction:amountSpan:to:)`,
    /// which owns both halves and the extent hazard the blur introduces.
    ///
    /// MEASURED findings for the POSITIVE half, inherited unchanged from
    /// `definition`:
    /// - Filter: `CIUnsharpMask` — the SAME filter Sharpen uses (already
    ///   measured numerically identical to `CISharpenLuminance` there), here
    ///   at a much larger radius/lower intensity. Chosen for its explicit
    ///   `radius` + `intensity` params, since Clarity is defined by its
    ///   wide radius. `intensity: 0` is an exact no-op (measured max diff
    ///   0.0). Rejected: `CIHighlightShadowAdjust` — measured to be an
    ///   ASYMMETRIC shadow/highlight tone-mapper (it LIFTS the dark side of a
    ///   test edge from 0.2 to 0.303), not a symmetric local-contrast
    ///   operator.
    /// - Span: slider maps to `intensity = amount * 0.8`. At slider 1.0 a
    ///   0.2/0.5 edge overshoots to 0.66061 / undershoots to 0.12525 —
    ///   comparable PEAK punch to Sharpen's full strength, but spread far
    ///   wider (still 0.50955 elevated at 60px from the edge, where Sharpen
    ///   has already decayed back to baseline — this width is what makes it
    ///   local CONTRAST, not fine sharpening).
    /// - Resolution: like Sharpen (UNLIKE Noise Reduction), the filter's
    ///   radius is in ABSOLUTE PIXELS (measured: a fixed radius gives
    ///   byte-identical halos regardless of image size), so it MUST scale
    ///   with image size; radius = 0.04 * min(width,height) — 16x Sharpen's
    ///   own 0.0025 fraction, since local contrast needs a far wider reach
    ///   than fine-detail sharpening.
    /// - Domain: perceptual sandwich, matching Sharpen — though MEASURED,
    ///   domain barely mattered here (~1% relative difference between
    ///   perceptual and scene-linear lift across shadow/mid/highlight test
    ///   edges, all ~77% of baseline in both domains), unlike Sharpen (~5%
    ///   difference) or Noise Reduction (~2x difference). Perceptual chosen
    ///   for consistency with Sharpen's established sandwich, not because it
    ///   measurably wins here.
    /// - Headroom/alpha: does NOT clamp above 1.0 (a 1.4 flat survives at
    ///   1.40127) and preserves alpha exactly (measured).
    /// - Vignette ordering: UNLIKE Sharpen (which commutes with Vignette
    ///   within 0.00100), Clarity does NOT cleanly commute with Vignette
    ///   (measured corner differences up to 0.0188 between
    ///   Clarity-then-Vignette and Vignette-then-Clarity) — its wide
    ///   radius interacts with Vignette's spatially-varying darkening in a
    ///   way Sharpen's tiny radius doesn't. This is why the pipeline order
    ///   (Clarity runs AFTER Vignette) is a real, measured requirement,
    ///   not an arbitrary choice.
    /// v1 scope: single Amount slider only — same scope-cut pattern as every
    /// other v1 feature. Dehaze, the third member of Lightroom's Presence
    /// panel, is a deliberately separate future slice: it is a different
    /// algorithm, not another radius on this filter.
    var clarity: Double = 0

    /// Haze removal, -1...1, default 0 (identity). Positive removes haze;
    /// negative ADDS it (Lightroom's Dehaze is bipolar the same way, and here
    /// the negative half took almost no extra CODE — it reuses the atmospheric
    /// light the removal path already estimates). Note that is an
    /// implementation-cost statement, not a runtime one: measured, negative
    /// and positive show no meaningful render-cost difference (two
    /// methodologies, 0.6% and 3.5% apart, in opposite directions). Absolute
    /// numbers for this stage do not reproduce — see IMPROVEMENTS.md D17.
    ///
    /// The third member of Lightroom's Presence panel, and the one that is NOT
    /// another radius on `CIUnsharpMask`. Core Image ships no dehaze filter,
    /// so this is a real implementation of the DARK CHANNEL PRIOR (He, Sun &
    /// Tang, "Single Image Haze Removal Using Dark Channel Prior", CVPR 2009)
    /// across two custom kernels plus `CIMorphologyMinimum` and
    /// `CIAreaMaximum` — see `EditPipeline.applyDehaze` and
    /// `Sources/Rendering/Shaders/DehazeDarkChannel.cikernel` /
    /// `DehazeRecover.cikernel`.
    ///
    /// Purely additive: unlike `clarity`, this field has no predecessor in any
    /// shipped sidecar, so there is NO migration and no `LegacyCodingKeys`
    /// entry. Absent keys already default to 0 via the schema-tolerant
    /// decoder.
    ///
    /// Identity at 0 is exact, but because `EditPipeline.dehazeActive` SKIPS
    /// the stage — not because the maths round-trips. `(I - A)/1 + A` is not
    /// identity in float32 (measured: 265 of 1024 components differ on a
    /// 256-value ramp, max delta 2.98e-08). That guard is load-bearing.
    ///
    /// v1 scope: single Amount slider, matching every other v1 feature here.
    /// The prior's own parameters (patch radius, omega, transmission floor)
    /// are tuned constants in `EditPipeline`, not exposed.
    var dehaze: Double = 0

    // MARK: - Noise Reduction

    /// Luminance noise reduction amount, 0...1, default 0 (identity).
    /// One-directional (0 = none, positive = smoother) — same 0...1 family
    /// as Vignette Radius and Sharpen, not the bipolar -1...1 tone/color
    /// sliders. Applied just BEFORE Sharpen (standard denoise-then-sharpen
    /// order), in SCENE-LINEAR light — NOT the perceptual sandwich Sharpen
    /// uses — via Core Image's `CINoiseReduction`. See `EditPipeline`.
    ///
    /// MEASURED findings (this app's extendedLinearSRGB/RGBAf working
    /// space, not assumed):
    /// - Filter: `CINoiseReduction`. Its `inputSharpness` param is a
    ///   re-sharpen that ADDS noise back (the filter's own default of 0.4
    ///   raised a flat noisy patch's std to 136% of baseline), so it is
    ///   PINNED to 0; only `inputNoiseLevel` is driven by this slider.
    ///   `CIMedianFilter` (no parameter — can't drive a strength slider,
    ///   and measured weaker) and `CIGaussianBlur` (not edge-aware —
    ///   destroys a clean step edge) were measured and rejected.
    /// - Span: slider maps to `noiseLevel = amount * 0.15`, the measured
    ///   saturation onset (noiseLevel 0.15 and 0.40 measure identical). On
    ///   amp±0.10 noise a flat patch drops from std 0.05781 to 0.04378
    ///   (slider 0.5) / 0.01378 (slider 1.0, the ~23.8% residual floor),
    ///   while a clean 0.2/0.5 step edge is preserved (softened over only
    ///   ~4px). The knee is content-dependent (≈1.5x the image's own noise
    ///   amplitude) — response stays monotone and slider 0 is an exact
    ///   no-op regardless.
    /// - Resolution: UNLIKE Sharpen's radius, `noiseLevel` needs NO
    ///   extent-derived scaling — measured near-identical residual std
    ///   (23.8-23.9%) and byte-identical edge ramps at 400/800/1600px. A
    ///   fixed-pixel kernel is exactly correct here because noise is
    ///   inherently per-pixel, unlike Sharpen's edge halo which is a
    ///   frame-relative feature.
    /// - Domain: scene-linear denoises evenly across the tonal range
    ///   (shadows/mids/highlights all ~24% residual); the perceptual
    ///   sandwich under-denoises shadows (47%) because the sRGB encode
    ///   lifts shadow noise above the threshold — the opposite of
    ///   Sharpen's domain choice, and matching Vignette's.
    /// - Headroom/alpha: does NOT clamp above 1.0 (a noisy 1.4 flat
    ///   survives at 1.39988) and preserves alpha exactly (measured).
    /// v1 scope: single Amount slider (no per-channel/color-noise/detail
    /// controls) — same scope-cut pattern as Sharpen's Amount-only.
    var noiseReduction: Double = 0

    // MARK: - Sharpen

    /// Detail/edge sharpening amount, 0...1, default 0 (identity).
    /// One-directional (0 = none, positive = sharpen) — unlike the bipolar
    /// tone/color sliders — matching Crop insets/Vignette Radius's 0...1
    /// convention rather than the -1...1 family. Applied AFTER Vignette, in
    /// the perceptual sRGB-gamma domain, via Core Image's
    /// `CISharpenLuminance` — see `EditPipeline`. NOT the pipeline's final
    /// stage (stale claim, corrected here): Defringe runs right after it —
    /// a CONVENTION backed by a real measurement, not a requirement (a
    /// wider measurement shows the reversed order actually leaves LESS
    /// residual chroma in aggregate on a real test fixture — see
    /// `EditState.defringePurple`'s own doc comment for the full,
    /// corrected story). Grain is the true final stage.
    ///
    /// MEASURED findings (this app's extendedLinearSRGB/RGBAf working
    /// space, not assumed):
    /// - Filter: `CISharpenLuminance` and `CIUnsharpMask` are NUMERICALLY
    ///   IDENTICAL at matched parameters here (grayscale AND color edges,
    ///   to 5 decimals) — the textbook "luminance sharpen avoids color
    ///   fringing" claim does NOT hold in this working space; both
    ///   overshoot per-channel. `CISharpenLuminance` is chosen only for
    ///   its single `sharpness` param and exact sharpness=0 no-op, not for
    ///   any measured fringing benefit.
    /// - Span: slider maps to `sharpness = amount * 1.5`. At slider 1.0 a
    ///   0.2/0.5 edge overshoots to 0.63963 / undershoots to 0.13242
    ///   (strong, dark side stays well positive).
    /// - Resolution: the filter's radius is in ABSOLUTE PIXELS (a fixed
    ///   radius gives an identical pixel-halo on 400px and 1600px images,
    ///   both peak 0.63963), so it MUST scale with image size; radius =
    ///   0.0025 * min(width,height) makes the halo track the frame (peak
    ///   0.53896/0.63963/0.72959 at 400/800/1600px) — mirrors
    ///   vignette/perspective deriving geometry from `image.extent`.
    /// - Domain: perceptual sandwich (measured more even edge response
    ///   than linear: bright 0.61349 vs 0.58325).
    /// - Headroom/alpha: does NOT clamp above 1.0 (a 1.4 flat survives at
    ///   1.40238) and preserves alpha exactly (measured).
    /// v1 scope: single Amount slider only — Radius/Detail/Masking
    /// (Photos/Lightroom expose more) are deferred, same scope-cut
    /// pattern as Vignette's Softness and Black & White's tone/grain.
    var sharpness: Double = 0

    // MARK: - Defringe (Chromatic Aberration)

    /// Purple fringe removal amount, 0...1, default 0 (identity).
    /// Lightroom's own "Defringe" (Lens Corrections panel) — this app's
    /// answer to the roadmap's "Chromatic Aberration removal" gap, scoped
    /// deliberately to Defringe alone: Lightroom's OTHER chromatic-
    /// aberration mechanism, the automatic "Remove Chromatic Aberration"
    /// checkbox, needs per-lens profile calibration data this app has no
    /// source for and won't build a database for. Defringe needs none —
    /// it's a LOCAL, hue-selective chroma suppression at high-contrast
    /// edges (purple/green fringing on a backlit branch or wire against
    /// bright sky is the textbook case), not a geometric per-channel
    /// realignment, so it works on every photo regardless of lens.
    ///
    /// Runs AFTER Sharpen (a CONVENTION, backed by a real but genuinely
    /// mixed measurement — NOT a requirement) and BEFORE Grain (a real,
    /// MEASURED, unconditional requirement). The two orderings are NOT the
    /// same kind of claim — kept deliberately distinct below rather than
    /// bundled into one "both measured requirements" statement, which an
    /// earlier draft of this comment wrongly did.
    ///
    /// AFTER Sharpen (`testSharpenBeforeDefringeIsAConventionNotARequirement`):
    /// Sharpen's own doc comment documents (MEASURED) that it overshoots
    /// PER-CHANNEL in this working space; measured here (on a genuinely
    /// per-channel misregistered edge — chromatic aberration's own
    /// textbook definition) that this overshoot mostly MANUFACTURES fresh
    /// colored fringing at previously-neutral pixels next to a
    /// misregistered edge, rather than shifting an existing fringe's hue
    /// (at most sampled pixels on this fixture, the INPUT is already
    /// perfectly neutral). Sampling a 9-point sweep with BOTH bands
    /// engaged: shipped order wins at 3 pixels, reversed wins at 4, ties
    /// at the 2 pixels carrying real input fringe — and reversed leaves
    /// ~46% LESS residual chroma in AGGREGATE across the sweep. This is a
    /// genuinely weak/mixed measurement, not a case for the shipped order
    /// — per CLAUDE.md's own rule for exactly this situation ("call the
    /// decision a convention... rather than dressing it up as a measured
    /// necessity"), Sharpen-before-Defringe ships because it reads more
    /// intuitively (Sharpen is a documented fringing producer elsewhere in
    /// this file, so Defringe naturally reads as the cleanup step), not
    /// because the numbers prove it. An earlier version of this same doc
    /// comment claimed the OPPOSITE — a "measured requirement" — based on
    /// a test that only sampled the 2 pixels where the shipped order
    /// happens to win; reviewer-caught, by independently re-measuring a
    /// wider pixel sweep, not by re-reading the existing test.
    ///
    /// BEFORE Grain (`testDefringeMustRunBeforeGrainOrTheFlatGuardBreaks`):
    /// a much more dramatic, unconditional finding. Grain adds
    /// high-frequency per-pixel noise EVERYWHERE, including flat content;
    /// measured that if it ran before Defringe, that noise alone inflates
    /// the edge gate's own `localMax - localMin` signal enough to fool it
    /// into treating FLAT content as a real edge — breaking this field's
    /// own "a genuinely purple/green FLAT subject is structurally
    /// protected regardless of amount" guarantee across the WHOLE image
    /// (measured: a large flat saturated purple region desaturates almost
    /// to gray). Defringe running before Grain avoids this entirely.
    ///
    /// Core Image ships no defringe filter, so this is a real
    /// implementation: a local edge/contrast signal (the difference between
    /// `CIMorphologyMaximum`/`CIMorphologyMinimum` on a luma image — near
    /// zero in flat regions, large at sharp edges) gates a hue-selective
    /// desaturation, so a genuinely purple/green FLAT subject (a flower, a
    /// lawn) is structurally protected regardless of amount — see
    /// `EditPipeline.applyDefringe` and
    /// `Sources/Rendering/Shaders/Defringe.cikernel`.
    ///
    /// Real, known limitation (measured, not just theoretical): the gate
    /// protects FLAT subjects but NOT textured ones — a high-contrast
    /// TEXTURED subject in the target hue (foliage against sky is the
    /// common case) reads as a real edge and gets desaturated too. Measured:
    /// foliage green (0.08, 0.35, 0.10) at a high-contrast sky boundary with
    /// `defringeGreen = 1` fully desaturates (chroma 0.27 -> 0.022). This is
    /// inherent to any hue-band defringe approach without a separate
    /// selection mechanism (Lightroom's own Defringe exposes a Hue Range
    /// control for exactly this reason — not built here, see v1 scope
    /// below), not a bug in this implementation. See IMPROVEMENTS.md.
    ///
    /// v1 scope: two Amount sliders (this one, and `defringeGreen`), the
    /// SAME "single Amount, sophistication deferred" pattern `dehaze`/
    /// `clarity`/`texture` already established here. The hue windows that
    /// define "what counts as purple/green" (`EditPipeline`'s
    /// `kDefringePurpleHueCenter`/`kDefringeGreenHueCenter`/
    /// `kDefringeHueWindow`) are tuned constants, not exposed — matching
    /// `dehaze`'s own "the prior's own parameters ... are tuned constants
    /// in `EditPipeline`, not exposed" precedent. Desaturation is PLAIN
    /// (pulls saturation toward the pixel's own luma), not neighbor-color
    /// replacement — a known, deliberately simpler v1 choice than
    /// Lightroom's own likely-fancier behavior, not claimed to match it.
    ///
    /// Purely additive: no predecessor in any shipped sidecar, so there is
    /// NO migration and no `LegacyCodingKeys` entry. Absent keys already
    /// default to 0 via the schema-tolerant decoder.
    var defringePurple: Double = 0

    /// Green fringe removal amount, 0...1, default 0 (identity). Same
    /// mechanism/domain/ordering/scope as `defringePurple` — see that
    /// field's own doc comment for the full story. Selects a DIFFERENT
    /// fixed hue band (`EditPipeline.kDefringeGreenHueCenter`) and is
    /// otherwise fully independent: picking Purple never touches a green
    /// fringe and vice versa (see `testDefringePurpleAndGreenAreIndependent`).
    var defringeGreen: Double = 0

    // MARK: - Grain

    /// Film grain simulation amount, 0...1, default 0 (identity).
    /// One-directional (0 = none, positive = grain) — matching Sharpen/
    /// Noise Reduction's 0...1 family, not the bipolar tone/color sliders.
    /// Applied as the pipeline's new TRUE FINAL stage, AFTER Sharpen AND
    /// Defringe (see `EditPipeline` — Sharpen's own doc comment previously
    /// called ITSELF the final stage, then Defringe was inserted between
    /// the two; this claim now belongs here), in the perceptual
    /// sRGB-gamma domain, via a custom kernel (`FilmGrain.cikernel`) blending
    /// a `CIRandomGenerator` noise field — see `EditPipeline.applyGrain`.
    ///
    /// Noise source: `CIRandomGenerator`, not a hand-rolled per-pixel hash —
    /// a coordinate-hash noise function's output is hardware/precision-
    /// dependent, which would threaten this app's core "replaying the same
    /// params must be deterministic" invariant. `CIRandomGenerator` is
    /// Apple's own fixed, coordinate-derived noise field (MEASURED
    /// identical across independent `CIContext`s — see
    /// `EditPipelineTests`).
    ///
    /// That determinism guarantee is per OUTPUT SIZE, not universal — worth
    /// stating explicitly, since Grain is the first stage in this pipeline
    /// with this property. The noise is locked to absolute `CIImage`
    /// coordinates, so replaying the same `EditState` against the same
    /// SOURCE at the same rendered size reproduces the identical grain
    /// pattern, but an export at a DIFFERENT output resolution than the
    /// Editor's preview will show a different (still deterministic, still
    /// amplitude-consistent per `kGrainCellFraction`) noise realization,
    /// not a pixel-for-pixel match. This is inherent to sizing the noise
    /// off the render's own extent rather than the source photo's fixed
    /// dimensions, and is a documented non-goal, not an oversight — see
    /// IMPROVEMENTS.md's Grain entry.
    ///
    /// MEASURED findings (this app's extendedLinearSRGB/RGBAf working
    /// space, not assumed):
    /// - Span: slider maps to amplitude `amount * kGrainAmountSpan` — see
    ///   `EditPipeline.kGrainAmountSpan`'s own doc comment for the sweep.
    /// - Resolution: like Sharpen's radius, the noise cell size is a
    ///   FRACTION of `min(extent)`, not a fixed pixel count — a fixed cell
    ///   would make the interactive downscaled proxy show visibly larger
    ///   grain than the settled full-res render. See
    ///   `EditPipeline.kGrainCellFraction`.
    /// - Domain/ordering: perceptual sandwich, same domain as Sharpen and
    ///   for the same reason (a fixed-amplitude LINEAR perturbation is
    ///   invisible in highlights and violent in shadows) — see
    ///   `EditPipeline.applyGrain`'s own doc comment for the measured
    ///   stage-order requirement relative to Noise Reduction and Sharpen.
    /// - Headroom/alpha: preserves alpha exactly; the kernel's tonal weight
    ///   is a PRINCIPLED choice (not measured) that clamps grain to zero
    ///   above linear 1.0 headroom and at pure black.
    /// v1 scope: single Amount slider only — Lightroom's own Size/Roughness
    /// controls are deferred, same scope-cut pattern as every other
    /// Tier-1 Effects slider in this app (Texture/Clarity/Dehaze/Sharpen/
    /// Noise Reduction are all single-slider v1s).
    var grain: Double = 0

    // MARK: - Look (LUT profile)

    /// The creative look applied before the user's own adjustments, `""` = none. Built-in ids are
    /// `builtin:<slug>` (`BuiltInLooks`), imported `.cube` files `user:<sha256-12>` (purely content-addressed,
    /// so an id always means the same pixels). An id this machine cannot resolve renders as NO look (fail-open:
    /// a sidecar from a machine that had a look this one lacks must still open) — the UI shows it as missing.
    /// Purely additive: absent key decodes to `""`.
    var lookID: String = ""

    /// 0...1, how strongly the look is blended in; only meaningful when `lookID` is non-empty. NON-ZERO
    /// identity default (1.0): decodes with `?? 1.0`, not `?? 0` — the same hazard class as
    /// `transformScale`/`levelsWhitePoint`.
    var lookIntensity: Double = 1.0

    // MARK: - Style (preset + Tone/Color pad + strength)

    /// The style preset (`StyleLibrary`), `""` = none (the pad can still be used on its own). `builtin:<slug>`. An id this
    /// build does not know renders as NO preset but is kept, so a photo edited in a newer build keeps its style. A style
    /// only ADDS render-time nudges (`StyleMath`) — it never writes the user's own sliders. Purely additive: absent = `""`.
    var styleID: String = ""

    /// The pad's vertical axis, -1...1: Tone (shadows lift/deepen with a small opposite contrast move). 0 = centre.
    var styleTone: Double = 0

    /// The pad's horizontal axis, -1...1: Color (mostly Vibrance, plus some Saturation; no skin masking yet). 0 = centre.
    var styleColor: Double = 0

    /// 0...1, scales the WHOLE style (preset + pad + tints) exactly linearly. NON-ZERO identity default (1.0), decoded with
    /// `?? 1.0` (the `lookIntensity`/`transformScale` hazard class). Meaningful only while a preset or pad offset is set; a
    /// lone `styleStrength != 1` is an invisible edit, so the UI resets it when the style is cleared.
    var styleStrength: Double = 1.0

    /// The Style's texture (`StyleTexture` id: "soft", "glow", "film"), `""` = none. Adds render-time nudges to the detail
    /// stages (Texture/Clarity/Sharpen, plus Glow's bloom) — never the user's own sliders. An id this build does not know
    /// renders as none but is kept. INDEPENDENT of `styleStrength` (which scales the tone/colour preset and pad). Purely
    /// additive: absent decodes to `""`.
    var styleTexture: String = ""

    /// 0...1, scales the texture's nudges exactly linearly. NON-ZERO identity default (1.0), decoded with `?? 1.0`.
    /// Meaningful only while a texture is chosen; the UI resets it when the texture is cleared with Grain off.
    var styleTextureAmount: Double = 1.0

    /// The Style's Grain toggle: adds a fixed film-grain amount (`StyleMath.toggleGrainAmount`) on top of the user's own
    /// Grain slider, through the same Grain stage (so it is deferred after output sharpening on export like any grain).
    var styleGrain: Bool = false

    /// "Protect skin": hold the style's COLOUR changes (saturation/vibrance/tints) back on detected skin, keeping its tone
    /// changes. Off by default. While on, `styleSkinMaskPNG` holds the raster that says where skin is; turning it off clears
    /// the raster and revision together (a stranded one would make a photo look edited and cost bytes for nothing), so re-enabling re-detects. That clearing is enforced by `ImageDocumentModel` (Styles v3 commit 5), not by this struct.
    var styleProtectSkin: Bool = false

    /// 0...1, how much of the protection applies (1 = the style's colour changes are fully held back on skin). NON-ZERO
    /// identity default (1.0), decoded with `?? 1.0` (the `lookIntensity`/`transformScale` hazard class).
    var styleProtectAmount: Double = 1.0

    /// The skin raster (`SkinMaskGenerator`): 8-bit grayscale PNG, row 0 = the TOP of the oriented SOURCE frame, stretched over
    /// the photo at render time. PERSISTED rather than recomputed per render: Vision's first call costs seconds and its output
    /// is not guaranteed stable across OS versions (replay determinism). Photo-specific like `masks`, so Presets and Paste do
    /// NOT carry it; `comparisonOriginal()` clears it.
    var styleSkinMaskPNG: Data?

    /// The Vision revision that produced `styleSkinMaskPNG` (recorded, never trusted at render time).
    var styleSkinMaskRevision: Int?

    // MARK: - RAW (CIRAWFilter-native)

    /// Core Image's own RAW tone-curve strength — configures `CIRAWFilter`
    /// itself (`boostAmount`, 0...1, default 1: linear/no-curve at 0, full
    /// curve at 1), upstream of `EditPipeline`, not a pipeline stage.
    ///
    /// STRUCTURALLY UNLIKE EVERY OTHER FIELD ABOVE: `EditPipeline` never
    /// reads this. Changing it can only take effect by RE-DECODING the
    /// file — re-running `EditPipeline` against the already-materialized
    /// buffer does nothing (see `RawDecoder.materialize`'s "forward
    /// hazard for slice 2" note, which predicted exactly this).
    /// `ImageDocumentModel.editState`'s `didSet` is what re-decodes;
    /// `requiresRawRedecode(comparedTo:)` below is the one place that
    /// knows which fields behave this way.
    ///
    /// Ignored outright for non-RAW files. Default `1.0` measured LIVE
    /// against `CIRAWFilter`'s own default on a real Nikon D610 NEF
    /// (matches the SDK header's own documented default) — not assumed
    /// — so an untouched photo decodes byte-for-byte as it did before
    /// this field existed. `lensCorrectionEnabled` was the original
    /// slice-2 candidate but was measured DEAD on this camera+lens
    /// combination (`CIRAWFilter.isLensCorrectionSupported == false` on
    /// all three sampled files) before any code was written — deferred
    /// to a future slice, not shipped as a no-op toggle.
    var boostAmount: Double = 1.0

    /// Additive EV offset applied via `CIRAWFilter.exposure` — a
    /// DIFFERENT property from `baselineExposure` (the camera-profile
    /// exposure the decoder bakes in per-file). `exposure`'s own SDK
    /// header declares a fixed default of `0`, independent of any camera
    /// profile — confirmed live: `0.0` on three real Nikon D610 NEFs
    /// whose `baselineExposure` all read `0.3`. So this field IS absolute,
    /// unlike `shadowBoostScale` below — no read-modify-write, no
    /// per-file base to reason about, and no exception to this file's
    /// determinism invariant (replaying the same params always renders
    /// the same pixels, independent of camera profile or decoder
    /// version). An earlier draft of this field mutated `baselineExposure`
    /// with `+=` instead — reviewer-caught: measured live that `exposure`
    /// and `baselineExposure` combine additively inside `CIRAWFilter`
    /// (`filter.exposure = 2.0` and `filter.baselineExposure += 2.0`
    /// produced BYTE-IDENTICAL pixels on the same file), so `exposure`
    /// gives the identical rendered result with none of the
    /// read-modify-write hazard.
    ///
    /// Distinct from `exposureEV`, which is post-decode `CIExposureAdjust`
    /// gain — NOT a duplicate control. Measured at +2 EV on the same
    /// file: this clips nothing (max channel 0.9907, zero of 1600 sampled
    /// points above 1.0) because the decoder folds it into its own tone
    /// curve, while `exposureEV` at +2 pushes 99 of 1600 sampled points
    /// past 1.0 (max 1.9506). Decoder-level exposure buys highlight
    /// headroom that post-decode gain cannot.
    ///
    /// Same structural caveat as `boostAmount`: `EditPipeline` never
    /// reads this; it only takes effect by re-decoding.
    var rawExposureEV: Double = 0

    /// Multiplicative scale on the file's OWN `boostShadowAmount` (the
    /// decoder's built-in shadow lift). `1` = untouched, `0` = lift fully
    /// off. Relative, unlike `rawExposureEV` above, because
    /// `boostShadowAmount` genuinely IS per-file: measured `0.9` on four
    /// real D610 NEFs, against the SDK header's own declared default of
    /// `1` (not `0` — an earlier draft of this comment mis-cited the
    /// header; the anomaly is real but smaller than first stated: 0.9 vs.
    /// a declared 1, not vs. 0). An absolute field with a fixed default
    /// would still silently override each file's own camera profile on
    /// every load, same reasoning as `boostAmount`'s own doc comment.
    ///
    /// Deliberately a 0...1 SCALE rather than an absolute 0...2 slider
    /// matching `CIRAWFilter`'s own declared range, because the upward
    /// half of that range was measured inert: mean linear luma over the
    /// darkest quartile moved -31% going native→0, but only +3.5% going
    /// native→2.0, with 1.4 and 2.0 rendering identically. Exposing
    /// travel that does nothing would repeat the exact mistake
    /// `lensCorrectionEnabled` avoided by being measured unsupported
    /// before shipping.
    ///
    /// Reviewer-caught: the SDK header states this control "has no
    /// effect if the boostAmount is 0" — so it is a genuinely dead
    /// control whenever `boostAmount == 0`. `AdjustTabView`'s Shadow
    /// Boost row disables itself in that case rather than silently doing
    /// nothing.
    ///
    /// Same structural caveat as `boostAmount`: `EditPipeline` never
    /// reads this; it only takes effect by re-decoding.
    var shadowBoostScale: Double = 1.0

    /// At most ONE element: `[]` means "no RAW-native neutral point set"
    /// (the identity/default state, matching `redEyePoints`' own
    /// empty-means-off convention even though — unlike that field's
    /// genuine multi-point accumulation — this one's real invariant is
    /// 0-or-1, never more; a new tap always REPLACES the entry, never
    /// appends).
    ///
    /// ONLY ever written by `ImageDocumentModel.pickWhiteBalance`, and
    /// only when ALL of: the photo is RAW; `isGeometryAtIdentity` (below)
    /// is true; and the file's own EXIF orientation was CONFIRMED `.up`
    /// at load time (`ImageDocumentModel.currentRawOrientationIsUp` — an
    /// UNREADABLE orientation does NOT qualify, deliberately: it could
    /// just as easily be non-`.up`, and defaulting it to `.up` would
    /// reopen exactly the ordering hazard below) — the one combination
    /// where a screen tap maps onto this coordinate space with NO
    /// inverse-geometry or
    /// inverse-orientation transform needed. Measured live: setting
    /// `CIRAWFilter.neutralLocation` to identical coordinates produced a
    /// DIFFERENT (implausible) result when `orientation` was already
    /// non-`.up` at that moment vs. left at its default — rather than
    /// work out that interaction in general, the eligibility check
    /// avoids it entirely by only firing in the one regime where "RAW
    /// native pixel space" and "what's on screen" are the same thing by
    /// construction (confirmed live: `nativeSize` and
    /// `outputImage.extent` matched exactly when orientation is `.up`).
    /// Falls back to the existing `WhiteBalanceSolver` search otherwise,
    /// unchanged.
    ///
    /// Deliberately NOT a thin translation of the app's own
    /// `whiteBalanceTemperature`/`whiteBalanceTint` fields: measured live
    /// that `CIRAWFilter`'s computed `neutralTemperature`/`neutralTint`
    /// for a tapped point do NOT neutralize the same pixel when fed
    /// directly into those fields (they're applied via a completely
    /// different filter, `CITemperatureAndTint`, in a different
    /// convention — see `EditPipeline.applyWhiteBalance`'s own doc
    /// comment). This field configures `CIRAWFilter` itself instead, the
    /// same architecture as the other three RAW-native fields below.
    ///
    /// Composes safely with `WhiteBalanceSolver`'s search without any
    /// extra invalidation logic: that search always samples whatever
    /// `currentImage` actually IS at tap time — including an
    /// already-neutralized-by-this-field image — so a LATER slow-path
    /// tap (e.g. after the user adds a crop) just measures and corrects
    /// the residual, converging toward identity rather than
    /// double-correcting. Once set, this point stays anchored to the
    /// RAW's own native grid regardless of geometry added afterward
    /// (crop/straighten run post-decode, so they never invalidate it) —
    /// only a new tap or Revert (`EditState()`'s literal default) clears
    /// it.
    ///
    /// Same structural caveat as the other three RAW-native fields:
    /// `EditPipeline` never reads this; it only takes effect by
    /// re-decoding.
    var rawWhiteBalanceNeutralPoints: [RawNeutralPoint] = []

    /// Additive offset on the file's OWN `luminanceNoiseReductionAmount`
    /// (CIRAWFilter's own pre-demosaic luminance noise reduction). `0` =
    /// untouched. NOT a multiplicative scale like `shadowBoostScale` —
    /// reviewer-caught: an earlier draft WAS a `0...1` scale (`1` =
    /// untouched, `0` = off), but this camera's own native
    /// `luminanceNoiseReductionAmount` measures `0.0` — so `native * 0`
    /// is `0` REGARDLESS of the scale, making that shape a provably dead
    /// control across its ENTIRE range on any file with a zero native
    /// default, exactly the trap `lensCorrectionEnabled` was deferred to
    /// avoid in slice 2, just discovered one slice later instead of
    /// before shipping. An additive offset has no such degenerate case —
    /// confirmed live that an ABSOLUTE assignment of `1.0` DOES move real
    /// pixels (a measured, non-zero delta on a real NEF), so there is
    /// genuinely useful range above this camera's own native `0.0`; an
    /// offset reaches it (`native + offset`, clamped to the property's
    /// own `0...1` valid range) where a scale never could.
    ///
    /// Per-file-camera-profile reason for being relative, not absolute,
    /// is otherwise identical to `shadowBoostScale`'s (SDK header
    /// documents this default "varies per image"). Guarded to only
    /// mutate when `!= 0` — same structural-no-op requirement as every
    /// other read-modify-write RAW-native field.
    ///
    /// Distinct from the existing post-decode `noiseReduction` field
    /// (`CINoiseReduction`, any photo type) — this one runs at DECODE
    /// time, on the RAW sensor data before demosaic, architecturally
    /// upstream of and independent from that stage; the two compose
    /// additively rather than conflicting, same as `rawExposureEV`
    /// composing with `exposureEV`.
    ///
    /// Same structural caveat as the other RAW-native fields:
    /// `EditPipeline` never reads this; it only takes effect by
    /// re-decoding.
    var rawLuminanceNoiseReductionAdjust: Double = 0

    /// Multiplicative scale on the file's OWN `colorNoiseReductionAmount`
    /// (CIRAWFilter's own pre-demosaic chroma noise reduction). Same
    /// shape, same reasoning, same per-file-default caveat as
    /// `shadowBoostScale` — measured `0.5` on three real D610 NEFs (a
    /// meaningfully non-zero default, confirmed live to be effectively
    /// scaled by `*=`, UNLIKE `rawLuminanceNoiseReductionAdjust` above —
    /// a multiplicative scale genuinely works here specifically because
    /// this camera's native default isn't zero). Known limitation of the
    /// scale shape: can only ever REDUCE color NR below this camera's
    /// own `0.5` native ceiling, never increase it — accepted, since (a)
    /// it wasn't measured to have useful range above native the way
    /// luminance NR did, and (b) a future camera with a genuinely
    /// zero-or-near-zero native default here would hit the same dead-
    /// range trap `rawLuminanceNoiseReductionAdjust`'s doc comment
    /// describes — re-measure before assuming this shape still holds on
    /// a different camera.
    var rawColorNoiseReductionScale: Double = 1.0

    /// Multiplicative scale on the file's OWN `sharpnessAmount`
    /// (CIRAWFilter's own pre-demosaic edge sharpening). Same shape,
    /// same reasoning, same per-file-default caveat and same "can only
    /// reduce, not increase beyond this camera's native ceiling"
    /// limitation as `rawColorNoiseReductionScale` above — measured
    /// `0.9` on three real D610 NEFs (also meaningfully non-zero,
    /// confirmed live to be effectively scaled). Distinct from the
    /// existing post-decode `sharpness` field (`CISharpenLuminance`) for
    /// the same reason `rawExposureEV` is distinct from `exposureEV` —
    /// decode-time vs. post-decode, additive not conflicting.
    var rawSharpnessScale: Double = 1.0

    /// Additive offset on the file's OWN `contrastAmount` (CIRAWFilter's
    /// pre-demosaic local/edge contrast). `0` = untouched. ADDITIVE, not
    /// a multiplicative scale like `shadowBoostScale`/
    /// `rawColorNoiseReductionScale` — this camera's own native
    /// `contrastAmount` measures `0.0` (same per-file-camera-profile
    /// pattern as every other RAW-native field; SDK header documents
    /// this varies per image), so a scale would be dead across its
    /// entire range, the exact trap `rawLuminanceNoiseReductionAdjust`
    /// hit in slice 5. Confirmed live: absolute `1.0` moves substantial
    /// real pixels (the largest single-field delta measured in this
    /// app's RAW-native work). Clamped so `native + adjust` stays within
    /// the property's own declared `0...1` range.
    ///
    /// Reviewer-noted asymmetry, accepted not fixed: since this camera's
    /// own native value is `0.0` (the property's own floor), the NEGATIVE
    /// half of this field's `-1...1` range is inert HERE (`max(0, 0 +
    /// negative) == 0`) — the same shape of measured-dead travel that
    /// motivated `rawMoireReductionAdjust`'s narrower UI range below.
    /// Kept symmetric anyway, unlike that field, because a camera with a
    /// genuinely non-zero native default (as the SDK header's own "varies
    /// per image" wording implies exists) would have real use for the
    /// negative half — this is camera-generic design, not a UI/UX call
    /// about THIS camera's own inert range the way the moiré cap was.
    ///
    /// Same structural caveat as the other RAW-native fields:
    /// `EditPipeline` never reads this; it only takes effect by
    /// re-decoding.
    var rawContrastAdjust: Double = 0

    /// Additive offset on the file's OWN `detailAmount` (CIRAWFilter's
    /// pre-demosaic edge/detail enhancement). Same shape and reasoning
    /// as `rawContrastAdjust` above — measured native `0.0` on this
    /// camera, confirmed live that absolute `3.0` (this property's own
    /// declared max) moves substantial real pixels. Clamped so
    /// `native + adjust` stays within the property's own declared
    /// `0...3` range — wider than most RAW-native fields, matching the
    /// SDK's own declared span for this one.
    var rawDetailAdjust: Double = 0

    /// Additive offset on the file's OWN `moireReductionAmount`
    /// (CIRAWFilter's pre-demosaic moiré-artifact reduction). Same
    /// per-file-default reasoning as the other two. UNLIKE them, the
    /// UI-facing range is DELIBERATELY narrower than the property's own
    /// true valid range: the SDK header declares `0...1` but that's
    /// contradicted by its own comment text ("3 indicates maximum") and
    /// by measurement — the property genuinely accepts and retains
    /// values up to `3.0` (confirmed live, no clamping on readback). But
    /// the measured EFFECT saturates hard near `1.0` (delta grew only
    /// ~3% across the entire `1.0...3.0` span) — the same inert-long-
    /// tail pattern `boostShadowAmount` showed in slice 3. Exposing that
    /// dead travel would repeat the exact mistake this project has
    /// already caught and fixed twice (`boostShadowAmount`'s upper half
    /// in slice 3, `rawLuminanceNoiseReductionAdjust`'s multiplicative
    /// shape in slice 5) — so the clamp here is `-1...1` even though
    /// `CIRAWFilter` itself would accept a wider range without
    /// complaint.
    ///
    /// Same structural caveat as the other RAW-native fields:
    /// `EditPipeline` never reads this; it only takes effect by
    /// re-decoding.
    var rawMoireReductionAdjust: Double = 0

    /// The exact `CIRAWFilter.decoderVersion` string (e.g. `"7"`) pinned
    /// at this photo's FIRST decode — `""` means "not yet pinned, use
    /// whatever's currently newest" (the identity/default state for a
    /// never-opened RAW photo, or any non-RAW photo, which never reads
    /// this at all).
    ///
    /// UNLIKE every other RAW-native field, this is never a user-facing
    /// slider — `CIRAWFilter.decoderVersion` defaults to "the newest
    /// available decoder for the image type" on its own (confirmed live,
    /// SDK header), so there's no "opt in to get newer" action to
    /// expose. The problem this field solves is the opposite: WITHOUT
    /// pinning, replaying the exact same `EditState` after a future
    /// macOS/Core Image update could silently decode differently, once
    /// "newest" means a different version than it did when the photo
    /// was first edited — the one documented exception to this app's
    /// own "replaying the same params must be deterministic" principle,
    /// logged back in Phase 6 slice 1 and closed here. Confirmed live
    /// the setting isn't cosmetic: switching this camera's decoder from
    /// its own default (version 7) to version 6 produced a substantial
    /// measured pixel delta (57790, 256×256 region) — a genuinely
    /// different demosaic algorithm, not a rounding difference.
    ///
    /// Written by `ImageDocumentModel.load(from:)` — only when a RAW
    /// photo's restored `EditState` has this field still empty (no prior
    /// sidecar value to respect), so the pin, once set, is never silently
    /// overwritten there. Also carried forward (not reset) by
    /// `revertToOriginal()`, the one deliberate exception to that
    /// method's usual "reset every RAW-native field to identity"
    /// behavior — see its own doc comment.
    ///
    /// Deliberately EXCLUDED from any user-facing "is this photo edited?"
    /// check (e.g. what gates the Revert-to-Original button) — see
    /// `isEffectivelyIdentity` below, which every such call site must use
    /// instead of a bare `== .identity`/`!= .identity` comparison once a
    /// RAW photo carries a pin. This field is invisible bookkeeping, not
    /// a user edit, and must never make an otherwise-untouched photo
    /// appear "edited."
    ///
    /// Same structural caveat as the other RAW-native fields:
    /// `EditPipeline` never reads this; it only takes effect by
    /// re-decoding.
    var rawDecoderVersionPin: String = ""

    /// True when every geometric transform (straighten/perspective/
    /// transform-scale/crop/flip) is at its identity value — the exact
    /// field GROUP already
    /// named together in `comparisonOriginal()`/`applyingPreset()`'s own
    /// comments. Pure and independently testable without a RAW fixture,
    /// unlike most of this feature — used by
    /// `ImageDocumentModel.pickWhiteBalance` to decide whether a screen
    /// tap maps 1:1 onto RAW-native pixel coordinates (see
    /// `rawWhiteBalanceNeutralPoints`'s own doc comment).
    var isGeometryAtIdentity: Bool {
        straightenAngle == 0
            && verticalPerspective == 0
            && horizontalPerspective == 0
            && transformScale == 1
            && transformAspect == 0
            && !flipHorizontal
            && !flipVertical
            && cropInsetTop == 0
            && cropInsetBottom == 0
            && cropInsetLeft == 0
            && cropInsetRight == 0
    }

    /// An `EditState()` with only THIS state's geometry (the same field
    /// group `isGeometryAtIdentity` just above checks) copied over —
    /// everything else, including white balance, left at identity. Used by
    /// any whole-image statistical analysis (`ImageDocumentModel.
    /// fixColorCast`/`autoTone`) that needs to sample the image as WB/
    /// Exposure/tone would first see it: those stages don't change extent,
    /// so a render of this state still shares the real render's exact
    /// coordinate space, and geometry (crop especially) still needs to be
    /// applied so the analysis doesn't include content the user already
    /// cropped away. Extracted from `fixColorCast`'s own original inline
    /// field list, which `autoTone` would otherwise have had to duplicate.
    func geometryOnlySamplingState() -> EditState {
        var s = EditState()
        s.straightenAngle = straightenAngle
        s.verticalPerspective = verticalPerspective
        s.horizontalPerspective = horizontalPerspective
        s.transformScale = transformScale
        s.transformAspect = transformAspect
        s.flipHorizontal = flipHorizontal
        s.flipVertical = flipVertical
        s.cropInsetTop = cropInsetTop
        s.cropInsetBottom = cropInsetBottom
        s.cropInsetLeft = cropInsetLeft
        s.cropInsetRight = cropInsetRight
        return s
    }

    /// True if `other` differs from `self` in any field that can ONLY
    /// take effect by re-running `RawDecoder.decode` — i.e. that
    /// configures `CIRAWFilter` itself rather than being an
    /// `EditPipeline` stage. `ImageDocumentModel`'s `editState` `didSet`
    /// is the only caller. `RawDecoder.applyRawNativeSettings` is the
    /// other place this exact field set is enumerated — keep both in
    /// sync.
    func requiresRawRedecode(comparedTo other: EditState) -> Bool {
        boostAmount != other.boostAmount
            || rawExposureEV != other.rawExposureEV
            || shadowBoostScale != other.shadowBoostScale
            || rawWhiteBalanceNeutralPoints != other.rawWhiteBalanceNeutralPoints
            || rawLuminanceNoiseReductionAdjust != other.rawLuminanceNoiseReductionAdjust
            || rawColorNoiseReductionScale != other.rawColorNoiseReductionScale
            || rawSharpnessScale != other.rawSharpnessScale
            || rawContrastAdjust != other.rawContrastAdjust
            || rawDetailAdjust != other.rawDetailAdjust
            || rawMoireReductionAdjust != other.rawMoireReductionAdjust
            || rawDecoderVersionPin != other.rawDecoderVersionPin
    }

    /// The no-op edit state: every adjustment at its default (identity) value.
    static let identity = EditState()

    /// True when this state is identity in every respect a USER can
    /// perceive — i.e. `== .identity` except that `rawDecoderVersionPin`
    /// is ignored. Phase 6 slice 7 review (round 2) caught a real bug a
    /// bare `== .identity` comparison introduces once RAW photos always
    /// carry a pin from their very first open: the Revert-to-Original
    /// button (`ContentView`) would read as permanently enabled for every
    /// RAW photo — including a never-touched one — since `editState`
    /// would never again equal literal identity. Every call site that
    /// means "has the user made any visible edit," not "is this struct
    /// bit-for-bit its default," must use this instead of the raw
    /// equality/inequality operator. (`ThumbnailGenerator`'s own
    /// `!= .identity` fast-path check is a deliberate exception — see its
    /// own comment — because that fast path deliberately decodes
    /// UNPINNED, so treating a pinned-but-otherwise-identity photo as
    /// "identity" there would decode the grid thumbnail with a different
    /// decoder version than the Editor uses.)
    var isEffectivelyIdentity: Bool {
        var copy = self
        copy.rawDecoderVersionPin = ""
        return copy == .identity
    }

    /// This state with its Look and Style put back to their defaults — `lookID`/`lookIntensity` and EVERY `style*` field
    /// (preset, pad, strength, texture, grain, skin protection and its raster/revision) — and everything else untouched.
    /// The ONE list of those fields for the Looks tab's reset: `isLookAndStyleAtIdentity` is defined through it, so the
    /// reset and the "is there anything to reset" check cannot drift apart. Defaults come from `EditState()` itself, so a
    /// non-zero identity default (`lookIntensity`, `styleStrength`, `styleTextureAmount`, `styleProtectAmount`) is never
    /// hand-copied. A NEW look/style field must be added here: `EditStateLookStyleResetTests` compares the
    /// `look*`/`style*` stored properties (via `Mirror`) with its table and fails for any new one, which forces both entries.
    /// Its blind spot is a new field WITHOUT the `look`/`style` prefix.
    func resettingLookAndStyle() -> EditState {
        let d = EditState()
        var s = self
        s.lookID = d.lookID; s.lookIntensity = d.lookIntensity
        s.styleID = d.styleID; s.styleTone = d.styleTone; s.styleColor = d.styleColor; s.styleStrength = d.styleStrength
        s.styleTexture = d.styleTexture; s.styleTextureAmount = d.styleTextureAmount; s.styleGrain = d.styleGrain
        s.styleProtectSkin = d.styleProtectSkin; s.styleProtectAmount = d.styleProtectAmount
        s.styleSkinMaskPNG = d.styleSkinMaskPNG; s.styleSkinMaskRevision = d.styleSkinMaskRevision
        return s
    }

    /// True when the Look and Style are at their defaults (nothing for the Looks tab's "Reset Look & Style" to do).
    var isLookAndStyleAtIdentity: Bool { self == resettingLookAndStyle() }

    /// The "original" side for the Compare feature: the CURRENT geometry
    /// (crop/straighten/perspective/transformScale/transformAspect/flip) is
    /// KEPT — copied via `var s =
    /// self` below — so both compared images share one extent and align
    /// pixel-for-pixel, while every color/tone adjustment is reset to its
    /// identity value. The Adjust tab's `resetAdjustmentsButton` field list plus the Looks tab's look/style fields
    /// (`resettingLookAndStyle()`), PLUS clearing
    /// `redEyePoints` AND `retouchSpots` (pixel repair is retouching: the "before" side shows none) — a real
    /// difference, not an oversight, in red-eye's case:
    /// `EditPipeline`'s red-eye stage is active whenever `redEyePoints`
    /// is non-empty AND `redEyeStrength != 0`, and the identity/default
    /// `redEyeStrength` (0.7) is non-zero, so merely resetting the
    /// sliders (as the Reset Adjustments button intentionally does,
    /// leaving user-placed points alone) would still show red-eye
    /// correction applied on the "original" side — wrong for a view
    /// whose whole point is "zero retouching." This makes
    /// `comparisonOriginal()` a superset of `resetAdjustmentsButton`'s
    /// reset, not identical to it.
    func comparisonOriginal() -> EditState {
        var s = self
        // light/tone
        s.exposureEV = 0
        s.brightness = 0
        s.brilliance = 0
        s.contrast = 0
        s.curvesHighlights = 0
        s.curvesShadows = 0
        s.blackPoint = 0
        s.whites = 0
        // Cleared: Compare's "original" means zero tone edits, and a
        // surviving point curve would show tone shaping on the BEFORE side.
        // Safe for this method's pixel-alignment guarantee — the point
        // curve stage is extent-preserving, the same argument already made
        // for `masks`. Same reasoning for the three per-channel curves.
        s.toneCurvePoints = []
        s.toneCurvePointsRed = []
        s.toneCurvePointsGreen = []
        s.toneCurvePointsBlue = []
        s.levelsBlackPoint = 0
        s.levelsWhitePoint = 1
        s.levelsGamma = 1.0
        // white balance
        s.whiteBalanceTemperature = 6500
        s.whiteBalanceTint = 0
        // hsl / color
        s.hslHue = 0
        s.vibrance = 0
        s.hslSaturation = 0
        // selective color (range + all 8 bands' hue/saturation/luminance)
        s.selectiveColorRange = 0.5
        s.redHue = 0; s.redSaturation = 0; s.redLuminance = 0
        s.orangeHue = 0; s.orangeSaturation = 0; s.orangeLuminance = 0
        s.yellowHue = 0; s.yellowSaturation = 0; s.yellowLuminance = 0
        s.greenHue = 0; s.greenSaturation = 0; s.greenLuminance = 0
        s.aquaHue = 0; s.aquaSaturation = 0; s.aquaLuminance = 0
        s.blueHue = 0; s.blueSaturation = 0; s.blueLuminance = 0
        s.purpleHue = 0; s.purpleSaturation = 0; s.purpleLuminance = 0
        s.magentaHue = 0; s.magentaSaturation = 0; s.magentaLuminance = 0
        // black & white + effects
        s.blackAndWhite = false
        s.grayMixRed = 0
        s.grayMixOrange = 0
        s.grayMixYellow = 0
        s.grayMixGreen = 0
        s.grayMixAqua = 0
        s.grayMixBlue = 0
        s.grayMixPurple = 0
        s.grayMixMagenta = 0
        s.bwIntensity = 0; s.bwNeutrals = 0; s.bwTone = 0; s.bwGrain = 0
        s.shadowHue = 0; s.shadowSaturation = 0; s.shadowLuminance = 0
        s.midtoneHue = 0; s.midtoneSaturation = 0; s.midtoneLuminance = 0
        s.highlightHue = 0; s.highlightSaturation = 0; s.highlightLuminance = 0
        s.colorGradingBlending = 0; s.colorGradingBalance = 0
        s.globalHue = 0; s.globalSaturation = 0; s.globalLuminance = 0
        s.vignetteStrength = 0
        s.vignetteRadius = 0.5
        s.vignetteSoftness = 0
        s.texture = 0
        s.clarity = 0
        s.dehaze = 0
        s.sharpness = 0
        s.noiseReduction = 0
        s.defringePurple = 0
        s.defringeGreen = 0
        s.grain = 0
        s = s.resettingLookAndStyle() // look + every style field, one shared list
        // red-eye: reset sliders AND clear points (see doc comment above)
        s.redEyeSize = 0.5
        s.redEyeStrength = 0.7
        s.redEyePoints.removeAll()
        s.retouchSpots.removeAll() // pixel repair is retouching: the "before" side shows none
        // masks: retouching/stylization, same reasoning as redEyePoints
        // just above — a non-identity mask is unconditionally active (no
        // non-zero-default subtlety to argue, unlike red-eye), so leaving
        // it would obviously break this method's "zero retouching" contract.
        // Safe to clear without touching extent: `applyMasks` is
        // extent-preserving, which is exactly what this method's own
        // pixel-alignment guarantee (see the doc comment above) depends on.
        s.masks.removeAll()
        // pointColors: same retouching/stylization reasoning as masks
        // just above. `applyPointColors` is extent-preserving too (a
        // sequential kernel pass over the whole extent, no crop/resize),
        // so clearing it here is safe by the same pixel-alignment
        // argument this method's own doc comment makes for masks.
        s.pointColors.removeAll()
        // geometry (cropInset*, straightenAngle, verticalPerspective,
        // horizontalPerspective, transformScale, transformAspect,
        // flipHorizontal, flipVertical) is left untouched — inherited from
        // `self` via `var s = self` above.
        // `boostAmount`/`rawExposureEV`/`shadowBoostScale`/
        // `rawWhiteBalanceNeutralPoints`/`rawLuminanceNoiseReductionAdjust`/
        // `rawColorNoiseReductionScale`/`rawSharpnessScale`/
        // `rawContrastAdjust`/`rawDetailAdjust`/`rawMoireReductionAdjust`/
        // `rawDecoderVersionPin` are ALSO left untouched, for a different
        // reason: `EditPipeline`
        // never reads any of them at all (see their own doc comments), so resetting them here
        // couldn't be honored by either side of the Compare render
        // anyway — inherit them rather than set a
        // value this method has no way to actually apply.
        return s
    }

    /// Applies `self` as a saved preset onto `target`, returning the merged
    /// result. Every field `comparisonOriginal()` resets to identity gets
    /// copied from `self` (the preset) instead; everything that method
    /// leaves untouched — crop/straighten/perspective/transformScale/
    /// transformAspect/flip geometry, and `redEyePoints` itself — is
    /// preserved from `target`, since both are
    /// specific to ONE photo's composition/face positions, never part of a
    /// reusable "look". Deliberately reuses `comparisonOriginal()`'s exact
    /// field partition (see its own doc comment for the full reasoning)
    /// rather than re-deriving a second list that could drift out of sync.
    func applyingPreset(onto target: EditState) -> EditState {
        var result = target
        // light/tone
        result.exposureEV = exposureEV
        result.brightness = brightness
        result.brilliance = brilliance
        result.contrast = contrast
        result.curvesHighlights = curvesHighlights
        result.curvesShadows = curvesShadows
        result.blackPoint = blackPoint
        result.whites = whites
        // COPIED, unlike `redEyePoints`/`masks`. A tone curve is the
        // archetypal reusable look, and this is the first variable-length
        // field the preset path copies — so the rule is not "arrays are
        // photo-specific", it is "PLACEMENT is photo-specific": eye
        // positions and mask geometry belong to one photo, a tone curve
        // does not. Same reasoning for the three per-channel curves.
        result.toneCurvePoints = toneCurvePoints
        result.toneCurvePointsRed = toneCurvePointsRed
        result.toneCurvePointsGreen = toneCurvePointsGreen
        result.toneCurvePointsBlue = toneCurvePointsBlue
        result.levelsBlackPoint = levelsBlackPoint
        result.levelsWhitePoint = levelsWhitePoint
        result.levelsGamma = levelsGamma
        // white balance
        result.whiteBalanceTemperature = whiteBalanceTemperature
        result.whiteBalanceTint = whiteBalanceTint
        // hsl / color
        result.hslHue = hslHue
        result.vibrance = vibrance
        result.hslSaturation = hslSaturation
        // selective color (range + all 8 bands' hue/saturation/luminance)
        result.selectiveColorRange = selectiveColorRange
        result.redHue = redHue; result.redSaturation = redSaturation; result.redLuminance = redLuminance
        result.orangeHue = orangeHue; result.orangeSaturation = orangeSaturation; result.orangeLuminance = orangeLuminance
        result.yellowHue = yellowHue; result.yellowSaturation = yellowSaturation; result.yellowLuminance = yellowLuminance
        result.greenHue = greenHue; result.greenSaturation = greenSaturation; result.greenLuminance = greenLuminance
        result.aquaHue = aquaHue; result.aquaSaturation = aquaSaturation; result.aquaLuminance = aquaLuminance
        result.blueHue = blueHue; result.blueSaturation = blueSaturation; result.blueLuminance = blueLuminance
        result.purpleHue = purpleHue; result.purpleSaturation = purpleSaturation; result.purpleLuminance = purpleLuminance
        result.magentaHue = magentaHue; result.magentaSaturation = magentaSaturation; result.magentaLuminance = magentaLuminance
        // black & white + effects
        result.blackAndWhite = blackAndWhite
        result.grayMixRed = grayMixRed
        result.grayMixOrange = grayMixOrange
        result.grayMixYellow = grayMixYellow
        result.grayMixGreen = grayMixGreen
        result.grayMixAqua = grayMixAqua
        result.grayMixBlue = grayMixBlue
        result.grayMixPurple = grayMixPurple
        result.grayMixMagenta = grayMixMagenta
        result.bwIntensity = bwIntensity; result.bwNeutrals = bwNeutrals; result.bwTone = bwTone; result.bwGrain = bwGrain
        result.shadowHue = shadowHue; result.shadowSaturation = shadowSaturation; result.shadowLuminance = shadowLuminance
        result.midtoneHue = midtoneHue; result.midtoneSaturation = midtoneSaturation; result.midtoneLuminance = midtoneLuminance
        result.highlightHue = highlightHue; result.highlightSaturation = highlightSaturation; result.highlightLuminance = highlightLuminance
        result.colorGradingBlending = colorGradingBlending; result.colorGradingBalance = colorGradingBalance
        result.globalHue = globalHue; result.globalSaturation = globalSaturation; result.globalLuminance = globalLuminance
        result.vignetteStrength = vignetteStrength
        result.vignetteRadius = vignetteRadius
        result.vignetteSoftness = vignetteSoftness
        result.texture = texture
        result.clarity = clarity
        result.dehaze = dehaze
        result.sharpness = sharpness
        result.noiseReduction = noiseReduction
        result.defringePurple = defringePurple
        result.defringeGreen = defringeGreen
        result.grain = grain
        // A look is the archetypal reusable look (unlike placement fields such as masks/red-eye points).
        result.lookID = lookID
        result.lookIntensity = lookIntensity
        // A style is reusable like a look (nudges + tints, no placement data), so Presets and Paste carry it.
        result.styleID = styleID
        result.styleTone = styleTone
        result.styleColor = styleColor
        result.styleStrength = styleStrength
        result.styleTexture = styleTexture
        result.styleTextureAmount = styleTextureAmount
        result.styleGrain = styleGrain
        // Skin protection is NOT carried (`styleProtectSkin`/`styleProtectAmount`/`styleSkinMaskPNG`/`styleSkinMaskRevision`):
        // the raster describes THIS photo's pixels, so the target keeps its own — a photo carrying a pasted style but never
        // detected skin simply renders the style unprotected.
        // red-eye correction INTENSITY only — `redEyePoints` (where the
        // corrections sit) stays `target`'s own, untouched.
        result.redEyeSize = redEyeSize
        result.redEyeStrength = redEyeStrength
        // geometry (cropInset*, straightenAngle, verticalPerspective,
        // horizontalPerspective, transformScale, transformAspect,
        // flipHorizontal, flipVertical), redEyePoints, retouchSpots, AND masks are NOT
        // copied — they stay `target`'s own via `var result = target`
        // above. `masks` joins `redEyePoints`
        // here for the identical reason: an ellipse placed on THIS photo's
        // subject is meaningless dropped onto another photo's target.
        // `boostAmount`/`rawExposureEV`/`shadowBoostScale`/
        // `rawWhiteBalanceNeutralPoints`/`rawLuminanceNoiseReductionAdjust`/
        // `rawColorNoiseReductionScale`/`rawSharpnessScale`/
        // `rawContrastAdjust`/`rawDetailAdjust`/`rawMoireReductionAdjust`/
        // `rawDecoderVersionPin` are ALSO not copied, for a different
        // reason: carrying them would make applying ANY preset
        // kick off a multi-second RAW re-decode (no other preset field
        // does that), and would silently set RAW-decode parameters on a
        // JPEG target — dead weight that also
        // defeats `ThumbnailGenerator`'s `editState != .identity` fast
        // path for an otherwise-unedited thumbnail. Presets are
        // cross-photo looks; these are per-decode technical settings,
        // not a look. `rawDecoderVersionPin` specifically must NEVER
        // carry across photos: forcing one photo's target to decode
        // with a DIFFERENT photo's pinned decoder version would be
        // actively wrong, not just inert.
        return result
    }
}

// MARK: - Custom decoding (schema-tolerant)

extension EditState {
    /// Swift's SYNTHESIZED `Decodable` (the default, used everywhere else in
    /// this codebase) throws `keyNotFound` the moment a single key is
    /// missing — it does NOT fall back to a property's declared default.
    /// This project adds new `EditState` fields almost every session; any
    /// sidecar file written today would fail to decode ENTIRELY (not just
    /// partially) the moment a future session adds one more field, unless
    /// decoding is tolerant of that from the start. This custom `init(from:)`
    /// uses `decodeIfPresent(...) ?? <declared default>` for every field, so
    /// an older/smaller sidecar decodes successfully with any missing field
    /// silently at its current default, and a newer/larger sidecar (read by
    /// older logic, hypothetically) decodes fine too since unknown keys are
    /// already harmlessly ignored by standard keyed decoding.
    ///
    /// Deliberately NOT pairing this with a custom `encode(to:)` — encoding
    /// a fully-in-memory `EditState` is never ambiguous, so Swift still
    /// synthesizes `Encodable` on its own (each `Codable` requirement is
    /// synthesized independently; providing `init(from:)` by hand doesn't
    /// prevent `encode(to:)` from still being auto-generated).
    private enum CodingKeys: String, CodingKey {
        case whiteBalanceTemperature, whiteBalanceTint
        case exposureEV
        case levelsBlackPoint, levelsWhitePoint, levelsGamma
        case brightness
        case contrast
        case curvesShadows, curvesHighlights, blackPoint, whites
        case toneCurvePoints
        case toneCurvePointsRed, toneCurvePointsGreen, toneCurvePointsBlue
        case brilliance
        case hslHue, hslSaturation
        case redHue, redSaturation, redLuminance
        case orangeHue, orangeSaturation, orangeLuminance
        case yellowHue, yellowSaturation, yellowLuminance
        case greenHue, greenSaturation, greenLuminance
        case aquaHue, aquaSaturation, aquaLuminance
        case blueHue, blueSaturation, blueLuminance
        case purpleHue, purpleSaturation, purpleLuminance
        case magentaHue, magentaSaturation, magentaLuminance
        case selectiveColorRange
        case vibrance
        case blackAndWhite
        case grayMixRed
        case grayMixOrange
        case grayMixYellow
        case grayMixGreen
        case grayMixAqua
        case grayMixBlue
        case grayMixPurple
        case grayMixMagenta
        case bwIntensity, bwNeutrals, bwTone, bwGrain
        case shadowHue, shadowSaturation, shadowLuminance
        case midtoneHue, midtoneSaturation, midtoneLuminance
        case highlightHue, highlightSaturation, highlightLuminance
        case colorGradingBlending, colorGradingBalance
        case globalHue, globalSaturation, globalLuminance
        case straightenAngle
        case verticalPerspective, horizontalPerspective
        case transformScale, transformAspect
        case flipHorizontal, flipVertical
        case cropInsetTop, cropInsetBottom, cropInsetLeft, cropInsetRight
        case redEyePoints, redEyeSize, redEyeStrength
        case retouchSpots
        case masks
        case pointColors
        case vignetteStrength, vignetteRadius, vignetteSoftness
        case texture, clarity, dehaze
        case noiseReduction
        case sharpness
        case defringePurple, defringeGreen
        case grain
        case lookID, lookIntensity
        case styleID, styleTone, styleColor, styleStrength
        case styleTexture, styleTextureAmount, styleGrain
        case styleProtectSkin, styleProtectAmount, styleSkinMaskPNG, styleSkinMaskRevision
        case boostAmount
        case rawExposureEV, shadowBoostScale, rawWhiteBalanceNeutralPoints
        case rawLuminanceNoiseReductionAdjust, rawColorNoiseReductionScale, rawSharpnessScale
        case rawContrastAdjust, rawDetailAdjust, rawMoireReductionAdjust
        case rawDecoderVersionPin
    }

    /// Keys this type NO LONGER writes but must still read, kept in their own
    /// enum rather than as extra `CodingKeys` cases on purpose: Swift's
    /// SYNTHESIZED `encode(to:)` (which this type still relies on — only
    /// `init(from:)` is hand-written) requires every `CodingKeys` case to
    /// have a matching stored property, so a property-less legacy case there
    /// would not compile. A second container also keeps the compatibility
    /// shim visibly separate from the live schema.
    ///
    /// - `definition`: the pre-split single local-contrast field, replaced by
    ///   `texture` + `clarity`. Decoded into `clarity` (see `init(from:)`).
    ///   Sidecars and presets written before the split still carry it.
    private enum LegacyCodingKeys: String, CodingKey {
        case definition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyDefinition = try legacyContainer.decodeIfPresent(Double.self, forKey: .definition)
        whiteBalanceTemperature = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceTemperature) ?? 6500
        whiteBalanceTint = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceTint) ?? 0
        exposureEV = try container.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        levelsBlackPoint = try container.decodeIfPresent(Double.self, forKey: .levelsBlackPoint) ?? 0
        levelsWhitePoint = try container.decodeIfPresent(Double.self, forKey: .levelsWhitePoint) ?? 1
        levelsGamma = try container.decodeIfPresent(Double.self, forKey: .levelsGamma) ?? 1
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        curvesShadows = try container.decodeIfPresent(Double.self, forKey: .curvesShadows) ?? 0
        curvesHighlights = try container.decodeIfPresent(Double.self, forKey: .curvesHighlights) ?? 0
        blackPoint = try container.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        // `try?`, DELIBERATELY DIFFERENT from the bare `try` that
        // `redEyePoints`/`masks`/`rawWhiteBalanceNeutralPoints` use below.
        // Every sidecar read wraps the whole decode in `try?`
        // (`ImageDocumentModel.loadSidecarIfReachable`, `PhotoExporter`), so
        // ONE throw anywhere in here discards EVERY edit on that photo.
        // `Mask.init(from:)` already makes this exact trade for
        // `brushPoints`. What makes it more reachable here: a tone curve is
        // the first array in this struct that is genuinely HUMAN-AUTHORABLE
        // — a short list of readable numbers describing a shape — and until
        // the editor ships, a hand-written sidecar is the ONLY way to set
        // one. Cost of `try?`: a malformed point drops the whole CURVE to
        // identity instead of the whole PHOTO to identity, which is
        // strictly the better failure. `ToneCurvePoint`'s own `Codable`
        // stays synthesized and STRICT on purpose — a tolerant element
        // decode defaulting a missing `y` to 0 would silently CORRUPT a
        // curve (the point becomes a black clamp at y=0) rather than
        // discard it.
        toneCurvePoints = (try? container.decodeIfPresent([ToneCurvePoint].self, forKey: .toneCurvePoints)) ?? nil ?? []
        // Same tolerant-per-field shape as `toneCurvePoints` above, and the
        // same reasoning: a malformed RED curve should drop only the red
        // curve, not the green/blue curves or the rest of the photo's edits.
        toneCurvePointsRed = (try? container.decodeIfPresent([ToneCurvePoint].self, forKey: .toneCurvePointsRed)) ?? nil ?? []
        toneCurvePointsGreen = (try? container.decodeIfPresent([ToneCurvePoint].self, forKey: .toneCurvePointsGreen)) ?? nil ?? []
        toneCurvePointsBlue = (try? container.decodeIfPresent([ToneCurvePoint].self, forKey: .toneCurvePointsBlue)) ?? nil ?? []
        brilliance = try container.decodeIfPresent(Double.self, forKey: .brilliance) ?? 0
        hslHue = try container.decodeIfPresent(Double.self, forKey: .hslHue) ?? 0
        hslSaturation = try container.decodeIfPresent(Double.self, forKey: .hslSaturation) ?? 0
        redHue = try container.decodeIfPresent(Double.self, forKey: .redHue) ?? 0
        redSaturation = try container.decodeIfPresent(Double.self, forKey: .redSaturation) ?? 0
        redLuminance = try container.decodeIfPresent(Double.self, forKey: .redLuminance) ?? 0
        orangeHue = try container.decodeIfPresent(Double.self, forKey: .orangeHue) ?? 0
        orangeSaturation = try container.decodeIfPresent(Double.self, forKey: .orangeSaturation) ?? 0
        orangeLuminance = try container.decodeIfPresent(Double.self, forKey: .orangeLuminance) ?? 0
        yellowHue = try container.decodeIfPresent(Double.self, forKey: .yellowHue) ?? 0
        yellowSaturation = try container.decodeIfPresent(Double.self, forKey: .yellowSaturation) ?? 0
        yellowLuminance = try container.decodeIfPresent(Double.self, forKey: .yellowLuminance) ?? 0
        greenHue = try container.decodeIfPresent(Double.self, forKey: .greenHue) ?? 0
        greenSaturation = try container.decodeIfPresent(Double.self, forKey: .greenSaturation) ?? 0
        greenLuminance = try container.decodeIfPresent(Double.self, forKey: .greenLuminance) ?? 0
        aquaHue = try container.decodeIfPresent(Double.self, forKey: .aquaHue) ?? 0
        aquaSaturation = try container.decodeIfPresent(Double.self, forKey: .aquaSaturation) ?? 0
        aquaLuminance = try container.decodeIfPresent(Double.self, forKey: .aquaLuminance) ?? 0
        blueHue = try container.decodeIfPresent(Double.self, forKey: .blueHue) ?? 0
        blueSaturation = try container.decodeIfPresent(Double.self, forKey: .blueSaturation) ?? 0
        blueLuminance = try container.decodeIfPresent(Double.self, forKey: .blueLuminance) ?? 0
        purpleHue = try container.decodeIfPresent(Double.self, forKey: .purpleHue) ?? 0
        purpleSaturation = try container.decodeIfPresent(Double.self, forKey: .purpleSaturation) ?? 0
        purpleLuminance = try container.decodeIfPresent(Double.self, forKey: .purpleLuminance) ?? 0
        magentaHue = try container.decodeIfPresent(Double.self, forKey: .magentaHue) ?? 0
        magentaSaturation = try container.decodeIfPresent(Double.self, forKey: .magentaSaturation) ?? 0
        magentaLuminance = try container.decodeIfPresent(Double.self, forKey: .magentaLuminance) ?? 0
        selectiveColorRange = try container.decodeIfPresent(Double.self, forKey: .selectiveColorRange) ?? 0.5
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        blackAndWhite = try container.decodeIfPresent(Bool.self, forKey: .blackAndWhite) ?? false
        grayMixRed = try container.decodeIfPresent(Double.self, forKey: .grayMixRed) ?? 0
        grayMixOrange = try container.decodeIfPresent(Double.self, forKey: .grayMixOrange) ?? 0
        grayMixYellow = try container.decodeIfPresent(Double.self, forKey: .grayMixYellow) ?? 0
        grayMixGreen = try container.decodeIfPresent(Double.self, forKey: .grayMixGreen) ?? 0
        grayMixAqua = try container.decodeIfPresent(Double.self, forKey: .grayMixAqua) ?? 0
        grayMixBlue = try container.decodeIfPresent(Double.self, forKey: .grayMixBlue) ?? 0
        grayMixPurple = try container.decodeIfPresent(Double.self, forKey: .grayMixPurple) ?? 0
        grayMixMagenta = try container.decodeIfPresent(Double.self, forKey: .grayMixMagenta) ?? 0
        bwIntensity = try container.decodeIfPresent(Double.self, forKey: .bwIntensity) ?? 0
        bwNeutrals = try container.decodeIfPresent(Double.self, forKey: .bwNeutrals) ?? 0
        bwTone = try container.decodeIfPresent(Double.self, forKey: .bwTone) ?? 0
        bwGrain = try container.decodeIfPresent(Double.self, forKey: .bwGrain) ?? 0
        shadowHue = try container.decodeIfPresent(Double.self, forKey: .shadowHue) ?? 0
        shadowSaturation = try container.decodeIfPresent(Double.self, forKey: .shadowSaturation) ?? 0
        shadowLuminance = try container.decodeIfPresent(Double.self, forKey: .shadowLuminance) ?? 0
        midtoneHue = try container.decodeIfPresent(Double.self, forKey: .midtoneHue) ?? 0
        midtoneSaturation = try container.decodeIfPresent(Double.self, forKey: .midtoneSaturation) ?? 0
        midtoneLuminance = try container.decodeIfPresent(Double.self, forKey: .midtoneLuminance) ?? 0
        highlightHue = try container.decodeIfPresent(Double.self, forKey: .highlightHue) ?? 0
        highlightSaturation = try container.decodeIfPresent(Double.self, forKey: .highlightSaturation) ?? 0
        highlightLuminance = try container.decodeIfPresent(Double.self, forKey: .highlightLuminance) ?? 0
        colorGradingBlending = try container.decodeIfPresent(Double.self, forKey: .colorGradingBlending) ?? 0
        colorGradingBalance = try container.decodeIfPresent(Double.self, forKey: .colorGradingBalance) ?? 0
        globalHue = try container.decodeIfPresent(Double.self, forKey: .globalHue) ?? 0
        globalSaturation = try container.decodeIfPresent(Double.self, forKey: .globalSaturation) ?? 0
        globalLuminance = try container.decodeIfPresent(Double.self, forKey: .globalLuminance) ?? 0
        straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0
        verticalPerspective = try container.decodeIfPresent(Double.self, forKey: .verticalPerspective) ?? 0
        horizontalPerspective = try container.decodeIfPresent(Double.self, forKey: .horizontalPerspective) ?? 0
        // `?? 1.0`, NOT `?? 0` — transformScale's identity is 1.0, not 0.
        // A sidecar predating this field must decode to "no scale applied",
        // not "scale the image to zero size."
        transformScale = try container.decodeIfPresent(Double.self, forKey: .transformScale) ?? 1.0
        transformAspect = try container.decodeIfPresent(Double.self, forKey: .transformAspect) ?? 0
        flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        cropInsetTop = try container.decodeIfPresent(Double.self, forKey: .cropInsetTop) ?? 0
        cropInsetBottom = try container.decodeIfPresent(Double.self, forKey: .cropInsetBottom) ?? 0
        cropInsetLeft = try container.decodeIfPresent(Double.self, forKey: .cropInsetLeft) ?? 0
        cropInsetRight = try container.decodeIfPresent(Double.self, forKey: .cropInsetRight) ?? 0
        redEyePoints = try container.decodeIfPresent([RedEyePoint].self, forKey: .redEyePoints) ?? []
        // Element-by-element: one corrupt spot is dropped, never the sidecar. Non-finite spots are dropped too
        // (a NaN in EditState would make every later sidecar write throw) and the cap is enforced.
        retouchSpots = Array(
            ((try? container.decodeIfPresent([LossyRetouchSpot].self, forKey: .retouchSpots)) ?? nil ?? [])
                .compactMap(\.spot).filter(\.isFinite).prefix(Self.maxRetouchSpots)
        ).withUniqueIDs()
        redEyeSize = try container.decodeIfPresent(Double.self, forKey: .redEyeSize) ?? 0.5
        redEyeStrength = try container.decodeIfPresent(Double.self, forKey: .redEyeStrength) ?? 0.7
        masks = try container.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        pointColors = try container.decodeIfPresent([PointColor].self, forKey: .pointColors) ?? []
        vignetteStrength = try container.decodeIfPresent(Double.self, forKey: .vignetteStrength) ?? 0
        vignetteRadius = try container.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? 0.5
        vignetteSoftness = try container.decodeIfPresent(Double.self, forKey: .vignetteSoftness) ?? 0
        texture = try container.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        // `clarity` falls back to the pre-split `definition` key — see
        // `LegacyCodingKeys`. Positive `definition` at value X and `clarity`
        // at X are the same filter at the same settings, so this is a true
        // rename, not a lossy approximation.
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity)
            ?? legacyDefinition
            ?? 0
        dehaze = try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        defringePurple = try container.decodeIfPresent(Double.self, forKey: .defringePurple) ?? 0
        defringeGreen = try container.decodeIfPresent(Double.self, forKey: .defringeGreen) ?? 0
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        lookID = (try? container.decodeIfPresent(String.self, forKey: .lookID)) ?? ""
        lookIntensity = try container.decodeIfPresent(Double.self, forKey: .lookIntensity) ?? 1.0
        styleID = (try? container.decodeIfPresent(String.self, forKey: .styleID)) ?? ""
        styleTone = try container.decodeIfPresent(Double.self, forKey: .styleTone) ?? 0
        styleColor = try container.decodeIfPresent(Double.self, forKey: .styleColor) ?? 0
        styleStrength = try container.decodeIfPresent(Double.self, forKey: .styleStrength) ?? 1.0
        styleTexture = (try? container.decodeIfPresent(String.self, forKey: .styleTexture)) ?? ""
        styleTextureAmount = try container.decodeIfPresent(Double.self, forKey: .styleTextureAmount) ?? 1.0
        styleGrain = (try? container.decodeIfPresent(Bool.self, forKey: .styleGrain)) ?? false
        styleProtectSkin = (try? container.decodeIfPresent(Bool.self, forKey: .styleProtectSkin)) ?? false
        styleProtectAmount = (try? container.decodeIfPresent(Double.self, forKey: .styleProtectAmount)) ?? 1.0
        styleSkinMaskPNG = try? container.decodeIfPresent(Data.self, forKey: .styleSkinMaskPNG)
        styleSkinMaskRevision = try? container.decodeIfPresent(Int.self, forKey: .styleSkinMaskRevision)
        boostAmount = try container.decodeIfPresent(Double.self, forKey: .boostAmount) ?? 1.0
        rawExposureEV = try container.decodeIfPresent(Double.self, forKey: .rawExposureEV) ?? 0
        shadowBoostScale = try container.decodeIfPresent(Double.self, forKey: .shadowBoostScale) ?? 1.0
        rawWhiteBalanceNeutralPoints = try container.decodeIfPresent([RawNeutralPoint].self, forKey: .rawWhiteBalanceNeutralPoints) ?? []
        rawLuminanceNoiseReductionAdjust = try container.decodeIfPresent(Double.self, forKey: .rawLuminanceNoiseReductionAdjust) ?? 0
        rawColorNoiseReductionScale = try container.decodeIfPresent(Double.self, forKey: .rawColorNoiseReductionScale) ?? 1.0
        rawSharpnessScale = try container.decodeIfPresent(Double.self, forKey: .rawSharpnessScale) ?? 1.0
        rawContrastAdjust = try container.decodeIfPresent(Double.self, forKey: .rawContrastAdjust) ?? 0
        rawDetailAdjust = try container.decodeIfPresent(Double.self, forKey: .rawDetailAdjust) ?? 0
        rawMoireReductionAdjust = try container.decodeIfPresent(Double.self, forKey: .rawMoireReductionAdjust) ?? 0
        rawDecoderVersionPin = try container.decodeIfPresent(String.self, forKey: .rawDecoderVersionPin) ?? ""
    }
}
