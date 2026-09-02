import SwiftUI

@main
struct PhotoAppApp: App {
    /// Owns `ImageDocumentModel` here, not in `ContentView`, so the Edit
    /// menu below (a `Scene`-level construct) and the toolbar's own
    /// Undo/Redo buttons in `ContentView` can both act on the SAME
    /// document instance.
    @StateObject private var document = ImageDocumentModel()

    /// Phase 4 slice 1's catalog DB + basic folder import. Owned here,
    /// same reasoning as `document` — a single shared instance for
    /// `ContentView` (and, later, any browsing UI) to observe.
    @StateObject private var catalog = CatalogModel()

    /// Whether the window is showing the Library grid instead of the Editor.
    /// Presentation-only, and `ContentView`'s own `@State` until the Photo
    /// menu below needed it: prev/next is EDITOR navigation, so it must
    /// disable while the grid is up (there, it would be an invisible load).
    /// Lifted here for exactly the reason `document` and `catalog` were — a
    /// Scene-level command can't read a view's private state.
    @State private var showLibrary = false

    var body: some Scene {
        WindowGroup {
            ContentView(document: document, catalog: catalog, showLibrary: $showLibrary)
        }
        .commands {
            // Replaces macOS's default (inert) Edit > Undo/Redo items —
            // the canonical, keyboard-shortcut-owning home for these
            // actions. Wired to the SAME `document.undo()`/`.redo()` the
            // toolbar buttons already call; `canUndo`/`canRedo` being
            // `@Published` on `document` means these reactively
            // enable/disable in sync with the toolbar.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { document.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!document.canUndo)
                Button("Redo") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!document.canRedo)
            }
            // Move between photos without a round-trip through the Library
            // grid. Same pattern as the Edit menu above: the Scene-level
            // command owns the shortcut (the toolbar deliberately doesn't
            // duplicate shortcuts — see `ContentView`'s Undo/Redo buttons),
            // and `.disabled` reads `@Published` state (`document.currentURL`
            // plus `catalog`'s own published fields, which `displayedPhotos`
            // is derived from) so both items enable/disable reactively.
            CommandMenu("Photo") {
                // Bound ONCE per body pass on purpose. `catalog.displayedPhotos`
                // is a full filter+sort of the library, and this Scene's body
                // re-evaluates on every `document.editState` publish — i.e. on
                // every slider tick while editing. Asking each item separately
                // would pay it twice per tick. MEASURED (see PROGRESS.md):
                // 0.37ms per apply at 1,000 photos, 3.61ms at 10,000.
                let neighbors = photoNeighbors
                Button("Previous Photo") { open(neighbors.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(neighbors.previous == nil)
                Button("Next Photo") { open(neighbors.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(neighbors.next == nil)
            }
        }
    }

    /// What ⌘← and ⌘→ would open, both resolved from ONE pass over
    /// `displayedPhotos` — see the call site for why that matters. Either side
    /// is `nil` when that direction is unavailable; see
    /// `LibraryNavigation.neighbor(of:in:offset:)` for the cases it covers.
    /// Walking `displayedPhotos` (not `photos`) is what makes navigation follow
    /// the grid's current sort/filter/search.
    private var photoNeighbors: (previous: Photo?, next: Photo?) {
        // Both cheap disqualifiers first, so the common "no photo open" and
        // "browsing the grid" cases never touch the filter+sort at all.
        guard !showLibrary, let currentPath = document.currentURL?.path else { return (nil, nil) }
        let displayed = catalog.displayedPhotos
        return (
            previous: LibraryNavigation.neighbor(of: currentPath, in: displayed, offset: -1),
            next: LibraryNavigation.neighbor(of: currentPath, in: displayed, offset: 1)
        )
    }

    /// Deliberately goes through the SAME `load(from:)` the Library grid's own
    /// tap-to-open uses, rather than a parallel load path: that method already
    /// flushes the OUTGOING photo's still-debounced sidecar save, restores the
    /// incoming photo's saved edits, and resets undo history so it can't reach
    /// back into the previous photo.
    ///
    /// Takes an optional and no-ops on `nil` so the menu items can hand over
    /// the very photo their own `.disabled` was computed from, rather than
    /// re-deriving it when clicked.
    private func open(_ photo: Photo?) {
        guard let photo else { return }
        Task { await document.load(from: URL(fileURLWithPath: photo.path)) }
    }
}
