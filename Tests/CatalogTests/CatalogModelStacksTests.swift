import XCTest
@testable import PhotoApp

/// `CatalogModel`'s stack state (`CatalogModel+Stacks`): what the grid draws, the selection rule for stacked cells, the manual stack
/// operations (with their hidden-by-filter disclosure) and the local-first sync when photos leave the library. In-memory catalog.
@MainActor
final class CatalogModelStacksTests: XCTestCase {
    private var db: CatalogDatabase!
    private var ids: [Int64] = []
    private let suiteName = "CatalogModelStacksTests-\(UUID().uuidString)"

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...6).map { URL(fileURLWithPath: "/tmp/stk/s\($0).jpg") })
        ids = []
        for index in 1...6 { ids.append(try need(try await db.photo(atPath: "/tmp/stk/s\(index).jpg")?.id)) }
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        db = nil
    }

    private func makeModel() async -> CatalogModel {
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        await model.refresh()
        return model
    }

    private func photo(_ model: CatalogModel, _ index: Int) throws -> Photo {
        try XCTUnwrap(model.photos.first { $0.id == ids[index - 1] })
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 3, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func gridIDs(_ model: CatalogModel) -> [Int64] { model.gridPhotos.compactMap(\.photo.id) }

    // MARK: Loading

    func testRefreshLoadsTheStacksAndTheByPhotoMap() async throws {
        let stackID = try await db.createStack(photoIDs: [ids[0], ids[3]], manual: true)
        let model = await makeModel()
        XCTAssertEqual(model.stacks.map(\.id), [try XCTUnwrap(stackID)])
        XCTAssertEqual(model.stack(of: try photo(model, 4))?.id, stackID)
        XCTAssertNil(model.stack(of: try photo(model, 2)))
    }

    func testExpandedFlagsOfVanishedStacksAreDropped() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        let model = await makeModel()
        model.toggleExpanded(stackID: stackID)
        XCTAssertTrue(model.expandedStackIDs.contains(stackID))
        try await db.dissolveStack(stackID: stackID)
        await model.refresh()
        XCTAssertTrue(model.expandedStackIDs.isEmpty, "a stack that no longer exists is not 'expanded'")
    }

    // MARK: The grid

    func testGridCollapsesAStackToOneCellWhileDisplayedPhotosStaysFlat() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[3]], manual: true, cover: ids[3])
        let model = await makeModel()
        XCTAssertEqual(model.displayedPhotos.count, 6, "the flat list every other tool reads is untouched")
        XCTAssertEqual(gridIDs(model), [ids[3], ids[1], ids[2], ids[4], ids[5]], "the stack cell (cover s4) sits where s1, its first visible member, was")
        XCTAssertEqual(model.gridPhotos.first?.role, .collapsedStack)
        XCTAssertEqual(model.gridPhotos.first?.hiddenMemberCount, 1)
        XCTAssertEqual(model.gridCellPhotos.count, 5)
    }

    func testExpandedMembersStayContiguousAtTheFirstPositionUnderANonDateSort() async throws {
        try await db.setRating(5, for: ids[3])
        try await db.setRating(1, for: ids[0])
        for index in [1, 2, 4, 5] { try await db.setRating(3, for: ids[index]) }
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[3]], manual: true))
        let model = await makeModel()
        model.sortOption = .ratingHighToLow
        let flat = model.displayedPhotos.compactMap(\.id)
        XCTAssertEqual(flat.first, ids[3], "the 5-star member is first, the 1-star member last: scattered in the flat list")
        XCTAssertEqual(flat.last, ids[0])
        model.toggleExpanded(stackID: stackID)
        let expanded = gridIDs(model)
        XCTAssertEqual(Array(expanded.prefix(2)), [ids[3], ids[0]], "both members as one run at the first member's position")
        XCTAssertEqual(expanded.count, 6)
        XCTAssertTrue(model.gridPhotos.prefix(2).allSatisfy { $0.role == .expandedMember })
    }

    func testAFilterThatHidesTheCoverShowsTheFirstVisibleMember() async throws {
        for index in [1, 3] { try await db.setRating(4, for: ids[index]) }
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[3]], manual: true, cover: ids[0])
        let model = await makeModel()
        model.minimumRating = 4
        let cells = model.gridPhotos
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].role, .collapsedStack)
        XCTAssertEqual(cells[0].photo.id, ids[1], "the cover (s1) is filtered out; the first visible member stands in")
        XCTAssertEqual(cells[0].hiddenMemberCount, 1)
    }

    func testAStackWithOneVisibleMemberIsAPlainPhoto() async throws {
        try await db.setRating(4, for: ids[1])
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let model = await makeModel()
        model.minimumRating = 4
        XCTAssertEqual(model.gridPhotos.map(\.role), [.plain])
        XCTAssertEqual(model.gridPhotos.first?.photo.id, ids[1])
    }

    func testAHiddenMemberCannotHoldKeyboardFocusCells() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        let cellIDs = Set(model.gridCellPhotos.compactMap(\.id))
        XCTAssertFalse(cellIDs.contains(ids[1]))
        XCTAssertFalse(cellIDs.contains(ids[2]))
        XCTAssertEqual(LibraryNavigation.neighbor(of: try photo(model, 1).editKey, in: model.gridCellPhotos, offset: 1)?.id, ids[3],
                       "arrow movement steps over the hidden members")
    }

    func testCollapsingMovesFocusFromAHiddenMemberToTheStackCell() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0]))
        let model = await makeModel()
        model.toggleExpanded(stackID: stackID)
        model.focusedPhotoPath = try photo(model, 2).editKey // a non-cover member, visible while expanded
        model.toggleExpanded(stackID: stackID)
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 1).editKey, "focus follows the member into its collapsed cell")
    }

    func testCollapsingLeavesFocusAloneWhenItIsStillACell() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0]))
        let model = await makeModel()
        model.toggleExpanded(stackID: stackID)
        model.focusedPhotoPath = try photo(model, 5).editKey
        model.toggleExpanded(stackID: stackID)
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 5).editKey)
    }

    // MARK: Selection of cells

    func testTickingACollapsedStackSelectsEveryVisibleMemberAndTickingAgainClearsThem() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        let cell = try XCTUnwrap(model.gridPhotos.first)
        XCTAssertFalse(model.isSelected(cell))
        model.toggleSelection(of: cell)
        XCTAssertEqual(model.selectedPhotoIDs, Set([ids[0], ids[1], ids[2]]))
        XCTAssertTrue(model.isSelected(cell))
        model.toggleSelection(of: cell)
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    }

    func testTickingACoverDoesNotSelectMembersTheFiltersHide() async throws {
        for index in [0, 1] { try await db.setRating(4, for: ids[index]) }
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        model.minimumRating = 4
        model.toggleSelection(of: try XCTUnwrap(model.gridPhotos.first))
        XCTAssertEqual(model.selectedPhotoIDs, Set([ids[0], ids[1]]), "only the visible members: the badge counts what the grid shows")
    }

    func testAnExpandedMemberTicksAlone() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        let model = await makeModel()
        model.toggleExpanded(stackID: stackID)
        model.toggleSelection(of: try XCTUnwrap(model.gridPhotos.first { $0.photo.id == ids[1] }))
        XCTAssertEqual(model.selectedPhotoIDs, [ids[1]])
    }

    func testAPartlySelectedCollapsedStackReadsAsUnticked() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let model = await makeModel()
        model.select([ids[0]])
        let cell = try XCTUnwrap(model.gridPhotos.first)
        XCTAssertFalse(model.isSelected(cell))
        model.toggleSelection(of: cell)
        XCTAssertEqual(model.selectedPhotoIDs, Set([ids[0], ids[1]]), "the next tick completes it")
    }

    // MARK: Manual operations

    func testStackSelectedStacksTheSelectionAndDisclosesHiddenPhotos() async throws {
        try await db.setRating(4, for: ids[0])
        let model = await makeModel()
        model.select([ids[0], ids[1], ids[2]])
        model.minimumRating = 4 // only s1 is shown; s2 and s3 are selected but hidden
        await model.stackSelected()
        XCTAssertEqual(model.stacks.count, 1)
        XCTAssertEqual(Set((model.stacks.first?.memberIDs ?? [])), Set([ids[0], ids[1], ids[2]]), "hidden selected photos are stacked too, like Edit Keywords")
        XCTAssertTrue((model.stacks.first?.isManual == true))
        XCTAssertEqual(model.importStatusMessage, "Stacked 3 photos, including 2 hidden by the current filters.")
    }

    func testStackSelectedWithOnePhotoSaysSoAndChangesNothing() async throws {
        let model = await makeModel()
        model.select([ids[0]])
        await model.stackSelected()
        XCTAssertTrue(model.stacks.isEmpty)
        XCTAssertEqual(model.importStatusMessage, "Select at least two photos to stack.")
    }

    func testStackSelectedWithoutHiddenPhotosIsSilent() async throws {
        let model = await makeModel()
        model.select([ids[0], ids[1]])
        await model.stackSelected()
        XCTAssertEqual(model.stacks.count, 1)
        XCTAssertNil(model.importStatusMessage)
    }

    func testUnstackRemovesOnlyTheSelectedPhotosAndKeepsTheRestStacked() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2], ids[3]], manual: true)
        let model = await makeModel()
        model.select([ids[0]])
        await model.unstackSelected()
        XCTAssertEqual(model.stacks.first.map { Set($0.memberIDs) }, Set([ids[1], ids[2], ids[3]]), "unselected members stay stacked")
        let exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, [ids[0]], "only the photo taken out is remembered")
        XCTAssertEqual(model.importStatusMessage, "Removed 1 photo from their stacks. Auto Stack will not stack the removed photos again.")
    }

    func testUnstackOfAWholeCollapsedStackDissolvesItAndRemembersEveryMember() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        model.toggleSelection(of: try XCTUnwrap(model.gridPhotos.first)) // ticking the collapsed cover selects all members
        await model.unstackSelected()
        XCTAssertTrue(model.stacks.isEmpty)
        let exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, Set([ids[0], ids[1], ids[2]]))
        let message = try XCTUnwrap(model.importStatusMessage)
        XCTAssertTrue(message.contains("Removed 3 photos") && message.contains("1 stack ended"), message)
    }

    func testUnstackThatLeavesOnePhotoEndsTheStackAndSaysSo() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        model.select([ids[0], ids[1]])
        await model.unstackSelected()
        XCTAssertTrue(model.stacks.isEmpty, "a stack of one does not exist")
        let message = try XCTUnwrap(model.importStatusMessage)
        XCTAssertTrue(message.contains("1 stack ended (1 remaining photo is no longer stacked)"), message)
    }

    func testStackingPhotosOutOfAnotherStackSaysWhenThatDissolvesIt() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let model = await makeModel()
        model.select([ids[0], ids[4]]) // s1 leaves [s1, s2], which would be left with one photo
        await model.stackSelected()
        let message = try XCTUnwrap(model.importStatusMessage)
        XCTAssertTrue(message.contains("1 other stack was left with a single photo and dissolved"), message)
        XCTAssertEqual(model.stacks.count, 1)
    }

    // MARK: Focus follows a hidden member to its cell

    func testSetStacksMovesFocusOffAMemberThatIsNowHidden() async throws {
        let model = await makeModel()
        model.focusedPhotoPath = try photo(model, 2).editKey
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 2).editKey)
        let stack = StackSnapshot(id: 99, isManual: true, coverPhotoID: ids[0], memberIDs: [ids[0], ids[1]])
        model.setStacks([stack])
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 1).editKey, "s2 is hidden inside the collapsed stack; its cell is s1")
    }

    func testStackSelectedMovesFocusToTheNewStackCell() async throws {
        let model = await makeModel()
        model.select([ids[0], ids[1]])
        model.focusedPhotoPath = try photo(model, 2).editKey
        await model.stackSelected()
        XCTAssertEqual(model.focusedPhotoPath, model.gridPhotos.first?.photo.editKey)
    }

    func testUnstackLeavesFocusOnAVisibleCell() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        let model = await makeModel()
        model.toggleExpanded(stackID: stackID)
        model.focusedPhotoPath = try photo(model, 2).editKey
        model.select([ids[0], ids[1]])
        await model.unstackSelected()
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 2).editKey, "no stack: every photo is its own cell")
    }

    func testRefreshNormalisesFocus() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0])
        let model = await makeModel()
        model.focusedPhotoPath = try photo(model, 2).editKey // set behind the model's back, e.g. by Cull
        await model.refresh()
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 1).editKey)
    }

    func testApplyAutoStackNormalisesFocus() async throws {
        let model = await makeModel()
        model.autoStack.seams.apply = { [db = self.db!, ids = self.ids] _, _ in
            _ = try await db.createStack(photoIDs: [ids[0], ids[1]], manual: false, cover: ids[0])
            return 1
        }
        model.autoStack.seams.environment = DuplicateScanner.Environment(stat: { _ in (1000, 1) }, hash: { _ in nil }, featurePrint: { _ in nil })
        model.autoStack.seams.plan = { candidates, _ in StackPlan(proposals: [StackProposal(memberIDs: candidates.map(\.id).sorted())], plannedIDs: candidates.map(\.id).sorted()) }
        model.autoStack.seams.persist = { _ in }
        var metadata: [Int64: PhotoMetadata] = [:]
        for id in ids { metadata[id] = PhotoMetadata(photoId: id, fileSize: 1, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision, captureDate: 1_000_000, scannedAt: Date()) }
        model.autoStack.begin(photos: model.photos, metadata: metadata, database: db)
        for _ in 0..<400 where model.autoStack.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        model.focusedPhotoPath = try photo(model, 2).editKey
        await model.applyAutoStack()
        XCTAssertEqual(model.focusedPhotoPath, try photo(model, 1).editKey)
    }

    // MARK: Mixed checkbox

    func testAPartlySelectedCollapsedStackHasAMixedSelectionState() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let model = await makeModel()
        let cell = try XCTUnwrap(model.gridPhotos.first)
        XCTAssertEqual(model.selectionState(of: cell), .none)
        model.select([ids[0]])
        XCTAssertEqual(model.selectionState(of: cell), .partial)
        model.select([ids[1]])
        XCTAssertEqual(model.selectionState(of: cell), .all)
    }

    func testUnstackOfPhotosInNoStackSaysSo() async throws {
        let model = await makeModel()
        model.select([ids[4]])
        await model.unstackSelected()
        XCTAssertEqual(model.importStatusMessage, "None of the selected photos is in a stack.")
    }

    func testMakeCoverChangesTheCellThatStandsForTheStack() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[0])
        let model = await makeModel()
        XCTAssertEqual(model.gridPhotos.first?.photo.id, ids[0])
        await model.makeCover(try photo(model, 2))
        XCTAssertEqual(model.stacks.first?.coverPhotoID, ids[1])
        XCTAssertEqual(model.gridPhotos.first?.photo.id, ids[1])
        XCTAssertTrue(model.stacks.first?.isManual == true, "touching a stack makes it manual")
    }

    func testRemoveFromStackLeavesTheOthersAndDissolvesATwoPhotoStack() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        await model.removeFromStack(try photo(model, 3))
        XCTAssertEqual(model.stacks.first.map { Set($0.memberIDs) }, Set([ids[0], ids[1]]))
        await model.removeFromStack(try photo(model, 2))
        XCTAssertTrue(model.stacks.isEmpty, "a stack of one does not exist")
        XCTAssertEqual(model.gridPhotos.count, 6)
    }

    // MARK: Photos leaving the library

    func testRemovingAMemberUpdatesTheStacksAtOnceAndAfterTheDeleteLands() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true, cover: ids[0])
        let model = await makeModel()
        model.removePhoto(try photo(model, 1)) // the cover
        XCTAssertEqual(model.stacks.first.map { Set($0.memberIDs) }, Set([ids[1], ids[2]]), "local-first, before the database answers")
        XCTAssertNil(model.stacks.first?.coverPhotoID)
        try await waitUntil("the database dropped the member") { try await self.db.allStacks().first?.memberIDs.count == 2 }
        XCTAssertEqual(model.stacks.count, 1)
    }

    func testRemovingTheSecondLastMemberDissolvesTheStackLocally() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let model = await makeModel()
        model.removePhoto(try photo(model, 2))
        XCTAssertTrue(model.stacks.isEmpty)
        XCTAssertEqual(model.gridPhotos.map(\.role), Array(repeating: .plain, count: 5))
        try await waitUntil("the trigger dissolved it in the database") { try await self.db.allStacks().isEmpty }
    }

    func testRemovingAVirtualCopyKeepsTheMastersStack() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let master = try need(try await db.photo(atPath: "/tmp/stk/s1.jpg"))
        _ = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        let model = await makeModel()
        let copy = try XCTUnwrap(model.photos.first { $0.isVirtualCopy })
        model.removePhoto(copy)
        XCTAssertEqual(model.stacks.count, 1)
        XCTAssertEqual(Set((model.stacks.first?.memberIDs ?? [])), Set([ids[0], ids[1]]))
    }

    func testTrashedPhotosLeaveTheirStacks() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let model = await makeModel()
        try await model.removeTrashedPhotos(ids: [ids[2]], paths: ["/tmp/stk/s3.jpg"])
        XCTAssertEqual(model.stacks.first.map { Set($0.memberIDs) }, Set([ids[0], ids[1]]))
        try await model.removeTrashedPhotos(ids: [ids[1]], paths: ["/tmp/stk/s2.jpg"])
        XCTAssertTrue(model.stacks.isEmpty)
        XCTAssertEqual(model.photoCount, 4)
    }

    // MARK: Busy flags

    func testTheAutoStackSheetCountsAsABusyToolSheet() async throws {
        let model = await makeModel()
        XCTAssertFalse(model.toolSheetIsBusy)
        model.autoStackSheetPresented = true
        XCTAssertTrue(model.toolSheetIsBusy, "batch rename must not start under the Auto Stack sheet")
        model.autoStackSheetPresented = false
        XCTAssertFalse(model.toolSheetIsBusy)
    }
}

private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
