import Foundation

/// What a key press does while the Remove section's Place Spots tool is armed and/or a spot is selected. Pure, so the routing is
/// unit-tested; `ContentView` maps the actual `KeyPress` to the two booleans and carries the action out.
///  - Delete / Backspace: delete the selected spot (nothing selected = ignored, so key repeat cannot delete a second spot after
///    the first deletion cleared the selection).
///  - Escape: deselect the spot first; with nothing selected, stop the tool; with neither, ignored.
enum RetouchKeyAction: Equatable {
    case deleteSelected, deselect, disarm, ignore

    static func action(isEscape: Bool, isDelete: Bool, hasSelection: Bool, isArmed: Bool) -> RetouchKeyAction {
        if isDelete { return hasSelection ? .deleteSelected : .ignore }
        if isEscape {
            if hasSelection { return .deselect }
            return isArmed ? .disarm : .ignore
        }
        return .ignore
    }
}
