import Foundation

/// Pure: where keyboard focus belongs when it names a photo that is HIDDEN inside a collapsed stack. A hidden member is not a cell, so
/// focus follows it to the stack's cell (the cover or first visible member); a key that is a cell already, or belongs to nothing the grid
/// knows, is returned unchanged (the grid's own "focus left the list" handling then applies).
enum StackFocus {
    static func resolve(_ focusedKey: String?, in items: [StackGridItem]) -> String? {
        guard let focusedKey else { return nil }
        if items.contains(where: { $0.photo.editKey == focusedKey }) { return focusedKey }
        for item in items where item.role == .collapsedStack && item.visibleMembers.contains(where: { $0.editKey == focusedKey }) {
            return item.photo.editKey
        }
        return focusedKey
    }
}
