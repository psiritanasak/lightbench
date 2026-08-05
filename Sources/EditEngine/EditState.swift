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
