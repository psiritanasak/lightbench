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
            Button {
                document.autoStraighten()
            } label: {
                Label(document.isAutoStraightening ? "Finding horizon…" : "Auto", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.flat)
            .disabled(document.currentImage == nil || document.isAutoStraightening || document.isAutoUprighting)
            .help("Find the horizon and set Straighten to level it")
            .alert(
                "Auto Straighten",
                isPresented: Binding(
                    get: { document.straightenMessage != nil },
                    set: { if !$0 { document.straightenMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(document.straightenMessage ?? "")
            }
            HStack(spacing: 8) {
                uprightButton(.level, title: "Level", help: "Find the dominant lines and rotate the photo so they are level")
                uprightButton(.vertical, title: "Vertical", help: "Straighten vertical lines: rotate and correct keystone so they run parallel")
            }
            .alert(
                "Upright",
                isPresented: Binding(
                    get: { document.uprightMessage != nil },
                    set: { if !$0 { document.uprightMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(document.uprightMessage ?? "")
            }
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

    private func uprightButton(_ mode: UprightMode, title: String, help: String) -> some View {
        Button {
            document.autoUpright(mode)
        } label: {
            Label(document.runningUprightMode == mode ? "Finding lines…" : title, systemImage: "wand.and.stars")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.flat)
        .disabled(document.currentImage == nil || document.isAutoUprighting || document.isAutoStraightening)
        .help(help)
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
                                .foregroundStyle(Theme.textSecondary)
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
