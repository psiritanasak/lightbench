import Foundation

/// A navigation / view command that both the View menu and the bare app keys will run (A3 / B4). Pure data: the rules below decide
/// whether one is enabled, and `ContentView.performViewCommand` re-checks them when it runs.
enum ViewCommand: Equatable {
    case showLibrary
    case showEditor
    case toggleBefore
    case toggleSideBySide
    case setCompare(CompareViewMode)
    case selectTab(EditorTab)
    case toggleFilmstrip
    case revertToOriginal
    case export
}

/// The app state the view-command rules read. Plain values only (no NSApp reads), so every rule is a table test.
struct ViewCommandContext: Equatable {
    var mode: PhotoActionContext.Mode = .library
    /// `document.currentImage != nil`.
    var hasOpenImage = false
    /// `document.isLoadInFlight`.
    var loadInFlight = false
    /// `renameModel.isWorking`.
    var renameWorking = false
    /// A sheet, alert or long operation is up.
    var modalUp = false
    /// `catalog.editorPopoverOpen`.
    var editorPopoverOpen = false
    /// The Editor can compare (not on Crop, no point tool armed, an image is open).
    var canCompare = false
    /// `EditorRailActionRules.canRevert(...)`.
    var canRevert = false
    /// The toolbar's own Export enabling expression.
    var canExport = false
    var compareMode: CompareViewMode = .off
    var selectedTab: EditorTab = .adjust
    var filmstripVisible = false
}

enum ViewCommandRules {
    static func isEnabled(_ command: ViewCommand, context c: ViewCommandContext) -> Bool {
        // While culling every view command is off: Cull is its own mode with its own keys.
        guard c.mode != .cull else { return false }
        let free = !c.modalUp && !c.editorPopoverOpen
        let editor = c.mode == .editor
        switch command {
        case .showLibrary, .showEditor:
            return free
        case .toggleBefore, .toggleSideBySide, .setCompare:
            return editor && c.canCompare && free
        case .selectTab(let tab):
            return editor && free && EditorTab.railTabs.contains(tab)
        case .toggleFilmstrip:
            return editor && free
        case .revertToOriginal:
            return editor && c.canRevert && !c.loadInFlight && !c.renameWorking && free
        case .export:
            return c.mode == .library && c.canExport && !c.renameWorking && !c.modalUp
        }
    }

    /// The checkmark a menu item shows.
    static func isChecked(_ command: ViewCommand, context c: ViewCommandContext) -> Bool {
        switch command {
        case .toggleBefore: return c.compareMode == .before
        case .toggleSideBySide: return c.compareMode == .sideBySide
        case .setCompare(let mode): return c.compareMode == mode
        case .selectTab(let tab): return c.selectedTab == tab
        case .toggleFilmstrip: return c.filmstripVisible
        case .showLibrary, .showEditor, .revertToOriginal, .export: return false
        }
    }

    /// The compare mode a compare command leads to from `current` (nil for any other command).
    static func compareMode(after command: ViewCommand, from current: CompareViewMode) -> CompareViewMode? {
        switch command {
        case .toggleBefore: return current.toggledBefore()
        case .toggleSideBySide: return current.toggledSideBySide()
        case .setCompare(let mode): return mode
        default: return nil
        }
    }
}

/// The bare keys (no menu equivalent: a bare-letter menu key could swallow typing). Free everywhere else: not a `PhotoKeyCommand`,
/// not Editor `0` / Space, not Cull's C N S `/`.
enum AppKeyCommand {
    /// The command for a typed character in `mode`, or nil. Cull never routes any. Case-insensitive.
    static func command(for character: Character, mode: PhotoActionContext.Mode) -> ViewCommand? {
        let key = Character(character.lowercased())
        switch mode {
        case .cull:
            return nil
        case .library:
            return key == "e" ? .showEditor : nil
        case .editor:
            switch key {
            case "g": return .showLibrary
            case "e": return .selectTab(.adjust)
            case "l": return .selectTab(.looks)
            case "q": return .selectTab(.retouch)
            case "m": return .selectTab(.masks)
            case "r": return .selectTab(.crop)
            case "y": return .toggleSideBySide
            case "\\": return .toggleBefore
            default: return nil
            }
        }
    }
}

/// Whether a key press may become an app key. Option and Shift are accepted on purpose (the decision rests on the produced
/// character), because `\` needs Option on German and French layouts; Command and Control are never app keys.
enum AppKeyGate {
    static func allows(
        command: Bool, control: Bool, option: Bool = false, shift: Bool = false,
        textFieldFocused: Bool, modalUp: Bool, isRepeat: Bool
    ) -> Bool {
        !command && !control && !textFieldFocused && !modalUp && !isRepeat
    }

    /// Gate + table in one call: the command a press runs, or nil.
    static func resolve(
        character: Character, mode: PhotoActionContext.Mode,
        command: Bool, control: Bool, option: Bool, shift: Bool,
        textFieldFocused: Bool, modalUp: Bool, isRepeat: Bool
    ) -> ViewCommand? {
        guard allows(command: command, control: control, option: option, shift: shift,
                     textFieldFocused: textFieldFocused, modalUp: modalUp, isRepeat: isRepeat) else { return nil }
        return AppKeyCommand.command(for: character, mode: mode)
    }
}
