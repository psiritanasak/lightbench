import Foundation

/// Pure selection rule for stacked cells. Ticking a COLLAPSED stack selects every visible member, so a batch tool acts on the whole
/// stack (what the count badge promises); every other cell (plain photo, expanded member) is its own photo.
enum StackSelection {
    /// The photo ids the cell stands for.
    static func ids(for item: StackGridItem) -> [Int64] {
        switch item.role {
        case .collapsedStack: return item.visibleMembers.compactMap(\.id)
        case .plain, .expandedMember: return item.photo.id.map { [$0] } ?? []
        }
    }

    /// A collapsed stack reads as ticked only when ALL its visible members are selected (a partly selected one, left over from
    /// an expanded stack, is unticked, so the next tick completes it).
    static func isSelected(_ item: StackGridItem, in selection: Set<Int64>) -> Bool {
        let members = ids(for: item)
        return !members.isEmpty && members.allSatisfy(selection.contains)
    }

    /// The selection after a tick on `item`: unticked becomes ticked (all its ids added), ticked becomes unticked (all removed).
    static func toggled(_ item: StackGridItem, in selection: Set<Int64>) -> Set<Int64> {
        let members = ids(for: item)
        var result = selection
        if isSelected(item, in: selection) { result.subtract(members) } else { result.formUnion(members) }
        return result
    }
}
