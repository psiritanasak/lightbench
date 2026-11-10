import Foundation

/// Pure click and keyboard selection rules for the Library grid, over the grid's CELLS (`[StackGridItem]` in `gridPhotos` order, which is
/// the displayed order). A cell stands for `StackSelection.ids(for:)` (a collapsed stack = all its visible members). Foundation only.
enum GridSelection {
    // MARK: - Clicks

    enum ClickKind: Equatable, Sendable {
        case plain, toggle, extend

        /// Shift wins (Shift-Command-click extends); Command alone toggles; no modifier is a plain click.
        init(command: Bool, shift: Bool) {
            if shift { self = .extend } else if command { self = .toggle } else { self = .plain }
        }
    }

    enum ClickEffect: Equatable, Sendable {
        case select(ClickKind), open, ignore
    }

    /// Click 1 selects; a second (or later) click with no modifier opens; a second click with Command or Shift does nothing.
    static func clickEffect(clickCount: Int, command: Bool, shift: Bool) -> ClickEffect {
        if clickCount <= 1 { return .select(ClickKind(command: command, shift: shift)) }
        return (command || shift) ? .ignore : .open
    }

    // MARK: - Selection outcomes

    /// Where a Shift range starts (`key` = the cell's photo edit key, the cover for a collapsed stack) and the selection it adds to.
    struct Anchor: Equatable, Sendable {
        var key: String
        var base: Set<Int64>
    }

    struct Outcome: Equatable, Sendable {
        var selection: Set<Int64>
        var anchor: Anchor?
        var focusKey: String
    }

    /// A plain click / a plain arrow: exactly this cell is selected, and it becomes the anchor.
    static func selectingOnly(_ item: StackGridItem) -> Outcome {
        let key = item.photo.editKey
        return Outcome(selection: Set(StackSelection.ids(for: item)), anchor: Anchor(key: key, base: []), focusKey: key)
    }

    /// Command-click / the checkbox: `StackSelection.toggled`; the anchor is this cell and the base is everything else selected.
    static func toggling(_ item: StackGridItem, in selection: Set<Int64>) -> Outcome {
        let key = item.photo.editKey
        let new = StackSelection.toggled(item, in: selection)
        let base = new.subtracting(StackSelection.ids(for: item))
        return Outcome(selection: new, anchor: Anchor(key: key, base: base), focusKey: key)
    }

    /// Shift-click / Shift-arrow: the range from the anchor to `cells[index]`, added to the anchor's base. Nil when `index` is out of
    /// range or neither the anchor nor the focus names a cell (the caller then falls back to a plain select / a focus move).
    static func extending(to index: Int, in cells: [StackGridItem], selection: Set<Int64>, anchor: Anchor?, focusKey: String?) -> Outcome? {
        guard cells.indices.contains(index) else { return nil }
        let start: Int
        let base: Set<Int64>
        let newAnchor: Anchor
        if let anchor, let at = cellIndex(of: anchor.key, in: cells) {
            start = at
            base = anchor.base.intersection(selection)
            newAnchor = anchor
        } else if let at = cellIndex(of: focusKey, in: cells) {
            start = at
            base = selection
            newAnchor = Anchor(key: cells[at].photo.editKey, base: selection)
        } else {
            return nil
        }
        var result = base
        for cell in cells[min(start, index)...max(start, index)] { result.formUnion(StackSelection.ids(for: cell)) }
        return Outcome(selection: result, anchor: newAnchor, focusKey: cells[index].photo.editKey)
    }

    /// Every id of every cell (hidden members of collapsed stacks included): Select All.
    static func allIDs(in cells: [StackGridItem]) -> Set<Int64> {
        var result: Set<Int64> = []
        for cell in cells { result.formUnion(StackSelection.ids(for: cell)) }
        return result
    }

    private static func cellIndex(of key: String?, in cells: [StackGridItem]) -> Int? {
        guard let resolved = StackFocus.resolve(key, in: cells) else { return nil }
        return cells.firstIndex { $0.photo.editKey == resolved }
    }

    // MARK: - Command keys

    enum CommandKey: Equatable, Sendable { case selectAll, clearSelection }

    /// Command-A / Command-D only: Command held, no Shift/Option/Control.
    static func commandKey(character: Character?, command: Bool, shift: Bool, option: Bool, control: Bool) -> CommandKey? {
        guard command, !shift, !option, !control, let character else { return nil }
        switch Character(character.lowercased()) {
        case "a": return .selectAll
        case "d": return .clearSelection
        default: return nil
        }
    }
}
