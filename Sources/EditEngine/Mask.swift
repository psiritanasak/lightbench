import Foundation

/// Which geometry a `Mask` uses. `.radial` (an ellipse, Phase 7 slice 2)
/// reads `radiusX`/`radiusY`/`feather`; `.linear` (a graduated band, slice
/// 3) reads `width` instead; `.brush` (a freehand stroke, slice 4) reads
/// `brushPoints`/`brushSize`/`feather` instead — `feather` is now SHARED
/// between `.radial` and `.brush` (both a soft-edge amount around a drawn
/// shape), still inert only on `.linear`. The OTHER kind(s)' geometry
/// fields sit inert at their defaults, never read by
/// `EditPipeline.applyMasks`'s matching branch. `.radial`/`.linear` share
/// `centerX`/`centerY` (the anchor point) and `rotationDegrees` (the
/// mask's own local +X axis direction — see that field's own doc comment
/// for what "+X axis" means per kind); `.brush` uses neither — a stroke's
/// position lives entirely in `brushPoints`.
enum MaskKind: String, Codable {
    case radial
    case linear
    case brush
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

/// One local adjustment, radial (ellipse), linear (graduated band), or
/// brush (freehand stroke) per `kind` — Phase 7 slices 2/3/4's mask
/// geometry kinds. Lives in its own file, not inside `EditState.swift`
/// (already 1000+ lines), following `EditHistory.swift`'s precedent for a
/// standalone `EditEngine` type.
///
/// Unlike `RedEyePoint`/`RawNeutralPoint` (both trivial 2-`Double` points
/// with SYNTHESIZED `Codable`), `Mask` needs its OWN hand-written
/// schema-tolerant decoding — see the `extension Mask` below — because
/// slices 5-6 will add new geometry variants and combining flags to THIS
/// struct, so a mask written today must still decode after those land, the
/// same reasoning `EditState` itself already applies one level up. This is
/// also why `kind`/geometry live as FLAT fields on one struct rather than
/// an enum-with-associated-values: an associated-value variant would break
/// both the flat `CodingKeys` list below and `deterministicFallbackID`'s
/// fixed-arity parameter list.
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
    /// two can never drift apart. `.radial` only — inert on `.linear`.
    var feather: Double = 0.5

    /// `.linear` only — inert on `.radial`. The FULL guide-to-guide
    /// distance (not a half-width), as a fraction of
    /// `min(extent.width, extent.height)` — the same non-axis-specific
    /// denominator Definition/Sharpen's own radii use, chosen for the
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
    /// 0...1, ONE-DIRECTIONAL like `EditState.definition` — `CIUnsharpMask`
    /// is measured (see that field's own doc comment) to silently clamp
    /// negative intensity to a bit-identical no-op, so a bipolar range here
    /// would ship a provably dead half of the slider.
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

    /// `true` when every adjustment param is at its identity (0) —
    /// geometry-only. `EditPipeline.applyMasks` skips a mask entirely when
    /// this is `true`, which is what makes a geometry-only mask render
    /// BYTE-IDENTICAL to no mask at all. Deliberately excludes geometry —
    /// including `kind`/`width`/`brushSize`/`brushPoints` (added slices 3-4):
    /// a mask can be `isIdentity` yet still a real, undo-worthy edit (the
    /// user placed it or painted a stroke), mirroring `redEyePoints`' own
    /// existing behavior (a placed point with strength 0 renders
    /// identically but still counts as an edit) — see
    /// `EditState.isEffectivelyIdentity`.
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
        case exposureEV, contrast, highlights, shadows
        case clarity, saturation, temperature, tint
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
        // well-typed value. `.brush` is real as of slice 4; a future
        // slice 5/6 kind string still falls back to `.radial` the same way.
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
        exposureEV = try container.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
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
                brushPoints: brushPoints,
                exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
                clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
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
    private static func deterministicFallbackID(
        kind: MaskKind, centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
        rotationDegrees: Double, feather: Double, width: Double, brushSize: Double,
        brushPoints: [BrushPoint],
        exposureEV: Double, contrast: Double, highlights: Double, shadows: Double,
        clarity: Double, saturation: Double, temperature: Double, tint: Double
    ) -> UUID {
        let values = [
            centerX, centerY, radiusX, radiusY, rotationDegrees, feather, width, brushSize,
            exposureEV, contrast, highlights, shadows, clarity, saturation, temperature, tint
        ]
        let kindSeed: UInt64
        switch kind {
        case .radial: kindSeed = 0x9e3779b97f4a7c15
        case .linear: kindSeed = 0x517cc1b727220a95
        case .brush: kindSeed = 0x2545f4914f6cdd1d
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
