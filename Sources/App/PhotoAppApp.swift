import SwiftUI

@main
struct PhotoAppApp: App {
    /// Receives files and folders opened from Finder / the Dock (queued in `OpenRequests`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owns `ImageDocumentModel` here, not in `ContentView`, so the Edit
    /// menu below (a `Scene`-level construct) and the toolbar's own
    /// Undo/Redo buttons in `ContentView` can both act on the SAME
    /// document instance.
    @StateObject private var document = ImageDocumentModel()

    /// Phase 4 slice 1's catalog DB + basic folder import. Owned here,
    /// same reasoning as `document` — a single shared instance for
    /// `ContentView` (and, later, any browsing UI) to observe.
    @StateObject private var catalog = CatalogModel()

    /// Owns "Copy Settings"/"Paste Settings" (Copy/Paste Edit Settings
    /// across a Library multi-selection). Owned here, same reasoning as
    /// `document`/`catalog` — the Photo menu's own ⇧⌘C/⇧⌘V below (a
    /// Scene-level construct) must act on the SAME instance the toolbar
    /// buttons in `ContentView` do.
    @StateObject private var pasteModel = PasteSettingsModel()

    /// Owns the Library's "Rename Files…" sheet and "Undo Rename". Owned here, same reasoning as
    /// `pasteModel`: the Photo menu's items below (Scene-level) must act on the SAME instance the
    /// toolbar menu in `ContentView` does — the menu only sets `renameModel.request`; `ContentView`
    /// (which can see the selection and the Export/Enhance state) performs it.
    @StateObject private var renameModel = RenameModel()

    /// The culling pass. Owned here, same reasoning as `renameModel`: the Photo menu's ⌘Z must undo a CULL action (not the Editor's edit
    /// history) while culling, and "Cull Photos" starts it.
    @StateObject private var cull = CullModel()

    /// Photo ▸ Import Lightroom Settings… (Editor-only; reads a Camera Raw `.xmp`, applies one undo step).
    @StateObject private var lightroomImport = LightroomImportModel()

    /// Whether the window is showing the Library grid instead of the Editor.
    /// Presentation-only, and `ContentView`'s own `@State` until the Photo
    /// menu below needed it: prev/next is EDITOR navigation, so it must
    /// disable while the grid is up (there, it would be an invisible load).
    /// Lifted here for exactly the reason `document` and `catalog` were — a
    /// Scene-level command can't read a view's private state.
    @State private var showLibrary = false

    /// The Preferences window's state (⌘,).
    @StateObject private var preferences = PreferencesModel()

    init() {
        // User looks must be registered BEFORE any render (Editor, thumbnails, export): an unresolved look renders
        // as no look, which would silently disagree with the Editor. Synchronous on purpose.
        LookStore.shared.loadAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                document: document, catalog: catalog, pasteModel: pasteModel, renameModel: renameModel, cull: cull,
                showLibrary: $showLibrary
            )
            // Drag a folder or photo onto the window, or open one from Finder / the Dock.
            .modifier(DropAndOpenModifier(document: document, catalog: catalog, renameModel: renameModel, cull: cull, showLibrary: $showLibrary))
            .modifier(LightroomImportModifier(model: lightroomImport, document: document))
            // Flat window buttons instead of the system's glass ones (see `WindowChrome.swift`). To go back to the system buttons,
            // delete this one line.
            .background(WindowChromeInstaller())
            // System controls (checked Toggle, native Slider) fill light grey, not blue: see `Theme.controlTint`.
            // The blue `Theme.accent` is applied explicitly, by prominent buttons only.
            .tint(Theme.controlTint)
            // ONE main window: the Library, Editor and every sheet share this app's single set of models, so a second window is a
            // blank duplicate whose alerts also fire on the first. Without this, every Finder / Dock / "Open With" open made SwiftUI
            // create another window (live-checked 2026-10-19: 2 -> 3). Open events now go to the existing window.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .commands {
            // No "New Window" for the same reason (a Dock click with no window still reopens one).
            CommandGroup(replacing: .newItem) {}
            AboutAndHelpCommands()
            // Replaces macOS's default (inert) Edit > Undo/Redo items —
            // the canonical, keyboard-shortcut-owning home for these
            // actions. Wired to the SAME `document.undo()`/`.redo()` the
            // rail's Undo/Redo entries call; `canUndo`/`canRedo` being
            // `@Published` on `document` means these reactively
            // enable/disable in sync with the rail.
            CommandGroup(replacing: .undoRedo) {
                // While culling, ⌘Z undoes the last CULL action (flag / rating / label) and never reaches the Editor's edit history.
                Button("Undo") { if cull.isActive { cull.undo() } else { document.undo() } }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(cull.isActive ? !cull.canUndo : !document.canUndo)
                Button("Redo") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(cull.isActive || !document.canRedo)
            }
            // Move between photos without a round-trip through the Library
            // grid. Same pattern as the Edit menu above: the Scene-level
            // command owns the shortcut (the toolbar deliberately doesn't
            // duplicate shortcuts — see `ContentView`'s Undo/Redo buttons),
            // and `.disabled` reads `@Published` state (`document.currentURL`
            // plus `catalog`'s own published fields, which `displayedPhotos`
            // is derived from) so both items enable/disable reactively.
            // Catalog safety, in the File menu: a backup is a consistent snapshot of the catalog (ratings, flags, labels, keywords, collections,
            // presets, people); a restore is staged and applied at the next launch. Both only REQUEST (`CatalogBackupDialogModifier` acts).
            CommandGroup(after: .newItem) {
                Divider()
                Button("Back Up Catalog…") { catalog.backupRequested = .backUp }
                    .disabled(cull.isActive || catalog.backupBusy)
                Button("Copy Photos into Library…") { catalog.importCopyRequested = true }
                    .disabled(cull.isActive || !showLibrary || catalog.isRenameInProgress || catalog.fileToolBusy || catalog.mergeBusy || renameModel.isWorking)
                Button("Restore Catalog from Backup…") { catalog.backupRequested = .restore }
                    .disabled(cull.isActive || catalog.backupBusy || catalog.isRenameInProgress || renameModel.isWorking)
            }
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
                    .disabled(neighbors.previous == nil || renameModel.isWorking)
                Button("Next Photo") { open(neighbors.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(neighbors.next == nil || renameModel.isWorking)
                Divider()
                // Culling: a full-window Pick / Reject review of the photos the Library is showing.
                Button("Cull Photos") {
                    guard !renameModel.isWorking else { return }
                    cull.begin(startingAtPath: showLibrary ? catalog.focusedPhotoPath : document.currentEditKey)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .help("Review photos one by one. Esc returns to the Library.")
                .disabled(cull.isActive || catalog.photos.isEmpty || renameModel.isWorking || document.isLoadInFlight)
                Divider()
                // Copy/Paste Edit Settings — Lightroom's own Photo-menu
                // placement and shortcuts. "Paste Settings" here shows the
                // SAME confirmation dialog the Library toolbar's own
                // button does (`ContentView`'s `.confirmationDialog`,
                // bound to `pasteModel.pendingTargets`) — this item only
                // calls `requestPaste`, never `performPaste` directly, so
                // there is exactly one path into the actual (mostly
                // irreversible) write, not two.
                Button("Copy Settings") {
                    pasteModel.copy(document.editState, fileName: document.currentFileName ?? "photo")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(cull.isActive || document.currentImage == nil)
                Button("Paste Settings") {
                    pasteModel.requestPaste(onto: catalog.selectedPhotos)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                // Same `isLoadInFlight` guard as the Library toolbar's own
                // Paste Settings button — see that call site's own doc
                // comment for the race this closes. This shortcut isn't
                // scoped to the Library pane, so it needs the SAME guard
                // independently, not just the toolbar button's copy of it.
                .disabled(
                    cull.isActive || pasteModel.copied == nil || catalog.selectedPhotos.isEmpty || document.isLoadInFlight || catalog.mergeBusy || catalog.fileToolBusy
                        || renameModel.isWorking || renameModel.isPresentingSheet || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                        || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                )
                // Editor-only: acts on the OPEN photo (reads its Lightroom / Camera Raw .xmp). No shortcut. Only REQUESTS; the modifier confirms.
                Button("Import Lightroom Settings…") { lightroomImport.request(for: document) }
                    .disabled(
                        cull.isActive || showLibrary || document.currentImage == nil || document.isLoadInFlight || lightroomImport.isBusy
                            || catalog.mergeBusy || catalog.fileToolBusy || renameModel.isWorking || renameModel.isPresentingSheet
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                    )
                // Virtual copies: another independent edit version of the same file (Lightroom's own ⌘'). Library: the selected visible
                // photos, else the focused one; Editor: the open photo/version. Edits made so far in the Editor are flushed first.
                Button("Create Virtual Copy") {
                    catalog.createVirtualCopies(
                        of: catalog.virtualCopyTargets(showLibrary: showLibrary, openEditKey: document.currentEditKey),
                        flushEdits: { document.flushPendingSidecarSave() },
                        openVersion: document.currentEditKey.map { ($0, document.editState) }
                    )
                }
                .keyboardShortcut("'", modifiers: .command)
                .disabled(
                    cull.isActive || catalog.virtualCopyTargets(showLibrary: showLibrary, openEditKey: document.currentEditKey).isEmpty
                        || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight || catalog.mergeBusy
                        || catalog.fileToolBusy || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                )
                Divider()
                // Batch rename: no default shortcut (matches Enhance). These only REQUEST — `ContentView`
                // performs the request with its own selection and busy-state providers.
                // Library-only: it edits the Library SELECTION, which in the Editor may not include the open photo.
                // Only REQUESTS — `KeywordSheetModifier` drops it while another sheet/dialog is up.
                Button("Edit Keywords…") { catalog.keywordSheetRequested = true }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotos.isEmpty || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet
                    )
                // Library-only like Edit Keywords; only REQUESTS (`InfoSheetModifier` drops it while another sheet/dialog is up).
                Button("Edit Info…") { catalog.infoSheetRequested = true }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotos.isEmpty || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.mergeBusy || catalog.fileToolBusy
                            || renameModel.isWorking || renameModel.isPresentingSheet
                    )
                // Photo stacks (Library only; the grid ignores ⌘ chords, so these are menu items). Manual stack operations act on the whole
                // SELECTION, including photos the filters hide (the result message says so); they move no files, so only the sheets that
                // edit the selection or its stacks block them.
                Button("Stack Selected") { Task { await catalog.stackSelected() } }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotos.count < 2 || catalog.autoStackSheetPresented || catalog.autoStack.isWorking
                            || catalog.trashBusy || renameModel.isWorking || renameModel.isPresentingSheet
                    )
                Button("Unstack") { Task { await catalog.unstackSelected() } }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotos.isEmpty || catalog.autoStackSheetPresented || catalog.autoStack.isWorking
                            || catalog.trashBusy || renameModel.isWorking || renameModel.isPresentingSheet
                    )
                // Library-only; only REQUESTS (`AutoStackSheetModifier` drops it while another sheet is up). No default shortcut.
                Button("Auto Stack…") { catalog.autoStackSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.autoStackSheetPresented || catalog.autoStack.isWorking || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.mergeBusy || catalog.fileToolBusy
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`DuplicatesSheetModifier` drops it while another sheet is up).
                Button("Find Duplicates…") { catalog.duplicatesSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`PeopleSheetModifier` drops it while another sheet is up). No default shortcut.
                Button("People…") { catalog.peopleSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`MergeDialogModifier` drops it while another sheet is up). Needs 2+ visible selected photos.
                Button("Merge Photos to HDR…") { catalog.mergeRequested = .hdr }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy
                            || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                Button("Merge Photos to Panorama…") { catalog.mergeRequested = .panorama }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy
                            || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUEST (`XMPDialogModifier` drops them while another sheet is up). Act on the selected visible photos.
                Button("Write Metadata to XMP…") { catalog.xmpRequested = .write }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.isEmpty || catalog.fileToolBusy || catalog.mergeBusy
                            || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                Button("Read Metadata from XMP…") { catalog.xmpRequested = .read }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.isEmpty || catalog.fileToolBusy || catalog.mergeBusy
                            || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                Button("Rename Files…") { renameModel.request = .rename }
                    .disabled(
                        cull.isActive || catalog.selectedPhotos.isEmpty || renameModel.isWorking || document.isLoadInFlight || catalog.mergeBusy || catalog.fileToolBusy
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                    )
                // Library-only, destructive: only REQUEST (`TrashDialogModifier` confirms, naming what the Library is showing).
                Button("Move Rejected to Trash…") { catalog.trashRequested = .rejected }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.fileToolBusy || catalog.mergeBusy || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                            || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || renameModel.isWorking
                            || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                Button("Undo Rename") { renameModel.request = .undo }
                    .disabled(
                        cull.isActive || !renameModel.canUndo || renameModel.isWorking || renameModel.isPresentingSheet || catalog.mergeBusy || catalog.fileToolBusy
                            || document.isLoadInFlight || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                    )
            }
        }
        Window("Keyboard Shortcuts", id: AboutAndHelpCommands.shortcutsWindowID) {
            KeyboardShortcutsView()
                .tint(Theme.controlTint)
        }
        .windowResizability(.contentSize)
        Settings {
            PreferencesView(model: preferences, showPhotosInSubfolders: $catalog.showPhotosInSubfolders, isBackupBusy: catalog.backupBusy, backUpNow: { await catalog.backUpNow() },
                            backupsFolder: { catalog.backupsFolderURL })
                .tint(Theme.controlTint)
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
        guard !showLibrary, !cull.isActive, let currentKey = document.currentEditKey else { return (nil, nil) }
        // By EDIT KEY: with a virtual copy open, its master (same path) must not be mistaken for the open photo.
        return LibraryNavigation.neighbors(ofEditKey: currentKey, in: catalog.displayedPhotos)
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
        // Not while a batch rename/undo is moving files (see `RenameModel`).
        guard let photo, !renameModel.isWorking else { return }
        Task {
            await catalog.ensureAccessActive(forPhotoAt: photo.path)
            await document.load(photo: photo)
        }
    }
}
