import SwiftUI

/// The selected mask's 14 slider rows — a top-level `struct`, deliberately
/// NOT a computed property inside `AdjustTabView` (that file's `body`
/// `VStack` already has 15 children, and two of its own doc comments warn
/// of a real, already-hit Swift type-checker blow-up from over-packed
/// `@ViewBuilder` closures; 14 more rows plus the list/add/delete chrome
/// would repeat exactly that mistake).
///
/// One `@Binding var mask: Mask` (not `Binding<EditState>` narrowed
/// elsewhere, not 14 separate scalar bindings) is the right granularity —
/// it already structurally cannot touch any other mask or any global field,
/// and it resolves the by-ID lookup (`Binding<EditState>.mask(id:)`,
/// `MaskBinding.swift`) exactly once per view build, not 14 times.
///
/// These 14 rows ARE the accessibility answer for `MaskOverlayView`, not a
/// nice-to-have: they're what lets that overlay be `.accessibilityHidden(true)`
/// the same way `CropOverlayView` already is — justified there, and here,
/// ONLY because the same values are independently AT-adjustable via labeled
/// sliders. Without these rows, mask geometry would be the only
/// `EditState`-backed value in the app reachable solely by mouse.
struct MaskDetailView: View {
    @Binding var mask: Mask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjustments").font(.caption).foregroundStyle(.secondary)
            toneRows
            colorRows
            Text("Shape").font(.caption).foregroundStyle(.secondary)
            shapeRows
        }
    }

    private var toneRows: some View {
        Group {
            EditSliderRow(
                label: "Exposure", value: $mask.exposureEV,
                range: -5...5, identity: 0
            ) { String(format: "%+.2f EV", $0) }
            EditSliderRow(
                label: "Contrast", value: $mask.contrast,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Highlights", value: $mask.highlights,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Shadows", value: $mask.shadows,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
        }
    }

    private var colorRows: some View {
        Group {
            // Clarity is 0...1, ONE-DIRECTIONAL, NOT bipolar -- matching
            // the global Definition slider. Mask.clarity's own doc comment
            // records CIUnsharpMask's measured negative-intensity no-op;
            // a bipolar range here would ship a provably dead half.
            EditSliderRow(
                label: "Clarity", value: $mask.clarity,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $mask.saturation,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            // A Kelvin OFFSET from wherever white balance already left the
            // image, NOT an absolute value like the global Temperature row
            // -- see Mask.temperature's own doc comment.
            EditSliderRow(
                label: "Temperature", value: $mask.temperature,
                range: -2000...2000, identity: 0
            ) { String(format: "%+.0fK", $0) }
            EditSliderRow(
                label: "Tint", value: $mask.tint,
                range: -100...100, identity: 0
            ) { String(format: "%+.0f", $0) }
        }
    }

    private var shapeRows: some View {
        Group {
            EditSliderRow(
                label: "Center X", value: $mask.centerX,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Center Y", value: $mask.centerY,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Radius X", value: $mask.radiusX,
                range: MaskGeometry.minRadius...MaskGeometry.maxRadius, identity: 0.25, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Radius Y", value: $mask.radiusY,
                range: MaskGeometry.minRadius...MaskGeometry.maxRadius, identity: 0.25, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            // -90...90, not -180...180: an ellipse has 180-degree symmetry,
            // so the wider range would be duplicate travel -- the same
            // "don't expose measured-dead travel" discipline CLAUDE.md
            // documents for rawMoireReductionAdjust.
            EditSliderRow(
                label: "Rotation", value: $mask.rotationDegrees,
                range: -90...90, identity: 0
            ) { String(format: "%+.0f°", $0) }
            EditSliderRow(
                label: "Feather", value: $mask.feather,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }
}
