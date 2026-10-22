import Foundation

/// One cell of the grid when stacking is on.
struct StackGridItem: Equatable, Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        /// A photo in no stack (or the only visible member of one).
        case plain
        /// The cell of a COLLAPSED stack: `photo` is its cover.
        case collapsedStack
        /// One member of an EXPANDED stack, drawn with the stack marker.
        case expandedMember
    }

    var photo: Photo
    var role: Role
    /// The stack this cell belongs to (nil for `.plain`).
    var stackID: Int64?
    /// Every VISIBLE photo of the stack (copies of its masters included), in displayed order; empty for `.plain`.
    var visibleMembers: [Photo]
    /// Visible members not drawn as their own cell: `visibleMembers.count - 1` while collapsed, 0 otherwise.
    var hiddenMemberCount: Int
    var isCover: Bool

    var isExpanded: Bool { role == .expandedMember }
    var id: String {
        switch role {
        case .plain, .expandedMember: return "p\(photo.id ?? -1)"
        case .collapsedStack: return "s\(stackID ?? -1)"
        }
    }
}

/// Pure: turns the FLAT filtered+sorted list into the grid's cells. A stack is a view over the list, never a filter on it.
///
/// - A photo belongs to the stack of its MASTER (`masterId ?? id`), so a virtual copy is hidden and shown exactly with its master.
/// - The members of a stack that are in `displayed` are its VISIBLE members. With two or more distinct masters, a collapsed stack is ONE cell at the
///   position of its first visible member, showing the stack's cover when that is visible and otherwise its first visible member.
///   An expanded stack puts all its visible members (displayed order) in a run at that same position, each marked as a member.
/// - A stack with one visible MASTER is a plain photo (the filters left it nothing to hide); a master and its own copies count as one,
///   so they never collapse into a "+1" cell.
/// - Everything else keeps its displayed order.
enum StackDisplay {
    static func apply(displayed: [Photo], stacks: [StackSnapshot], expandedIDs: Set<Int64>) -> [StackGridItem] {
        var stackOfMaster: [Int64: StackSnapshot] = [:]
        for stack in stacks { for member in stack.memberIDs { stackOfMaster[member] = stack } }
        func stack(of photo: Photo) -> StackSnapshot? {
            guard let id = photo.masterId ?? photo.id else { return nil }
            return stackOfMaster[id]
        }

        var visible: [Int64: [Photo]] = [:]
        for photo in displayed {
            if let owner = stack(of: photo) { visible[owner.id, default: []].append(photo) }
        }

        var items: [StackGridItem] = []
        var emitted = Set<Int64>()
        for photo in displayed {
            guard let owner = stack(of: photo), let members = visible[owner.id], Set(members.map { $0.masterId ?? $0.id }).count > 1 else {
                items.append(StackGridItem(photo: photo, role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false))
                continue
            }
            guard emitted.insert(owner.id).inserted else { continue }
            let cover = members.first { $0.id == owner.coverPhotoID } ?? members[0]
            if expandedIDs.contains(owner.id) {
                for member in members {
                    items.append(StackGridItem(
                        photo: member, role: .expandedMember, stackID: owner.id, visibleMembers: members,
                        hiddenMemberCount: 0, isCover: member.id == cover.id
                    ))
                }
            } else {
                items.append(StackGridItem(
                    photo: cover, role: .collapsedStack, stackID: owner.id, visibleMembers: members,
                    hiddenMemberCount: members.count - 1, isCover: true
                ))
            }
        }
        return items
    }
}
