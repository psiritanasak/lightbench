import SwiftUI

/// Color Grading Slice B: which of the 4 wheels (3 tonal ranges + Global) the "Color Grading"
/// section's single shared `ColorGradingWheelView` currently shows/edits —
/// presentation-only, not stored in `EditState` itself (which holds all 4
/// wheels' Hue/Saturation/Luminance at once), matching the existing
/// `selectedToneCurveChannel`/`selectedSelectiveColorBand` pattern.
///
/// `String, CaseIterable, Identifiable` with the rawValue doubling as the
/// display label — same shape as `ToneCurveChannel`, since this also drives
/// a segmented `Picker`.
enum ColorGradingRange: String, CaseIterable, Identifiable {
    case shadow = "Shadows"
    case midtone = "Midtones"
    case highlight = "Highlights"
    /// The 4th wheel: a uniform wash over the whole tonal range (`EditState.globalHue/Saturation/Luminance`).
    case global = "Global"

    var id: String { rawValue }
}
