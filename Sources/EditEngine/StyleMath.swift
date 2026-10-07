import Foundation

/// What a style adds at render time, in the pipeline's own units (each tone value is clamped to -1...1; tints keep their
/// hue and have their saturation scaled).
struct StyleNudges: Equatable, Sendable {
    var contrast = 0.0
    var shadows = 0.0
    var highlights = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var shadowTint = StyleTint.none
    var midTint = StyleTint.none
    var highlightTint = StyleTint.none

    static let zero = StyleNudges()

    var isZero: Bool { self == .zero }
    var hasTint: Bool { shadowTint.saturation != 0 || midTint.saturation != 0 || highlightTint.saturation != 0 }
}

/// Strength is exactly linear: every output (tone nudges and tint saturations) is the clamped preset+pad sum times strength.
///
/// Pure math from a style's stored parameters (preset id, pad Tone/Color, strength) to the nudges the renderer adds.
/// No Core Image, no UI: exact-number testable.
///
/// The pad mapping is a CONVENTION (v1, tuned by eye, not measured): Tone (Y, -1...1) lifts/deepens the shadows with a
/// small opposite contrast move; Color (X, -1...1) drives Vibrance more than Saturation, because `CIVibrance` already
/// protects skin and already-saturated tones — the only skin handling v1 has (real masking is v3).
enum StyleMath {
    static let toneShadowWeight = 0.5
    static let toneContrastWeight = -0.25
    static let colorVibranceWeight = 0.5
    static let colorSaturationWeight = 0.25

    /// True when nothing is selected and the pad sits at the centre: the style contributes exactly nothing, whatever the
    /// strength slider says (a lone strength is an invisible edit the UI resets). A non-finite pad value counts as the
    /// centre (the same sanitising `nudges` does). An UNKNOWN non-empty id is deliberately NOT identity: the id is kept so a
    /// photo edited in a newer build keeps its style when reopened here (it renders as no preset meanwhile).
    static func isIdentity(id: String, tone: Double, color: Double) -> Bool {
        id.isEmpty && (tone.isFinite ? tone : 0) == 0 && (color.isFinite ? color : 0) == 0
    }

    /// The nudges for (preset `id`, pad `tone`/`color`, `strength`). Strength scales the WHOLE style (preset + pad + tints),
    /// is clamped to 0...1, and a non-finite strength or pad value contributes nothing (a NaN must never reach the
    /// renderer or a sidecar). An unknown id behaves as no preset (the pad still applies).
    static func nudges(id: String, tone: Double, color: Double, strength: Double) -> StyleNudges {
        guard strength.isFinite else { return .zero }
        let s = min(max(strength, 0), 1)
        let t = tone.isFinite ? min(max(tone, -1), 1) : 0
        let c = color.isFinite ? min(max(color, -1), 1) : 0
        let preset = StyleLibrary.preset(for: id)
        // Clamp the preset+pad SUM first, then scale: scaling first leaves a dead zone (a sum past +-1 clamps to the same value
        // over the top of the strength range) and breaks strength's linearity. s is in 0...1, so the result stays in range.
        func bound(_ v: Double) -> Double { min(max(v, -1), 1) * s }
        func scaled(_ tint: StyleTint?) -> StyleTint {
            guard let tint, tint.saturation > 0 else { return .none }
            let saturation = min(max(tint.saturation * s, 0), 1)
            return saturation == 0 ? .none : StyleTint(hue: tint.hue, saturation: saturation)   // a zero tint has no hue
        }
        return StyleNudges(
            contrast: bound((preset?.contrast ?? 0) + t * toneContrastWeight),
            shadows: bound((preset?.shadows ?? 0) + t * toneShadowWeight),
            highlights: bound(preset?.highlights ?? 0),
            saturation: bound((preset?.saturation ?? 0) + c * colorSaturationWeight),
            vibrance: bound((preset?.vibrance ?? 0) + c * colorVibranceWeight),
            shadowTint: scaled(preset?.shadowTint),
            midTint: scaled(preset?.midTint),
            highlightTint: scaled(preset?.highlightTint)
        )
    }
}
