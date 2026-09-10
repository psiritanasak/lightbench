import SwiftUI

/// The selected mask's slider rows (14 for `.radial`, 12 for `.linear`) —
/// a top-level `struct`, deliberately
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
/// These rows ARE the accessibility answer for the on-image mask overlays
/// (`MaskOverlayView` for `.radial`, `LinearMaskOverlayView` for `.linear`),
/// not a nice-to-have: they're what lets both overlays be
/// `.accessibilityHidden(true)` the same way `CropOverlayView` already is —
/// justified there, and here, ONLY because the same values are
/// independently AT-adjustable via labeled sliders. Without these rows,
/// mask geometry would be the only `EditState`-backed value in the app
/// reachable solely by mouse.
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

    /// Kind-switched (Phase 7 slice 3) — the shape params genuinely differ
    /// per kind (an ellipse's radii/feather vs. a graduated band's width),
    /// while `centerX`/`centerY` and the rotation convention are shared
    /// (see `Mask.rotationDegrees`'s own doc comment for why there's only
    /// ONE rotation field/sign rule across both kinds).
    @ViewBuilder private var shapeRows: some View {
        switch mask.kind {
        case .radial: radialShapeRows
        case .linear: linearShapeRows
        }
    }

    private var radialShapeRows: some View {
        Group {
            centerRows
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

    private var linearShapeRows: some View {
        Group {
            centerRows
            // -180...180, NOT the ellipse's -90...90: a LINE has no
            // 180-degree symmetry -- flipping it 180 degrees swaps WHICH
            // SIDE of the frame gets the effect (Mask.rotationDegrees'
            // own doc comment), so the full range is real travel here,
            // not duplicate travel.
            EditSliderRow(
                label: "Angle", value: $mask.rotationDegrees,
                range: -180...180, identity: 0
            ) { String(format: "%+.0f°", $0) }
            // The FULL guide-to-guide distance, not a half-width; 0 is a
            // legitimate hard edge (clamped to LinearMaskGeometry
            // .minimumWidth in the render), unlike a zero-radius ellipse,
            // which is a no-op -- see Mask.width's own doc comment. Range
            // cites MaskGeometry.minWidth/maxWidth (Phase 7 slice 3
            // Session B), the same "keep the two in sync, or a drag could
            // produce a value the slider then silently clamps away"
            // discipline that file's own doc comment already states for
            // minRadius/maxRadius -- a plain 0...1 literal here would be
            // a second, driftable source of truth for the same bounds
            // LinearMaskOverlayView's own drag math already clamps to.
            EditSliderRow(
                label: "Width", value: $mask.width,
                range: MaskGeometry.minWidth...MaskGeometry.maxWidth, identity: 0.3, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    /// Shared between both kinds — the mask's anchor point, same
    /// semantics regardless of `kind` (see `Mask.centerX`/`centerY`'s own
    /// doc comment).
    private var centerRows: some View {
        Group {
            EditSliderRow(
                label: "Center X", value: $mask.centerX,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Center Y", value: $mask.centerY,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }
}
