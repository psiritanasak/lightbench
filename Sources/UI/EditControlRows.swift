import SwiftUI

/// A single edit-adjustment control: label + live readout on one line, with
/// a Reset button, and a full-width slider below — label-above-slider,
/// matching Lightroom/Photos' sidebar inspector convention (as opposed to a
/// label-beside-slider `HStack`, which gets cramped in a ~300pt-wide panel).
struct EditSliderRow: View {
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
                Button {
                    value = identity
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(value == identity)
                .accessibilityLabel("Reset \(label)")
            }
            ThinSlider(value: $value, range: range)
                .accessibilityLabel(label)
        }
    }
}

/// A single boolean edit-adjustment control: label + `Toggle` on one line.
/// No Reset button — unlike a continuous slider, a boolean is already
/// trivially reversible with a single click either direction.
struct EditToggleRow: View {
    let label: String
    @Binding var value: Bool

    var body: some View {
        Toggle(label, isOn: $value)
    }
}
