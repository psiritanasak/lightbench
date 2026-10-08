import SwiftUI

/// One rail entry's face: an SF Symbol over a small caption. Shared by the tab entries and the action entries so both look
/// identical. `isOn` = the accent-tinted "selected / active" state (the current tab, History open, Compare active, Filmstrip
/// visible); `isEnabled == false` dims it. Drawing only — the caller owns the button / menu around it.
struct RailEntryLabel: View {
    let title: String
    let symbol: String
    var isOn = false
    var isEnabled = true

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17))
            Text(title).font(.system(size: 10)).lineLimit(1)
        }
        .frame(width: EditorToolRailMetrics.width - 8, height: Self.height)
        // Dimmed through the COLOUR, not `.opacity`: a `Menu` draws its label itself and ignores an opacity set on it, but it follows
        // the foreground colour (this is what makes a disabled Compare entry look disabled like the others).
        .foregroundStyle(Self.color(isOn: isOn, isEnabled: isEnabled))
        .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.accentColor.opacity(isEnabled ? 0.18 : 0.06) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    static let height: CGFloat = 48

    /// The enabled colours are the plain `Color.accentColor` / `Color.secondary` values (wrapping them in `.opacity(1)` changed how a
    /// `Menu` label resolved the accent); only a disabled entry gets a dimmed copy.
    private static func color(isOn: Bool, isEnabled: Bool) -> Color {
        let base = isOn ? Color.accentColor : Color.secondary
        return isEnabled ? base : base.opacity(0.35)
    }
}
