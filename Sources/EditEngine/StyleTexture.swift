import Foundation

/// The Style section's textures (our own interpretations — Apple has not published what its textures do to the pixels).
/// A texture is a bundle of render-time nudges to the detail stages (Texture, Clarity, Sharpen) plus, for Glow, a highlight
/// bloom; it never writes the user's own sliders. Every number is a CONVENTION chosen by eye, owned by the renderer, so
/// retuning restyles photos already carrying that id.
enum StyleTexture: String, CaseIterable, Identifiable, Sendable {
    /// Smooths fine detail (negative Texture, a touch of negative Clarity). Not skin-aware: it softens everything alike.
    case soft
    /// A highlight bloom: bright areas bleed a soft light into their surroundings. Its `glow` nudge is consumed by the Glow
    /// stage (a separate commit; until that lands Glow renders only its small Clarity nudge, so the UI must not expose it first).
    case glow
    /// Crisp, slightly gritty rendering (mild positive Texture and Sharpen). Grain is its own toggle, available on any texture.
    case film

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: return "Soft"
        case .glow: return "Glow"
        case .film: return "Film"
        }
    }

    /// The nudges at full amount.
    fileprivate var nudges: StyleDetailNudges {
        switch self {
        case .soft: return StyleDetailNudges(texture: -0.5, clarity: -0.15)
        case .glow: return StyleDetailNudges(clarity: -0.05, glow: 1.0)
        case .film: return StyleDetailNudges(texture: 0.2, sharpness: 0.15)
        }
    }
}

/// What the texture group adds at render time, in the pipeline's own units.
struct StyleDetailNudges: Equatable, Sendable {
    var texture = 0.0
    var clarity = 0.0
    var sharpness = 0.0
    var grain = 0.0
    var glow = 0.0

    static let zero = StyleDetailNudges()

    var isZero: Bool { self == .zero }
}

extension StyleMath {
    /// The Grain toggle's fixed amount (a convention, by eye), added to whatever the user's own Grain slider is set to.
    static let toggleGrainAmount = 0.25

    /// True when no texture is chosen and Grain is off: the texture group contributes nothing, whatever the texture-strength
    /// slider says (a lone strength is an invisible edit the UI resets). A non-empty UNKNOWN id is deliberately NOT identity:
    /// it is kept so a photo edited in a newer build keeps its texture when reopened here (it renders as none meanwhile).
    static func isDetailIdentity(texture: String, grain: Bool) -> Bool {
        texture.isEmpty && !grain
    }

    /// The detail nudges for (texture id, texture strength, Grain toggle). The texture's nudges scale exactly linearly with
    /// `amount` (clamped to 0...1; non-finite counts as 0 — it must never reach the renderer or a sidecar). The Grain toggle is
    /// INDEPENDENT of `amount` (a toggle, not a slider) and of the texture. An unknown id behaves as no texture.
    static func detailNudges(texture: String, amount: Double, grain: Bool) -> StyleDetailNudges {
        var result = StyleDetailNudges.zero
        if let kind = StyleTexture(rawValue: texture) {
            let a = amount.isFinite ? min(max(amount, 0), 1) : 0
            let base = kind.nudges
            result = StyleDetailNudges(
                texture: base.texture * a, clarity: base.clarity * a, sharpness: base.sharpness * a, grain: 0, glow: base.glow * a
            )
        }
        if grain { result.grain = toggleGrainAmount }
        return result
    }
}
