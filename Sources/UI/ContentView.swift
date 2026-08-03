import SwiftUI

struct ContentView: View {
    @StateObject private var document = ImageDocumentModel()

    var body: some View {
        HSplitView {
            MetalImageView(image: document.currentImage, editState: document.editState)
                .frame(minWidth: 480, minHeight: 360)
                .layoutPriority(1)

            editControls
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Open…") {
                    document.openImage()
                }
            }
        }
        .navigationTitle(document.currentFileName ?? "PhotoApp")
        .alert(
            "Couldn't Open Image",
            isPresented: Binding(
                get: { document.loadErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { document.loadErrorMessage = nil }
                }
            ),
            presenting: document.loadErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var editControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EditSliderRow(
                    label: "Temperature", value: $document.editState.whiteBalanceTemperature,
                    range: 3500...9500, identity: 6500
                ) { String(format: "%.0fK", $0) }
                EditSliderRow(
                    label: "Tint", value: $document.editState.whiteBalanceTint,
                    range: -100...100, identity: 0
                ) { String(format: "%+.0f", $0) }
                EditSliderRow(
                    label: "Exposure", value: $document.editState.exposureEV,
                    range: -5...5, identity: 0
                ) { String(format: "%+.2f EV", $0) }
                EditSliderRow(
                    label: "Brightness", value: $document.editState.brightness,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Brilliance", value: $document.editState.brilliance,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Contrast", value: $document.editState.contrast,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Highlights", value: $document.editState.curvesHighlights,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Shadows", value: $document.editState.curvesShadows,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Black Point", value: $document.editState.blackPoint,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Hue", value: $document.editState.hslHue,
                    range: -180...180, identity: 0
                ) { String(format: "%+.0f°", $0) }
                EditSliderRow(
                    label: "Saturation", value: $document.editState.hslSaturation,
                    range: -1...1, identity: 0
                ) { String(format: "%+.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Crop Top", value: $document.editState.cropInsetTop,
                    range: 0...0.45, identity: 0
                ) { String(format: "%.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Crop Bottom", value: $document.editState.cropInsetBottom,
                    range: 0...0.45, identity: 0
                ) { String(format: "%.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Crop Left", value: $document.editState.cropInsetLeft,
                    range: 0...0.45, identity: 0
                ) { String(format: "%.0f%%", $0 * 100) }
                EditSliderRow(
                    label: "Crop Right", value: $document.editState.cropInsetRight,
                    range: 0...0.45, identity: 0
                ) { String(format: "%.0f%%", $0 * 100) }
            }
            .padding()
        }
        .disabled(document.currentImage == nil)
    }
}

/// A single edit-adjustment control: label + live readout on one line, with
/// a Reset button, and a full-width slider below — label-above-slider,
/// matching Lightroom/Photos' sidebar inspector convention (as opposed to a
/// label-beside-slider `HStack`, which gets cramped in a ~300pt-wide panel).
private struct EditSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identity: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Reset") {
                    value = identity
                }
                .disabled(value == identity)
            }
            Slider(value: $value, in: range)
        }
    }
}

#Preview {
    ContentView()
}
