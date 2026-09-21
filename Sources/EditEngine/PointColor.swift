import Foundation

/// One Point Color instance — Lightroom-style per-color eyedropper
/// refinement: pick an exact color from the photo, then adjust Hue/
/// Saturation/Luminance targeted at pixels similar to THAT picked color,
/// with an independent falloff `range`. Distinct from Selective Color's 8
/// FIXED hue bands (`EditState.redHue` etc.) — `EditState.pointColors` is a
/// variable-length array, this app's third such collection field after
/// `redEyePoints` and `masks` (see `EditState.masks`'s own doc comment for
/// the "inherently unbounded, per-photo" rationale this one shares).
///
/// Deliberately much smaller than `Mask`: no `kind` polymorphism, no
/// geometry, no combine mode — just a picked target plus an HSL delta.
/// `hasTarget`/`targetHue`/`targetSaturation` are written by the eyedropper
/// (Slice B, not yet built — Slice A ships this struct and its pipeline
/// stage settable only via a hand-edited sidecar or a preset). Unlike
/// `Mask.colorRangeTargetLuminance`, there is NO stored target luminance —
/// see `PointColor.cikernel`'s own header comment for why a luminance-
/// distance SELECTION axis was deliberately left out for v1 (headroom
/// normalization makes the kernel's own luminance RELATIVE, not a domain
/// mismatch the way it first looked — reviewer-corrected). Real, accepted
/// consequence: a bright highlight and a dark shadow of the same picked
/// hue/saturation are inseparable by this kernel (a divergence from
/// Lightroom's own Point Color, logged in IMPROVEMENTS.md).
///
/// **A picked target's window is narrow** (`PointColorTuning`'s own
/// saturation window is 0.05...0.5) — reviewer-caught implication for
/// Slice B: any upstream stage that moves a pixel's saturation (Selective
/// Color, global Hue, exposure/curves via headroom normalization) can
/// silently push a picked color out of its own instance's selection
/// window. The eyedropper MUST sample at this stage's own pipeline
/// position (immediately after Selective Color — see
/// `EditPipeline.applyPointColors`), not from the final displayed pixel
/// or the decoded original, the same "sample a truncated state" technique
/// `ImageDocumentModel.pickColorRangeTarget` already uses for `.colorRange`
/// masks.
struct PointColor: Identifiable, Equatable, Codable {
    var id: UUID = UUID()

    /// False until the eyedropper (Slice B) picks a color — an instance
    /// with no target selects nothing, matching `Mask.colorRangeHasTarget`'s
    /// own "an un-picked selector selects NOTHING, never an arbitrary
    /// default color" contract.
    var hasTarget: Bool = false
    /// Degrees, 0..<360. Irrelevant while `targetSaturation == 0` (a
    /// picked neutral/gray color has no meaningful hue), the same
    /// irrelevant-at-degenerate-saturation shape `EditState.shadowHue`
    /// already documents for Color Grading's own wheels.
    var targetHue: Double = 0
    /// Nominally 0...1, but NOT clamped to it: `PointColorSelection.
    /// hueSaturation(forPerceptualRGB:)` (Slice B's eyedropper) deliberately
    /// mirrors `PointColor.cikernel`'s own un-clamped `rgb2hsl` rather than
    /// `ColorRangeSelection`'s clamping one, so a picked pixel with a
    /// negative channel can legitimately store a value above 1 here
    /// (`PointColorSelectionTests.testHueSaturationDoesNotClampNegativeChannels`
    /// pins this). Reviewer-caught (round 2): render behavior stays correct
    /// either way (the kernel computes the identical value for the
    /// identical pixel, so the selection distance is unaffected), but
    /// `PointColorDetailView`'s swatch/readout DOES clamp to 1 for display
    /// and would under-report in that case.
    var targetSaturation: Double = 0
    /// 0...1, shared hue+saturation falloff width for THIS instance —
    /// mirrors `EditState.selectiveColorRange`'s own shared-dial
    /// precedent (one dial widens/narrows both axes at once), not two
    /// separate dials.
    var range: Double = 0.5

    /// -1...1, identity 0. Adjustment amounts — see
    /// `EditPipeline.applyPointColors` for how these combine with the
    /// hue/saturation-distance weight into a per-pixel delta.
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    /// True when every ADJUSTMENT field is at identity, regardless of
    /// `hasTarget`/target/range — matches `Mask.isIdentity`'s own
    /// convention (based on the adjustment fields only). This is the
    /// enable/skip mechanism: an un-picked instance, or a picked one with
    /// all-zero sliders, is a guaranteed no-op in the pipeline.
    var isIdentity: Bool {
        hue == 0 && saturation == 0 && luminance == 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, hasTarget, targetHue, targetSaturation, range, hue, saturation, luminance
    }
}

/// `init(from:)` lives in this extension, not the primary struct
/// declaration above — deliberately, matching `Mask`'s own file
/// structure: an initializer declared INSIDE a struct's primary
/// declaration suppresses Swift's synthesized memberwise initializer,
/// but one declared in an extension does not, so `PointColor(hasTarget:
/// targetHue: ...)` stays available (used throughout this app's tests
/// and, eventually, Slice B's UI) alongside this custom Codable decode.
extension PointColor {
    /// Custom, schema-tolerant decode (matches `Mask`'s own convention,
    /// not synthesized `Decodable`) — `decodeIfPresent(...) ?? default`
    /// per field, so a future added field never breaks an existing
    /// sidecar's already-saved `pointColors` entries.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hasTarget = try container.decodeIfPresent(Bool.self, forKey: .hasTarget) ?? false
        targetHue = try container.decodeIfPresent(Double.self, forKey: .targetHue) ?? 0
        targetSaturation = try container.decodeIfPresent(Double.self, forKey: .targetSaturation) ?? 0
        range = try container.decodeIfPresent(Double.self, forKey: .range) ?? 0.5
        hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try container.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }
}
