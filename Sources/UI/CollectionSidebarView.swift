import SwiftUI

/// The Library's left sidebar — Phase 4 slice 4, the first `List` in this
/// app. Lists "All Photos", a "Collections" section (flat, user-created
/// `PhotoCollection`s), and — for folder-mirrored nested collections — a
/// "Folders" section showing the recursive on-disk tree via
/// `OutlineGroup` (this file's `FolderTreeNode`/`buildFolderTree`, built
/// client-side from the same flat `catalog.collections` array; no
/// separate published tree state on `CatalogModel`). Every row, at any
/// depth, is bound the same way: `catalog.selectedFilter`;
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

    /// `List(selection:)` only accepts an Optional-wrapped selection
    /// binding (it needs to represent "nothing selected"), even though
    /// `catalog.selectedFilter` itself is deliberately non-optional (see
    /// `LibraryFilter`'s own doc comment for why). This coerces the rare
    /// "deselected" case back to `.allPhotos` rather than ever letting
    /// `catalog.selectedFilter` observe a real `nil` — every row's own
    /// `.tag(...)` below is still a concrete, non-optional `LibraryFilter`
    /// value, which is what actually avoids the live-discovered bug.
    private var selection: Binding<LibraryFilter?> {
        Binding(
            get: { catalog.selectedFilter },
            set: { catalog.selectedFilter = $0 ?? .allPhotos }
        )
    }

    var body: some View {
        List(selection: selection) {
            Text("All Photos").tag(LibraryFilter.allPhotos)

            Section("Collections") {
                ForEach(catalog.collections.filter { !$0.isFolder }) { collection in
                    if let id = collection.id {
                        Text(collection.name)
                            .tag(LibraryFilter.collection(id))
                            .contextMenu {
                                Button("Rename…") {
                                    renameText = collection.name
                                    collectionPendingRename = collection
                                }
                                Button(role: .destructive) {
                                    collectionPendingDeletion = collection
                                } label: {
                                    // `role: .destructive` alone doesn't
                                    // render red text on a macOS context
                                    // menu item — the same live-caught
                                    // lesson already documented at
                                    // `LibraryGridView`'s own destructive
                                    // menu item.
                                    Label {
                                        Text("Delete")
                                            .foregroundStyle(.red)
                                    } icon: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                    }
                }
                Button("New Collection…") {
                    newCollectionName = ""
                    isPresentingNewCollection = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Smart Collections") {
                ForEach(catalog.smartCollections) { smart in
                    if let id = smart.id {
                        Text(smart.name)
                            .tag(LibraryFilter.smartCollection(id))
                            .contextMenu {
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
                            }
                    }
                }
                Button("Save Current Filters…") {
                    newSmartName = ""
                    isPresentingNewSmart = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!catalog.hasSaveableFilterCriteria)
                .help("Save the rating, flag, label and keyword filters as a smart collection over the whole catalog (search text is not saved)")
            }

            let folderRoots = Self.buildFolderTree(from: catalog.collections)
            if !folderRoots.isEmpty {
                Section("Folders") {
                    OutlineGroup(folderRoots, children: \.children) { node in
                        if let id = node.collection.id {
                            Text(node.collection.name).tag(LibraryFilter.collection(id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

    /// Builds the `OutlineGroup`-ready tree from `catalog.collections`'
    /// `isFolder`/`parentId` fields, keeping `CatalogModel` itself free of
    /// any tree-shaped state — it only ever needs to publish a flat array.
    private static func buildFolderTree(from collections: [PhotoCollection]) -> [FolderTreeNode] {
        let folders = collections.filter(\.isFolder)
        let byParent = Dictionary(grouping: folders, by: \.parentId)
        func node(for collection: PhotoCollection) -> FolderTreeNode {
            let childCollections = (byParent[collection.id] ?? []).sorted { $0.name < $1.name }
            return FolderTreeNode(collection: collection, rawChildren: childCollections.map(node(for:)))
        }
        return (byParent[nil] ?? []).sorted { $0.name < $1.name }.map(node(for:))
    }
}

/// One node in the folder-mirrored collection tree, wrapping a
/// `PhotoCollection` (`isFolder == true`) plus its already-resolved
/// children.
private struct FolderTreeNode: Identifiable {
    let collection: PhotoCollection
    let rawChildren: [FolderTreeNode]

    var id: Int64 { collection.id ?? -1 }

    /// `nil`, not an empty array, when there are no children — required
    /// so `OutlineGroup` hides the disclosure triangle on a leaf folder
    /// (a "Day" node with photos but no subfolders) rather than showing
    /// an always-empty one.
    var children: [FolderTreeNode]? {
        rawChildren.isEmpty ? nil : rawChildren
    }
}
