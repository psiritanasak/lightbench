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

    // MARK: - Definition (Clarity)

    /// Local-contrast enhancement, 0...1, default 0 (identity). One-directional
    /// (0 = none, positive = more defined) — same 0...1 family as Vignette
    /// Radius/Sharpen/Noise Reduction, NOT bipolar. A bipolar "Clarity" slider
    /// (positive = punch, negative = soften, the Lightroom convention) was the
    /// original design intent, but MEASURED (not assumed): `CIUnsharpMask`
    /// silently clamps negative `intensity` to a no-op in this app's working
    /// space (intensity -0.2 through -1.0 all produced output BIT-IDENTICAL to
    /// the unfiltered baseline — not a subtle effect, a dead half of the
    /// slider range). So this ships one-directional, named "Definition" to
    /// match CLAUDE.md's own "Definition (Clarity)" backlog heading, matching
    /// Apple Photos' one-directional convention rather than Lightroom's
    /// bipolar one. Applied in the perceptual sRGB-gamma domain, AFTER
    /// Vignette and BEFORE the Noise Reduction + Sharpen detail pair, via
    /// Core Image's `CIUnsharpMask` at a LARGE radius — see `EditPipeline`.
    ///
    /// MEASURED findings (this app's extendedLinearSRGB/RGBAf working space,
    /// not assumed):
    /// - Filter: `CIUnsharpMask` — the SAME filter Sharpen uses (already
    ///   measured numerically identical to `CISharpenLuminance` there), here
    ///   at a much larger radius/lower intensity. Chosen for its explicit
    ///   `radius` + `intensity` params, since Definition is defined by its
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
    ///   within 0.00100), Definition does NOT cleanly commute with Vignette
    ///   (measured corner differences up to 0.0188 between
    ///   Definition-then-Vignette and Vignette-then-Definition) — its wide
    ///   radius interacts with Vignette's spatially-varying darkening in a
    ///   way Sharpen's tiny radius doesn't. This is why the pipeline order
    ///   (Definition runs AFTER Vignette) is a real, measured requirement,
    ///   not an arbitrary choice.
    /// v1 scope: single Amount slider only — same scope-cut pattern as every
    /// other v1 feature.
    var definition: Double = 0

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
    /// convention rather than the -1...1 family. Applied as the pipeline's
    /// TRUE FINAL stage, AFTER Vignette, in the perceptual sRGB-gamma
    /// domain, via Core Image's `CISharpenLuminance` — see `EditPipeline`.
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

    /// The no-op edit state: every adjustment at its default (identity) value.
    static let identity = EditState()
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
        case curvesShadows, curvesHighlights, blackPoint
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
        case straightenAngle
        case verticalPerspective, horizontalPerspective
        case flipHorizontal, flipVertical
        case cropInsetTop, cropInsetBottom, cropInsetLeft, cropInsetRight
        case redEyePoints, redEyeSize, redEyeStrength
        case vignetteStrength, vignetteRadius
        case definition
        case noiseReduction
        case sharpness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0
        verticalPerspective = try container.decodeIfPresent(Double.self, forKey: .verticalPerspective) ?? 0
        horizontalPerspective = try container.decodeIfPresent(Double.self, forKey: .horizontalPerspective) ?? 0
        flipHorizontal = try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        cropInsetTop = try container.decodeIfPresent(Double.self, forKey: .cropInsetTop) ?? 0
        cropInsetBottom = try container.decodeIfPresent(Double.self, forKey: .cropInsetBottom) ?? 0
        cropInsetLeft = try container.decodeIfPresent(Double.self, forKey: .cropInsetLeft) ?? 0
        cropInsetRight = try container.decodeIfPresent(Double.self, forKey: .cropInsetRight) ?? 0
        redEyePoints = try container.decodeIfPresent([RedEyePoint].self, forKey: .redEyePoints) ?? []
        redEyeSize = try container.decodeIfPresent(Double.self, forKey: .redEyeSize) ?? 0.5
        redEyeStrength = try container.decodeIfPresent(Double.self, forKey: .redEyeStrength) ?? 0.7
        vignetteStrength = try container.decodeIfPresent(Double.self, forKey: .vignetteStrength) ?? 0
        vignetteRadius = try container.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? 0.5
        definition = try container.decodeIfPresent(Double.self, forKey: .definition) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
    }
}
