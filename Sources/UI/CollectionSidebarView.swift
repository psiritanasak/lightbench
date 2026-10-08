import SwiftUI

/// The Library's left sidebar. Lists "All Photos", a "Collections" section (flat, user-created `PhotoCollection`s), "Smart
/// Collections", and — for folder-mirrored nested collections — a "Folders" section showing the recursive on-disk tree. It draws its
/// OWN rows (`SidebarRows` is the pure, ordered row list) instead of using a system `List`, because the system's selection highlight
/// is the accent blue and cannot be restyled: the selected row is a soft grey chip (`Theme.selectedFill`). Every row, at any depth,
/// is bound the same way: `catalog.selectedFilter`;
/// `CatalogModel.refresh()` re-filters `photos` whenever that selection
/// changes. Creating a (manual) collection is a simple name-entry
/// `.alert`, matching this app's existing alert-based prompt pattern
/// rather than introducing a new sheet UI.
struct CollectionSidebarView: View {
    @ObservedObject var catalog: CatalogModel

    @State private var isPresentingNewCollection = false
    @State private var newCollectionName = ""

    /// D5 (IMPROVEMENTS.md): rename/delete, flat "Collections" rows only —
    /// deliberately not offered on "Folders" rows, since deleting a folder
    /// collection recursively deletes its whole subtree
    /// (`Migrations/004_folder_collections.swift`'s self-referencing
    /// `ON DELETE CASCADE` on `parentId`) and both rename and delete
    /// interact oddly with re-import (`findOrCreateFolderCollection`
    /// matches purely by `folderPath`, never `name`) — out of scope for
    /// this slice, matching this project's own prior explicit exclusion
    /// when folder collections first shipped.
    ///
    /// `presenting:`-driven (unlike the "New Collection" alert above,
    /// which needs no per-item state) — both need to know WHICH collection
    /// was tapped, the same shape `LibraryGridView`'s "Remove from
    /// Library?" alert already established for exactly this reason.
    @State private var collectionPendingRename: PhotoCollection?
    @State private var renameText = ""
    @State private var collectionPendingDeletion: PhotoCollection?

    /// Smart collections (saved filter sets): the name alert for saving the current filters, plus per-row rename and
    /// delete — the same `presenting:`-driven shape as the plain collections above.
    @State private var isPresentingNewSmart = false
    @State private var newSmartName = ""
    @State private var smartPendingRename: SmartCollection?
    @State private var smartRenameText = ""
    @State private var smartPendingDeletion: SmartCollection?

    /// A section header in the Adjust panel's quiet style (small, uppercase, secondary).
    private static func header(_ title: String) -> some View {
        Text(title).font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
    }

    /// Folders whose children are shown. Collapsed by default, like the old `OutlineGroup`.
    @State private var expandedFolders: Set<Int64> = []
    @State private var hoveredRowID: String?
    @FocusState private var isFocused: Bool

    private var rows: [SidebarRow] {
        SidebarRows.rows(collections: catalog.collections, smartCollections: catalog.smartCollections, expandedFolders: expandedFolders)
    }

    var body: some View {
        let rows = rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in rowView(row) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        // Solid like the Editor's Adjust panel (no system sidebar material).
        .background(Theme.panel)
        // Keyboard: Up / Down move the selection, Right / Left expand / collapse a folder (the system List did this for us).
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { catalog.selectedFilter = SidebarRows.moved(from: catalog.selectedFilter, by: -1, in: rows); return .handled }
        .onKeyPress(.downArrow) { catalog.selectedFilter = SidebarRows.moved(from: catalog.selectedFilter, by: 1, in: rows); return .handled }
        .onKeyPress(.rightArrow) {
            expandedFolders = SidebarRows.expanding(catalog.selectedFilter, expanded: expandedFolders, in: rows)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            let result = SidebarRows.collapsing(catalog.selectedFilter, expanded: expandedFolders, in: rows)
            expandedFolders = result.expanded
            catalog.selectedFilter = result.selection
            return .handled
        }
        .onChange(of: catalog.collections) { _, collections in
            expandedFolders = SidebarRows.pruned(expandedFolders, collections: collections)
        }
        .alert("New Collection", isPresented: $isPresentingNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                catalog.createCollection(name: newCollectionName)
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) {
                newCollectionName = ""
            }
        }
        .alert("New Smart Collection", isPresented: $isPresentingNewSmart) {
            TextField("Name", text: $newSmartName)
            Button("Save") {
                let name = newSmartName
                newSmartName = ""
                Task { await catalog.saveFiltersAsSmartCollection(name: name) }
            }
            Button("Cancel", role: .cancel) { newSmartName = "" }
        } message: {
            Text("Saves the current rating, flag, label and keyword filters. It covers the whole catalog, whichever collection is open. Search text is not saved.")
        }
        .alert(
            "Rename Smart Collection",
            isPresented: Binding(
                get: { smartPendingRename != nil },
                set: { isPresented in if !isPresented { smartPendingRename = nil } }
            ),
            presenting: smartPendingRename
        ) { smart in
            TextField("Name", text: $smartRenameText)
            Button("Rename") {
                let name = smartRenameText
                smartPendingRename = nil
                Task { await catalog.renameSmartCollection(smart, to: name) }
            }
            Button("Cancel", role: .cancel) { smartPendingRename = nil }
        }
        .alert(
            "Delete Smart Collection?",
            isPresented: Binding(
                get: { smartPendingDeletion != nil },
                set: { isPresented in if !isPresented { smartPendingDeletion = nil } }
            ),
            presenting: smartPendingDeletion
        ) { smart in
            Button("Delete", role: .destructive) {
                smartPendingDeletion = nil
                Task { await catalog.deleteSmartCollection(smart) }
            }
            Button("Cancel", role: .cancel) { smartPendingDeletion = nil }
        } message: { smart in
            Text("\"\(smart.name)\" will be deleted. The photos in it, and their files on disk, are not affected.")
        }
        .alert(
            "Rename Collection",
            isPresented: Binding(
                get: { collectionPendingRename != nil },
                set: { isPresented in if !isPresented { collectionPendingRename = nil } }
            ),
            presenting: collectionPendingRename
        ) { collection in
            TextField("Name", text: $renameText)
            Button("Rename") {
                catalog.renameCollection(collection, to: renameText)
                collectionPendingRename = nil
            }
            Button("Cancel", role: .cancel) {
                collectionPendingRename = nil
            }
        }
        .alert(
            "Delete Collection?",
            isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { isPresented in if !isPresented { collectionPendingDeletion = nil } }
            ),
            presenting: collectionPendingDeletion
        ) { collection in
            Button("Delete", role: .destructive) { catalog.deleteCollection(collection) }
            Button("Cancel", role: .cancel) {}
        } message: { collection in
            Text("\"\(collection.name)\" will be deleted. The photos in it, and their files on disk, are not affected.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        switch row.kind {
        case .header:
            Self.header(row.title)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            Button(row.title) { perform(row.action) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(row.action == .saveFilters && !catalog.hasSaveableFilterCriteria)
                .help(row.action == .saveFilters
                      ? "Save the rating, flag, label and keyword filters as a smart collection over the whole catalog (search text is not saved)"
                      : "")
        case .item:
            itemRow(row)
        }
    }

    private func perform(_ action: SidebarRow.Action?) {
        switch action {
        case .newCollection:
            newCollectionName = ""
            isPresentingNewCollection = true
        case .saveFilters:
            newSmartName = ""
            isPresentingNewSmart = true
        case nil: break
        }
    }

    private func itemRow(_ row: SidebarRow) -> some View {
        let isSelected = row.filter == catalog.selectedFilter
        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.folderID != nil {
                // A fixed-width disclosure slot so titles line up whether or not a folder has sub-folders.
                if row.hasChildren, let id = row.folderID {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused = true; toggle(id) }
                        .accessibilityLabel(row.isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")
                        .accessibilityAddTraits(.isButton)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
            }
            Text(row.title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionChip(isSelected: isSelected, isHovered: hoveredRowID == row.id)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredRowID = row.id } else if hoveredRowID == row.id { hoveredRowID = nil }
        }
        .onTapGesture { select(row) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { select(row) }
        .modifier(DisclosureAccessibility(row: row) { if let id = row.folderID { toggle(id) } })
        .contextMenu { contextMenu(for: row) }
    }

    /// A click takes keyboard focus (a bare `.focusable()` view does not on macOS), so Up / Down reach the sidebar, not the grid.
    private func select(_ row: SidebarRow) {
        isFocused = true
        if let filter = row.filter { catalog.selectedFilter = filter }
    }

    private func toggle(_ folderID: Int64) {
        let result = SidebarRows.toggled(folderID, selected: catalog.selectedFilter, expanded: expandedFolders, in: rows)
        expandedFolders = result.expanded
        catalog.selectedFilter = result.selection
    }

    /// Rename / Delete on the flat collections and smart collections; nothing on folder rows (deleting a folder collection deletes
    /// its whole subtree — see the note on `collectionPendingRename`).
    @ViewBuilder
    private func contextMenu(for row: SidebarRow) -> some View {
        switch row.source {
        case .collection(let collection):
            Button("Rename…") {
                renameText = collection.name
                collectionPendingRename = collection
            }
            Button(role: .destructive) {
                collectionPendingDeletion = collection
            } label: {
                // `role: .destructive` alone doesn't render red text on a macOS context menu item — the same live-caught lesson
                // already documented at `LibraryGridView`'s own destructive menu item.
                Label {
                    Text("Delete").foregroundStyle(.red)
                } icon: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
            }
        case .smart(let smart):
            Button("Rename…") {
                smartRenameText = smart.name
                smartPendingRename = smart
            }
            Button("Update from Current Filters") {
                Task { await catalog.updateSmartCollectionFromFilters(smart) }
            }
            .disabled(!catalog.hasSaveableFilterCriteria)
            Button(role: .destructive) {
                smartPendingDeletion = smart
            } label: {
                Label {
                    Text("Delete").foregroundStyle(.red)
                } icon: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
            }
        case .allPhotos, .folder, nil:
            EmptyView()
        }
    }
}

/// Exposes a folder row's expanded / collapsed state and an Expand / Collapse action to VoiceOver (the row is one combined element, so
/// the chevron's own button is not reachable).
private struct DisclosureAccessibility: ViewModifier {
    let row: SidebarRow
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if row.hasChildren {
            content
                .accessibilityValue(row.isExpanded ? "expanded" : "collapsed")
                .accessibilityAction(named: row.isExpanded ? "Collapse" : "Expand", toggle)
        } else {
            content
        }
    }
}
