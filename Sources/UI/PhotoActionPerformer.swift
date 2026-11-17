import Foundation

// The UI half of the photo action menu (`PhotoActionMenu` is the pure half): it reads the live models into a `PhotoActionContext` and
// a `PhotoActionTarget`, and `PhotoActionPerformer.perform` runs a chosen `PhotoActionCommand`. Each case calls exactly what the item it
// replaced called (the old cell menu, the toolbar's selection menu and the Photo menu).

// MARK: - Context

extension PhotoActionContext {
    /// Reads the busy state of every model the gates name. The sheet flags stay on one line (a source pin reads them).
    @MainActor
    static func make(
        catalog: CatalogModel, document: ImageDocumentModel, pasteModel: PasteSettingsModel, renameModel: RenameModel,
        cullActive: Bool, showLibrary: Bool, exportActive: Bool
    ) -> PhotoActionContext {
        var context = PhotoActionContext()
        context.mode = cullActive ? .cull : (showLibrary ? .library : .editor)
        context.editorPopoverOpen = catalog.editorPopoverOpen
        context.loadInFlight = document.isLoadInFlight
        context.renameWorking = renameModel.isWorking
        context.renameSheet = renameModel.isPresentingSheet
        context.renameInProgress = catalog.isRenameInProgress
        context.exportActive = exportActive
        context.pastePending = pasteModel.pendingTargets != nil
        context.hasCopiedSettings = pasteModel.copied != nil
        context.hasOpenImage = document.currentImage != nil
        context.mergeBusy = catalog.mergeBusy
        context.fileToolBusy = catalog.fileToolBusy
        context.trashBusy = catalog.trashBusy
        context.keywordSheetOpen = catalog.keywordSheetPhotoIDs != nil; context.infoSheetOpen = catalog.infoSheetPhotoIDs != nil; context.duplicatesSheetOpen = catalog.duplicatesSheetPresented; context.peopleSheetOpen = catalog.peopleSheetPresented; context.autoStackSheetOpen = catalog.autoStackSheetPresented; context.autoStackWorking = catalog.autoStack.isWorking
        context.hasCollections = !catalog.collections.isEmpty
        return context
    }
}

// MARK: - Target

extension PhotoActionTarget {
    /// The selection that is really on screen: the ids of the grid's cells (hidden stack members included) that are selected. A stale id
    /// (a photo that is no longer loaded) is dropped, so a partly selected collapsed stack cannot look fully selected. It also drops
    /// selected photos the filters hide (they are not in the cells), while `PhotoActionTarget.count` still counts them: Add to
    /// Collection, Edit Keywords and Paste Settings act on `catalog.selectedPhotos` and so reach those hidden photos too, as the old
    /// toolbar menu did; rating, flag, label, Merge, XMP and Trash act on the shown ones only.
    @MainActor
    static func ghostFreeSelection(catalog: CatalogModel, cells: [StackGridItem]) -> Set<Int64> {
        guard !catalog.selectedPhotoIDs.isEmpty else { return [] }
        return GridSelection.allIDs(in: cells).intersection(catalog.selectedPhotoIDs)
    }

    /// The target of an action that acts on the selection. Built ONCE per grid body from the cells (no second filter + sort of the
    /// library); `.empty` when nothing is selected. `visibleCount` is the selected photos the grid shows; `count` also holds selected
    /// photos hidden by the filters (like `catalog.selectedPhotos`). `selectedIDs` is `ghostFreeSelection(catalog:cells:)`.
    @MainActor
    static func selection(catalog: CatalogModel, cells: [StackGridItem], selectedIDs: Set<Int64>, openEditKey: String?) -> PhotoActionTarget {
        guard !catalog.selectedPhotoIDs.isEmpty else { return .empty }
        var shown: [Photo] = []
        for cell in cells {
            let photos = cell.role == .collapsedStack ? cell.visibleMembers : [cell.photo]
            for photo in photos where photo.id.map(selectedIDs.contains) ?? false { shown.append(photo) }
        }
        var count = 0
        for photo in catalog.photos where catalog.isSelected(photo) { count += 1 }
        var target = PhotoActionTarget()
        target.count = count
        target.visibleCount = shown.count
        target.virtualCopyCount = shown.count
        target.isOpenPhoto = openEditKey.map { key in shown.contains { $0.editKey == key } } ?? false
        target.ratings = Set(shown.map(\.rating))
        target.flags = Set(shown.map(\.flagStatus))
        target.labels = Set(shown.map(\.colorLabel))
        return target
    }
}

extension PhotoActionTarget {
    /// The target of the Photo menu's items, built in the App scene's body (re-run on every edit publish and, while culling, on every
    /// cull publish, so it stays cheap). While culling every model item is off, so nothing expensive is computed (only `isOpenPhoto`).
    /// Otherwise the selection is counted only when something is selected, and the visible selection (a filter + sort of the library)
    /// is computed at most once here, only in the Library with a non-empty selection. `virtualCopyTargets` is not called when that
    /// visible selection already answers it (it returns exactly that in the Library); when it is empty (no selection, or one the filters
    /// hide entirely) `virtualCopyTargets` runs and recomputes it to find the focused photo, as the old item did. `isOpenPhoto` is
    /// `hasOpenImage`: Copy Settings (⇧⌘C) copies the open photo whatever the Library selection is.
    @MainActor
    static func menuBar(catalog: CatalogModel, showLibrary: Bool, cullActive: Bool = false, openEditKey: String?, hasOpenImage: Bool) -> PhotoActionTarget {
        var target = PhotoActionTarget()
        target.isOpenPhoto = hasOpenImage
        if cullActive { return target }
        var shownCount = 0
        if !catalog.selectedPhotoIDs.isEmpty {
            var count = 0
            for photo in catalog.photos where catalog.isSelected(photo) { count += 1 }
            target.count = count
            if showLibrary {
                shownCount = catalog.selectedPhotosInDisplayedGrid.count
                target.visibleCount = shownCount
            }
        }
        if showLibrary && shownCount > 0 {
            target.virtualCopyCount = shownCount
        } else {
            target.virtualCopyCount = catalog.virtualCopyTargets(showLibrary: showLibrary, openEditKey: openEditKey).count
        }
        return target
    }
}

/// Everything a grid cell needs to build its own menu target from values it already has (computed once per grid body).
struct PhotoActionGridInput {
    var context: PhotoActionContext
    /// The ghost-free selection (`PhotoActionTarget.ghostFreeSelection`).
    var selection: Set<Int64>
    var selectionTarget: PhotoActionTarget
    var openEditKey: String?
}

// MARK: - Performer

/// Runs a chosen photo action. Holds instance closures only (no stored static closures); the grid fills `open` and `requestRemoval`,
/// `ContentView` fills `beginExport`.
@MainActor
struct PhotoActionPerformer {
    let catalog: CatalogModel
    let document: ImageDocumentModel
    let pasteModel: PasteSettingsModel
    let renameModel: RenameModel
    let showLibrary: Bool
    var open: ((Photo) -> Void)?
    var requestRemoval: ((Photo) -> Void)?
    var beginExport: (() -> Void)?

    /// The edit key of the photo open in the Editor, if any.
    var openEditKey: String? { document.currentEditKey }

    /// `clicked` is the one grid cell's photo when the target is exactly that cell (`target.cell != nil`), else nil.
    /// `batchIDs`: the only photo ids rating / flag / label write (`PhotoActionMenu.cellPlan`); nil writes the visible selection.
    func perform(_ command: PhotoActionCommand, clicked: Photo?, batchIDs: [Int64]? = nil) {
        switch command {
        case .rate(let stars): writeBatch(.rating(stars), only: batchIDs)
        case .flag(let status): writeBatch(.flag(status), only: batchIDs)
        case .label(let label): writeBatch(.label(label), only: batchIDs)
        case .toggleCollection(let collectionID):
            guard let clicked, let collection = collection(collectionID) else { return fail("add to the collection") }
            catalog.toggleMembership(of: clicked, in: collection)
        case .addToCollection(let collectionID):
            guard let collection = collection(collectionID) else { return fail("add to the collection") }
            catalog.addSelectedPhotos(to: collection)
        case .run(let action):
            run(action, clicked: clicked)
        }
    }

    private func run(_ action: PhotoActionID, clicked: Photo?) {
        switch action {
        case .openInEditor:
            guard let clicked else { return fail("open it") }
            open?(clicked)
        case .editKeywords:
            if showLibrary { catalog.keywordSheetRequested = true } else { catalog.editorKeywordsToggleRequested = true }
        case .editInfo:
            if showLibrary { catalog.infoSheetRequested = true } else { catalog.editorInfoToggleRequested = true }
        case .copySettings:
            pasteModel.copy(document.editState, fileName: document.currentFileName ?? "photo")
        case .pasteSettings:
            pasteModel.requestPaste(onto: catalog.selectedPhotos)
        case .stackSelected:
            Task { await catalog.stackSelected() }
        case .unstack:
            Task { await catalog.unstackSelected() }
        case .makeCover:
            guard let clicked else { return fail("make it the cover") }
            Task { await catalog.makeCover(clicked) }
        case .removeFromStack:
            guard let clicked else { return fail("remove it from the stack") }
            Task { await catalog.removeFromStack(clicked) }
        case .createVirtualCopy:
            // The same hooks as the Photo menu: the open version's in-memory edits and a flush of its pending save.
            catalog.createVirtualCopies(
                of: catalog.virtualCopyTargets(showLibrary: showLibrary, openEditKey: document.currentEditKey),
                flushEdits: { document.flushPendingSidecarSave() },
                openVersion: document.currentEditKey.map { ($0, document.editState) })
        case .mergeHDR:
            catalog.mergeRequested = .hdr
        case .mergePanorama:
            catalog.mergeRequested = .panorama
        case .writeXMP:
            catalog.xmpRequested = .write
        case .readXMP:
            catalog.xmpRequested = .read
        case .renameFiles:
            // Only REQUESTS, like the menu bar: `ContentView` performs it with its providers after the busy-tool check.
            renameModel.request = .rename
        case .locate:
            if let clicked {
                Task { await catalog.relocatePhoto(clicked) }
            } else {
                Task { await catalog.relocateSelectedPhotos() }
            }
        case .removeFromLibrary:
            guard let clicked else { return fail("remove it") }
            requestRemoval?(clicked)
        case .moveToTrash:
            catalog.trashRequested = .selected
        case .export:
            beginExport?()
        case .clearSelection:
            catalog.clearSelection()
        case .ratingMenu, .flagMenu, .labelMenu, .collectionMenu, .stackMenu, .mergeMenu, .metadataMenu:
            break // submenus only open; they carry no command
        }
    }

    // MARK: Helpers

    private func collection(_ id: Int64) -> PhotoCollection? { catalog.collections.first { $0.id == id } }

    private func fail(_ what: String) {
        catalog.post(.error("Couldn't do that", "The photo this applies to is not available, so nothing was changed (\(what))."))
    }

    private enum Batch {
        case rating(Int)
        case flag(FlagStatus)
        case label(ColorLabel)
    }

    /// Rating, flag and label act on the selected photos the grid SHOWS, in one catalog write and one grid update. A failed write is
    /// an error alert (the model has already re-read the catalog); a success shows nothing.
    private func writeBatch(_ batch: Batch, only: [Int64]?) {
        let ids = only ?? catalog.selectedPhotosInDisplayedGrid.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let catalog = catalog
        Task {
            let written: Set<Int64>?
            switch batch {
            case .rating(let stars): written = await catalog.setRating(stars, forPhotoIDs: ids)
            case .flag(let status): written = await catalog.setFlagStatus(status, forPhotoIDs: ids)
            case .label(let label): written = await catalog.setColorLabel(label, forPhotoIDs: ids)
            }
            if written == nil {
                catalog.post(.error("Couldn't save the change", "The catalog could not be written, so the photos were re-read from it."))
            }
        }
    }
}
