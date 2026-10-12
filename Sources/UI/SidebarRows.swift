import Foundation

/// One line of the Library sidebar: a section header, a selectable item (All Photos, a collection, a smart collection, a folder) or a
/// small action ("New Collection…", "Save Current Filters…"). The sidebar draws its own rows (the system `List` highlight cannot be
/// restyled), so this flat, ordered list is what it renders and what the keyboard navigates. Pure: no SwiftUI.
struct SidebarRow: Identifiable, Equatable {
    enum Kind: Equatable { case header, item, action }
    enum Action: Equatable { case newCollection, saveFilters }
    enum Source: Equatable { case allPhotos, collection(PhotoCollection), smart(SmartCollection), folder(PhotoCollection) }

    let id: String
    let kind: Kind
    let title: String
    var filter: LibraryFilter?
    var source: Source?

    /// The hover text of a row: a smart collection describes its criteria; nothing else has one.
    var tooltip: String? {
        if case .smart(let smart)? = source { return smart.criteria.summary }
        return nil
    }
    var action: Action?
    /// Folder rows only: nesting depth (0 = a root), whether it has sub-folders, and whether they are shown.
    var depth = 0
    var hasChildren = false
    var isExpanded = false
    var folderID: Int64?
    var parentFolderID: Int64?
}

enum SidebarRows {
    /// The rows, top to bottom: All Photos, Collections (+ "New Collection…"), Smart Collections (+ "Save Current Filters…"), then the
    /// Folders tree (only when there are folders). Folder children are listed only under EXPANDED folders (collapsed by default).
    static func rows(collections: [PhotoCollection], smartCollections: [SmartCollection], expandedFolders: Set<Int64>) -> [SidebarRow] {
        var rows: [SidebarRow] = [SidebarRow(id: "all", kind: .item, title: "All Photos", filter: .allPhotos, source: .allPhotos)]

        rows.append(SidebarRow(id: "header-collections", kind: .header, title: "Collections"))
        for collection in collections where !collection.isFolder {
            guard let id = collection.id else { continue }
            rows.append(SidebarRow(id: "collection-\(id)", kind: .item, title: collection.name, filter: .collection(id),
                                   source: .collection(collection)))
        }
        rows.append(SidebarRow(id: "action-new-collection", kind: .action, title: "New Collection…", action: .newCollection))

        rows.append(SidebarRow(id: "header-smart", kind: .header, title: "Smart Collections"))
        for smart in smartCollections {
            guard let id = smart.id else { continue }
            rows.append(SidebarRow(id: "smart-\(id)", kind: .item, title: smart.name, filter: .smartCollection(id), source: .smart(smart)))
        }
        rows.append(SidebarRow(id: "action-save-filters", kind: .action, title: "Save Current Filters…", action: .saveFilters))

        let folders = collections.filter(\.isFolder)
        if !folders.isEmpty {
            rows.append(SidebarRow(id: "header-folders", kind: .header, title: "Folders"))
            let byParent = Dictionary(grouping: folders, by: \.parentId)
            func append(_ folder: PhotoCollection, depth: Int) {
                guard let id = folder.id else { return }
                let children = (byParent[id] ?? []).sorted { $0.name < $1.name }
                let expanded = expandedFolders.contains(id) && !children.isEmpty
                rows.append(SidebarRow(id: "folder-\(id)", kind: .item, title: folder.name, filter: .collection(id), source: .folder(folder),
                                       depth: depth, hasChildren: !children.isEmpty, isExpanded: expanded, folderID: id,
                                       parentFolderID: folder.parentId))
                if expanded { for child in children { append(child, depth: depth + 1) } }
            }
            for root in (byParent[nil] ?? []).sorted(by: { $0.name < $1.name }) { append(root, depth: 0) }
        }
        return rows
    }

    /// The filters of the visible selectable rows, in order (what Up / Down walk through).
    static func selectableFilters(in rows: [SidebarRow]) -> [LibraryFilter] {
        rows.compactMap { $0.kind == .item ? $0.filter : nil }
    }

    /// The filter `offset` rows away from `current` among the visible selectable rows, clamped at both ends. An unknown `current` (its
    /// row is hidden, e.g. inside a collapsed folder) selects the first row for a forward move and stays put for none.
    static func moved(from current: LibraryFilter, by offset: Int, in rows: [SidebarRow]) -> LibraryFilter {
        let filters = selectableFilters(in: rows)
        guard !filters.isEmpty else { return current }
        guard let index = filters.firstIndex(of: current) else { return filters[0] }
        return filters[min(max(index + offset, 0), filters.count - 1)]
    }

    /// Right arrow: expand the selected folder if it has sub-folders and is collapsed.
    static func expanding(_ selected: LibraryFilter, expanded: Set<Int64>, in rows: [SidebarRow]) -> Set<Int64> {
        guard let row = rows.first(where: { $0.kind == .item && $0.filter == selected && $0.folderID != nil }),
              let id = row.folderID, row.hasChildren, !row.isExpanded else { return expanded }
        return expanded.union([id])
    }

    /// Left arrow: collapse the selected folder if it is expanded, otherwise select its parent folder (if any).
    static func collapsing(_ selected: LibraryFilter, expanded: Set<Int64>, in rows: [SidebarRow]) -> (selection: LibraryFilter, expanded: Set<Int64>) {
        guard let row = rows.first(where: { $0.kind == .item && $0.filter == selected && $0.folderID != nil }), let id = row.folderID else {
            return (selected, expanded)
        }
        if row.isExpanded { return (selected, expanded.subtracting([id])) }
        if let parent = row.parentFolderID { return (.collection(parent), expanded) }
        return (selected, expanded)
    }

    /// The chevron: toggle one folder. Collapsing a folder that CONTAINS the selection moves the selection to that folder (as Finder
    /// does), so the selection never ends up on a hidden row.
    static func toggled(_ folderID: Int64, selected: LibraryFilter, expanded: Set<Int64>, in rows: [SidebarRow]) -> (selection: LibraryFilter, expanded: Set<Int64>) {
        guard let index = rows.firstIndex(where: { $0.kind == .item && $0.folderID == folderID }) else { return (selected, expanded) }
        let folder = rows[index]
        guard expanded.contains(folderID) else { return (selected, expanded.union([folderID])) }
        var selection = selected
        if folder.isExpanded {
            for row in rows[(index + 1)...] {
                if row.kind != .item || row.depth <= folder.depth { break }
                if row.filter == selected, let own = folder.filter { selection = own; break }
            }
        }
        return (selection, expanded.subtracting([folderID]))
    }

    /// `expanded` without folders that no longer exist (a deleted folder's id can be reused by SQLite).
    static func pruned(_ expanded: Set<Int64>, collections: [PhotoCollection]) -> Set<Int64> {
        expanded.intersection(Set(collections.filter(\.isFolder).compactMap(\.id)))
    }
}
