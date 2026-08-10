import SwiftUI

/// The Library's left sidebar — Phase 4 slice 4, the first `List` in this
/// app. Lists "All Photos" plus every user-created `PhotoCollection`,
/// bound directly to `catalog.selectedFilter`; `CatalogModel.refresh()`
/// re-filters `photos` whenever that selection changes. Creating a
/// collection is a simple name-entry `.alert`, matching this app's
/// existing alert-based prompt pattern rather than introducing a new
/// sheet UI.
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
            ForEach(catalog.collections) { collection in
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
}
