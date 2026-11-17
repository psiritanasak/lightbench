import XCTest
@testable import PhotoApp

/// The pure photo-action menu model: titles and layout, hidden/enabled rules for each kind of target, every busy flag on its own,
/// and the click-target rule. The "moved, not rewritten" test transcribes the disabling expressions as they stood in the three old
/// surfaces and compares them with the model over the single-flag cases and a seeded random sweep.
final class PhotoActionMenuTests: XCTestCase {
    // MARK: Fixtures

    private func photo(_ id: Int64, rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none, key: String? = nil) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              rating: rating, flagStatus: flag, colorLabel: label, masterId: key == nil ? nil : 1, versionKey: key,
              versionName: key == nil ? nil : "Copy 1")
    }

    private func plainItem(_ id: Int64) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false)
    }

    private func collapsedItem(_ ids: [Int64]) -> StackGridItem {
        let members = ids.map { photo($0) }
        return StackGridItem(photo: members[0], role: .collapsedStack, stackID: 9, visibleMembers: members,
                             hiddenMemberCount: members.count - 1, isCover: true)
    }

    private func memberItem(_ id: Int64, cover: Bool) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .expandedMember, stackID: 9, visibleMembers: [photo(id)], hiddenMemberCount: 0, isCover: cover)
    }

    /// Three selected photos, all visible, the Library, one copied look, an open photo that is one of them.
    private let selection = PhotoActionTarget(count: 3, visibleCount: 3, virtualCopyCount: 3, isOpenPhoto: true)
    private var library: PhotoActionContext {
        PhotoActionContext(mode: .library, hasCopiedSettings: true, hasOpenImage: true, hasCollections: true)
    }

    private func enabled(_ action: PhotoActionID, _ target: PhotoActionTarget, _ context: PhotoActionContext) -> Bool {
        PhotoActionMenu.isEnabled(action, target: target, context: context)
    }

    /// Items the busy-flag table covers.
    private let tabled: [PhotoActionID] = [
        .openInEditor, .editKeywords, .editInfo, .copySettings, .pasteSettings, .stackSelected, .unstack, .createVirtualCopy,
        .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .renameFiles, .locate, .moveToTrash, .collectionMenu
    ]

    // MARK: Titles and layout

    func testTitlesAreNonEmptyAndUnique() {
        let titles = PhotoActionID.allCases.map { PhotoActionMenu.title($0) }
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testLayoutHoldsEveryIDExceptTheBarOnesOnceInOrder() {
        let flat = PhotoActionMenu.layout.flatMap { $0 }
        XCTAssertEqual(Set(flat).count, flat.count, "no id twice")
        let inSubmenus = Set([PhotoActionID.stackMenu, .mergeMenu, .metadataMenu].flatMap { PhotoActionMenu.submenuItems($0) })
        let placed = Set(flat).union(inSubmenus)
        XCTAssertEqual(placed, Set(PhotoActionID.allCases).subtracting([.export, .clearSelection]))
        XCTAssertTrue(inSubmenus.isDisjoint(with: flat))
        XCTAssertEqual(PhotoActionMenu.layout, [
            [.openInEditor], [.ratingMenu, .flagMenu, .labelMenu], [.collectionMenu], [.editKeywords, .editInfo],
            [.copySettings, .pasteSettings], [.stackMenu], [.createVirtualCopy], [.mergeMenu], [.metadataMenu],
            [.renameFiles, .locate], [.removeFromLibrary, .moveToTrash]
        ])
    }

    func testDestructiveSetIsExactlyTheLastGroup() {
        let destructive = Set(PhotoActionID.allCases.filter { PhotoActionMenu.isDestructive($0) })
        XCTAssertEqual(destructive, [.removeFromLibrary, .moveToTrash])
        XCTAssertEqual(Set(PhotoActionMenu.layout.last ?? []), destructive)
    }

    func testSubmenuChildCountsAndTitles() throws {
        let target = PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, ratings: [3], flags: [.picked], labels: [.red])
        let rows = PhotoActionMenu.entries(target: target, context: library).flatMap { $0 }
        let rating = try XCTUnwrap(rows.first { $0.action == .ratingMenu })
        let flag = try XCTUnwrap(rows.first { $0.action == .flagMenu })
        let label = try XCTUnwrap(rows.first { $0.action == .labelMenu })
        XCTAssertEqual(rating.children.count, 6)
        XCTAssertEqual(flag.children.count, 3)
        XCTAssertEqual(label.children.count, 6)
        XCTAssertEqual(rating.children.map(\.title), ["No Rating", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"])
        XCTAssertEqual(flag.children.map(\.title), ["Pick", "Reject", "Unflag"])
        XCTAssertEqual(label.children.map(\.title), ["No Label", "Red", "Yellow", "Green", "Blue", "Purple"])
        XCTAssertEqual(rating.children.filter(\.isChecked).map(\.title), ["3 Stars"])
        XCTAssertEqual(flag.children.filter(\.isChecked).map(\.title), ["Pick"])
        XCTAssertEqual(label.children.filter(\.isChecked).map(\.title), ["Red"])
        XCTAssertEqual(rating.children[2].command, .rate(2))
    }

    func testACheckmarkShowsOnlyWhenTheTargetHasExactlyOneValue() throws {
        let mixed = PhotoActionTarget(count: 2, visibleCount: 2, ratings: [1, 2], flags: [.picked, .none], labels: [])
        let rows = PhotoActionMenu.entries(target: mixed, context: library).flatMap { $0 }
        for id in [PhotoActionID.ratingMenu, .flagMenu, .labelMenu] {
            let menu = try XCTUnwrap(rows.first { $0.action == id })
            XCTAssertTrue(menu.children.allSatisfy { !$0.isChecked }, "\(id)")
        }
    }

    func testEntriesDropHiddenItemsAndEmptyGroups() {
        let rows = PhotoActionMenu.entries(target: selection, context: library)
        XCTAssertTrue(rows.allSatisfy { !$0.isEmpty })
        let ids = Set(rows.flatMap { $0 }.map(\.action))
        XCTAssertFalse(ids.contains(.openInEditor), "cell-only")
        XCTAssertFalse(ids.contains(.removeFromLibrary), "cell-only")
        XCTAssertTrue(ids.contains(.moveToTrash))
        XCTAssertTrue(ids.contains(.locate), "a multi-selection always offers Locate")
        let stack = rows.flatMap { $0 }.first { $0.action == .stackMenu }
        XCTAssertEqual(stack?.children.map(\.action), [.stackSelected, .unstack], "Make Cover / Remove from Stack need a cell")
    }

    // MARK: Targets

    func testEmptyTarget() {
        let context = library
        XCTAssertFalse(enabled(.ratingMenu, .empty, context))
        XCTAssertFalse(enabled(.collectionMenu, .empty, context))
        XCTAssertFalse(enabled(.editKeywords, .empty, context))
        XCTAssertFalse(enabled(.moveToTrash, .empty, context))
        XCTAssertFalse(enabled(.createVirtualCopy, .empty, context))
        XCTAssertTrue(enabled(.clearSelection, .empty, context), "D33: Clear is never gated on the loaded-photo count (a ghost selection must be clearable)")
        XCTAssertFalse(enabled(.export, .empty, context))
    }

    func testASinglePlainCell() {
        let target = PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, cell: .init())
        let context = library
        XCTAssertFalse(PhotoActionMenu.isHidden(.openInEditor, target: target))
        XCTAssertFalse(PhotoActionMenu.isHidden(.removeFromLibrary, target: target))
        XCTAssertTrue(PhotoActionMenu.isHidden(.makeCover, target: target))
        XCTAssertTrue(PhotoActionMenu.isHidden(.removeFromStack, target: target))
        XCTAssertTrue(PhotoActionMenu.isHidden(.locate, target: target), "not missing")
        XCTAssertTrue(enabled(.createVirtualCopy, target, context))
        XCTAssertTrue(enabled(.openInEditor, target, context))
        XCTAssertFalse(enabled(.stackSelected, target, context), "needs 2")
        XCTAssertTrue(enabled(.unstack, target, context))
        XCTAssertFalse(enabled(.mergeHDR, target, context))
        XCTAssertTrue(enabled(.writeXMP, target, context))
    }

    func testAMultiSelection() {
        let context = library
        for action in [PhotoActionID.stackSelected, .unstack, .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .renameFiles, .locate,
                       .moveToTrash, .editKeywords, .editInfo, .pasteSettings, .createVirtualCopy, .copySettings, .collectionMenu] {
            XCTAssertTrue(enabled(action, selection, context), "\(action)")
        }
        XCTAssertEqual(PhotoActionMenu.collectionCommand(for: 4, target: selection), .addToCollection(4))
    }

    func testPhotosHiddenByFiltersCountForKeywordsButNotForMergeXMPTrash() {
        let target = PhotoActionTarget(count: 3, visibleCount: 1, virtualCopyCount: 1)
        XCTAssertTrue(enabled(.editKeywords, target, library))
        XCTAssertTrue(enabled(.stackSelected, target, library))
        XCTAssertFalse(enabled(.mergeHDR, target, library), "merge acts on the visible photos only")
        XCTAssertTrue(enabled(.writeXMP, target, library))
        let none = PhotoActionTarget(count: 3, visibleCount: 0, virtualCopyCount: 0)
        XCTAssertFalse(enabled(.writeXMP, none, library))
        XCTAssertFalse(enabled(.moveToTrash, none, library))
        XCTAssertTrue(enabled(.renameFiles, none, library), "rename acts on the selection")
    }

    func testAMissingCellOffersLocateAndCannotBeVirtualCopied() {
        let target = PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, cell: .init(isMissing: true))
        XCTAssertFalse(PhotoActionMenu.isHidden(.locate, target: target))
        XCTAssertTrue(enabled(.locate, target, library))
        XCTAssertFalse(enabled(.createVirtualCopy, target, library))
    }

    func testAnExpandedMemberOffersMakeCoverButTheCoverDoesNot() {
        let member = PhotoActionTarget(count: 1, visibleCount: 1, cell: .init(inStack: true, isCover: false))
        let cover = PhotoActionTarget(count: 1, visibleCount: 1, cell: .init(inStack: true, isCover: true))
        XCTAssertFalse(PhotoActionMenu.isHidden(.makeCover, target: member))
        XCTAssertTrue(PhotoActionMenu.isHidden(.makeCover, target: cover))
        XCTAssertFalse(PhotoActionMenu.isHidden(.removeFromStack, target: member))
        XCTAssertFalse(PhotoActionMenu.isHidden(.removeFromStack, target: cover))
        XCTAssertTrue(enabled(.makeCover, member, library))
    }

    func testACollapsedStackCellOfThree() {
        let target = PhotoActionTarget(count: 3, visibleCount: 3, virtualCopyCount: 3, cell: .init(inStack: true, isCover: true))
        XCTAssertTrue(enabled(.mergeHDR, target, library))
        XCTAssertTrue(enabled(.stackSelected, target, library))
        XCTAssertTrue(enabled(.removeFromLibrary, target, library))
        XCTAssertFalse(PhotoActionMenu.isHidden(.removeFromLibrary, target: target))
        XCTAssertEqual(PhotoActionMenu.collectionCommand(for: 4, target: target), .addToCollection(4), "several ids: add only, no checkmarks")
        let single = PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, cell: .init())
        XCTAssertEqual(PhotoActionMenu.collectionCommand(for: 4, target: single), .toggleCollection(4))
    }

    func testAVirtualCopyCellHasTheSameEnabledSetAsAMaster() {
        var master = PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, cell: .init())
        var copy = master
        copy.cell?.isVirtualCopy = true
        master.cell?.isVirtualCopy = false
        for action in PhotoActionID.allCases {
            XCTAssertEqual(enabled(action, master, library), enabled(action, copy, library), "\(action)")
            XCTAssertEqual(PhotoActionMenu.isHidden(action, target: master), PhotoActionMenu.isHidden(action, target: copy), "\(action)")
        }
    }

    // MARK: Busy flags, one at a time

    private func disabledSet(_ mutate: (inout PhotoActionContext) -> Void) -> Set<PhotoActionID> {
        var context = library
        mutate(&context)
        return Set(tabled.filter { !enabled($0, selection, context) })
    }

    func testTheBaselineEnablesEveryTabledItem() {
        XCTAssertEqual(disabledSet { _ in }, [])
    }

    func testEachBusyFlagAgainstItsExpectedTable() {
        let osp: Set<PhotoActionID> = [.editKeywords, .editInfo, .stackSelected, .unstack, .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .moveToTrash]
        let toolBusy = osp.union([.pasteSettings, .createVirtualCopy, .renameFiles])
        let sheetUp: Set<PhotoActionID> = [.editInfo, .pasteSettings, .createVirtualCopy, .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .renameFiles]
        let cases: [(String, (inout PhotoActionContext) -> Void, Set<PhotoActionID>)] = [
            ("loadInFlight", { $0.loadInFlight = true },
             [.pasteSettings, .createVirtualCopy, .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .renameFiles, .moveToTrash]),
            ("renameWorking", { $0.renameWorking = true },
             osp.union([.openInEditor, .pasteSettings, .createVirtualCopy, .mergeHDR, .renameFiles])),
            ("renameSheet", { $0.renameSheet = true },
             osp.union([.pasteSettings, .createVirtualCopy, .renameFiles])),
            ("renameInProgress", { $0.renameInProgress = true }, [.locate]),
            ("exportActive", { $0.exportActive = true }, osp),
            ("pastePending", { $0.pastePending = true }, osp),
            ("mergeBusy", { $0.mergeBusy = true }, toolBusy),
            ("fileToolBusy", { $0.fileToolBusy = true }, toolBusy),
            ("trashBusy", { $0.trashBusy = true }, [.stackSelected, .unstack]),
            ("keywordSheetOpen", { $0.keywordSheetOpen = true }, sheetUp.union([.editKeywords])),
            ("infoSheetOpen", { $0.infoSheetOpen = true }, sheetUp.union([.editKeywords])),
            ("duplicatesSheetOpen", { $0.duplicatesSheetOpen = true }, sheetUp),
            ("peopleSheetOpen", { $0.peopleSheetOpen = true }, sheetUp),
            ("autoStackSheetOpen", { $0.autoStackSheetOpen = true }, sheetUp.union([.stackSelected, .unstack])),
            ("autoStackWorking", { $0.autoStackWorking = true }, [.stackSelected, .unstack]),
            ("noCollections", { $0.hasCollections = false }, [.collectionMenu])
        ]
        for (name, mutate, expected) in cases {
            XCTAssertEqual(disabledSet(mutate), expected, name)
        }
    }

    func testNothingCopiedOrNoOpenPhotoDisablesCopyAndPaste() {
        XCTAssertEqual(disabledSet { $0.hasCopiedSettings = false }, [.pasteSettings])
        XCTAssertEqual(disabledSet { $0.hasOpenImage = false }, [.copySettings])
        var other = selection
        other.isOpenPhoto = false
        XCTAssertFalse(enabled(.copySettings, other, library))
    }

    // MARK: Modes

    func testCullDisablesEveryItem() {
        var context = library
        context.mode = .cull
        for action in PhotoActionID.allCases {
            XCTAssertFalse(enabled(action, selection, context), "\(action)")
        }
    }

    func testTheEditorPopoverDisablesEveryItemThatCouldFireMidTypingButNotTheToggles() {
        var context = library
        context.editorPopoverOpen = true
        for action in [PhotoActionID.copySettings, .pasteSettings, .createVirtualCopy, .stackSelected, .unstack, .mergeHDR, .moveToTrash] {
            XCTAssertFalse(enabled(action, selection, context), "\(action)")
        }
        // Edit Keywords / Edit Info are the toggles that close the popover; Rename Files never named it.
        for action in [PhotoActionID.editKeywords, .editInfo, .renameFiles] {
            XCTAssertTrue(enabled(action, selection, context), "\(action)")
        }
    }

    func testTheEditorModeDisablesLibraryOnlyItemsAndLeavesTheRestToTheirRules() {
        var context = library
        context.mode = .editor
        for action in [PhotoActionID.openInEditor, .ratingMenu, .flagMenu, .labelMenu, .collectionMenu, .stackSelected, .unstack,
                       .mergeHDR, .mergePanorama, .writeXMP, .readXMP, .locate, .moveToTrash, .clearSelection] {
            XCTAssertFalse(enabled(action, selection, context), "\(action)")
        }
        for action in [PhotoActionID.copySettings, .pasteSettings, .renameFiles, .createVirtualCopy] {
            XCTAssertTrue(enabled(action, selection, context), "\(action)")
        }
    }

    func testExportAndClear() {
        XCTAssertTrue(enabled(.export, selection, library))
        var context = library
        context.exportActive = true
        XCTAssertFalse(enabled(.export, selection, context))
        context = library
        context.renameWorking = true
        XCTAssertFalse(enabled(.export, selection, context))
        XCTAssertTrue(enabled(.clearSelection, selection, library))
    }

    func testOtherSheetIsPresentedIsTheSameExpressionAsContentViews() {
        // Transcribed from `ContentView.otherSheetIsPresented`:
        //   renameModel.isPresentingSheet || renameModel.isWorking || exportModel.isPresentingOptions
        //   || exportModel.isExporting || pasteModel.pendingTargets != nil || catalog.mergeBusy || catalog.fileToolBusy
        for mask in 0..<64 {
            var context = PhotoActionContext()
            context.renameSheet = mask & 1 != 0
            context.renameWorking = mask & 2 != 0
            context.exportActive = mask & 4 != 0
            context.pastePending = mask & 8 != 0
            context.mergeBusy = mask & 16 != 0
            context.fileToolBusy = mask & 32 != 0
            XCTAssertEqual(context.otherSheetIsPresented, mask != 0, "mask \(mask)")
        }
        var open = PhotoActionContext()
        open.keywordSheetOpen = true
        XCTAssertFalse(open.otherSheetIsPresented, "the five sheets are not part of it")
        XCTAssertTrue(open.sheetUp)
    }

    // MARK: Click target and forCell

    func testClickTargetRule() {
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [1], selection: []), .cell([1]))
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [1], selection: [2, 3]), .cell([1]))
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [1], selection: [1, 2, 3]), .selection)
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [1, 2, 3], selection: [1, 2, 3, 4]), .selection, "a fully selected collapsed stack")
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [1, 2, 3], selection: [1, 2]), .cell([1, 2, 3]), "partly selected")
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [], selection: [1]), .cell([]))
        XCTAssertEqual(PhotoActionMenu.clickTarget(cellIDs: [], selection: []), .cell([]))
    }

    func testAnEmptyCellTargetsNothing() {
        let item = StackGridItem(photo: photo(1), role: .collapsedStack, stackID: 9, visibleMembers: [], hiddenMemberCount: 0, isCover: true)
        let target = PhotoActionTarget.forCell(item, isMissing: false, selection: [1], selectionTarget: selection, openEditKey: nil)
        XCTAssertEqual(target.count, 0)
        for action in PhotoActionID.allCases where action != .clearSelection {
            XCTAssertFalse(enabled(action, target, library), "\(action)")
        }
        XCTAssertTrue(enabled(.clearSelection, target, library))
    }

    func testForCellBuildsACellTargetWhenTheCellIsNotSelected() {
        let item = plainItem(5)
        let target = PhotoActionTarget.forCell(item, isMissing: true, memberships: [7], selection: [1, 2], selectionTarget: selection,
                                               openEditKey: "/p/5.jpg")
        XCTAssertEqual(target.count, 1)
        XCTAssertEqual(target.cell, .init(isMissing: true, inStack: false, isCover: false, isVirtualCopy: false, memberships: [7]))
        XCTAssertTrue(target.isOpenPhoto)
        XCTAssertEqual(target.ratings, [0])
    }

    func testForCellOnACollapsedStackActsOnAllItsMembers() {
        let item = collapsedItem([1, 2, 3])
        let target = PhotoActionTarget.forCell(item, isMissing: false, selection: [], selectionTarget: .empty, openEditKey: "/p/3.jpg")
        XCTAssertEqual(target.count, 3)
        XCTAssertEqual(target.cell?.inStack, true)
        XCTAssertEqual(target.cell?.isCover, true)
        XCTAssertFalse(target.isOpenPhoto, "a hidden member being open does not make the cover's menu offer Copy Settings")
        let cover = PhotoActionTarget.forCell(item, isMissing: false, selection: [], selectionTarget: .empty, openEditKey: "/p/1.jpg")
        XCTAssertTrue(cover.isOpenPhoto, "the cover itself being open does")
    }

    func testForCellOfAStackChecksTheCoverOnly() {
        let members = [photo(1, rating: 2, flag: .picked), photo(2, rating: 5, flag: .rejected), photo(3)]
        let item = StackGridItem(photo: members[0], role: .collapsedStack, stackID: 9, visibleMembers: members, hiddenMemberCount: 2, isCover: true)
        let target = PhotoActionTarget.forCell(item, isMissing: false, selection: [], selectionTarget: .empty, openEditKey: nil)
        XCTAssertEqual(target.ratings, [2])
        XCTAssertEqual(target.flags, [.picked])
        // The same stack already selected as a whole (a plain click selects every member): the checkmarks still show the cover.
        let ticked = PhotoActionTarget.forCell(item, isMissing: false, selection: [1, 2, 3], selectionTarget: selection, openEditKey: nil)
        XCTAssertNotNil(ticked.cell)
        XCTAssertEqual(ticked.ratings, [2])
        XCTAssertEqual(ticked.flags, [.picked])
        XCTAssertEqual(ticked.labels, [.none])
    }

    func testCopySettingsOnACellNeedsTheCLICKEDCellsPhotoOpen() {
        // Right-click A while B is open: no Copy, whether A is alone, unselected, or selected among others (B among them too).
        let a = plainItem(1)
        let openB = "/p/2.jpg"
        let unselected = PhotoActionTarget.forCell(a, isMissing: false, selection: [2], selectionTarget: selection, openEditKey: openB)
        XCTAssertFalse(unselected.isOpenPhoto)
        let among = PhotoActionTarget.forCell(a, isMissing: false, selection: [1, 2, 3], selectionTarget: selection, openEditKey: openB)
        XCTAssertFalse(among.isOpenPhoto)
        XCTAssertFalse(enabled(.copySettings, among, library))
        let alone = PhotoActionTarget.forCell(a, isMissing: false, selection: [1], selectionTarget: selection, openEditKey: "/p/1.jpg")
        XCTAssertTrue(alone.isOpenPhoto)
        XCTAssertTrue(enabled(.copySettings, alone, library))
    }

    // MARK: Cell plan (what choosing an item from a cell does)

    func testCellPlanForEachKindOfClick() {
        let plain = plainItem(1)
        let unselected = PhotoActionMenu.cellPlan(for: plain, hasCell: true, selection: [])
        XCTAssertEqual(unselected, .init(selectsCellFirst: true, passesClicked: true, batchIDs: [1]))
        let alone = PhotoActionMenu.cellPlan(for: plain, hasCell: true, selection: [1])
        XCTAssertEqual(alone, .init(selectsCellFirst: false, passesClicked: true, batchIDs: [1]), "selected alone: the cell is the whole target")
        let among = PhotoActionMenu.cellPlan(for: plain, hasCell: false, selection: [1, 2, 3])
        XCTAssertEqual(among, .init(selectsCellFirst: false, passesClicked: false, batchIDs: nil))
        let stack = collapsedItem([1, 2, 3])
        let partly = PhotoActionMenu.cellPlan(for: stack, hasCell: true, selection: [1, 2])
        XCTAssertEqual(partly, .init(selectsCellFirst: true, passesClicked: true, batchIDs: [1]), "a partly selected stack acts on the cover only")
        let fullWhole = PhotoActionMenu.cellPlan(for: stack, hasCell: true, selection: [1, 2, 3])
        XCTAssertEqual(fullWhole, .init(selectsCellFirst: false, passesClicked: true, batchIDs: [1]), "a ticked stack that is the whole selection still writes the cover only")
        let fullAmong = PhotoActionMenu.cellPlan(for: stack, hasCell: false, selection: [1, 2, 3, 4])
        XCTAssertEqual(fullAmong, .init(selectsCellFirst: false, passesClicked: false, batchIDs: nil))
        let unselectedStack = PhotoActionMenu.cellPlan(for: stack, hasCell: true, selection: [])
        XCTAssertEqual(unselectedStack.batchIDs, [1])
    }

    func testForCellSetsTheCellOnlyWhenTheSelectionEqualsTheCell() {
        let item = plainItem(1)
        let alone = PhotoActionTarget.forCell(item, isMissing: false, selection: [1], selectionTarget: selection, openEditKey: nil)
        XCTAssertNotNil(alone.cell)
        XCTAssertEqual(alone.count, selection.count, "it is the selection's target with the cell details attached")
        let among = PhotoActionTarget.forCell(item, isMissing: false, selection: [1, 2, 3], selectionTarget: selection, openEditKey: nil)
        XCTAssertNil(among.cell)
        var expected = selection
        expected.isOpenPhoto = false // no open photo given: the clicked cell's own photo is what counts
        XCTAssertEqual(among, expected)
        let other = PhotoActionTarget.forCell(item, isMissing: false, selection: [2], selectionTarget: selection, openEditKey: nil)
        XCTAssertEqual(other.count, 1)
        XCTAssertNotNil(other.cell)
    }

    func testForCellCollectsTheCellsRatingFlagAndLabel() {
        let item = StackGridItem(photo: photo(1, rating: 4, flag: .picked, label: .blue), role: .plain, stackID: nil,
                                 visibleMembers: [], hiddenMemberCount: 0, isCover: false)
        let target = PhotoActionTarget.forCell(item, isMissing: false, selection: [], selectionTarget: .empty, openEditKey: nil)
        XCTAssertEqual(target.ratings, [4])
        XCTAssertEqual(target.flags, [.picked])
        XCTAssertEqual(target.labels, [.blue])
    }

    // MARK: Moved, not rewritten

    /// Reference expressions: each returns "would be DISABLED" exactly as the source expression reads, with the old names mapped to the
    /// model's fields (`cull.isActive` = mode == .cull, `!showLibrary` = mode != .library, `selectedPhotos.count` = count,
    /// `selectedPhotosInDisplayedGrid.count` = visibleCount, `virtualCopyTargets(...).count` = virtualCopyCount, the sheet flags as named).
    private enum Reference {
        // Sources/App/PhotoAppApp.swift, CommandMenu("Photo"), item "Paste Settings".
        static func menuPaste(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.editorPopoverOpen || c.mode == .cull || !c.hasCopiedSettings || t.count == 0 || c.loadInFlight || c.mergeBusy || c.fileToolBusy
                || c.renameWorking || c.renameSheet || c.keywordSheetOpen || c.infoSheetOpen
                || c.duplicatesSheetOpen || c.peopleSheetOpen || c.autoStackSheetOpen
        }

        // Sources/App/PhotoAppApp.swift, item "Copy Settings".
        static func menuCopy(_ c: PhotoActionContext) -> Bool {
            c.editorPopoverOpen || c.mode == .cull || !c.hasOpenImage
        }

        // Sources/App/PhotoAppApp.swift, item "Create Virtual Copy".
        static func menuVirtualCopy(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.editorPopoverOpen || c.mode == .cull || t.virtualCopyCount == 0
                || c.renameWorking || c.renameSheet || c.loadInFlight || c.mergeBusy
                || c.fileToolBusy || c.keywordSheetOpen || c.infoSheetOpen || c.duplicatesSheetOpen || c.peopleSheetOpen || c.autoStackSheetOpen
        }

        // Sources/App/PhotoAppApp.swift, item "Edit Keywords…": `keywordsLibraryBlocked` (the library branch of EditorKeywordsMenuRules).
        static func menuKeywords(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.mode == .cull || t.count == 0 || c.keywordSheetOpen || c.infoSheetOpen || c.renameWorking || c.renameSheet
        }

        // Sources/App/PhotoAppApp.swift, item "Edit Info…": `infoLibraryBlocked`.
        static func menuInfo(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.mode == .cull || t.count == 0 || c.keywordSheetOpen || c.infoSheetOpen
                || c.duplicatesSheetOpen || c.peopleSheetOpen || c.autoStackSheetOpen || c.mergeBusy || c.fileToolBusy
                || c.renameWorking || c.renameSheet
        }

        // Sources/App/PhotoAppApp.swift, items "Stack Selected" (count < 2) and "Unstack" (count == 0).
        static func menuStack(_ c: PhotoActionContext, _ t: PhotoActionTarget, minimum: Int) -> Bool {
            c.editorPopoverOpen || c.mode == .cull || c.mode != .library || t.count < minimum || c.autoStackSheetOpen || c.autoStackWorking
                || c.trashBusy || c.renameWorking || c.renameSheet
        }

        // Sources/App/PhotoAppApp.swift, items "Merge Photos to HDR…" / "Merge Photos to Panorama…".
        static func menuMerge(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.mode == .cull || c.mode != .library || t.visibleCount < 2 || c.mergeBusy
                || c.peopleSheetOpen || c.autoStackSheetOpen || c.duplicatesSheetOpen || c.keywordSheetOpen || c.infoSheetOpen
                || c.renameWorking || c.renameSheet || c.loadInFlight
        }

        // Sources/App/PhotoAppApp.swift, items "Write Metadata to XMP…" / "Read Metadata from XMP…".
        static func menuXMP(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.mode == .cull || c.mode != .library || t.visibleCount == 0 || c.fileToolBusy || c.mergeBusy
                || c.peopleSheetOpen || c.autoStackSheetOpen || c.duplicatesSheetOpen || c.keywordSheetOpen || c.infoSheetOpen
                || c.renameWorking || c.renameSheet || c.loadInFlight
        }

        // Sources/App/PhotoAppApp.swift, item "Rename Files…".
        static func menuRename(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            c.mode == .cull || t.count == 0 || c.renameWorking || c.loadInFlight || c.mergeBusy || c.fileToolBusy
                || c.keywordSheetOpen || c.infoSheetOpen || c.duplicatesSheetOpen || c.peopleSheetOpen || c.autoStackSheetOpen
        }

        // Sources/UI/ContentView.swift, `libraryToolbarItems`, selection menu. `selectedPhotosVisibleInGrid` = selectedPhotos (count).
        static func toolbarCollection(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool { !c.hasCollections || t.count == 0 }
        static func toolbarLocate(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool { t.count == 0 || c.renameInProgress }
        static func toolbarKeywords(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool { t.count == 0 || c.otherSheetIsPresented }
        static func toolbarInfo(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool { t.count == 0 || c.otherSheetIsPresented }
        static func toolbarStack(_ c: PhotoActionContext, _ t: PhotoActionTarget, minimum: Int) -> Bool {
            t.count < minimum || c.otherSheetIsPresented || c.autoStackSheetOpen || c.autoStackWorking
        }
        static func toolbarMerge(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            t.visibleCount < 2 || c.otherSheetIsPresented || c.mergeBusy || c.loadInFlight
        }
        static func toolbarXMP(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            t.visibleCount == 0 || c.otherSheetIsPresented || c.fileToolBusy || c.mergeBusy || c.loadInFlight
        }
        static func toolbarRename(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            t.count == 0 || c.renameWorking || c.renameSheet || c.loadInFlight || c.mergeBusy || c.fileToolBusy
        }
        static func toolbarTrash(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            t.visibleCount == 0 || c.otherSheetIsPresented || c.fileToolBusy || c.mergeBusy || c.renameWorking || c.loadInFlight
        }
        static func toolbarPaste(_ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
            !c.hasCopiedSettings || t.count == 0 || c.loadInFlight || c.renameWorking
        }

        // Sources/UI/LibraryGridView.swift, cell menu, item "Create Virtual Copy": `.disabled(isMissing)`.
        static func cellVirtualCopy(_ t: PhotoActionTarget) -> Bool { t.cell?.isMissing ?? false }
    }

    /// Items only the plan puts behind the Library (no old expression named it) or behind cull / the popover (no old surface that
    /// can be reached then names it): added to the old union so the comparison covers the whole model.
    private func planAddition(_ action: PhotoActionID, _ c: PhotoActionContext) -> Bool {
        let libraryOnly: Set<PhotoActionID> = [.ratingMenu, .flagMenu, .labelMenu, .openInEditor, .clearSelection, .collectionMenu, .locate, .moveToTrash, .stackSelected, .unstack, .mergeHDR, .mergePanorama, .writeXMP, .readXMP]
        let popoverExempt: Set<PhotoActionID> = [.editKeywords, .editInfo, .renameFiles]
        return c.mode == .cull || (c.editorPopoverOpen && !popoverExempt.contains(action)) || (libraryOnly.contains(action) && c.mode != .library)
    }

    private func oldDisabled(_ action: PhotoActionID, _ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
        let old: Bool
        switch action {
        case .editKeywords: old = Reference.menuKeywords(c, t) || Reference.toolbarKeywords(c, t)
        case .editInfo: old = Reference.menuInfo(c, t) || Reference.toolbarInfo(c, t)
        case .pasteSettings: old = Reference.menuPaste(c, t) || Reference.toolbarPaste(c, t)
        case .stackSelected: old = Reference.menuStack(c, t, minimum: 2) || Reference.toolbarStack(c, t, minimum: 2)
        case .unstack: old = Reference.menuStack(c, t, minimum: 1) || Reference.toolbarStack(c, t, minimum: 1)
        case .createVirtualCopy: old = Reference.menuVirtualCopy(c, t) || Reference.cellVirtualCopy(t)
        case .mergeHDR, .mergePanorama: old = Reference.menuMerge(c, t) || Reference.toolbarMerge(c, t)
        case .writeXMP, .readXMP: old = Reference.menuXMP(c, t) || Reference.toolbarXMP(c, t)
        case .renameFiles: old = Reference.menuRename(c, t) || Reference.toolbarRename(c, t)
        case .locate: old = Reference.toolbarLocate(c, t)
        case .moveToTrash: old = Reference.toolbarTrash(c, t)
        case .collectionMenu: old = Reference.toolbarCollection(c, t)
        case .copySettings: old = Reference.menuCopy(c)
        // Sources/UI/ContentView.swift `libraryToolbarItems`, item "Clear Selection": no `.disabled` at all (D33).
        case .clearSelection: old = false
        // Sources/UI/ContentView.swift ~1738, the toolbar Export button: `photosToExport.isEmpty || exportModel.isExporting || renameModel.isWorking`.
        case .export: old = t.count == 0 || c.renameWorking
        // Sources/UI/LibraryGridView.swift cell menu: the star/flag/label taps, Make Cover, Remove from Stack, Remove from Library and
        // the open action carry no `.disabled` at all.
        case .ratingMenu, .flagMenu, .labelMenu, .openInEditor, .makeCover, .removeFromStack, .removeFromLibrary: old = false
        default: XCTFail("no reference for \(action)"); old = false
        }
        return old || planAddition(action, c) || planGate(action, c, t)
    }

    /// Gates the model adds that no old expression had, named one by one: a menu needs at least one target photo; Export also waits for
    /// its options sheet (`exportActive` is `isPresentingOptions || isExporting`, the old button only read `isExporting`); Open in Editor
    /// waits for a rename.
    private func planGate(_ action: PhotoActionID, _ c: PhotoActionContext, _ t: PhotoActionTarget) -> Bool {
        switch action {
        case .ratingMenu, .flagMenu, .labelMenu, .makeCover, .removeFromStack, .removeFromLibrary: return t.count == 0
        case .openInEditor: return t.count == 0 || c.renameWorking
        case .export: return c.exportActive
        default: return false
        }
    }

    private let compared: [PhotoActionID] = [
        .editKeywords, .editInfo, .pasteSettings, .stackSelected, .unstack, .createVirtualCopy, .mergeHDR, .mergePanorama,
        .writeXMP, .readXMP, .renameFiles, .locate, .moveToTrash, .collectionMenu, .copySettings, .clearSelection, .export,
        .ratingMenu, .flagMenu, .labelMenu, .openInEditor, .makeCover, .removeFromStack, .removeFromLibrary
    ]

    private func assertSameAsOld(_ c: PhotoActionContext, _ target: PhotoActionTarget, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        // The menu-bar contract: Copy Settings copies the open photo whatever the Library selection is, so a menu-bar target has
        // `isOpenPhoto == hasOpenImage` (see `PhotoActionTarget.isOpenPhoto`). The cell/bar restriction is `testCopySettingsOnACellNeedsTheOpenPhoto`.
        var t = target
        t.isOpenPhoto = c.hasOpenImage
        for action in compared {
            XCTAssertEqual(enabled(action, t, c), !oldDisabled(action, c, t), "\(action) \(note)", file: file, line: line)
        }
    }

    func testEnabledRulesEqualTheUnionOfTheOldExpressionsForEverySingleFlag() {
        let flags: [WritableKeyPath<PhotoActionContext, Bool>] = [
            \.editorPopoverOpen, \.loadInFlight, \.renameWorking, \.renameSheet, \.renameInProgress, \.exportActive, \.pastePending,
            \.hasCopiedSettings, \.hasOpenImage, \.mergeBusy, \.fileToolBusy, \.trashBusy, \.keywordSheetOpen, \.infoSheetOpen,
            \.duplicatesSheetOpen, \.peopleSheetOpen, \.autoStackSheetOpen, \.autoStackWorking, \.hasCollections
        ]
        let targets = [selection, .empty, PhotoActionTarget(count: 1, visibleCount: 1, virtualCopyCount: 1, isOpenPhoto: true, cell: .init(isMissing: true))]
        for mode in [PhotoActionContext.Mode.library, .editor, .cull] {
            for target in targets {
                var base = library
                base.mode = mode
                assertSameAsOld(base, target, "baseline \(mode)")
                for (index, flag) in flags.enumerated() {
                    var context = base
                    context[keyPath: flag].toggle()
                    assertSameAsOld(context, target, "flag \(index) \(mode)")
                }
            }
        }
    }

    func testEnabledRulesEqualTheUnionOfTheOldExpressionsOverSeededRandomContexts() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
        for round in 0..<2_000 {
            var c = PhotoActionContext()
            c.mode = [.library, .library, .editor, .cull][Int(next() % 4)]
            c.editorPopoverOpen = chance(15)
            c.loadInFlight = chance(25)
            c.renameWorking = chance(15)
            c.renameSheet = chance(15)
            c.renameInProgress = chance(15)
            c.exportActive = chance(15)
            c.pastePending = chance(15)
            c.hasCopiedSettings = chance(60)
            c.hasOpenImage = chance(60)
            c.mergeBusy = chance(15)
            c.fileToolBusy = chance(15)
            c.trashBusy = chance(15)
            c.keywordSheetOpen = chance(15)
            c.infoSheetOpen = chance(15)
            c.duplicatesSheetOpen = chance(15)
            c.peopleSheetOpen = chance(15)
            c.autoStackSheetOpen = chance(15)
            c.autoStackWorking = chance(15)
            c.hasCollections = chance(70)
            let count = Int(next() % 4)
            var t = PhotoActionTarget(count: count, visibleCount: count == 0 ? 0 : Int(next() % UInt64(count + 1)),
                                      virtualCopyCount: Int(next() % 4), isOpenPhoto: chance(50))
            if chance(40) { t.cell = .init(isMissing: chance(40), inStack: chance(40), isCover: chance(50), isVirtualCopy: chance(30)) }
            assertSameAsOld(c, t, "round \(round)")
        }
    }

    func testCopySettingsOnACellNeedsTheOpenPhoto() {
        // The plan's addition (the menu bar's Copy Settings is not subject to it): a cell or bar target is enabled only when the open
        // photo is among its photos.
        var open = PhotoActionTarget(count: 1, visibleCount: 1, isOpenPhoto: true, cell: .init())
        XCTAssertTrue(enabled(.copySettings, open, library))
        open.isOpenPhoto = false
        XCTAssertFalse(enabled(.copySettings, open, library))
    }

    func testCopySettingsNeedsAnOpenImage() {
        var context = library
        context.hasOpenImage = false
        XCTAssertFalse(enabled(.copySettings, selection, context))
    }

    // MARK: Mutation anchor

    /// Pins two rules by name so a weakened rule shows up here, not only in the sweep.
    func testTwoRulesPinnedByName() {
        var merging = library
        merging.mergeBusy = true
        XCTAssertFalse(enabled(.mergeHDR, selection, merging))
        var trashing = library
        trashing.fileToolBusy = true
        XCTAssertFalse(enabled(.moveToTrash, selection, trashing))
    }
}
