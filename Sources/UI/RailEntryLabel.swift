import SwiftUI

/// One rail entry's face: an SF Symbol, with a small caption under it unless `showsTitle` is false. The tab entries show the
/// caption; the action entries are icon-only. Shared so both groups are drawn by the same code. `isOn` is the quiet "selected /
/// active" state (the current tab, History open, Compare active, Filmstrip visible): a white icon on a grey chip, never blue.
/// `isEnabled == false` dims it. Drawing only — the caller owns the button / menu around it.
struct RailEntryLabel: View {
    let title: String
    let symbol: String
    var isOn = false
    var isEnabled = true
    /// false = icon only (the action group); the title then lives only in the tooltip and the accessibility label the caller sets.
    var showsTitle = true

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17))
            if showsTitle { Text(title).font(.system(size: 10)).lineLimit(1) }
        }
        .frame(width: EditorToolRailMetrics.width - 8, height: showsTitle ? Self.height : Self.iconOnlyHeight)
        // Dimmed through the COLOUR, not `.opacity`: a `Menu` draws its label itself and ignores an opacity set on it, but it follows
        // the foreground colour (this is what makes a disabled Compare entry look disabled like the others).
        .foregroundStyle(Self.color(isOn: isOn, isEnabled: isEnabled))
        .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.selectedFill.opacity(isEnabled ? 1 : 0.4) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    static let height: CGFloat = 48
    /// The cell height without a caption.
    static let iconOnlyHeight: CGFloat = Theme.Metrics.barHeight

    /// Dimmed through the COLOUR (a disabled `Menu` label ignores `.opacity`). Enabled entries use plain white (on) /
    /// `Theme.textSecondary` values; only a disabled entry gets a dimmed copy.
    static func color(isOn: Bool, isEnabled: Bool) -> Color {
        let base = isOn ? Color.white : Theme.textSecondary
        return isEnabled ? base : base.opacity(0.35)
    }
}
