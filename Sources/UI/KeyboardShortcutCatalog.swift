import SwiftUI

/// The keyboard shortcuts the Help ▸ Keyboard Shortcuts window lists, as DATA, each tied to the place that really implements it so the
/// list cannot silently drift: `KeyboardShortcutCatalogTests` checks the menu entries against the `.keyboardShortcut(` lines in
/// `PhotoAppApp`, the photo / cull keys against `PhotoKeyCommand` and `CullKeyAction` (in BOTH directions: a new key that is not listed
/// fails), and every other entry against a snippet of the source that handles it.
struct ShortcutEntry: Equatable {
    /// Where the shortcut is implemented, so a test can confirm the entry is true.
    enum Source: Equatable {
        /// A Photo / Edit / File / Help menu item: a spec like `cmd+shift+z`, matched against `PhotoAppApp.swift`.
        case menu(String)
        /// Characters handled by `PhotoKeyCommand` (the Library grid, the Editor and Culling share it); `allowsZero: false` means the characters must ALSO work in the Editor, where `0` is zoom-reset instead of a rating.
        case photoKeys(String, allowsZero: Bool)
        /// Bare characters handled by `AppKeyCommand` in `mode` (case-insensitive; listed lower case). Checked in both directions.
        case appKey(String, mode: PhotoActionContext.Mode)
        /// A culling key, handled by `CullKeyAction`.
        case cull(CullKey)
        /// Anything else: a snippet that must still appear in `file`.
        case code(file: String, contains: String)
        /// Provided by macOS itself (the Settings scene's ⌘, and the like): not checkable here.
        case system
    }

    var keys: String
    var action: String
    /// Everything this ONE row documents (a row such as "⌘← ⌘→" covers two menu items), each checked against its implementation.
    var sources: [Source]

    init(keys: String, action: String, sources: [Source]) {
        self.keys = keys
        self.action = action
        self.sources = sources
    }

    init(keys: String, action: String, source: Source) { self.init(keys: keys, action: action, sources: [source]) }
}

struct ShortcutSection: Equatable {
    var title: String
    var entries: [ShortcutEntry]
}

enum KeyboardShortcutCatalog {
    static let sections: [ShortcutSection] = [
        ShortcutSection(title: "Anywhere", entries: [
            ShortcutEntry(keys: "\u{2318}Z", action: "Undo (an edit, or the last culling action while culling)", source: .menu("cmd+z")),
            ShortcutEntry(keys: "\u{21E7}\u{2318}Z", action: "Redo", source: .menu("cmd+shift+z")),
            ShortcutEntry(keys: "\u{2318},", action: "Preferences", source: .system),
            ShortcutEntry(keys: "\u{2318}/", action: "Keyboard Shortcuts", source: .menu("cmd+/")),
            ShortcutEntry(keys: "\u{21E7}\u{2318}C  \u{21E7}\u{2318}V", action: "Copy the open photo's edit settings (Editor) / paste them onto the selected photos (Library)",
                          sources: [.menu("cmd+shift+c"), .menu("cmd+shift+v")]),
            ShortcutEntry(keys: "\u{2318}K", action: "Edit keywords: of the selected photos (Library) or of the open photo (Editor)", source: .menu("cmd+k")),
            ShortcutEntry(keys: "\u{2318}I", action: "Edit the title, caption, creator and copyright: of the selected photos (Library) or of the open photo (Editor)", source: .menu("cmd+i")),
            ShortcutEntry(keys: "\u{2318}G  \u{21E7}\u{2318}G", action: "Stack the selected photos / unstack them (Library; Photo \u{25B8} Auto Stack\u{2026} finds bursts)",
                          sources: [.menu("cmd+g"), .menu("cmd+shift+g")]),
            ShortcutEntry(keys: "\u{2318}[  \u{2318}]", action: "Rotate the open photo 90\u{00B0} left / right (Editor)",
                          sources: [.menu("cmd+["), .menu("cmd+]")]),
            ShortcutEntry(keys: "\u{2318}'", action: "Create a virtual copy: another independent edit version of the photo (selected or open)", source: .menu("cmd+'")),
        ]),
        ShortcutSection(title: "View", entries: [
            ShortcutEntry(keys: "\u{2318}1  \u{2318}2", action: "Show the Library / the Editor",
                          sources: [.menu("cmd+1"), .menu("cmd+2")]),
            ShortcutEntry(keys: "E", action: "Library: switch to the Editor", source: .appKey("e", mode: .library)),
            ShortcutEntry(keys: "\u{2318}\u{2190}  \u{2318}\u{2192}", action: "Previous / next photo in the Editor",
                          sources: [.menu("cmd+left"), .menu("cmd+right")]),
            ShortcutEntry(keys: "\u{2325}\u{2318}C", action: "Cull Photos", source: .menu("cmd+opt+c")),
            ShortcutEntry(keys: "\u{2325}\u{2318}1 \u{2013} 6", action: "Editor: open the Edit / Looks / Retouch / Red-eye / Masks / Crop panel",
                          sources: [.menu("cmd+opt+1"), .menu("cmd+opt+2"), .menu("cmd+opt+3"), .menu("cmd+opt+4"), .menu("cmd+opt+5"), .menu("cmd+opt+6")]),
            ShortcutEntry(keys: "\u{21E7}\u{2318}R", action: "Revert the open photo to its original (one undo step)", source: .menu("cmd+shift+r")),
            ShortcutEntry(keys: "\u{21E7}\u{2318}E", action: "Export the selected photos (Library; File \u{25B8} Export\u{2026})", source: .menu("cmd+shift+e")),
        ]),
        ShortcutSection(title: "Rating, flags and labels (Library, Editor, Culling)", entries: [
            ShortcutEntry(keys: "1 \u{2013} 5", action: "Rate the photo (in the Library: the focused photo, not the whole selection); pressing 0 in the Library or while culling clears the rating",
                          source: .photoKeys("12345", allowsZero: false)),
            ShortcutEntry(keys: "0", action: "Clear the rating (Library and Culling; in the Editor 0 resets the zoom)", source: .photoKeys("0", allowsZero: true)),
            ShortcutEntry(keys: "P", action: "Pick", source: .photoKeys("pP", allowsZero: false)),
            ShortcutEntry(keys: "X", action: "Reject", source: .photoKeys("xX", allowsZero: false)),
            ShortcutEntry(keys: "U", action: "Unflag", source: .photoKeys("uU", allowsZero: false)),
            ShortcutEntry(keys: "F  or  .", action: "Toggle Pick", source: .photoKeys("fF.", allowsZero: false)),
            ShortcutEntry(keys: "6 7 8 9", action: "Colour label red / yellow / green / blue; the same key again removes it",
                          source: .photoKeys("6789", allowsZero: false)),
        ]),
        ShortcutSection(title: "Library grid", entries: [
            ShortcutEntry(keys: "\u{2190} \u{2192} \u{2191} \u{2193}", action: "Move between photos and select the one you land on",
                          source: .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .upArrow: return moveFocus(by: -columnCount, in: cells, extending: extend)")),
            ShortcutEntry(keys: "Return  Space", action: "Open the focused photo in the Editor",
                          sources: [.code(file: "Sources/UI/LibraryGridView.swift", contains: "case .return: return openFocused(in: displayed)"),
                                    .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .space: return openFocused(in: displayed)")]),
            ShortcutEntry(keys: "Double-click", action: "Open the photo in the Editor (a single click selects it)",
                          source: .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .open: onOpen(item.photo)")),
            ShortcutEntry(keys: "\u{2318}-click  \u{21E7}-click", action: "Add or remove one photo / select the range from the last clicked photo (the checkbox works like \u{2318}-click)",
                          source: .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .select(.extend):")),
            ShortcutEntry(keys: "\u{21E7}\u{2190} \u{21E7}\u{2192} \u{21E7}\u{2191} \u{21E7}\u{2193}", action: "Extend the selection",
                          source: .code(file: "Sources/UI/LibraryGridView.swift", contains: "let extend = keyPress.modifiers.contains(.shift)")),
            ShortcutEntry(keys: "\u{2318}A", action: "Select all the photos shown",
                          source: .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .selectAll: catalog.selectAllGridCells(in: cells)")),
            ShortcutEntry(keys: "Esc  \u{2318}D", action: "Clear the selection",
                          sources: [.code(file: "Sources/UI/LibraryGridView.swift", contains: "case .escape: return catalog.clearGridSelection()"),
                                    .code(file: "Sources/UI/LibraryGridView.swift", contains: "case .clearSelection: _ = catalog.clearGridSelection()")]),
        ]),
        ShortcutSection(title: "Library sidebar", entries: [
            ShortcutEntry(keys: "\u{2191} \u{2193}", action: "Move between collections and folders",
                          source: .code(file: "Sources/UI/CollectionSidebarView.swift", contains: ".onKeyPress(.upArrow) { catalog.selectedFilter = SidebarRows.moved(from: catalog.selectedFilter, by: -1, in: rows); return .handled }")),
            ShortcutEntry(keys: "\u{2192} \u{2190}", action: "Expand / collapse a folder",
                          source: .code(file: "Sources/UI/CollectionSidebarView.swift", contains: "expandedFolders = SidebarRows.expanding(catalog.selectedFilter")),
        ]),
        ShortcutSection(title: "Editor", entries: [
            ShortcutEntry(keys: "Click the histogram", action: "Switch the histogram between Luminance and RGB",
                          source: .code(file: "Sources/UI/EditorHistogramHeader.swift", contains: "mode = mode.next")),
            ShortcutEntry(keys: "\\", action: "Show the original photo (Before); press again to go back to your edits",
                          source: .appKey("\\", mode: .editor)),
            ShortcutEntry(keys: "Y", action: "Side by Side compare on / off", source: .appKey("y", mode: .editor)),
            ShortcutEntry(keys: "G", action: "Back to the Library", source: .appKey("g", mode: .editor)),
            ShortcutEntry(keys: "E  L  Q  M  R", action: "Open the Edit / Looks / Retouch / Masks / Crop panel", source: .appKey("elqmr", mode: .editor)),
            ShortcutEntry(keys: "0", action: "Reset the zoom (when zoomed in)",
                          source: .code(file: "Sources/UI/ContentView.swift", contains: "if keyPress.key == \"0\" {")),
            ShortcutEntry(keys: "\u{2190} \u{2192} \u{2191} \u{2193}", action: "Pan when zoomed in",
                          source: .code(file: "Sources/UI/ContentView.swift", contains: "case .leftArrow: delta = CGSize(width: -step, height: 0)")),
            ShortcutEntry(keys: "Delete", action: "Remove the selected Remove-tool spot",
                          source: .code(file: "Sources/UI/RetouchKeyAction.swift", contains: "if isDelete { return hasSelection ? .deleteSelected : .ignore }")),
            ShortcutEntry(keys: "Esc", action: "Deselect the spot, then stop the Remove tool",
                          source: .code(file: "Sources/UI/RetouchKeyAction.swift", contains: "return isArmed ? .disarm : .ignore")),
            ShortcutEntry(keys: "Esc", action: "Masks: stop the eyedropper / subject picker or painting, then deselect the mask",
                          source: .code(file: "Sources/UI/ContentView.swift", contains: "if isPaintingBrush {")),
            ShortcutEntry(keys: "Space + drag", action: "Pan while the Remove tool is active",
                          source: .code(file: "Sources/UI/ContentView.swift", contains: "RetouchZoomRules.spaceIsHandTool(toolActive: retouchToolActive)")),
            ShortcutEntry(keys: "\u{2325}-click a section title", action: "Edit tab: open only that section and close the others",
                          source: .code(file: "Sources/UI/AdjustTabView.swift", contains: "case .solo: onSolo?()")),
        ]),
        ShortcutSection(title: "Sliders", entries: [
            ShortcutEntry(keys: "Double-click a slider's name or track", action: "Edit panel sliders: reset to the default (one undo step)",
                          source: .code(file: "Sources/UI/EditControlRows.swift", contains: "onDoubleClick: requestReset")),
            ShortcutEntry(keys: "\u{2325}-drag a slider", action: "Fine adjustment (a quarter of the speed)",
                          source: .code(file: "Sources/UI/ThinSlider.swift", contains: "static let fineDivisor: Double = 4")),
            ShortcutEntry(keys: "\u{2325} \u{2190} \u{2192}", action: "Fine step on a focused slider",
                          source: .code(file: "Sources/UI/ThinSlider.swift", contains: "fine: press.modifiers.contains(.option)")),
        ]),
        ShortcutSection(title: "Tone curve editor (with a point selected)", entries: [
            ShortcutEntry(keys: "\u{2190} \u{2192} \u{2191} \u{2193}", action: "Nudge the point (hold Shift for bigger steps)",
                          source: .code(file: "Sources/UI/ToneCurveEditorView.swift", contains: "let step = keyPress.modifiers.contains(.shift) ? ToneCurveEditing.coarseNudgeStep : ToneCurveEditing.nudgeStep")),
            ShortcutEntry(keys: "[  ]", action: "Select the previous / next point",
                          source: .code(file: "Sources/UI/ToneCurveEditorView.swift", contains: "selectAdjacent(-1)")),
            ShortcutEntry(keys: "Delete", action: "Remove the point",
                          source: .code(file: "Sources/UI/ToneCurveEditorView.swift", contains: "case .delete, .deleteForward:")),
        ]),
        ShortcutSection(title: "Color Grading wheel (when it has focus)", entries: [
            ShortcutEntry(keys: "\u{2190} \u{2192}", action: "Step Hue (hold Shift for 3x)",
                          source: .code(file: "Sources/UI/ColorGradingWheelView.swift", contains: "case .rightArrow: step(hueDelta:")),
            ShortcutEntry(keys: "\u{2191} \u{2193}", action: "Step Saturation (hold Shift for 3x)",
                          source: .code(file: "Sources/UI/ColorGradingWheelView.swift", contains: "case .upArrow: step(saturationDelta:")),
        ]),
        ShortcutSection(title: "Culling", entries: [
            ShortcutEntry(keys: "\u{2190}", action: "Previous photo", source: .cull(.leftArrow)),
            ShortcutEntry(keys: "\u{2192}  Space", action: "Next photo", sources: [.cull(.rightArrow), .cull(.space)]),
            ShortcutEntry(keys: "C", action: "Compare two photos", source: .cull(.character("c"))),
            ShortcutEntry(keys: "N", action: "Survey a page of photos", source: .cull(.character("n"))),
            ShortcutEntry(keys: "\u{2191}", action: "Compare: swap the two photos", source: .cull(.upArrow)),
            ShortcutEntry(keys: "\u{2193}", action: "Compare: make this photo the one to compare against", source: .cull(.downArrow)),
            ShortcutEntry(keys: "/", action: "Survey: take the focused photo off the page", source: .cull(.character("/"))),
            ShortcutEntry(keys: "S", action: "Open / close the photo's stack (the photo keys act on the one cell shown)", source: .cull(.character("s"))),
            ShortcutEntry(keys: "Return", action: "Open the photo in the Editor", source: .cull(.returnKey)),
            ShortcutEntry(keys: "Esc", action: "Leave Compare / Survey, then leave culling", source: .cull(.escape)),
        ]),
    ]
}

/// Help ▸ Keyboard Shortcuts.
struct KeyboardShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(KeyboardShortcutCatalog.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(entry.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 150, alignment: .trailing)
                                Text(entry.action)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 560)
        .background(Theme.panel)
        // The panel is dark whatever the system appearance (this is a separate window, outside the main window's dark pin).
        .preferredColorScheme(.dark)
    }
}
