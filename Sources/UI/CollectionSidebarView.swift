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
                        Text(collection.name).tag(LibraryFilter.collection(id))
                    }
                }
                Button("New Collection…") {
                    newCollectionName = ""
                    isPresentingNewCollection = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
