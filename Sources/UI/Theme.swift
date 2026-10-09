import SwiftUI

/// The app's flat look, one place to retune it. Neutral greys for every surface and every selected / current mark; the one blue accent
/// only for a primary action; colour otherwise only where it carries meaning (reject, colour labels, on-image indicators). The grey levels and the accent hue are taste
/// calls (conventions, not measurements): change them here.
enum Theme {
    /// Layout constants that more than one place must agree on (or that carry a long explanation at their one use).
    enum Metrics {
        /// The Library's collection sidebar.
        static let sidebarMinWidth: CGFloat = 160, sidebarIdealWidth: CGFloat = 200, sidebarMaxWidth: CGFloat = 260
        /// The Editor's Adjust panel (`ContentView` explains why the minimum is 360).
        static let adjustPanelMinWidth: CGFloat = 360, adjustPanelMaxWidth: CGFloat = 420
        /// The bar under the Editor photo (rating / flag / label); also the height of an icon-only rail cell.
        static let barHeight: CGFloat = 36
    }

    /// The solid dark panel behind sidebars: the Editor's Adjust panel, the tool rail, the rating bar, the filmstrip and the Library's
    /// collection sidebar.
    static let panel = Color(white: 0.11)
    /// One step lighter than `panel`: floating HUDs and chips that sit on top of a panel or the photo.
    static let raised = Color(white: 0.17)
    /// A faint outline for `raised` surfaces.
    static let hairline = Color(white: 1, opacity: 0.10)
    /// The single accent (#0165DD). Used ONLY for the primary action of a sheet or bar (`FlatButtonStyle(prominent:)`): a SELECTED or
    /// CURRENT mark is never blue — it is the soft grey chip (`selectedFill`) or a white outline (`selectedOutline`).
    static let accent = Color(red: 0.004, green: 0.396, blue: 0.867)
    /// The selected / current chip: the raised grey, one step lighter than the panel it sits on.
    static let selectedFill = raised
    /// A white outline for selected / current marks over photos or where a fill alone is too subtle (armed buttons, rings).
    static let selectedOutline = Color(white: 1, opacity: 0.55)
    /// A fainter chip for the row under the pointer.
    static let hoverFill = Color(white: 1, opacity: 0.05)
    /// A "set" mark that carries no meaning of its own: a filled star, the duplicates BEST badge. Plain light grey, never yellow. (The Picked flag is yellow: it is a flag state, set apart from the stars.)
    static let markOn = Color(white: 0.85)
    /// Text greys (the app is dark-only): body-level, secondary captions, hints / disabled. Replace the system `.secondary` / `.tertiary`.
    static let textPrimary = Color(white: 0.90)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.45)
    /// Button chip fills (`FlatButtonStyle`) and the selected style / texture chip: one step per state above `raised` (0.17).
    static let pressedFill = Color(white: 0.23)
    static let armedFill = Color(white: 0.27)
    static let strongFill = Color(white: 0.32)
    /// The root `.tint`: what system controls (a checked Toggle, a native Slider; a progress bar and segmented Picker are expected to follow but are manual-check only) fill with. A light grey, so
    /// no system control is blue; `accent` is applied explicitly by `FlatButtonStyle(prominent:)` and does not depend on the tint.
    static let controlTint = Color(white: 0.85)
    /// The one caution colour (amber): missing files, notes that something will not behave as expected. Reject keeps red.
    static let warning = Color(red: 0.89, green: 0.66, blue: 0.24)
}

extension View {
    /// A SOLID floating panel — `Theme.raised` with a hairline outline, no blur or translucency — in place of `.regularMaterial`.
    func solidPanel(cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    /// The quiet selection mark: a soft grey rounded chip behind the content when selected (nothing otherwise).
    func selectionChip(isSelected: Bool, isHovered: Bool = false, cornerRadius: CGFloat = 6) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(isSelected ? Theme.selectedFill : (isHovered ? Theme.hoverFill : Color.clear)))
    }
}
