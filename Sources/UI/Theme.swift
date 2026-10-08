import SwiftUI

/// The app's flat look, one place to retune it. Neutral greys for every surface, ONE accent for "selected / active", colour
/// otherwise only where it carries meaning (reject, colour labels, on-image indicators). The grey levels and the accent hue are taste
/// calls (conventions, not measurements): change them here.
enum Theme {
    /// The solid dark panel behind sidebars: the Editor's Adjust panel, the tool rail, the rating bar, the filmstrip and the Library's
    /// collection sidebar.
    static let panel = Color(white: 0.11)
    /// One step lighter than `panel`: floating HUDs and chips that sit on top of a panel or the photo.
    static let raised = Color(white: 0.17)
    /// A faint outline for `raised` surfaces.
    static let hairline = Color(white: 1, opacity: 0.10)
    /// The single accent (#0165DD): the selected tool, the armed tool, the current item, prominent buttons.
    static let accent = Color(red: 0.004, green: 0.396, blue: 0.867)
}

extension View {
    /// A SOLID floating panel — `Theme.raised` with a hairline outline, no blur or translucency — in place of `.regularMaterial`.
    func solidPanel(cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Theme.hairline, lineWidth: 1))
    }
}
