import SwiftUI

/// The selected Point Color instance's rows — a top-level `struct`,
/// deliberately NOT a computed property inside `AdjustTabView`, matching
/// `MaskDetailView`'s own precedent (that file's `body` `VStack` already
/// has many children, and two of its own doc comments warn of a real
/// Swift type-checker blow-up from over-packed `@ViewBuilder` closures).
///
/// One `@Binding var pointColor: PointColor` (not `Binding<EditState>`
/// narrowed elsewhere) is the right granularity — it already structurally
/// cannot touch any other instance or any global field, and it resolves
/// the by-ID lookup (`Binding<EditState>.pointColor(id:)`,
/// `PointColorBinding.swift`) exactly once per view build.
///
/// Picking the color itself is a mouse-AND-keyboard spatial tap —
/// `ContentView` wires this instance's picking mode into the same
/// `crosshairPosition`/`handlePointPlacementKeyPress`/
/// `EditorCrosshairOverlay` machinery the White Balance/Red-Eye eyedroppers
/// already use, closing this feature's own share of that gap at ship
/// rather than opening a third instance of it. `.colorRange`'s own picker
/// (once mouse-only, logged as IMPROVEMENTS.md D14) now routes through the
/// identical machinery too — see `MaskDetailView`'s own doc comment.
struct PointColorDetailView: View {
    @Binding var pointColor: PointColor
    /// Called when "Pick Color"/"Re-pick Color" is tapped — mirrors
    /// `MaskDetailView.onBeginColorPick`'s shape exactly.
    var onBeginColorPick: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(pointColor.hasTarget ? "Re-pick Color" : "Pick Color") {
                onBeginColorPick?()
            }
            .buttonStyle(FlatButtonStyle(fullWidth: true))

            if pointColor.hasTarget {
                // Reconstructed from the 2 stored scalars via
                // `PointColorSelection.displaySRGB` — never a redundant
                // stored RGB field that could drift from what the kernel
                // uses. `.accessibilityHidden(true)`: the adjacent text
                // readout is the accessible answer, matching
                // `MaskDetailView.colorRangeShapeRows`' own precedent.
                // Deliberately shows Hue/Saturation only, at a fixed mid
                // lightness — `PointColor` stores no target luminance
                // (IMPROVEMENTS.md D22), so there is no picked brightness
                // to reconstruct.
                let swatch = PointColorSelection.displaySRGB(
                    hue: pointColor.targetHue, saturation: pointColor.targetSaturation
                )
                HStack {
                    Circle()
                        .fill(Color(red: swatch.r, green: swatch.g, blue: swatch.b))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                        .accessibilityHidden(true)
                    Text(String(format: "Hue %.0f°  Sat %.0f%%", pointColor.targetHue, pointColor.targetSaturation * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No color picked yet").font(.caption).foregroundStyle(.secondary)
            }

            EditSliderRow(
                label: "Hue", value: $pointColor.hue, range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $pointColor.saturation, range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Luminance", value: $pointColor.luminance, range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            // Cites `PointColorTuning.hueWindow(forRange:)`/
            // `saturationWindow(forRange:)` directly, never literals — the
            // same single-source-of-truth discipline every other kind's
            // ranges already follow. The `.help` tooltip shows the ACTUAL
            // window at the current slider position (not just the static
            // min/max), the same "cite the real function" reasoning
            // extended to a live value.
            EditSliderRow(
                label: "Range", value: $pointColor.range, range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            .help(String(
                format: "Selects colors within ±%.0f° hue and ±%.0f%% saturation of the picked target",
                PointColorTuning.hueWindow(forRange: pointColor.range),
                PointColorTuning.saturationWindow(forRange: pointColor.range) * 100
            ))
        }
    }
}
