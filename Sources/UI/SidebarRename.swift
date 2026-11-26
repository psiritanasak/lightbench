import Foundation

/// What the sidebar is editing in place: a new (draft) row under a section header, or the name of an existing row.
enum SidebarEdit: Hashable {
    case newCollection, newSmart
    case renameCollection(Int64), renameSmart(Int64)

    var isNew: Bool { self == .newCollection || self == .newSmart }
}

/// What to do with the text typed into a sidebar row. Pure: no SwiftUI, no database.
enum SidebarRenameVerdict: Equatable {
    case commit(String)
    /// Leave things as they were: a rename goes back to the old name, a draft row disappears. No write.
    case cancel
    /// Keep the field open and show this message.
    case invalid(String)
}

enum SidebarRename {
    /// Decides the fate of `text`. The name is cleaned with `KeywordName.normalize` (both kinds). Empty after cleaning, or equal to
    /// `original`: `.cancel`. A change of letter case only is a real rename. A name whose `KeywordName.key` matches one of
    /// `otherNames` (names of the SAME kind, the row being renamed excluded; folders are a separate namespace and never passed in) is
    /// `.invalid`. Only the UI enforces this for plain collections: the database stays permissive and existing duplicates keep working.
    static func verdict(_ edit: SidebarEdit, text: String, original: String, otherNames: [String]) -> SidebarRenameVerdict {
        guard let name = KeywordName.normalize(text) else { return .cancel }
        if !edit.isNew, name == original { return .cancel }
        let key = KeywordName.key(for: name)
        if otherNames.contains(where: { KeywordName.key(for: $0) == key }) {
            return .invalid("A \(edit.kindName) named \u{201C}\(name)\u{201D} already exists.")
        }
        return .commit(name)
    }
}

private extension SidebarEdit {
    var kindName: String {
        switch self {
        case .newCollection, .renameCollection: return "collection"
        case .newSmart, .renameSmart: return "smart collection"
        }
    }
}
