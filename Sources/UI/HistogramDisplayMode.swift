import Foundation

/// Whether `HistogramView` draws luminance only, or luminance + per-channel
/// RGB overlays. Presentation-only — `HistogramData` always carries all
/// four series; this just tracks which the UI currently shows, matching the
/// existing `selectedTab`/`selectedSelectiveColorBand` transient-`@State`
/// pattern.
enum HistogramDisplayMode: String, CaseIterable, Identifiable {
    case luminance = "Luminance"
    case rgb = "RGB"

    var id: String { rawValue }
}
