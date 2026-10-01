import Foundation

/// Which geometry (or, for `.luminanceRange`/`.colorRange`, SELECTION) a
/// `Mask` uses. `.radial` (an ellipse, Phase 7 slice 2) reads
/// `radiusX`/`radiusY`/`feather`; `.linear` (a graduated band, slice 3)
/// reads `width` instead; `.brush` (a freehand stroke, slice 4) reads
/// `brushPoints`/`brushSize`/`feather` instead; `.luminanceRange` (slice
/// 5 first half) reads `luminanceTarget`/`luminanceRange`/`feather`
/// instead; `.colorRange` (slice 5 second half) reads
/// `colorRangeTargetHue`/`colorRangeTargetSaturation`/
/// `colorRangeTargetLuminance`/`colorRangeTolerance`/
/// `colorRangeHasTarget`/`feather` instead — `feather` is now SHARED by
/// FOUR of the five kinds (`.radial`, `.brush`, `.luminanceRange`, and
/// `.colorRange` — see `feather`'s own doc comment for why a tonal/color
/// selection window's falloff reuses the exact same field/formula shape
/// as a drawn shape's soft edge), still inert only on `.linear`. The
/// OTHER kind(s)' geometry fields sit inert at their defaults, never read
/// by `EditPipeline.applyMasks`'s matching branch. `.radial`/`.linear`
/// share `centerX`/`centerY` (the anchor point) and `rotationDegrees`
/// (the mask's own local +X axis direction — see that field's own doc
/// comment for what "+X axis" means per kind); `.brush`/`.luminanceRange`/
/// `.colorRange` use neither — a stroke's position lives entirely in
/// `brushPoints`, and a Luminance Range or Color Range mask has no
/// position at all (both select by the image's OWN pixel values, not by
/// location — the two kinds that are genuinely content-derived rather
/// than drawn).
enum MaskKind: String, Codable {
    case radial
    case linear
    case brush
    case luminanceRange
    case colorRange
    /// AI subject selection (Vision `VNGenerateForegroundInstanceMaskRequest`): the selection is a
    /// persisted raster (`Mask.subjectMaskPNG`), not parameters. See `docs/ROADMAP_HISTORY.md`'s
    /// Vision spike entry.
    case subject
}

/// Phase 7 slice 6: whether — and how — a `Mask`'s own selection is
/// modified by ANOTHER mask's shape before that mask's adjustments are
/// applied. `.none` (the default) is BYTE-IDENTICAL to every mask kind's
/// own pre-slice-6 behavior — this is what makes slice 6 purely additive
/// rather than a breaking change to slices 2-5. `.intersect` narrows the
/// selection to where BOTH masks select (`M ∧ operand`); `.subtract`
/// removes the operand's selection from this mask's own
/// (`M ∧ ¬operand`). See `Mask.combineWithMaskID`'s own doc comment for
/// which mask "the operand" refers to, and `EditPipeline.applyMasks`'s
/// own doc comment for the exact Core Image technique (`CIMinimumCompositing`
/// for both — intersect direct, subtract against a channel-inverted
/// operand).
///
/// `CaseIterable` deliberately, though UNUSED as of this commit (Session
/// A: data model + pipeline only, no UI yet — see this slice's own plan).
/// RESERVED for Session B's not-yet-built mode picker, which is intended
/// to enumerate `.allCases` rather than a hand-written array a future
/// fourth case could silently omit — the exact hazard `AdjustTabView`'s
/// own `maskKindIcon`/`maskKindLabel` doc comments already record for a
/// pre-slice-4 ternary. (Labels themselves would still come from an
/// exhaustive `switch`, which a new case DOES break at compile time —
/// `.allCases` only protects the enumeration, not the display strings.)
enum MaskCombineMode: String, Codable, CaseIterable {
    case none
    case intersect
    case subtract
}

/// One point along a painted brush stroke. Mirrors `RedEyePoint`'s exact
/// shape/convention: normalized 0...1 fraction of the extent, SwiftUI
/// top-left-origin, y-DOWN (flipped the same `1 - y` way every other mask
/// kind's geometry already is before reaching `CIImage`'s y-up space).
/// Lives here (mask-scoped), not on `EditState`, since a stroke belongs to
/// exactly one `Mask`.
struct BrushPoint: Equatable, Codable {
    var x: Double
    var y: Double
}

/// One local adjustment, radial (ellipse), linear (graduated band), brush
/// (freehand stroke), or luminance range (tonal selection) per `kind` —
/// Phase 7 slices 2/3/4/5's mask kinds. Lives in its own file, not inside
/// `EditState.swift` (already 1000+ lines), following `EditHistory.swift`'s
/// precedent for a standalone `EditEngine` type.
///
/// Unlike `RedEyePoint`/`RawNeutralPoint` (both trivial 2-`Double` points
/// with SYNTHESIZED `Codable`), `Mask` needs its OWN hand-written
/// schema-tolerant decoding — see the `extension Mask` below — because
/// slice 6 will add combining flags to THIS struct (a future "Color
/// Range" kind is also expected but not yet scheduled), so a mask written
/// today must still decode after those land, the same reasoning
/// `EditState` itself already applies one level up. This is also why
/// `kind`/geometry live as FLAT fields on one struct rather than an
/// enum-with-associated-values: an associated-value variant would break
/// both the flat `CodingKeys` list below and `deterministicFallbackID`'s
/// fixed-arity parameter list.
///
/// `.luminanceRange` (slice 5) is the first kind that is CONTENT-DERIVED
/// rather than drawn — its "geometry" is a tonal window, not a shape, and
/// it has no anchor point/position at all. See `luminanceTarget`'s own
/// doc comment.
///
/// All geometry is a normalized FRACTION of the mask's photo's CURRENT
/// (post-crop) extent — never an absolute pixel value. This is not a style
/// preference: `ProxyScale.swift` documents that every extent-dependent
/// pipeline stage must express geometry this way, because the interactive
/// preview renders the whole pipeline on a proportionally-downscaled
/// source. Absolute pixels would render at the wrong place/size on every
/// proxied drag frame, every Library thumbnail, and every non-native-size
/// export — silently, and visually only.
struct Mask: Identifiable, Equatable, Codable {
    /// Stable across the mask's lifetime — round-trips through `Codable` so
    /// reloading a sidecar doesn't look like a spurious identity change,
    /// and lets UI bind to a specific mask by id rather than array position
    /// (array position shifts whenever an earlier mask is deleted).
    var id: UUID = UUID()

    /// `.radial` by default so every existing pre-slice-3 sidecar/preset
    /// keeps decoding to the same mask it always did (see the schema-
    /// tolerant decode below for how an UNRECOGNIZED future kind string
    /// also falls back here, safely).
    var kind: MaskKind = .radial

    // MARK: - Geometry

    /// Fraction of the extent's width/height, SwiftUI top-left-origin,
    /// y-DOWN — the SAME convention `RedEyePoint` already uses, so
    /// `EditPipeline`/`RadialMaskGeometry` reuse `applyRedEye`'s exact
    /// `1 - point.y` flip rather than inventing a second convention.
    var centerX: Double = 0.5
    var centerY: Double = 0.5

    /// Fraction of `extent.width`/`extent.height` RESPECTIVELY (each axis
    /// of its OWN dimension), matching `ProxyScale`'s own documented
    /// constraint that every extent-dependent stage express geometry as a
    /// fraction of the CURRENT extent — so both stay proportionally correct
    /// under a P2 proxy downscale, same as a single shared denominator
    /// would. The reason it's two independent fields rather than one
    /// shared radius is the aspect coupling, not proxy-scale correctness:
    /// equal `radiusX`/`radiusY` does NOT draw a
    /// circle — it draws an ellipse matching the extent's own aspect ratio
    /// (e.g. 0.25/0.25 on a 6000×4000 extent is a 1500×1000 px ellipse, not
    /// a 1500 px circle). A future UI that wants an on-screen circle must
    /// compute `radiusY = radiusX * (extent.width / extent.height)` itself
    /// — this struct does not, and structurally cannot, do that for it.
    /// `.radial` only — inert (never read) on a `.linear` mask.
    var radiusX: Double = 0.25
    var radiusY: Double = 0.25

    /// Degrees, CLOCKWISE-positive as drawn on screen (SwiftUI y-down
    /// space) — the mask's own local +X axis direction, per `kind`: for
    /// `.radial` that's the ellipse's own X axis (as before); for
    /// `.linear` (added slice 3) it's the direction of the graduated
    /// line ITSELF, with the falloff running along local +Y (0° = a
    /// horizontal line, dividing top/bottom — the classic graduated-ND
    /// default). One shared field/convention across both kinds rather
    /// than two, so there's only ever ONE rotation sign rule to remember
    /// in this struct. `RadialMaskGeometry.resolve` negates this
    /// internally to match `CGAffineTransform(rotationAngle:)`'s
    /// CCW-positive convention in `CIImage`'s y-up space (see that
    /// function's own doc comment) — `LinearMaskGeometry.resolve` instead
    /// flips each of its two computed guide POINTS individually (the
    /// same `1 - y` formula this struct's `centerY` already goes through
    /// on the render side), which is mathematically EQUIVALENT to
    /// negating the angle for this same quantity (independently
    /// re-derived and confirmed, not merely asserted — see that file's
    /// own doc comment), used only so that file has a single flip idiom
    /// rather than mixing two for the same purpose. This field itself
    /// always stores the UI-facing, on-screen sign, regardless of kind.
    /// CAUTION for whoever builds the mask-
    /// handle drag UI: this is the OPPOSITE on-screen sense from this
    /// struct's sibling `EditState.straightenAngle` (CCW-positive,
    /// `EditPipeline.applyStraighten`'s own doc comment) — two degree-
    /// valued rotation fields in this codebase with opposite screen
    /// senses is exactly the kind of mismatch that has caused real sign
    /// bugs here before (the Metal y-flip, the Compare split inversion)
    /// — do not assume the two share a convention.
    var rotationDegrees: Double = 0

    /// 0 = hard edge, 1 = falloff begins at the center (fully soft).
    /// `RadialMaskGeometry.innerRadiusFraction(feather:)` is the single
    /// source of truth for turning this into an actual inner radius, shared
    /// by the render stage and the mask overlay's feather guide, so the
    /// two can never drift apart. Inert on `.linear` only.
    ///
    /// REUSED a third time by `.luminanceRange` (slice 5) — deliberately,
    /// not merely to save a field: `LuminanceRangeSelection.resolve`
    /// applies the EXACT SAME formula shape `RadialMaskGeometry` already
    /// does (`innerHalfWidth = outerHalfWidth * (1 - feather)`), just
    /// against a tone window's half-width instead of an ellipse's radius.
    /// `feather == 0` gives a hard-edged tone window; `1` gives a pure
    /// tent peaking at `luminanceTarget` with no flat plateau; `0.5` (the
    /// identity) gives a plateau half as wide as the window. A user who
    /// has already learned what Feather does on a Radial mask has learned
    /// it here too — that transferable meaning is the actual argument for
    /// reusing the field, not just a smaller `CodingKeys` list.
    var feather: Double = 0.5

    /// `.linear` only — inert on `.radial`. The FULL guide-to-guide
    /// distance (not a half-width), as a fraction of
    /// `min(extent.width, extent.height)` — the same non-axis-specific
    /// denominator Clarity/Texture/Sharpen's own radii use, chosen for the
    /// same reason: it keeps the band's on-screen THICKNESS constant as
    /// `rotationDegrees` sweeps, which an axis-specific fraction would
    /// not. `LinearMaskGeometry.minimumWidth` is the single source of
    /// truth for the render-side clamp — unlike `radiusX`/`radiusY`,
    /// where a sub-half-pixel value means "covers nothing" and the mask
    /// is skipped, `width == 0` is a legitimate, deliberate HARD EDGE
    /// (a half-plane split with no feather at all), not "no mask" — so
    /// `LinearMaskGeometry.resolve` clamps this up to its minimum rather
    /// than returning `nil` the way `RadialMaskGeometry.resolve` does
    /// for a too-small radius.
    var width: Double = 0.3

    /// `.brush` only — inert on `.radial`/`.linear`. Dab radius, a fraction
    /// of `min(extent.width, extent.height)` (the same non-axis-specific
    /// denominator `width` above uses, for the same reason: constant
    /// on-screen thickness regardless of the extent's aspect ratio).
    /// `BrushMaskGeometry.radiusInPixels` is the single source of truth for
    /// the render-side clamp: unlike `radiusX`/`radiusY` (where a too-small
    /// value means "covers nothing" and the whole mask is skipped), a tiny
    /// brush is a legitimate, deliberate fine-detail tool — the pixel
    /// radius is clamped to a small floor instead of ever skipping the
    /// mask (a real bug this struct's own history already hit once for
    /// `.linear`'s `width`, on a small extent like a Library thumbnail).
    var brushSize: Double = 0.05

    /// `.brush` only — empty on every other kind. A FLAT, ordered list of
    /// points along one continuous stroke (not nested per-stroke arrays —
    /// painting a second area means adding another `.brush` `Mask`, since
    /// masks already compound sequentially for free). Empty is a real,
    /// valid state: a `.brush` mask that's been added but not yet painted
    /// (or whose stroke was discarded) — `EditPipeline.applyMasks` treats
    /// it as covering nothing, matching `redEyePoints`' own empty-means-off
    /// convention.
    var brushPoints: [BrushPoint] = []

    /// `.luminanceRange` only — inert on every other kind. The tone this
    /// mask selects, 0 = black … 1 = white, expressed in the PERCEPTUAL
    /// (sRGB-encoded) tone domain, NOT scene-linear — 0.5 reads as
    /// photographic middle gray to a slider, matching how every OTHER
    /// tone-shaped control in this app (Levels, Curves) already presents
    /// itself to the user. `LuminanceRangeSelection.linearLuminance
    /// (forTone:)` is the single source of truth mapping this to the
    /// scene-linear luminance `EditPipeline.applyMasks` actually compares
    /// pixels against — see that function's own doc comment for why the
    /// SLIDER is perceptual while the per-pixel COMPARISON stays
    /// scene-linear (the same domain every other per-mask adjustment
    /// already runs in at that point in the loop).
    ///
    /// This is the first mask parameter whose selection depends on the
    /// IMAGE'S OWN PIXEL VALUES rather than pure geometry — a downscaled
    /// render (the P2 interactive proxy, a Library thumbnail, a
    /// non-native-size export) resamples tones before this mask is
    /// computed, so it can select marginally differently at a tone
    /// boundary than the full-resolution render would (a fine gradient or
    /// high-frequency detail right at the window's edge is the only case
    /// this is visible in — a flat region is unaffected). Accepted,
    /// same category as this app's existing Noise Reduction/Sharpen
    /// radius caveats: resolution-independent by construction, not
    /// bit-identical across resolutions.
    var luminanceTarget: Double = 0.5

    /// `.luminanceRange` only — inert on every other kind. The FULL width
    /// of the selected tone window (not a half-width), in the same
    /// PERCEPTUAL tone units as `luminanceTarget` — deliberately matching
    /// `width`'s own full-not-half convention so this struct has ONE rule
    /// for what a field named "width"/"range" means. `LuminanceRangeSelection
    /// .minimumRange`/`.maximumRange` are the single source of truth for
    /// the render-side clamp: like `.linear`'s `width` (and unlike
    /// `.radial`'s radii), a very narrow window is a legitimate,
    /// deliberate PRECISE selection, so it CLAMPS rather than making
    /// `resolve` return `nil`.
    var luminanceRange: Double = 0.3

    /// `.colorRange` only — inert on every other kind. The picked color's
    /// hue, in degrees (0..<360), decomposed via `ColorRangeSelection
    /// .hueSaturation(forLinearRGB:_:_:)` at pick time. Meaningless
    /// (arbitrary leftover/default value) until `colorRangeHasTarget` is
    /// `true` — see that field's own doc comment.
    var colorRangeTargetHue: Double = 0

    /// `.colorRange` only. The picked color's HSL saturation, 0...1 —
    /// SCENE-LINEAR HSL (computed from the same linear-light pixel values
    /// `EditPipeline.applyMasks` compares against), NOT a perceptual/sRGB-
    /// encoded saturation.
    var colorRangeTargetSaturation: Double = 0

    /// `.colorRange` only. The picked color's Rec.709 luma, in SCENE-LINEAR
    /// light (`LuminanceRangeSelection.lumaRed/lumaGreen/lumaBlue`'s own
    /// weights, reused so both content-derived kinds can never drift on
    /// what "luminance" means) — a MEASURED pixel value, not a slider
    /// position, so unlike `luminanceTarget` this is NOT clamped to 0...1
    /// and NOT in the perceptual tone domain: a picked HEADROOM pixel
    /// (linear > 1) is a legitimate target.
    var colorRangeTargetLuminance: Double = 0

    /// `.colorRange` only. One abstract 0...1 "tightness" dial — NOT a
    /// width in any single unit, since hue (degrees)/saturation (0...1)/
    /// luminance (scene-linear) have no shared unit to express one width
    /// in. `ColorRangeSelection.resolve` interpolates each axis's own
    /// window between its own min/max constants by this one value —
    /// mirrors `EditState.selectiveColorRange`'s identical "one slider,
    /// many windows" shape. Default `0.3`, NOT `0` — an unpicked mask
    /// (`colorRangeHasTarget == false`) selects nothing regardless of this
    /// value (see that field's own doc comment), so there is no risk of a
    /// non-zero default silently doing something before a color is picked;
    /// once picked, a moderate starting tolerance is more useful than a
    /// maximally-tight one.
    var colorRangeTolerance: Double = 0.3

    /// `.colorRange` only. `false` until the user picks a color via the
    /// eyedropper (`ImageDocumentModel.pickColorRangeTarget`) — mirrors
    /// `brushPoints.isEmpty`'s "added but not yet used" convention: an
    /// unpicked `.colorRange` mask selects NOTHING (`ColorRangeSelection
    /// .resolve` returns `nil` whenever this is `false`), never an
    /// arbitrary default color. Also feeds `deterministicFallbackID` (see
    /// that function's own doc comment) — two id-less masks differing ONLY
    /// in "has a color been picked" are visibly different (one is inert,
    /// the other isn't), so this flag must be mixed into the hash too.
    var colorRangeHasTarget: Bool = false

    // MARK: - Adjustments

    /// The curated 8-parameter set (CLAUDE.md Phase 7 roadmap: "a small
    /// curated subset... pick the actual set deliberately, don't default to
    /// all of them"), each reusing the SAME filter technique as its global
    /// counterpart so a mask's value of X reads the same as the identically
    /// named global slider's value of X — see `EditPipeline.applyMasks`'s
    /// own doc comment for exactly which global stage each one reuses.
    ///
    /// EVERY identity here is 0 — a deliberate property, unlike `EditState`
    /// itself (which has five non-zero identities: 6500, 1.0, 0.5, 0.7,
    /// 1.0, each a small trap for reset/compare/preset code to remember).
    /// This is what makes `isIdentity` below trivially correct and keeps it
    /// that way as params are added.
    var exposureEV: Double = 0          // EV, matches EditState.exposureEV's -5...5
    var contrast: Double = 0            // matches EditState.contrast's -1...1
    var highlights: Double = 0          // matches EditState.curvesHighlights's -1...1
    var shadows: Double = 0             // matches EditState.curvesShadows's -1...1
    /// -1...1, BIPOLAR, matching `EditState.clarity`'s own range and using
    /// the identical `EditPipeline.localContrast` construction at the same
    /// `kClarityRadiusFraction`/`kClarityAmountSpan` — a mask's Clarity at
    /// value X is numerically identical to the global slider at X, either
    /// sign. Was 0...1 before the Texture/Clarity split, because
    /// `CIUnsharpMask` is measured to clamp negative intensity to a
    /// bit-identical no-op; the negative half now routes through a blur
    /// blend instead, so the range is genuinely live in both directions.
    /// Masks carry no `texture` counterpart yet — see CLAUDE.md.
    var clarity: Double = 0
    var saturation: Double = 0          // matches EditState.hslSaturation's -1...1
    /// Kelvin OFFSET from wherever white balance already left the image —
    /// NOT an absolute Kelvin value like `EditState.whiteBalanceTemperature`.
    /// `applyMasks` runs AFTER the global white-balance stage has already
    /// adapted the whole image, so an absolute per-mask value would
    /// double-apply chromatic adaptation with no way to undo the first
    /// pass. `0` is neutral (no shift); see `EditPipeline.applyMasks`.
    /// EXCEPTION to this struct's own "reads the same as the identically
    /// named global slider" guarantee: on a black & white photo, this field
    /// (and `tint` below) is a silent no-op — `applyMasks` gates the whole
    /// white-balance branch off whenever `EditState.blackAndWhite` is true,
    /// since applying a per-channel color matrix to an already-forced-
    /// desaturated image would paint color back in. The GLOBAL white
    /// balance fields don't have this exception (they run BEFORE the forced
    /// desaturation, so they genuinely still shape a B&W render — see
    /// `applyPerceptualAdjustments`'s own doc comment on that colored-filter
    /// effect); masks are local retouching on an already-graded image, not
    /// a second global grading pass, so this divergence is deliberate.
    var temperature: Double = 0
    /// Relative shift, matches `EditState.whiteBalanceTint`'s own
    /// -100...100 convention (clamped to that range in `applyMasks`, like
    /// the other color/tone fields — contrast/shadows/highlights/
    /// saturation. `temperature` above is NOT clamped, matching the global
    /// path's own unclamped `whiteBalanceTemperature`). Subject to the same
    /// black & white no-op exception documented on `temperature` above.
    var tint: Double = 0

    // MARK: - Subject (AI) selection

    /// `.subject` only. An 8-bit grayscale PNG of Vision's foreground-instance mask, in the frame of
    /// the UNEDITED, oriented source photo (BEFORE straighten/perspective/scale/flip/crop — the
    /// pipeline re-applies those same geometry stages to this raster so the selection follows the
    /// photo). A model OUTPUT rather than parameters, so it is persisted instead of recomputed: Vision
    /// can change between OS versions, and an inference per render is not affordable. `nil` = no
    /// subject computed yet; such a mask selects nothing. JSON stores `Data` as base64.
    var subjectMaskPNG: Data? = nil

    /// `VNGenerateForegroundInstanceMaskRequest.currentRevision` when `subjectMaskPNG` was computed.
    /// Provenance only (like `EditState.rawDecoderVersionPin`'s role for RAW); nothing branches on it yet.
    var subjectMaskRevision: Int? = nil

    /// `.subject` only (v1): select everything EXCEPT the subject — the background, plus any area
    /// geometry reveals outside the photo's frame. Inert on every other kind. A mask with NO raster
    /// (`subjectMaskPNG == nil` or undecodable) selects nothing REGARDLESS of this flag — inverting
    /// "no subject known" must not light up the whole photo.
    var invertSelection: Bool = false

    /// `.subject` only. One 8-bit gray PNG PER detected person/object (Vision "instance"), all the same
    /// size, ordered left-to-right by mass centroid so "Person 1…N" in the UI matches the picture. Kept
    /// as separate soft rasters (not a label map) because Vision's per-instance masks are refined against
    /// the full-resolution image while its native label map is a blocky 512x512. Empty for masks made
    /// before per-person selection existed — those render from `subjectMaskPNG` alone.
    var subjectInstancePNGs: [Data] = []

    /// `.subject` only. Which entries of `subjectInstancePNGs` are included. A missing entry (shorter
    /// array, or `[]`) means ENABLED, so a fresh mask selects everyone and a stale/short array never hides
    /// a person by accident.
    var subjectInstanceEnabled: [Bool] = []

    /// `.subject` only, 0...1, identity 0 (so every earlier subject mask renders byte-identically).
    /// Softens the selection's edge: a Gaussian blur of the combined raster whose radius is
    /// `subjectFeather * EditPipeline.kMaxSubjectFeatherFraction` of the raster's long side — a fraction,
    /// so it scales with the photo exactly like every other extent-relative parameter.
    var subjectFeather: Double = 0

    /// The raster PNGs that make up the selection: the ENABLED per-person rasters when any exist, else
    /// the single legacy `subjectMaskPNG` if present, else none. ZERO rasters selects nothing, even
    /// when `invertSelection` is set (inverting "nothing known" must not light up the whole photo).
    var subjectRasters: [Data] {
        if !subjectInstancePNGs.isEmpty {
            return subjectInstancePNGs.enumerated().compactMap { index, png in
                index < subjectInstanceEnabled.count && !subjectInstanceEnabled[index] ? nil : png
            }
        }
        return subjectMaskPNG.map { [$0] } ?? []
    }

    /// Whether any raster was ever stored (enabled or not) — drives "No subject stored" UI text.
    var hasStoredSubject: Bool { !subjectInstancePNGs.isEmpty || subjectMaskPNG != nil }

    // MARK: - Combining

    /// `.none` by default — every pre-slice-6 mask/sidecar decodes to
    /// `.none` (see `CodingKeys`' decode below), which is what makes this
    /// whole slice purely additive: a mask with `combineMode == .none`
    /// renders BYTE-IDENTICAL to how it always has, regardless of
    /// `combineWithMaskID`. See `MaskCombineMode`'s own doc comment for
    /// what `.intersect`/`.subtract` mean.
    var combineMode: MaskCombineMode = .none

    /// The OTHER mask this one's selection is intersected with/subtracted
    /// by, when `combineMode != .none`. `nil` means "no operand chosen
    /// yet" — `EditPipeline.applyMasks` treats that (and a `combineMode`
    /// left at `.none` regardless of this field) identically: no combine.
    ///
    /// Deliberately NOT transitive: if the referenced mask is ITSELF
    /// combining with a third mask, that third mask's shape is NOT
    /// consulted — this field always resolves against the referenced
    /// mask's own RAW, pre-combine shape. Cycle-safe by construction (no
    /// recursion means nothing to cycle, even for a mutual A-references-B/
    /// B-references-A pair) and matches v1's real-world need (one mask cut
    /// by one shape); chaining is a logged, deliberate deferral, not an
    /// oversight — see IMPROVEMENTS.md's D15 ("Combine-masks v1 scope
    /// cuts").
    ///
    /// FAILS OPEN in every broken-reference case, never fails closed
    /// (skips the mask) or crashes: a self-reference
    /// (`combineWithMaskID == id`, unreachable from the UI — the picker
    /// excludes the mask being edited — so only reachable via a
    /// hand-edited sidecar) and a DANGLING reference (the named mask was
    /// deleted, or this sidecar belongs to a different photo) both render
    /// as `combineMode == .none`. Deliberate: fail-open always degrades
    /// toward the pre-slice-6 shipped behavior — VISIBLE (the mask grows
    /// back to its full shape) and fixable — where fail-closed would make
    /// the whole adjustment silently vanish, the worst outcome for a
    /// corrupt/stale reference. `MaskDetailView` has no UI for this yet
    /// (Session A: data model + pipeline only — see IMPROVEMENTS.md's
    /// D15); Session B's planned combine-target picker is intended to
    /// independently coerce the same dangling case to display "None", so
    /// the canvas and the sidebar can never disagree, mirroring this
    /// codebase's own `LibraryFilter` fix for an identical class of
    /// Optional-bound-to-Picker-selection hazard.
    ///
    /// Deleting a mask does NOT scrub other masks' references to it (no
    /// new invariant to maintain across the several existing
    /// delete/discard call sites) — harmless per the fail-open behavior
    /// above, and Undo restores the relationship for free since
    /// `EditHistory` snapshots whole `EditState`s. Also feeds
    /// `deterministicFallbackID` (see that function's own doc comment) —
    /// two id-less masks differing only in their combine target are
    /// visibly different masks.
    var combineWithMaskID: UUID? = nil

    /// `true` when every adjustment param is at its identity (0) —
    /// geometry-only. `EditPipeline.applyMasks` skips a mask entirely when
    /// this is `true`, which is what makes a geometry-only mask render
    /// BYTE-IDENTICAL to no mask at all. Deliberately excludes geometry —
    /// including `kind`/`width`/`brushSize`/`brushPoints`/`luminanceTarget`/
    /// `luminanceRange`/`colorRangeTargetHue`/`colorRangeTargetSaturation`/
    /// `colorRangeTargetLuminance`/`colorRangeTolerance`/
    /// `colorRangeHasTarget`/`combineMode`/`combineWithMaskID` (added
    /// slices 3-6): a mask can be `isIdentity` yet still a real,
    /// undo-worthy edit (the user placed it, painted a stroke, tuned a
    /// tone window, or set up a combine relationship), mirroring
    /// `redEyePoints`' own existing behavior (a placed point with
    /// strength 0 renders identically but still counts as an edit) — see
    /// `EditState.isEffectivelyIdentity`. Slice 6 gives this exclusion a
    /// SECOND real purpose beyond "still counts as an edit": an
    /// all-zero-adjustment mask is exactly how a user creates a pure
    /// "shape-only" mask whose only job is to be referenced as another
    /// mask's combine operand — `EditPipeline.applyMasks` skips it as a
    /// standalone adjustment layer (as it always has), but its geometry
    /// is still fully resolvable when another mask names it via
    /// `combineWithMaskID`.
    var isIdentity: Bool {
        exposureEV == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && clarity == 0 && saturation == 0 && temperature == 0 && tint == 0
    }
}

// MARK: - Custom decoding (schema-tolerant)

extension Mask {
    /// Same reasoning as `EditState`'s own custom `init(from:)` (see that
    /// extension's doc comment), one level down: synthesized `Decodable`
    /// throws `keyNotFound` on the first missing key, which would break
    /// every mask ever saved the moment a future slice adds one more field
    /// to this struct. Deliberately NOT paired with a custom `encode(to:)`
    /// — same rationale as `EditState`'s: encoding a fully-in-memory value
    /// is never ambiguous, so Swift still synthesizes `Encodable` on its
    /// own.
    private enum CodingKeys: String, CodingKey {
        case id, kind
        case centerX, centerY, radiusX, radiusY, rotationDegrees, feather, width
        case brushSize, brushPoints
        case luminanceTarget, luminanceRange
        case colorRangeTargetHue, colorRangeTargetSaturation, colorRangeTargetLuminance
        case colorRangeTolerance, colorRangeHasTarget
        case exposureEV, contrast, highlights, shadows
        case clarity, saturation, temperature, tint
        case combineMode, combineWithMaskID
        case subjectMaskPNG, subjectMaskRevision, invertSelection
        case subjectInstancePNGs, subjectInstanceEnabled, subjectFeather
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `MaskKind` is a String-raw-value enum: decoding it directly via
        // `decodeIfPresent(MaskKind.self, forKey:)` THROWS on an
        // unrecognized raw value (`decodeIfPresent` only returns `nil` for
        // an ABSENT key, never for a present-but-invalid one). `EditState`
        // decodes `masks` inside its own container, and BOTH places that
        // read a sidecar wrap the whole decode in `try?`
        // (`ImageDocumentModel.load(from:)`, `PhotoExporter`'s own sidecar
        // read) — so a future slice's unrecognized kind string (say,
        // slice 4's `"brush"`) would silently discard the ENTIRE sidecar,
        // every global edit on that photo included, not just this one
        // mask. Decode the raw String ourselves and map it, falling back
        // to `.radial` on anything unrecognized — an accepted, logged
        // limitation: if the user then edits and the sidecar re-saves,
        // the unrecognized kind is silently rewritten as `.radial`. No
        // third kind exists yet, so this can't fire today; revisit the
        // moment one does.
        // Reviewer-caught: `try` alone still lets a TYPE mismatch (e.g. a
        // hand-authored sidecar encoding `"kind": 2`, a number, instead of
        // a string) throw and discard the whole sidecar — the exact
        // failure mode this whole fallback exists to close, just from a
        // different malformed input than an unrecognized string value.
        // `try?` makes the "never throws" guarantee unconditional on ANY
        // decode failure for this one key, not just an unrecognized-but-
        // well-typed value. `.brush`/`.luminanceRange`/`.colorRange` are
        // real as of slices 4/5; a future kind string still falls back to
        // `.radial` the same way.
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = rawKind.flatMap(MaskKind.init(rawValue:)) ?? .radial
        centerX = try container.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try container.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        radiusX = try container.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0.25
        radiusY = try container.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0.25
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        brushSize = try container.decodeIfPresent(Double.self, forKey: .brushSize) ?? 0.05
        // Same reasoning as `kind` above: a malformed single point (e.g.
        // missing `y`) must not discard the whole sidecar, so this decodes
        // via `try?` rather than a bare `try` on the array.
        brushPoints = (try? container.decodeIfPresent([BrushPoint].self, forKey: .brushPoints)) ?? nil ?? []
        // Plain `Double`s, like the sixteen adjustment/geometry fields
        // below — bare `try`, NOT `try?`. The `try?` sites in this
        // extension exist only for two specific hazards neither of these
        // fields has: `kind`'s raw-value-enum throw-on-unrecognized-value,
        // and `brushPoints`' nested-array throw-on-one-malformed-element.
        // A type-mismatched `"luminanceTarget": "half"` is the same hazard
        // class as today's type-mismatched `"centerX": "half"`, already
        // handled uniformly by every other scalar field's bare `try`.
        luminanceTarget = try container.decodeIfPresent(Double.self, forKey: .luminanceTarget) ?? 0.5
        luminanceRange = try container.decodeIfPresent(Double.self, forKey: .luminanceRange) ?? 0.3
        // Same hazard class as `luminanceTarget`/`luminanceRange` above —
        // plain scalars, bare `try`. `colorRangeHasTarget` is a plain
        // `Bool`, not a raw-value enum, so it has none of `kind`'s
        // unrecognized-value hazard and needs no `try?` of its own.
        colorRangeTargetHue = try container.decodeIfPresent(Double.self, forKey: .colorRangeTargetHue) ?? 0
        colorRangeTargetSaturation =
            try container.decodeIfPresent(Double.self, forKey: .colorRangeTargetSaturation) ?? 0
        colorRangeTargetLuminance =
            try container.decodeIfPresent(Double.self, forKey: .colorRangeTargetLuminance) ?? 0
        colorRangeTolerance = try container.decodeIfPresent(Double.self, forKey: .colorRangeTolerance) ?? 0.3
        colorRangeHasTarget = try container.decodeIfPresent(Bool.self, forKey: .colorRangeHasTarget) ?? false
        exposureEV = try container.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        // `MaskCombineMode` is a String-raw-value enum — the exact `kind`
        // hazard class, `try?` for the same reason: `decodeIfPresent`
        // THROWS on a present-but-unrecognized raw value, which (wrapped
        // in this app's `try?`-at-the-sidecar-level convention) would
        // otherwise discard the whole sidecar over one unrecognized
        // combine mode.
        let rawCombineMode = (try? container.decodeIfPresent(String.self, forKey: .combineMode)) ?? nil
        combineMode = rawCombineMode.flatMap(MaskCombineMode.init(rawValue:)) ?? .none
        // `combineWithMaskID` LOOKS like a plain-scalar bare-`try` field
        // (it's not a raw-value enum, not a nested array) but is NOT one:
        // `UUID.init(from:)` throws `DecodingError.dataCorrupted` on a
        // WELL-TYPED but unparseable string (e.g. a hand-typed
        // `"mask-3"`) — structurally the same hazard as `kind`'s
        // unrecognized-string throw, not the same as a type-mismatched
        // `"centerX": "half"`. And it's MORE reachable than `kind`'s own
        // hazard: a user hand-editing a combine reference by id is
        // exactly the person likely to type a non-UUID there. `try?`,
        // falling back to `nil` (== "no operand chosen").
        combineWithMaskID = (try? container.decodeIfPresent(UUID.self, forKey: .combineWithMaskID)) ?? nil
        // `Data` decodes from a base64 string; a present-but-corrupt blob throws `dataCorrupted`, the
        // same discard-the-whole-sidecar hazard as `kind` above, so `try?` -> nil (selects nothing).
        subjectMaskPNG = (try? container.decodeIfPresent(Data.self, forKey: .subjectMaskPNG)) ?? nil
        subjectMaskRevision = (try? container.decodeIfPresent(Int.self, forKey: .subjectMaskRevision)) ?? nil
        invertSelection = (try? container.decodeIfPresent(Bool.self, forKey: .invertSelection)) ?? false
        // Same `try?` reasoning: one corrupt element must lose only this array, never the sidecar.
        subjectInstancePNGs = (try? container.decodeIfPresent([Data].self, forKey: .subjectInstancePNGs)) ?? nil ?? []
        subjectInstanceEnabled = (try? container.decodeIfPresent([Bool].self, forKey: .subjectInstanceEnabled)) ?? nil ?? []
        subjectFeather = (try? container.decodeIfPresent(Double.self, forKey: .subjectFeather)) ?? nil ?? 0
        // Reviewer-corrected (Phase 7 slice 2): falls back to a DETERMINISTIC
        // id derived from every other decoded field, not a fresh random
        // UUID — unreachable via this app's own round-trip (every mask it
        // writes carries an id), bounded to a hand-edited/corrupted
        // sidecar, but a random fallback would have meant two decodes of
        // the SAME bytes are not `Equatable`-equal, which is otherwise
        // never true of any other field's default and would have been a
        // real (if rare) miss against the P3 render cache/`EditHistory`
        // no-op guard, both keyed on whole-`EditState` equality.
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            id = decodedID
        } else {
            id = Mask.deterministicFallbackID(
                kind: kind, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
                rotationDegrees: rotationDegrees, feather: feather, width: width, brushSize: brushSize,
                brushPoints: brushPoints, luminanceTarget: luminanceTarget, luminanceRange: luminanceRange,
                colorRangeTargetHue: colorRangeTargetHue, colorRangeTargetSaturation: colorRangeTargetSaturation,
                colorRangeTargetLuminance: colorRangeTargetLuminance, colorRangeTolerance: colorRangeTolerance,
                colorRangeHasTarget: colorRangeHasTarget,
                exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
                clarity: clarity, saturation: saturation, temperature: temperature, tint: tint,
                combineMode: combineMode, combineWithMaskID: combineWithMaskID,
                subjectMaskPNG: subjectMaskPNG, subjectMaskRevision: subjectMaskRevision,
                invertSelection: invertSelection,
                subjectInstancePNGs: subjectInstancePNGs, subjectInstanceEnabled: subjectInstanceEnabled,
                subjectFeather: subjectFeather
            )
        }
    }

    /// A stable (same bytes always produce the same id — unlike Swift's own
    /// per-process-randomized `Hasher`), non-cryptographic FNV-1a-style mix
    /// of every geometry/adjustment field, used ONLY as the `id` decode
    /// fallback above. Two DIFFERENT id-less masks with identical field
    /// values colliding is an accepted, harmless edge case for THIS slice
    /// (they'd already be visually and behaviorally identical, and this app
    /// never itself writes an id-less mask — every mask ever created via
    /// `Mask()`'s own default already carries a real, unique `UUID()`, so
    /// this fallback only fires for a hand-edited/corrupted sidecar).
    /// Reviewer-flagged for whoever builds the mask-list UI (Session B):
    /// `Mask: Identifiable`, and a `ForEach` over the list would misbehave
    /// if two DISTINCT, deliberately-authored masks ever collided here —
    /// re-check this reasoning still holds before shipping a UI that lets
    /// a user hand-author or import id-less mask JSON.
    ///
    /// Slice 3 note: `kind` now feeds this hash too (mixed in FIRST,
    /// before the field loop below) — omitting it would let a default
    /// id-less `.radial` mask and a default id-less `.linear` mask in the
    /// same hand-edited sidecar collide on the SAME id, which (unlike the
    /// accepted collision case above, where two field-identical masks are
    /// already visually identical) breaks `ForEach`/`delete(_:)` identity
    /// for two masks that are visibly DIFFERENT. Mixed in via a fixed,
    /// explicit `switch` rather than `MaskKind.hashValue` — Swift's
    /// `Hasher` is seeded per-process, so `.hashValue` would reintroduce
    /// exactly the non-determinism this whole function exists to avoid.
    /// Adding `kind` to this hash changes the ids previously produced for
    /// id-less sidecars — harmless: the only property being preserved is
    /// "the same bytes always decode to the same id," never cross-version
    /// id stability.
    ///
    /// Slice 4 note: `brushSize` joins the fixed-arity scalar list;
    /// `brushPoints` (variable-length, unlike every other field here) is
    /// mixed in as a SECOND pass after the fixed-arity loop — its own count
    /// first (so two masks differing only in point count never collide),
    /// then each point's x/y in order.
    ///
    /// Slice 5 first-half note: `luminanceTarget`/`luminanceRange` join the
    /// fixed-arity scalar list (both plain `Double`s, no variable-length
    /// pass needed), plus a fourth `kindSeed` arm for `.luminanceRange`.
    ///
    /// Slice 5 second-half note: `colorRangeTargetHue`/
    /// `colorRangeTargetSaturation`/`colorRangeTargetLuminance`/
    /// `colorRangeTolerance` join the fixed-arity scalar list too, plus
    /// `colorRangeHasTarget` mixed in as `1`/`0` — the flag MUST be mixed
    /// in, not just the three scalars it gates: two id-less masks
    /// differing ONLY in "has a color been picked" are visibly different
    /// (one is inert, the other isn't) and must not collide. A fifth
    /// `kindSeed` arm covers `.colorRange`.
    ///
    /// Subject refinement note: `subjectFeather`, the instance count, each instance PNG (length then
    /// bytes) and the enabled flags are mixed in after the Subject pass below (variable length: count first).
    ///
    /// Subject note (AI Subject mask): `invertSelection`, the revision (presence flag + value) and the
    /// PNG (presence flag, length, bytes) are mixed in as a final pass after `combineWithMaskID`'s.
    ///
    /// Slice 6 note: `combineMode` joins the fixed-arity scalar list, via
    /// an explicit `switch` producing `0`/`1`/`2` (never `.hashValue` —
    /// same per-process-seeding reason `kindSeed` itself avoids it; never
    /// `MaskCombineMode.allCases.firstIndex(of:)`, which works but is a
    /// needless indirection over a 3-case switch). `combineWithMaskID`
    /// gets a THIRD variable-length pass (after `brushPoints`' own),
    /// mirroring that pass's "count/presence flag first, then the raw
    /// data" shape: a byte count of 0 (nil) vs. 16 (present) doubles as
    /// the presence flag, so a nil and a present-but-different-valued
    /// reference never collide on the count alone. Unlike every
    /// `Double.bitPattern` mixed above, `UUID.uuid` is already a raw byte
    /// TUPLE, not a numeric value with an endianness convention to
    /// normalize — `withUnsafeBytes` yields its 16 bytes in a fixed,
    /// deterministic order with no `.bigEndian`/`.byteSwapped` step
    /// needed, unlike the `laneA.bigEndian`/`laneB` output step at the
    /// very end of this function (that asymmetry is intentional: it's
    /// UUID bytes flowing IN as already-deterministic raw data, versus
    /// this function's own OUTPUT lanes, which do need normalizing).
    private static func deterministicFallbackID(
        kind: MaskKind, centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
        rotationDegrees: Double, feather: Double, width: Double, brushSize: Double,
        brushPoints: [BrushPoint], luminanceTarget: Double, luminanceRange: Double,
        colorRangeTargetHue: Double, colorRangeTargetSaturation: Double,
        colorRangeTargetLuminance: Double, colorRangeTolerance: Double, colorRangeHasTarget: Bool,
        exposureEV: Double, contrast: Double, highlights: Double, shadows: Double,
        clarity: Double, saturation: Double, temperature: Double, tint: Double,
        combineMode: MaskCombineMode, combineWithMaskID: UUID?,
        subjectMaskPNG: Data?, subjectMaskRevision: Int?, invertSelection: Bool,
        subjectInstancePNGs: [Data], subjectInstanceEnabled: [Bool], subjectFeather: Double
    ) -> UUID {
        let combineModeSeed: Double
        switch combineMode {
        case .none: combineModeSeed = 0
        case .intersect: combineModeSeed = 1
        case .subtract: combineModeSeed = 2
        }
        let values = [
            centerX, centerY, radiusX, radiusY, rotationDegrees, feather, width, brushSize,
            luminanceTarget, luminanceRange,
            colorRangeTargetHue, colorRangeTargetSaturation, colorRangeTargetLuminance, colorRangeTolerance,
            colorRangeHasTarget ? 1 : 0,
            exposureEV, contrast, highlights, shadows, clarity, saturation, temperature, tint,
            combineModeSeed
        ]
        let kindSeed: UInt64
        switch kind {
        case .radial: kindSeed = 0x9e3779b97f4a7c15
        case .linear: kindSeed = 0x517cc1b727220a95
        case .brush: kindSeed = 0x2545f4914f6cdd1d
        case .luminanceRange: kindSeed = 0xbf58476d1ce4e5b9
        case .colorRange: kindSeed = 0x1b873593cc9e2d51
        case .subject: kindSeed = 0x6a09e667f3bcc909
        }
        let prime: UInt64 = 0x100000001b3
        var laneA: UInt64 = (0xcbf29ce484222325 ^ kindSeed) &* prime
        var laneB: UInt64 = (0x9e3779b97f4a7c15 ^ kindSeed.byteSwapped) &* prime
        for value in values {
            let bits = value.bitPattern
            laneA = (laneA ^ bits) &* prime
            laneB = (laneB ^ bits.byteSwapped) &* prime
        }
        let pointValues = [Double(brushPoints.count)] + brushPoints.flatMap { [$0.x, $0.y] }
        for value in pointValues {
            let bits = value.bitPattern
            laneA = (laneA ^ bits) &* prime
            laneB = (laneB ^ bits.byteSwapped) &* prime
        }
        let combineIDBytes: [UInt8] = combineWithMaskID.map { id in
            withUnsafeBytes(of: id.uuid) { Array($0) }
        } ?? []
        laneA = (laneA ^ UInt64(combineIDBytes.count)) &* prime
        laneB = (laneB ^ UInt64(combineIDBytes.count).byteSwapped) &* prime
        for byte in combineIDBytes {
            laneA = (laneA ^ UInt64(byte)) &* prime
            laneB = (laneB ^ UInt64(byte).byteSwapped) &* prime
        }
        // Subject pass: invert flag and revision as scalars, then the PNG's length and bytes (variable
        // length, so count first — same shape as the `brushPoints`/`combineWithMaskID` passes).
        let subjectBytes = [UInt8](subjectMaskPNG ?? Data())
        let subjectScalars: [UInt64] = [
            invertSelection ? 1 : 0,
            subjectMaskRevision == nil ? 0 : 1,
            subjectMaskRevision.map { UInt64(bitPattern: Int64($0)) } ?? 0,
            subjectMaskPNG == nil ? 0 : 1,
            UInt64(subjectBytes.count)
        ]
        for scalar in subjectScalars {
            laneA = (laneA ^ scalar) &* prime
            laneB = (laneB ^ scalar.byteSwapped) &* prime
        }
        for byte in subjectBytes {
            laneA = (laneA ^ UInt64(byte)) &* prime
            laneB = (laneB ^ UInt64(byte).byteSwapped) &* prime
        }
        // Subject refinement pass: feather bits, then instance count, each instance (length, bytes), then
        // the enabled flags (count, then 0/1 each) — counts before data so shapes can't collide.
        var refinement: [UInt64] = [subjectFeather.bitPattern, UInt64(subjectInstancePNGs.count)]
        for png in subjectInstancePNGs {
            refinement.append(UInt64(png.count))
            refinement.append(contentsOf: png.map { UInt64($0) })
        }
        refinement.append(UInt64(subjectInstanceEnabled.count))
        refinement.append(contentsOf: subjectInstanceEnabled.map { $0 ? 1 : 0 })
        for scalar in refinement {
            laneA = (laneA ^ scalar) &* prime
            laneB = (laneB ^ scalar.byteSwapped) &* prime
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        withUnsafeBytes(of: laneA.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: laneB.bigEndian) { bytes.append(contentsOf: $0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // force a valid version nibble
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // force a valid variant
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
