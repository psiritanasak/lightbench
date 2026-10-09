import SwiftUI

/// The app's quiet button: a solid `Theme.raised` chip with a hairline outline and white text — no bezel, gloss or system tint. Variants:
/// `isOn` = an armed / selected tool (a lighter grey chip with a white outline, never blue); `prominent` = the one primary action of a sheet or bar
/// (solid accent fill, white text); `fullWidth` = stretch to the row; `compact` = the small chip for keyword lists. Disabled buttons dim.
/// It replaces the system `.bordered` / `.borderedProminent` styles, whose label took the root tint's blue.
struct FlatButtonStyle: ButtonStyle {
    var isOn = false
    var prominent = false
    var fullWidth = false
    var compact = false

    @Environment(\.isEnabled) private var isEnabled

    /// The chip's fill; pure so the colours can be tested. Pressed = one step lighter (a prominent button, slightly translucent).
    static func fill(isOn: Bool, prominent: Bool, pressed: Bool) -> Color {
        if prominent { return pressed ? Theme.accent.opacity(0.8) : Theme.accent }
        if isOn { return pressed ? Theme.strongFill : Theme.armedFill }
        return pressed ? Theme.pressedFill : Theme.raised
    }

    static func outline(isOn: Bool, prominent: Bool) -> Color {
        if prominent { return .clear }
        return isOn ? Theme.selectedOutline : Theme.hairline
    }

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = compact ? 5 : 6
        return configuration.label
            .font(compact ? .caption : .body)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: radius).fill(Self.fill(isOn: isOn, prominent: prominent, pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Self.outline(isOn: isOn, prominent: prominent), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == FlatButtonStyle {
    /// The plain flat chip.
    static var flat: FlatButtonStyle { FlatButtonStyle() }
}
