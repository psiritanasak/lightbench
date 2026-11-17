import Foundation

/// The ONE description of the photo actions menu (the grid cell's context menu, the selection bar's menus and the Photo-menu
/// items that act on photos): which items exist, their titles and order, which are hidden for a target and which are enabled.
/// Pure: no SwiftUI, no closures, no state. The UI builds `Button`s from `entries(target:context:)` and performs each
/// `PhotoActionCommand` itself.
///
/// Every enabled rule is the UNION of the conditions that disable that item in the Photo menu (`PhotoAppApp`), the toolbar's
/// selection menu (`ContentView.libraryToolbarItems`) and the cell menu (`LibraryGridView`) as they were when this was written:
/// an item is disabled whenever any of those surfaces would have disabled it. The busy gates were moved here, not rewritten
/// (`PhotoActionMenuTests` transcribes the old expressions and compares).
enum PhotoActionID: String, CaseIterable, Sendable {
    case openInEditor, ratingMenu, flagMenu, labelMenu, collectionMenu, editKeywords, editInfo, copySettings, pasteSettings
    case stackMenu, stackSelected, unstack, makeCover, removeFromStack, createVirtualCopy
    case mergeMenu, mergeHDR, mergePanorama, metadataMenu, writeXMP, readXMP
    case renameFiles, locate, removeFromLibrary, moveToTrash, export, clearSelection
}

/// What choosing an item does. The UI maps it onto the model calls; the model only names it.
enum PhotoActionCommand: Equatable, Sendable {
    case run(PhotoActionID)
    case rate(Int)
    case flag(FlagStatus)
    case label(ColorLabel)
    case toggleCollection(Int64)
    case addToCollection(Int64)
}

/// The app state the busy gates read. Every field mirrors one property the three old surfaces read (named on each field).
struct PhotoActionContext: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case library, editor, cull }

    var mode: Mode = .library
    /// `catalog.editorPopoverOpen` (the Editor's Info or Keywords popover).
    var editorPopoverOpen = false
    /// `document.isLoadInFlight`.
    var loadInFlight = false
    /// `renameModel.isWorking`, `renameModel.isPresentingSheet`, `catalog.isRenameInProgress`.
    var renameWorking = false
    var renameSheet = false
    var renameInProgress = false
    /// `exportModel.isPresentingOptions || exportModel.isExporting`.
    var exportActive = false
    /// `pasteModel.pendingTargets != nil`.
    var pastePending = false
    /// `pasteModel.copied != nil`.
    var hasCopiedSettings = false
    /// `document.currentImage != nil`.
    var hasOpenImage = false
    /// `catalog.mergeBusy`, `catalog.fileToolBusy`, `catalog.trashBusy`.
    var mergeBusy = false
    var fileToolBusy = false
    var trashBusy = false
    /// `catalog.keywordSheetPhotoIDs != nil`, `infoSheetPhotoIDs != nil`, `duplicatesSheetPresented`, `peopleSheetPresented`,
    /// `autoStackSheetPresented`, `autoStack.isWorking`.
    var keywordSheetOpen = false
    var infoSheetOpen = false
    var duplicatesSheetOpen = false
    var peopleSheetOpen = false
    var autoStackSheetOpen = false
    var autoStackWorking = false
    /// `!catalog.collections.isEmpty`.
    var hasCollections = false

    /// Any of the five Library sheets is up.
    var sheetUp: Bool { keywordSheetOpen || infoSheetOpen || duplicatesSheetOpen || peopleSheetOpen || autoStackSheetOpen }

    /// The same expression as `ContentView.otherSheetIsPresented`: another sheet/dialog or a long operation is up.
    var otherSheetIsPresented: Bool {
        renameSheet || renameWorking || exportActive || pastePending || mergeBusy || fileToolBusy
    }
}

/// The photos an action would act on, summarised. Built by the UI from the selection (or from one clicked cell).
struct PhotoActionTarget: Equatable, Sendable {
    /// Set only when the target is exactly one grid cell.
    struct Cell: Equatable, Sendable {
        var isMissing = false
        var inStack = false
        var isCover = false
        var isVirtualCopy = false
        var memberships: Set<Int64> = []
    }

    /// `selectedPhotos.count`, or the clicked cell's ids.
    var count = 0
    /// `selectedPhotosInDisplayedGrid.count`, or the clicked cell's ids.
    var visibleCount = 0
    /// What `virtualCopyTargets` would return.
    var virtualCopyCount = 0
    /// The action would act on the photo open in the Editor. A MENU-BAR target sets it to true whenever a photo is open, because
    /// Copy Settings (⇧⌘C) always copies the open photo regardless of the Library selection; a cell or selection-bar target sets it
    /// only when the open photo is among the target's photos.
    var isOpenPhoto = false
    /// The distinct values among the target (a checkmark is drawn only when a set holds exactly one value).
    var ratings: Set<Int> = []
    var flags: Set<FlagStatus> = []
    var labels: Set<ColorLabel> = []
    var cell: Cell?

    static let empty = PhotoActionTarget()
}

enum PhotoActionMenu {
    /// One drawable menu row (or submenu, when `children` is non-empty or the action is a menu).
    struct Entry: Equatable, Sendable {
        var id: String
        var action: PhotoActionID
        var command: PhotoActionCommand?
        var title: String
        var isEnabled: Bool
        var isChecked: Bool
        var isDestructive: Bool
        var children: [Entry]
    }

    // MARK: - Titles and layout

    static func title(_ action: PhotoActionID) -> String {
        switch action {
        case .openInEditor: return "Open in Editor"
        case .ratingMenu: return "Rating"
        case .flagMenu: return "Flag"
        case .labelMenu: return "Label"
        case .collectionMenu: return "Add to Collection"
        case .editKeywords: return "Edit Keywords…"
        case .editInfo: return "Edit Info…"
        case .copySettings: return "Copy Settings"
        case .pasteSettings: return "Paste Settings"
        case .stackMenu: return "Stack"
        case .stackSelected: return "Stack Selected"
        case .unstack: return "Unstack"
        case .makeCover: return "Make Cover"
        case .removeFromStack: return "Remove from Stack"
        case .createVirtualCopy: return "Create Virtual Copy"
        case .mergeMenu: return "Merge"
        case .mergeHDR: return "Merge to HDR…"
        case .mergePanorama: return "Merge to Panorama…"
        case .metadataMenu: return "Metadata"
        case .writeXMP: return "Write Metadata to XMP…"
        case .readXMP: return "Read Metadata from XMP…"
        case .renameFiles: return "Rename Files…"
        case .locate: return "Locate…"
        case .removeFromLibrary: return "Remove from Library"
        case .moveToTrash: return "Move to Trash…"
        case .export: return "Export…"
        case .clearSelection: return "Clear"
        }
    }

    static func isDestructive(_ action: PhotoActionID) -> Bool {
        action == .removeFromLibrary || action == .moveToTrash
    }

    /// The menu groups in order (a divider between groups). `export` and `clearSelection` are selection-bar items only.
    static let layout: [[PhotoActionID]] = [
        [.openInEditor],
        [.ratingMenu, .flagMenu, .labelMenu],
        [.collectionMenu],
        [.editKeywords, .editInfo],
        [.copySettings, .pasteSettings],
        [.stackMenu],
        [.createVirtualCopy],
        [.mergeMenu],
        [.metadataMenu],
        [.renameFiles, .locate],
        [.removeFromLibrary, .moveToTrash]
    ]

    /// The items inside a submenu (empty for every other action). The collection submenu's children come from the catalog, so the UI fills them.
    static func submenuItems(_ action: PhotoActionID) -> [PhotoActionID] {
        switch action {
        case .stackMenu: return [.stackSelected, .unstack, .makeCover, .removeFromStack]
        case .mergeMenu: return [.mergeHDR, .mergePanorama]
        case .metadataMenu: return [.writeXMP, .readXMP]
        default: return []
        }
    }

    // MARK: - Hidden and enabled

    /// Items that do not apply to this target at all (hidden, not greyed).
    static func isHidden(_ action: PhotoActionID, target: PhotoActionTarget) -> Bool {
        switch action {
        case .openInEditor, .removeFromLibrary:
            return target.cell == nil
        case .makeCover:
            guard let cell = target.cell else { return true }
            return !(cell.inStack && !cell.isCover)
        case .removeFromStack:
            guard let cell = target.cell else { return true }
            return !cell.inStack
        case .locate:
            // A single cell offers Locate only when it is missing; a multi-selection always does.
            if let cell = target.cell { return !cell.isMissing }
            return false
        case .stackMenu:
            return submenuItems(.stackMenu).allSatisfy { isHidden($0, target: target) }
        default:
            return false
        }
    }

    static func isEnabled(_ action: PhotoActionID, target: PhotoActionTarget, context c: PhotoActionContext) -> Bool {
        let t = target
        // Off while culling: the grid and the Photo-menu items are not usable then.
        if c.mode == .cull { return false }
        // The Editor's Info/Keywords popovers: the Photo-menu items that could fire mid-typing were disabled by it. Edit Keywords /
        // Edit Info are the toggles that close those popovers, and Rename Files never named it, so they are exempt (as today).
        let popoverExempt: Set<PhotoActionID> = [.editKeywords, .editInfo, .renameFiles]
        if c.editorPopoverOpen && !popoverExempt.contains(action) { return false }
        let library = c.mode == .library
        let renameBusy = c.renameWorking || c.renameSheet

        switch action {
        case .openInEditor:
            return library && t.count > 0 && !c.renameWorking
        case .ratingMenu, .flagMenu, .labelMenu:
            return library && t.count > 0
        case .collectionMenu:
            return library && c.hasCollections && t.count > 0
        case .editKeywords:
            return t.count > 0 && !c.keywordSheetOpen && !c.infoSheetOpen && !renameBusy && !c.otherSheetIsPresented
        case .editInfo:
            return t.count > 0 && !c.keywordSheetOpen && !c.infoSheetOpen && !renameBusy && !c.otherSheetIsPresented
                && !c.sheetUp && !c.mergeBusy && !c.fileToolBusy
        case .copySettings:
            return c.hasOpenImage && t.isOpenPhoto
        case .pasteSettings:
            return c.hasCopiedSettings && t.count > 0 && !c.loadInFlight && !c.mergeBusy && !c.fileToolBusy
                && !renameBusy && !c.sheetUp
        case .stackMenu, .mergeMenu, .metadataMenu:
            return submenuItems(action).contains { isEnabled($0, target: target, context: c) }
        case .stackSelected:
            return library && t.count >= 2 && stackGate(c)
        case .unstack:
            return library && t.count > 0 && stackGate(c)
        case .makeCover, .removeFromStack:
            return t.count > 0
        case .createVirtualCopy:
            return t.virtualCopyCount > 0 && !(t.cell?.isMissing ?? false) && !renameBusy && !c.loadInFlight
                && !c.mergeBusy && !c.fileToolBusy && !c.sheetUp
        case .mergeHDR, .mergePanorama:
            return library && t.visibleCount >= 2 && !c.mergeBusy && !c.sheetUp && !renameBusy && !c.loadInFlight
                && !c.otherSheetIsPresented
        case .writeXMP, .readXMP:
            return library && t.visibleCount > 0 && !c.fileToolBusy && !c.mergeBusy && !c.sheetUp && !renameBusy
                && !c.loadInFlight && !c.otherSheetIsPresented
        case .renameFiles:
            return t.count > 0 && !renameBusy && !c.loadInFlight && !c.mergeBusy && !c.fileToolBusy && !c.sheetUp
        case .locate:
            return library && t.count > 0 && !c.renameInProgress
        case .removeFromLibrary:
            return t.count > 0
        case .moveToTrash:
            return library && t.visibleCount > 0 && !c.otherSheetIsPresented && !c.fileToolBusy && !c.mergeBusy
                && !c.renameWorking && !c.loadInFlight
        case .export:
            return t.count > 0 && !c.exportActive && !c.renameWorking
        case .clearSelection:
            // Deliberately NOT gated on `count` (IMPROVEMENTS.md D33; see the comment in `ContentView.libraryToolbarItems`): `count`
            // excludes selected ids whose photos are not loaded, and the old toolbar "Clear Selection" had no gate so such a ghost
            // selection can always be cleared.
            return library
        }
    }

    /// Stack / Unstack: the stack sheets, a trash in progress and the rename tool, plus every other dialog or long operation.
    private static func stackGate(_ c: PhotoActionContext) -> Bool {
        !c.autoStackSheetOpen && !c.autoStackWorking && !c.trashBusy && !c.renameWorking && !c.renameSheet && !c.otherSheetIsPresented
    }

    // MARK: - Entries

    /// The rows to draw, grouped (draw a divider between groups). Hidden items and empty groups are dropped. The collection
    /// submenu has no children here: the UI fills them from the catalog's collections (`collectionCommand(for:target:)` names the command).
    static func entries(target: PhotoActionTarget, context: PhotoActionContext) -> [[Entry]] {
        layout.compactMap { group in
            let rows = group.compactMap { entry(for: $0, target: target, context: context) }
            return rows.isEmpty ? nil : rows
        }
    }

    /// What choosing collection `collectionID` does: exactly one photo's cell toggles its membership (with checkmarks); several
    /// photos (including a collapsed stack cell of several ids) only add.
    static func collectionCommand(for collectionID: Int64, target: PhotoActionTarget) -> PhotoActionCommand {
        target.cell != nil && target.count == 1 ? .toggleCollection(collectionID) : .addToCollection(collectionID)
    }

    /// The row for one action, or nil when it is hidden for this target. Selection-bar items (`export`, `clearSelection`) work too.
    static func entry(for action: PhotoActionID, target: PhotoActionTarget, context: PhotoActionContext) -> Entry? {
        guard !isHidden(action, target: target) else { return nil }
        let enabled = isEnabled(action, target: target, context: context)
        let children: [Entry]
        switch action {
        case .ratingMenu:
            children = (0...5).map { stars in
                Entry(id: "rating.\(stars)", action: action, command: .rate(stars),
                      title: stars == 0 ? "No Rating" : (stars == 1 ? "1 Star" : "\(stars) Stars"),
                      isEnabled: enabled, isChecked: target.ratings == [stars], isDestructive: false, children: [])
            }
        case .flagMenu:
            children = FlagStatus.menuOrder.map { status in
                Entry(id: "flag.\(status.rawValue)", action: action, command: .flag(status), title: status.menuTitle,
                      isEnabled: enabled, isChecked: target.flags == [status], isDestructive: false, children: [])
            }
        case .labelMenu:
            children = ColorLabel.menuOrder.map { label in
                Entry(id: "label.\(label.rawValue)", action: action, command: .label(label), title: label.menuTitle,
                      isEnabled: enabled, isChecked: target.labels == [label], isDestructive: false, children: [])
            }
        case .stackMenu, .mergeMenu, .metadataMenu:
            children = submenuItems(action).compactMap { entry(for: $0, target: target, context: context) }
        default:
            children = []
        }
        let isMenu: Bool
        switch action {
        case .ratingMenu, .flagMenu, .labelMenu, .collectionMenu, .stackMenu, .mergeMenu, .metadataMenu: isMenu = true
        default: isMenu = false
        }
        return Entry(id: action.rawValue, action: action, command: isMenu ? nil : .run(action), title: title(action),
                     isEnabled: enabled, isChecked: false, isDestructive: isDestructive(action), children: children)
    }

    // MARK: - Click target

    enum ClickTarget: Equatable, Sendable {
        /// Act on the whole selection.
        case selection
        /// Act on the clicked cell only (its photo ids).
        case cell([Int64])
    }

    /// A right-click (or the ellipsis) on a cell acts on the SELECTION only when every photo the cell stands for is already
    /// selected (the `FaceMarking.targets` rule); on an unselected or partly selected cell it acts on that cell alone.
    static func clickTarget(cellIDs: [Int64], selection: Set<Int64>) -> ClickTarget {
        guard !cellIDs.isEmpty, cellIDs.allSatisfy(selection.contains) else { return .cell(cellIDs) }
        return .selection
    }
}

extension PhotoActionTarget {
    /// The target of a right-click on `item`. When the click acts on the selection that is `selectionTarget`; when the selection is
    /// exactly this cell, the cell's details are attached to it. Otherwise it is a fresh target built from this cell alone.
    ///
    /// `selection` must be the GHOST-FREE selection: only ids of photos that are loaded (not the raw `selectedPhotoIDs`). A stale id
    /// would make a partly selected collapsed stack look fully selected or break the "selection equals this cell" comparison, so the
    /// click would act on a selection the user cannot see.
    static func forCell(
        _ item: StackGridItem, isMissing: Bool, memberships: Set<Int64> = [], selection: Set<Int64>,
        selectionTarget: PhotoActionTarget, openEditKey: String?
    ) -> PhotoActionTarget {
        let ids = StackSelection.ids(for: item)
        let cell = Cell(isMissing: isMissing, inStack: item.stackID != nil, isCover: item.isCover,
                        isVirtualCopy: item.photo.isVirtualCopy, memberships: memberships)
        switch PhotoActionMenu.clickTarget(cellIDs: ids, selection: selection) {
        case .selection:
            guard selection == Set(ids) else { return selectionTarget }
            var target = selectionTarget
            target.cell = cell
            return target
        case .cell:
            let photos = item.role == .collapsedStack ? item.visibleMembers : [item.photo]
            return PhotoActionTarget(
                count: ids.count, visibleCount: ids.count, virtualCopyCount: ids.count,
                isOpenPhoto: openEditKey.map { key in photos.contains { $0.editKey == key } } ?? false,
                ratings: Set(photos.map(\.rating)), flags: Set(photos.map(\.flagStatus)),
                labels: Set(photos.map(\.colorLabel)), cell: cell)
        }
    }
}
