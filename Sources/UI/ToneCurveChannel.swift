import SwiftUI

/// Curves v2 slice 3: which of the four tone curves `ToneCurveEditorView`
/// currently shows/edits — presentation-only, not stored in `EditState`
/// itself (which holds all four `toneCurvePoints`/`toneCurvePointsRed/
/// Green/Blue` arrays at once); this only tracks which one the Curve
/// section's canvas currently targets, matching the existing
/// `selectedSelectiveColorBand`/`selectedMaskID` pattern.
///
/// `String, CaseIterable, Identifiable` with the rawValue doubling as the
/// display label — the same shape as `HistogramDisplayMode`, not
/// `SelectiveColorBand`'s own `switch`-based `label`, because this enum
/// drives a segmented `Picker` exactly like `HistogramDisplayMode` already
/// does one section above this one in the sidebar (the Levels Luminance/
/// RGB picker), not a row of tappable swatches.
enum ToneCurveChannel: String, CaseIterable, Identifiable {
    case composite = "RGB"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"

    var id: String { rawValue }

    /// The curve stroke's tint in `ToneCurveEditorView.draw(into:plotRect:)`
    /// — `.white` for `.composite`, so the shipped composite curve's
    /// rendering is structurally unchanged by this slice (a claim about the
    /// code as it stands, not a measurement). Pure, fully-saturated R/G/B
    /// for the other three, matching each channel's own histogram overlay
    /// tint below so the two visual cues never disagree.
    var strokeColor: Color {
        switch self {
        case .composite: return .white
        case .red: return Color(red: 1, green: 0, blue: 0)
        case .green: return Color(red: 0, green: 1, blue: 0)
        case .blue: return Color(red: 0, green: 0, blue: 1)
        }
    }

    /// Which histogram series `ToneCurveEditorView`'s backdrop shows while
    /// this channel is active. `.composite` keeps the pre-slice-3
    /// luminance-only backdrop; each other case shows ONLY its own
    /// channel's series — not all three additively overlaid
    /// (`HistogramChannelOverlay.allChannels`, the Levels section's own
    /// choice), since a three-way overlay is specifically illegible for
    /// reading any one channel out of it, which is the whole point of
    /// showing a histogram while editing that channel's curve.
    var histogramOverlay: HistogramChannelOverlay {
        switch self {
        case .composite: return .luminanceOnly
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}

// MARK: - Segment labels and the edited caption (D21)

/// The Curve section's channel picker shows PLAIN labels (a trailing " •" on an edited channel resized the
/// `NSSegmentedControl`'s segments, shifting them when the first point was added) and a separate caption names
/// the edited channels, the way the Color Grading picker already does.
enum ToneCurveChannelLabels {
    /// The picker's label for `channel`: always its plain name, whatever its curve holds.
    static func segmentLabel(for channel: ToneCurveChannel) -> String { channel.rawValue }

    /// "Edited: Red, Blue" (picker order) for the channels in `edited`, or nil when none is.
    static func editedCaption(editedChannels edited: Set<ToneCurveChannel>) -> String? {
        let names = ToneCurveChannel.allCases.filter { edited.contains($0) }.map(\.rawValue)
        return names.isEmpty ? nil : "Edited: \(names.joined(separator: ", "))"
    }

    /// The caption row's text, ALWAYS non-empty: a blank line (" ") while nothing is edited keeps the row's
    /// height constant, so the curve canvas below never moves when the first point is added mid-drag.
    static func captionRowText(editedChannels edited: Set<ToneCurveChannel>) -> String {
        editedCaption(editedChannels: edited) ?? " "
    }
}
