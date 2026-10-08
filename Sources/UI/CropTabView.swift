import SwiftUI

/// The Editor's Crop tab: geometry adjustments (straighten, perspective,
/// scale/stretch, flip), the Aspect preset list, and the four crop-inset
/// sliders.
///
/// The aspect LOGIC deliberately stays in `ContentView` and arrives here as
/// closures: `selectAspect(_:)`/`resetCropTab()` both need `currentFitRect`,
/// which depends on the editor's measured `containerSize`, and `ContentView`
/// itself also reads `effectiveAspectRatio` for the on-image crop overlay.
/// Splitting that math across two views would duplicate it.
struct CropTabView: View {
    @ObservedObject var document: ImageDocumentModel
    let selectedAspect: CropAspectPreset
    let onSelectAspect: (CropAspectPreset) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditSliderRow(
                label: "Straighten", value: $document.editState.straightenAngle,
                range: -45...45, identity: 0
            ) { String(format: "%+.1f°", $0) }
            EditSliderRow(
                label: "Vertical", value: $document.editState.verticalPerspective,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Horizontal", value: $document.editState.horizontalPerspective,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Scale", value: $document.editState.transformScale,
                range: 0.5...1.5, identity: 1.0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Stretch", value: $document.editState.transformAspect,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditToggleRow(label: "Flip Horizontal", value: $document.editState.flipHorizontal)
            EditToggleRow(label: "Flip Vertical", value: $document.editState.flipVertical)

            Divider()
            aspectSection
            Divider()

            EditSliderRow(
                label: "Crop Top", value: $document.editState.cropInsetTop,
                range: 0...0.45, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Bottom", value: $document.editState.cropInsetBottom,
                range: 0...0.45, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Left", value: $document.editState.cropInsetLeft,
                range: 0...0.45, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Right", value: $document.editState.cropInsetRight,
                range: 0...0.45, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }

            Button("Reset") { onReset() }
                .buttonStyle(.flat)
                .disabled(document.currentImage == nil)
        }
    }

    /// The Aspect preset list — a full always-visible vertical list (not a
    /// compact dropdown), matching Apple Photos' own Crop-panel layout now
    /// that it has a dedicated tab to live in. Each row is tappable; the
    /// selected preset shows a checkmark.
    private var aspectSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Aspect")
                .font(.headline)
                .padding(.bottom, 2)
            ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                Button {
                    onSelectAspect(preset)
                } label: {
                    HStack {
                        Text(preset.label)
                        Spacer()
                        if preset == selectedAspect {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                // D6 (IMPROVEMENTS.md): the row's own
                                // `.isSelected` trait below already conveys
                                // this; without hiding it too, VoiceOver
                                // would announce the checkmark redundantly
                                // as a second, unlabeled glyph.
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .accessibilityAddTraits(preset == selectedAspect ? [.isSelected] : [])
            }
        }
    }
}
