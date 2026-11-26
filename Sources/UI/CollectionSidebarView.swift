import SwiftUI

/// The Library's left sidebar. Lists "All Photos", a "Collections" section (flat, user-created `PhotoCollection`s), "Smart
/// Collections", and — for folder-mirrored nested collections — a "Folders" section showing the recursive on-disk tree. It draws its
/// OWN rows (`SidebarRows` is the pure, ordered row list) instead of using a system `List`, because the system's selection highlight
/// is the accent blue and cannot be restyled: the selected row is a soft grey chip (`Theme.selectedFill`). Every row, at any depth,
/// is bound the same way: `catalog.selectedFilter`;
/// `CatalogModel.refresh()` re-filters `photos` whenever that selection
/// changes. Creating and renaming collections and smart collections happens IN the row (a text field; the "+" at the right of a
/// section header adds a draft row under it). Only the two Delete confirmations remain alerts.
struct CollectionSidebarView: View {
    @ObservedObject var catalog: CatalogModel

    /// D5 (IMPROVEMENTS.md): rename/delete, flat "Collections" rows only — deliberately not offered on "Folders" rows, since deleting a
    /// folder collection recursively deletes its whole subtree (`Migrations/004_folder_collections.swift`'s self-referencing
    /// `ON DELETE CASCADE` on `parentId`) and both rename and delete interact oddly with re-import (`findOrCreateFolderCollection`
    /// matches purely by `folderPath`, never `name`).
    @State private var collectionPendingDeletion: PhotoCollection?
    @State private var smartPendingDeletion: SmartCollection?

    /// The row being named in place (nil = none), its text, the message of a refused name, and whether a commit is in flight (the field
    /// is read-only meanwhile, and losing focus no longer commits again).
    @State private var editing: SidebarEdit?
    @State private var editText = ""
    @State private var editError: String?
    @State private var isCommitting = false
    /// Focus is keyed per edit, so a field that loses focus can only ever submit ITS OWN edit (never a newer one that replaced it).
    @FocusState private var focusedEdit: SidebarEdit?

    /// A section header in the Adjust panel's quiet style (small, uppercase, secondary).
    private static func header(_ title: String) -> some View {
        Text(title).font(.caption).textCase(.uppercase).foregroundStyle(Theme.textSecondary)
    }

    /// Folders whose children are shown. Collapsed by default, like the old `OutlineGroup`.
    @State private var expandedFolders: Set<Int64> = []
    @State private var hoveredRowID: String?
    /// The plain collection row a thumbnail drag is currently over.
    @State private var dropTargetRowID: String?
    @FocusState private var isFocused: Bool

    private var rows: [SidebarRow] {
        SidebarRows.rows(
            collections: catalog.collections, smartCollections: catalog.smartCollections, expandedFolders: expandedFolders,
            collectionCounts: catalog.collectionPhotoCounts, allPhotosCount: catalog.photoCount,
            smartCounts: catalog.smartCollectionCounts, editing: editing)
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
        .onKeyPress(.upArrow) { if focusedEdit != nil { return .ignored }; catalog.selectedFilter = SidebarRows.moved(from: catalog.selectedFilter, by: -1, in: rows); return .handled }
        .onKeyPress(.downArrow) { if focusedEdit != nil { return .ignored }; catalog.selectedFilter = SidebarRows.moved(from: catalog.selectedFilter, by: 1, in: rows); return .handled }
        .onKeyPress(.rightArrow) {
            if focusedEdit != nil { return .ignored }
            expandedFolders = SidebarRows.expanding(catalog.selectedFilter, expanded: expandedFolders, in: rows)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if focusedEdit != nil { return .ignored }
            let result = SidebarRows.collapsing(catalog.selectedFilter, expanded: expandedFolders, in: rows)
            expandedFolders = result.expanded
            catalog.selectedFilter = result.selection
            return .handled
        }
        .onChange(of: catalog.collections) { _, collections in
            expandedFolders = SidebarRows.pruned(expandedFolders, collections: collections)
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
            HStack(spacing: 4) {
                Self.header(row.title)
                Spacer(minLength: 0)
                if let add = row.addAction { addButton(add) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .item:
            itemRow(row)
        }
    }

    /// The "+" at the right of a section header. Collections: a draft row. Smart Collections: a draft row too, but only while there is
    /// a filter worth saving (the tooltip says what it saves, and why it is off).
    private func addButton(_ action: SidebarRow.Action) -> some View {
        let isSmart = action == .saveFilters
        let enabled = !isSmart || catalog.hasSaveableFilterCriteria
        let title = isSmart ? "New Smart Collection" : "New Collection"
        let help = isSmart
            ? "Saves the current rating, flag, label and keyword filters and the search box (for example iso:>1600 camera:d610) as a smart collection over the whole catalog."
                + (enabled ? "" : " Set a filter first.")
            : "New collection"
        return Button { begin(isSmart ? .newSmart : .newCollection) } label: {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? "" : "Set a filter first")
    }

    // MARK: In-place naming

    private func begin(_ edit: SidebarEdit) {
        guard !isCommitting else { return }
        // An edit already open is settled first (a valid name commits, anything else is dropped), never silently overwritten.
        if editing != nil { submit(keepOpenOnInvalid: false) }
        guard !isCommitting else { return }
        switch edit {
        case .newCollection, .newSmart: editText = ""
        case .renameCollection(let id): editText = catalog.collections.first { $0.id == id }?.name ?? ""
        case .renameSmart(let id): editText = catalog.smartCollections.first { $0.id == id }?.name ?? ""
        }
        editError = nil
        editing = edit
    }

    private func original(of edit: SidebarEdit) -> String {
        switch edit {
        case .newCollection, .newSmart: return ""
        case .renameCollection(let id): return catalog.collections.first { $0.id == id }?.name ?? ""
        case .renameSmart(let id): return catalog.smartCollections.first { $0.id == id }?.name ?? ""
        }
    }

    /// Names of the same kind, the row being renamed excluded. Folders are a separate namespace.
    private func otherNames(for edit: SidebarEdit) -> [String] {
        switch edit {
        case .newCollection, .renameCollection:
            var own: Int64?
            if case .renameCollection(let id) = edit { own = id }
            return catalog.collections.filter { !$0.isFolder && $0.id != own }.map(\.name)
        case .newSmart, .renameSmart:
            var own: Int64?
            if case .renameSmart(let id) = edit { own = id }
            return catalog.smartCollections.filter { $0.id != own }.map(\.name)
        }
    }

    /// Return, or (`allowInvalid: false`) losing focus: commit a valid name; a refused name keeps the field open on Return and is
    /// dropped when focus leaves.
    private func submit(keepOpenOnInvalid: Bool) {
        guard let edit = editing, !isCommitting else { return }
        switch SidebarRename.verdict(edit, text: editText, original: original(of: edit), otherNames: otherNames(for: edit)) {
        case .cancel:
            editing = nil
        case .invalid(let message):
            if keepOpenOnInvalid {
                editError = message
                // Return makes the field give up first responder AFTER this handler returns, so setting focus here is undone (Esc then
                // never reached the field). Re-focus on the next run-loop pass, and only if this edit is still the open one.
                DispatchQueue.main.async {
                    guard editing == edit else { return }
                    focusedEdit = edit
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isFieldEditor, text.string == editText {
                        text.selectAll(nil)
                    }
                }
            } else {
                editing = nil
            }
        case .commit(let name):
            editError = nil
            switch edit {
            case .newCollection:
                isCommitting = true
                Task {
                    await catalog.createCollection(name: name)
                    isCommitting = false
                    editing = nil
                }
            case .newSmart:
                isCommitting = true
                Task {
                    await catalog.saveFiltersAsSmartCollection(name: name)
                    isCommitting = false
                    editing = nil
                }
            case .renameCollection(let id):
                editing = nil
                if let collection = catalog.collections.first(where: { $0.id == id }) { catalog.renameCollection(collection, to: name) }
            case .renameSmart(let id):
                editing = nil
                if let smart = catalog.smartCollections.first(where: { $0.id == id }) {
                    Task { await catalog.renameSmartCollection(smart, to: name) }
                }
            }
        }
    }

    /// Esc: the text goes back to the original FIRST (as `EditControlRows` does), then the field closes.
    private func cancelEditing() {
        if let edit = editing { editText = original(of: edit) }
        editError = nil
        editing = nil
    }

    private func edit(for row: SidebarRow) -> SidebarEdit? {
        if row.id == SidebarRows.draftCollectionID { return .newCollection }
        if row.id == SidebarRows.draftSmartID { return .newSmart }
        switch row.source {
        case .collection(let collection)?: return collection.id.map { .renameCollection($0) }
        case .smart(let smart)?: return smart.id.map { .renameSmart($0) }
        default: return nil
        }
    }

    private func nameField(_ row: SidebarRow) -> some View {
        let own = edit(for: row)
        return VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: $editText)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($focusedEdit, equals: own)
                .disabled(isCommitting)
                .onSubmit { submit(keepOpenOnInvalid: true) }
                .onExitCommand { cancelEditing() }
                .onAppear {
                    focusedEdit = own
                    // SwiftUI cannot select the text itself: ask the field editor once it exists, and only select when it holds
                    // THIS field's text (never another field's editor, e.g. the search box).
                    let expected = editText
                    DispatchQueue.main.async {
                        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isFieldEditor, text.string == expected {
                            text.selectAll(nil)
                        }
                    }
                }
                .onChange(of: focusedEdit) { old, _ in
                    // Only the field that LOST focus, and only while its own edit is still the open one.
                    if let own, old == own, editing == own { submit(keepOpenOnInvalid: false) }
                }
                .accessibilityLabel("Name")
            if let editError {
                Text(editError).font(.caption).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .padding(.vertical, 1)
        .overlay(alignment: .bottom) {
            if editError != nil { Rectangle().fill(Theme.warning).frame(height: 1) }
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
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused = true; toggle(id) }
                        .accessibilityLabel(row.isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")
                        .accessibilityAddTraits(.isButton)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
            }
            if row.isEditing { nameField(row) } else { Text(row.title).lineLimit(1) }
            Spacer(minLength: 0)
            if let count = row.count {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionChip(isSelected: isSelected, isHovered: hoveredRowID == row.id)
        .contentShape(Rectangle())
        .help(row.tooltip ?? "")
        .onHover { inside in
            if inside { hoveredRowID = row.id } else if hoveredRowID == row.id { hoveredRowID = nil }
        }
        .onTapGesture { if !row.isEditing { select(row) } }
        .modifier(CollectionDropTarget(enabled: SidebarDrop.accepts(row), isTargeted: dropTargetRowID == row.id,
                                       setTargeted: { inside in
                                           if inside { dropTargetRowID = row.id } else if dropTargetRowID == row.id { dropTargetRowID = nil }
                                       },
                                       drop: { ids in
                                           guard case .collection(let collection)? = row.source else { return false }
                                           catalog.addPhotos(ids: ids, to: collection)
                                           return true
                                       }))
        .modifier(ItemAccessibility(row: row, isSelected: isSelected, select: { select(row) }))
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

    /// Rename / Delete on the flat collections and smart collections; folder rows only get the "Show Photos in Subfolders" toggle
    /// (deleting a folder collection deletes its whole subtree — see the note on `collectionPendingDeletion`).
    @ViewBuilder
    private func contextMenu(for row: SidebarRow) -> some View {
        switch row.source {
        case .collection(let collection):
            Button("Rename") { begin(.renameCollection(collection.id ?? -1)) }
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
            Button("Rename") { begin(.renameSmart(smart.id ?? -1)) }
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
        case .folder:
            Toggle("Show Photos in Subfolders", isOn: $catalog.showPhotosInSubfolders)
        case .allPhotos, nil:
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

/// A row's VoiceOver element: one button with its title, selection and a select action. While its name is being edited the row is just a
/// container, so the text field stays reachable on its own.
private struct ItemAccessibility: ViewModifier {
    let row: SidebarRow
    let isSelected: Bool
    let select: () -> Void

    func body(content: Content) -> some View {
        if row.isEditing {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                .accessibilityAction { select() }
        }
    }
}

/// Makes a plain-collection row a drop target for dragged library thumbnails, with the quiet highlight (grey chip + white ring, never
/// blue) while one is over it. Rows that do not accept photos get no destination at all, so the drag falls through to the window's URL drop,
/// which refuses it (the cursor shows "not allowed").
private struct CollectionDropTarget: ViewModifier {
    let enabled: Bool
    let isTargeted: Bool
    let setTargeted: (Bool) -> Void
    let drop: ([Int64]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .background {
                    if isTargeted { RoundedRectangle(cornerRadius: 5).fill(Theme.selectedFill) }
                }
                .overlay {
                    if isTargeted { RoundedRectangle(cornerRadius: 5).stroke(Theme.selectedOutline, lineWidth: 1).allowsHitTesting(false) }
                }
                .dropDestination(for: LibraryPhotoDrag.self) { items, _ in
                    drop(Array(Set(items.flatMap(\.photoIDs))).sorted())
                } isTargeted: { setTargeted($0) }
        } else {
            content
        }
    }
}
