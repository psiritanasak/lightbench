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

    /// Owns Copy Settings / Paste Settings (Copy/Paste Edit Settings
    /// across a Library multi-selection). Owned here, same reasoning as
    /// `document`/`catalog` — the Photo menu's own ⇧⌘C/⇧⌘V below (a
    /// Scene-level construct) must act on the SAME instance the toolbar
    /// buttons in `ContentView` do.
    @StateObject private var pasteModel = PasteSettingsModel()

    /// Owns the Library's Rename Files sheet and "Undo Rename". Owned here, same reasoning as
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

    /// The View menu's link to `ContentView` (requests in, coarse Editor status out).
    @StateObject private var bridge = EditorViewBridge()

    /// The grid layout (square / justified), the same key the grid and its bottom bar use.
    @AppStorage(LibraryGridLayout.storageKey) private var gridLayout: String = LibraryGridLayout.square

    /// The Preferences window's state (⌘,).
    @StateObject private var preferences = PreferencesModel()

    /// The passing-result toast shared by every mode (Library, Editor, Cull).
    @StateObject private var toasts = ToastCenter()

    init() {
        // User looks must be registered BEFORE any render (Editor, thumbnails, export): an unresolved look renders
        // as no look, which would silently disagree with the Editor. Synchronous on purpose.
        LookStore.shared.loadAll()
    }

    var body: some Scene {
        // A single-instance `Window`, not a window group: a group can always make another window, and did whenever an open arrived
        // while an alert was showing (live-checked 2026-11-03: a second `open -a <folder>` with the import alert up gave a blank
        // duplicate window). A `Window` scene has exactly one instance, so no open event can add one.
        Window("Lightbench", id: "main") {
            ContentView(
                document: document, catalog: catalog, pasteModel: pasteModel, renameModel: renameModel, cull: cull, bridge: bridge,
                showLibrary: $showLibrary
            )
            .environmentObject(toasts)
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
            // Bound ONCE per body pass on purpose. `catalog.displayedPhotos`
            // is a full filter+sort of the library, and this Scene's body
            // re-evaluates on every `document.editState` publish — i.e. on
            // every slider tick while editing. Asking each item separately
            // would pay it twice per tick. MEASURED (see PROGRESS.md):
            // 0.37ms per apply at 1,000 photos, 3.61ms at 10,000.
            let neighbors = photoNeighbors
            // The photo actions take their title, hidden state and enabled state from `PhotoActionMenu` and run through the
            // performer, like the grid's cell menu and the selection bar. The scene cannot see `ExportModel` (so `exportActive` is
            // false: a request during an export is still dropped by each modifier's `blocked`) nor the grid's removal alert.
            let actionContext = PhotoActionContext.make(
                catalog: catalog, document: document, pasteModel: pasteModel, renameModel: renameModel,
                cullActive: cull.isActive, showLibrary: showLibrary, exportActive: false)
            let actionTarget = PhotoActionTarget.menuBar(
                catalog: catalog, showLibrary: showLibrary, cullActive: cull.isActive, openEditKey: document.currentEditKey, hasOpenImage: document.currentImage != nil)
            let actions = PhotoActionPerformer(
                catalog: catalog, document: document, pasteModel: pasteModel, renameModel: renameModel, showLibrary: showLibrary,
                open: nil, requestRemoval: nil, beginExport: nil)
            let viewContext = viewCommandContext()
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
                    .disabled(catalog.editorPopoverOpen || (cull.isActive ? !cull.canUndo : !document.canUndo))
                Button("Redo") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(catalog.editorPopoverOpen || cull.isActive || !document.canRedo)
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
                Menu("Import") {
                    ImportMenuItems(
                        catalog: catalog, document: document, renameModel: renameModel, showLibrary: $showLibrary,
                        openDisabled: cull.isActive || renameModel.isWorking || document.isLoadInFlight || catalog.toolSheetIsBusy || catalog.isRenameInProgress || renameModel.isPresentingSheet || catalog.editorPopoverOpen,
                        importDisabled: cull.isActive || catalog.isRenameInProgress || catalog.importCopyBusy || renameModel.isWorking || document.isLoadInFlight || catalog.toolSheetIsBusy || renameModel.isPresentingSheet || catalog.editorPopoverOpen,
                        copyPhotosDisabled: cull.isActive || !showLibrary || catalog.isRenameInProgress || catalog.fileToolBusy || catalog.mergeBusy || renameModel.isWorking)
                }
                // Library only; the request goes through the bridge and `ContentView` performs it (it owns the export model).
                Button(PhotoActionMenu.title(.export)) { bridge.request = .export }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!ViewCommandRules.isEnabled(.export, context: viewContext))
                Divider()
                Button("Back Up Catalog…") { catalog.backupRequested = .backUp }
                    .disabled(cull.isActive || catalog.backupBusy)
                Button("Restore Catalog from Backup…") { catalog.backupRequested = .restore }
                    .disabled(cull.isActive || catalog.backupBusy || catalog.isRenameInProgress || renameModel.isWorking)
            }
            // View menu items go into the system View menu (`before: .toolbar`), never a second menu of the same name. They only REQUEST
            // through `EditorViewBridge`: `ContentView` performs the request (it owns the compare / tab / filmstrip state) and re-checks the
            // same rule. Bare letters are NOT menu equivalents (a bare-letter key equivalent could swallow typing); only ⌘ chords are.
            CommandGroup(before: .toolbar) {
                Button("Library") { bridge.request = .showLibrary }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!ViewCommandRules.isEnabled(.showLibrary, context: viewContext))
                Button("Editor") { bridge.request = .showEditor }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!ViewCommandRules.isEnabled(.showEditor, context: viewContext))
                // Culling: a full-window Pick / Reject review of the photos the Library is showing.
                Button("Cull Photos") {
                    guard !renameModel.isWorking else { return }
                    cull.begin(startingAtPath: showLibrary ? catalog.focusedPhotoPath : document.currentEditKey)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .help("Review photos one by one. Esc returns to the Library.")
                .disabled(catalog.editorPopoverOpen || cull.isActive || catalog.photos.isEmpty || renameModel.isWorking || document.isLoadInFlight)
                Divider()
                Button("Previous Photo") { open(neighbors.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(catalog.editorPopoverOpen || neighbors.previous == nil || renameModel.isWorking)
                Button("Next Photo") { open(neighbors.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(catalog.editorPopoverOpen || neighbors.next == nil || renameModel.isWorking)
                Divider()
                viewToggle("Show Before", .toggleBefore, viewContext)
                    .disabled(!ViewCommandRules.isEnabled(.toggleBefore, context: viewContext))
                Menu("Compare") {
                    viewToggle("Off", .setCompare(.off), viewContext)
                        .disabled(!ViewCommandRules.isEnabled(.setCompare(.off), context: viewContext))
                    viewToggle("Side by Side", .setCompare(.sideBySide), viewContext)
                        .disabled(!ViewCommandRules.isEnabled(.setCompare(.sideBySide), context: viewContext))
                    viewToggle("Split", .setCompare(.split), viewContext)
                        .disabled(!ViewCommandRules.isEnabled(.setCompare(.split), context: viewContext))
                }
                viewToggle("Show Filmstrip", .toggleFilmstrip, viewContext)
                    .disabled(!ViewCommandRules.isEnabled(.toggleFilmstrip, context: viewContext))
                // The six panels, in rail order (`EditorTab.railTabs`). Written out, not a loop: the shortcut list is checked against
                // the literal `.keyboardShortcut(` lines.
                Menu("Editor Panel") {
                    viewToggle(EditorTab.adjust.railTitle, .selectTab(.adjust), viewContext)
                        .keyboardShortcut("1", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.adjust), context: viewContext))
                    viewToggle(EditorTab.looks.railTitle, .selectTab(.looks), viewContext)
                        .keyboardShortcut("2", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.looks), context: viewContext))
                    viewToggle(EditorTab.retouch.railTitle, .selectTab(.retouch), viewContext)
                        .keyboardShortcut("3", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.retouch), context: viewContext))
                    viewToggle(EditorTab.redEye.railTitle, .selectTab(.redEye), viewContext)
                        .keyboardShortcut("4", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.redEye), context: viewContext))
                    viewToggle(EditorTab.masks.railTitle, .selectTab(.masks), viewContext)
                        .keyboardShortcut("5", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.masks), context: viewContext))
                    viewToggle(EditorTab.crop.railTitle, .selectTab(.crop), viewContext)
                        .keyboardShortcut("6", modifiers: [.command, .option])
                        .disabled(!ViewCommandRules.isEnabled(.selectTab(.crop), context: viewContext))
                }
                Divider()
                // Library only (the layout and subfolder choices are the grid's own: the same `@AppStorage` key and the same catalog flag).
                Toggle("Square Grid", isOn: Binding(
                    get: { gridLayout != LibraryGridLayout.justified },
                    set: { _ in gridLayout = LibraryGridLayout.square }))
                    .disabled(cull.isActive || !showLibrary)
                Toggle("Justified Rows", isOn: Binding(
                    get: { gridLayout == LibraryGridLayout.justified },
                    set: { _ in gridLayout = LibraryGridLayout.justified }))
                    .disabled(cull.isActive || !showLibrary)
                Toggle("Show Photos in Subfolders", isOn: $catalog.showPhotosInSubfolders)
                    .disabled(cull.isActive || !showLibrary)
                Divider()
            }
            CommandMenu("Photo") {
                // Rating / Flag / Label write the Library's VISIBLE SELECTION (the grid keys 1-5, P X U, 6-9 write the focused photo). Built from the
                // same model entries as the cell menu and the selection bar, run through the same performer.
                ForEach([PhotoActionID.ratingMenu, .flagMenu, .labelMenu], id: \.self) { id in
                    if let entry = PhotoActionMenu.entry(for: id, target: actionTarget, context: actionContext) {
                        Menu(entry.title) {
                            ForEach(entry.children, id: \.id) { child in
                                PhotoActionLeaf(entry: child) { actions.perform($0, clicked: nil) }
                            }
                        }
                        .disabled(!entry.isEnabled)
                        .help("Writes the photos the Library is showing that are selected, not only the focused photo.")
                    }
                }
                Divider()
                // Copy/Paste Edit Settings — Lightroom's own Photo-menu
                // placement and shortcuts. Paste Settings here shows the
                // SAME confirmation dialog the Library toolbar's own
                // button does (`ContentView`'s `.confirmationDialog`,
                // bound to `pasteModel.pendingTargets`) — this item only
                // calls `requestPaste`, never `performPaste` directly, so
                // there is exactly one path into the actual (mostly
                // irreversible) write, not two.
                Button(PhotoActionMenu.title(.copySettings)) { actions.perform(.run(.copySettings), clicked: nil) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!PhotoActionMenu.isEnabled(.copySettings, target: actionTarget, context: actionContext))
                Button(PhotoActionMenu.title(.pasteSettings)) { actions.perform(.run(.pasteSettings), clicked: nil) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!PhotoActionMenu.isEnabled(.pasteSettings, target: actionTarget, context: actionContext))
                // Editor-only: acts on the OPEN photo (reads its Lightroom / Camera Raw .xmp). No shortcut. Only REQUESTS; the modifier confirms.
                Button("Import Lightroom Settings…") { lightroomImport.request(for: document) }
                    .disabled(
                        catalog.editorPopoverOpen || cull.isActive || showLibrary || document.currentImage == nil || document.isLoadInFlight || lightroomImport.isBusy
                            || catalog.mergeBusy || catalog.fileToolBusy || renameModel.isWorking || renameModel.isPresentingSheet
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                    )
                // Editor-only 90° turns of the open photo (one undo step each; the crop follows the picture).
                let canRotate = RotateAvailability.isEnabled(
                    hasImage: document.currentImage != nil, loadInFlight: document.isLoadInFlight,
                    renameWorking: renameModel.isWorking, cullActive: cull.isActive, showLibrary: showLibrary)
                Button("Rotate Left") { document.rotate(.left) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!canRotate || catalog.editorPopoverOpen)
                Button("Rotate Right") { document.rotate(.right) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!canRotate || catalog.editorPopoverOpen)
                // Editor-only: ONE undo step (the same `revertToOriginal` as the rail's Revert). `ContentView` performs the request.
                Button("Revert to Original") { bridge.request = .revertToOriginal }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!ViewCommandRules.isEnabled(.revertToOriginal, context: viewContext))
                // Virtual copies: another independent edit version of the same file (Lightroom's own ⌘'). Library: the selected visible
                // photos, else the focused one; Editor: the open photo/version. Edits made so far in the Editor are flushed first.
                Button(PhotoActionMenu.title(.createVirtualCopy)) { actions.perform(.run(.createVirtualCopy), clicked: nil) }
                    .keyboardShortcut("'", modifiers: .command)
                    .disabled(!PhotoActionMenu.isEnabled(.createVirtualCopy, target: actionTarget, context: actionContext))
                Divider()
                // Batch rename: no default shortcut (matches Enhance). These only REQUEST — `ContentView`
                // performs the request with its own selection and busy-state providers.
                // Library-only: it edits the Library SELECTION, which in the Editor may not include the open photo.
                // Only REQUESTS — `KeywordSheetModifier` drops it while another sheet/dialog is up.
                // Context-aware. Library: the sheet over the SELECTION (only REQUESTS; `KeywordSheetModifier` drops it while another sheet/dialog
                // is up). Editor: toggles the Keywords popover on the OPEN photo (`ContentView` performs it; see `EditorKeywordsMenuRules`).
                let keywordsLibraryBlocked = !PhotoActionMenu.isEnabled(.editKeywords, target: actionTarget, context: actionContext)
                Button(PhotoActionMenu.title(.editKeywords)) { actions.perform(.run(.editKeywords), clicked: nil) }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(EditorKeywordsMenuRules.isDisabled(
                    showLibrary: showLibrary, cullActive: cull.isActive, libraryBlocked: keywordsLibraryBlocked,
                    hasOpenPhoto: document.currentEditKey != nil, loadInFlight: document.isLoadInFlight,
                    hasCatalogRow: catalog.editorPhotoInCatalog, popoverOpen: catalog.editorKeywordsOpen, infoOpen: catalog.editorInfoOpen))
                // Context-aware. Library: the sheet over the SELECTION (only REQUESTS; `InfoSheetModifier` drops it while another sheet/dialog
                // is up). Editor: toggles the Info popover on the OPEN photo (`ContentView` performs it; see `EditorInfoMenuRules`).
                let infoLibraryBlocked = !PhotoActionMenu.isEnabled(.editInfo, target: actionTarget, context: actionContext)
                Button(PhotoActionMenu.title(.editInfo)) { actions.perform(.run(.editInfo), clicked: nil) }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(EditorInfoMenuRules.isDisabled(
                    showLibrary: showLibrary, cullActive: cull.isActive, libraryBlocked: infoLibraryBlocked,
                    hasOpenPhoto: document.currentEditKey != nil, loadInFlight: document.isLoadInFlight,
                    hasCatalogRow: catalog.editorPhotoInCatalog, popoverOpen: catalog.editorInfoOpen,
                    keywordsOpen: catalog.editorKeywordsOpen))
                // Photo stacks (Library only; the grid ignores ⌘ chords, so these are menu items). Manual stack operations act on the whole
                // SELECTION, including photos the filters hide (the result message says so); they move no files, so only the sheets that
                // edit the selection or its stacks block them.
                Menu(PhotoActionMenu.title(.stackMenu)) {
                    Button(PhotoActionMenu.title(.stackSelected)) { actions.perform(.run(.stackSelected), clicked: nil) }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(!PhotoActionMenu.isEnabled(.stackSelected, target: actionTarget, context: actionContext))
                    Button(PhotoActionMenu.title(.unstack)) { actions.perform(.run(.unstack), clicked: nil) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(!PhotoActionMenu.isEnabled(.unstack, target: actionTarget, context: actionContext))
                }
            }
            // Library-wide tools (moved here from the Photo menu, code unchanged). Every item is off in the Editor.
            CommandMenu("Library") {
                // Library-only; only REQUESTS (`DuplicatesSheetModifier` drops it while another sheet is up).
                Button("Find Duplicates…") { catalog.duplicatesSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`AutoStackSheetModifier` drops it while another sheet is up). No default shortcut.
                Button("Auto Stack…") { catalog.autoStackSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.autoStackSheetPresented || catalog.autoStack.isWorking || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.mergeBusy || catalog.fileToolBusy
                            || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`PeopleSheetModifier` drops it while another sheet is up). No default shortcut.
                Button("People…") { catalog.peopleSheetRequested = true }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || catalog.duplicatesSheetPresented
                            || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                Divider()
                Menu(PhotoActionMenu.title(.mergeMenu)) {
                    // Library-only; only REQUESTS (`MergeDialogModifier` drops it while another sheet is up). Needs 2+ visible selected photos.
                    Button(PhotoActionMenu.title(.mergeHDR)) { actions.perform(.run(.mergeHDR), clicked: nil) }
                        .disabled(!PhotoActionMenu.isEnabled(.mergeHDR, target: actionTarget, context: actionContext))
                    Button(PhotoActionMenu.title(.mergePanorama)) { actions.perform(.run(.mergePanorama), clicked: nil) }
                        .disabled(!PhotoActionMenu.isEnabled(.mergePanorama, target: actionTarget, context: actionContext))
                }
                Menu(PhotoActionMenu.title(.metadataMenu)) {
                    // Library-only; only REQUEST (`XMPDialogModifier` drops them while another sheet is up). Act on the selected visible photos.
                    Button(PhotoActionMenu.title(.writeXMP)) { actions.perform(.run(.writeXMP), clicked: nil) }
                        .disabled(!PhotoActionMenu.isEnabled(.writeXMP, target: actionTarget, context: actionContext))
                    Button(PhotoActionMenu.title(.readXMP)) { actions.perform(.run(.readXMP), clicked: nil) }
                        .disabled(!PhotoActionMenu.isEnabled(.readXMP, target: actionTarget, context: actionContext))
                }
                Divider()
                Button(PhotoActionMenu.title(.renameFiles)) { actions.perform(.run(.renameFiles), clicked: nil) }
                    .disabled(!PhotoActionMenu.isEnabled(.renameFiles, target: actionTarget, context: actionContext))
                Button("Undo Rename") { renameModel.request = .undo }
                    .disabled(
                        cull.isActive || !renameModel.canUndo || renameModel.isWorking || renameModel.isPresentingSheet || catalog.mergeBusy || catalog.fileToolBusy
                            || document.isLoadInFlight || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || !showLibrary
                    )
                Divider()
                // Library-only, destructive: only REQUEST (`TrashDialogModifier` confirms, naming what the Library is showing).
                Button("Move Rejected to Trash…") { catalog.trashRequested = .rejected }
                    .disabled(
                        cull.isActive || !showLibrary || catalog.fileToolBusy || catalog.mergeBusy || catalog.peopleSheetPresented || catalog.autoStackSheetPresented
                            || catalog.duplicatesSheetPresented || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil || renameModel.isWorking
                            || renameModel.isPresentingSheet || document.isLoadInFlight
                    )
                // Library-only; only REQUESTS (`RecentlyDeletedSheetModifier` drops it while another sheet is up). No default shortcut.
                Button("Recently Deleted…") { catalog.recentlyDeletedRequested = true }
                    .disabled(cull.isActive || !showLibrary || catalog.toolSheetIsBusy || renameModel.isWorking || renameModel.isPresentingSheet || document.isLoadInFlight)
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

    /// The state `ViewCommandRules` reads for the menu bar: the Editor's coarse status from the bridge plus what the scene can see. The sheet
    /// flags are only a first line (the scene cannot see every alert); `ContentView` re-checks the rule with the full picture when it runs.
    private func viewCommandContext() -> ViewCommandContext {
        var c = ViewCommandContext()
        let status = bridge.status
        c.mode = cull.isActive ? .cull : (showLibrary ? .library : .editor)
        c.hasOpenImage = status.hasOpenImage
        c.loadInFlight = document.isLoadInFlight
        c.renameWorking = renameModel.isWorking
        c.modalUp = renameModel.isPresentingSheet || catalog.keywordSheetPhotoIDs != nil || catalog.infoSheetPhotoIDs != nil
            || catalog.duplicatesSheetPresented || catalog.peopleSheetPresented || catalog.autoStackSheetPresented || status.blocked
        c.editorPopoverOpen = catalog.editorPopoverOpen
        c.canCompare = status.canCompare
        c.canRevert = status.canRevert
        c.canExport = status.canExport
        c.compareMode = status.compareMode
        c.selectedTab = status.selectedTab
        c.filmstripVisible = status.filmstripVisible
        return c
    }

    /// A checkable View-menu item: a `Toggle` (the checkmark comes from `ViewCommandRules.isChecked`) whose change only REQUESTS the command.
    private func viewToggle(_ title: String, _ command: ViewCommand, _ context: ViewCommandContext) -> some View {
        Toggle(title, isOn: Binding(
            get: { ViewCommandRules.isChecked(command, context: context) },
            set: { _ in bridge.request = command }))
    }

    /// What ⌘← and ⌘→ would open, both resolved from ONE pass over
    /// the filmstrip's cells (`filmstripItems`: `displayedPhotos` folded by stacks,
    /// the open photo's own stack expanded) — see the call site for why that matters. Either side
    /// is `nil` when that direction is unavailable; see
    /// `LibraryNavigation.neighbor(of:in:offset:)` for the cases it covers.
    /// Walking `displayedPhotos` (not `photos`) is what makes navigation follow
    /// the grid's current sort/filter/search.
    private var photoNeighbors: (previous: Photo?, next: Photo?) {
        // Both cheap disqualifiers first, so the common "no photo open" and
        // "browsing the grid" cases never touch the filter+sort at all.
        guard !showLibrary, !cull.isActive, let currentKey = document.currentEditKey else { return (nil, nil) }
        // By EDIT KEY: with a virtual copy open, its master (same path) must not be mistaken for the open photo.
        // No stacks (the common case): the cells ARE the flat list, so skip building them (a Debug-build measurement at 10,000 photos: the
        // flat walk 3.0 ms, the cell walk 10.4 ms without stacks and 17.6 ms with 1,000 stacks of three; this runs on every body pass).
        let walked = catalog.stacks.isEmpty ? catalog.displayedPhotos : catalog.filmstripItems(openEditKey: currentKey).map(\.photo)
        return LibraryNavigation.neighbors(ofEditKey: currentKey, in: walked)
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
