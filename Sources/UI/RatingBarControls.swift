import SwiftUI

/// Pick / Reject button shared by the Editor's rating bar and Cull's bottom bar, so the two look and read alike. The caller decides
/// what a press means (the Editor toggles the photo's current state back to unflagged; Cull sends the flag key's command).
struct FlagToggleButton: View {
    let target: FlagStatus
    let current: FlagStatus
    let isEnabled: Bool
    let help: String
    let onFlag: (FlagStatus) -> Void

    var body: some View {
        let isOn = current == target
        Button {
            onFlag(target)
        } label: {
            Image(systemName: isOn ? target.symbolName : (target == .picked ? "flag" : "xmark.circle"))
                .foregroundStyle(isOn ? target.tint : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(target == .picked ? "Pick" : "Reject")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The six colour-label dots (the current label ringed), shared by the Editor's rating bar and Cull's bottom bar. The caller decides
/// what a press means.
struct ColorLabelDots: View {
    let current: ColorLabel
    let isEnabled: Bool
    let onLabel: (ColorLabel) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.px5) {
            ForEach(ColorLabel.menuOrder.filter { $0 != .none }, id: \.self) { label in
                let isOn = current == label
                Button { onLabel(label) } label: {
                    Circle().fill(label.color).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.primary.opacity(isOn ? 0.9 : 0.15), lineWidth: isOn ? 2 : 1))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(label.accessibilityName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
