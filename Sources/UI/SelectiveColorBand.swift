import SwiftUI

/// The 8 fixed Selective Color bands. Presentation-only — not stored in
/// `EditState` itself (which has 24 flat named fields, 3 per band); this
/// enum exists purely so the UI can track "which band's sliders are
/// currently shown" as transient `@State`, matching the existing
/// `selectedTab`/`selectedAspect` pattern.
enum SelectiveColorBand: CaseIterable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var label: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }

    /// A representative swatch color for the band picker — matches the
    /// kernel's own band centers (`Sources/Rendering/Shaders/
    /// SelectiveColor.cikernel`) closely enough to be recognizable, not a
    /// promise of exact hue-degree equivalence.
    var swatchColor: Color {
        switch self {
        case .red: return Color(red: 1, green: 0, blue: 0)
        case .orange: return Color(red: 1, green: 0.5, blue: 0)
        case .yellow: return Color(red: 1, green: 1, blue: 0)
        case .green: return Color(red: 0, green: 1, blue: 0)
        case .aqua: return Color(red: 0, green: 1, blue: 1)
        case .blue: return Color(red: 0, green: 0, blue: 1)
        case .purple: return Color(red: 0.667, green: 0, blue: 1)
        case .magenta: return Color(red: 1, green: 0, blue: 0.667)
        }
    }
}
