import SwiftUI

/// The app's flat look, one place to retune it. Neutral greys for every surface and every selected / current mark; the one blue accent
/// only for a primary action; colour otherwise only where it carries meaning (reject, colour labels, on-image indicators). The grey levels and the accent hue are taste
/// calls (conventions, not measurements): change them here.
enum Theme {
    /// Layout constants that more than one place must agree on (or that carry a long explanation at their one use).
    enum Metrics {
        /// The Library's collection sidebar.
        static let sidebarMinWidth: CGFloat = 160, sidebarIdealWidth: CGFloat = 200, sidebarMaxWidth: CGFloat = 260
        /// The Editor's Adjust panel (`ContentView` explains why the minimum is a hard floor, not an ideal width). 2026-11-05: 360/420 -> 300/380 because the panel took about half of a small window; checked for clipping at window widths of 837 / 1100 / 1440 pt (Retouch with spots placed, Point Color instance detail and the Info popover were not checked).
        static let adjustPanelMinWidth: CGFloat = 300, adjustPanelMaxWidth: CGFloat = 380
        /// The bar under the Editor photo (rating / flag / label); also the height of an icon-only rail cell.
        static let barHeight: CGFloat = 36
        /// The three sheet widths (`SheetSize`): one place so every sheet lines up. By-eye conventions, not measurements.
        static let sheetSmallWidth: CGFloat = 460, sheetMediumWidth: CGFloat = 580, sheetLargeWidth: CGFloat = 780
        /// The padding inside every sheet (`SheetScaffold`).
        static let sheetPadding: CGFloat = 20
    }

    /// The spacing scale. `xs`...`xl` are the steps; the `px` values are EXACT off-scale numbers the UI already used (C3 changed no
    /// layout, so none was rounded to a neighbour). A new layout should use a step; a `px` value is for matching existing geometry.
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20
        static let px1: CGFloat = 1, px2: CGFloat = 2, px3: CGFloat = 3, px5: CGFloat = 5, px6: CGFloat = 6
        static let px10: CGFloat = 10, px14: CGFloat = 14, px18: CGFloat = 18, px22: CGFloat = 22, px24: CGFloat = 24
    }

    /// Corner radii. `s`/`m`/`l` are the steps; `px` values are exact off-scale radii already in use.
    enum Radius {
        static let s: CGFloat = 4, m: CGFloat = 6, l: CGFloat = 10
        static let px3: CGFloat = 3, px5: CGFloat = 5, px8: CGFloat = 8, px12: CGFloat = 12
    }

    /// Text and glyph sizes, named by role; each equals a size the UI already used. A function so a call site keeps its weight.
    enum Font {
        /// 9 pt: badge and count text.
        static func micro(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 9, weight: weight) }
        /// 10 pt: rail captions, small chrome.
        static func caption(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 10, weight: weight) }
        /// 11 pt: dense secondary text.
        static func body(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 11, weight: weight) }
        /// Glyph sizes for icon-only controls and empty-state art.
        static func glyph14(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 14, weight: weight) }
        static func glyph17(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 17, weight: weight) }
        static func glyph18(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 18, weight: weight) }
        static func glyph20(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 20, weight: weight) }
        /// 34 pt: the Cull view's large centred mark.
        static func display(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 34, weight: weight) }
        /// 40 / 44 pt: empty-state illustrations.
        static func hero40(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 40, weight: weight) }
        static func hero44(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: 44, weight: weight) }
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
    /// Something the user asked for failed or was refused (an invalid name template, a write error). Red, readable on `panel`; distinct from the amber `warning` (cautions). The Reject flag, colour labels and the Delete menu items keep their own reds.
    static let error = Color(red: 0.94, green: 0.38, blue: 0.34)
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
    func selectionChip(isSelected: Bool, isHovered: Bool = false, cornerRadius: CGFloat = Theme.Radius.m) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(isSelected ? Theme.selectedFill : (isHovered ? Theme.hoverFill : Color.clear)))
    }
}
