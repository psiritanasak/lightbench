import Foundation

extension StackGridItem {
    /// The SwiftUI identity of the grid CELL VIEW. It includes everything the cell draws from the stack (role, stack, size, cover), so the
    /// view is REBUILT when a photo changes between a plain cell, a collapsed stack and an expanded member. An id of just the photo's
    /// `editKey` kept the old view (and its stale badge and caption) alive across such a change.
    var cellID: String {
        let tag: String
        switch role {
        case .plain: tag = "plain"
        case .collapsedStack: tag = "collapsed"
        case .expandedMember: tag = "expanded"
        }
        return "\(tag)|\(stackID ?? -1)|\(hiddenMemberCount)|\(isCover ? 1 : 0)|\(photo.editKey)"
    }
}

/// Pure: what a grid cell shows for its stack role, and which cell a focused photo scrolls to.
enum StackCellPresentation {
    enum Badge: Equatable {
        /// A collapsed stack: its size; tapping expands it.
        case count(Int)
        /// A member of an expanded stack (the cover included): the stack glyph; tapping collapses it.
        case marker
        case none
    }

    static func badge(for item: StackGridItem) -> Badge {
        switch item.role {
        case .plain: return .none
        case .collapsedStack: return .count(item.hiddenMemberCount + 1)
        case .expandedMember: return .marker
        }
    }

    /// The caption: the name, plus the stack's size on a COLLAPSED stack's cell only (expanded members show their own file).
    static func caption(name: String, item: StackGridItem) -> String {
        item.role == .collapsedStack ? "\(name) · \(item.hiddenMemberCount + 1) photos" : name
    }

    static func badgeAccessibilityLabel(for item: StackGridItem) -> String {
        switch item.role {
        case .plain: return ""
        case .collapsedStack: return "Stack of \(item.hiddenMemberCount + 1) photos, expand"
        case .expandedMember: return item.isCover ? "Stack cover, collapse" : "Stack member, collapse"
        }
    }

    /// The id of the cell `proxy.scrollTo` must target for the focused photo: the focus is first resolved to a cell
    /// (`StackFocus.resolve`: a member hidden in a collapsed stack scrolls to the stack's cell), then to that cell's `cellID`.
    static func scrollTarget(forFocusedKey key: String?, in items: [StackGridItem]) -> String? {
        guard let resolved = StackFocus.resolve(key, in: items) else { return nil }
        return items.first { $0.photo.editKey == resolved }?.cellID
    }
}
