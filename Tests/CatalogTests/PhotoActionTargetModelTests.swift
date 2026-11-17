import XCTest
@testable import PhotoApp

/// `PhotoActionTarget.selection` against a real `CatalogModel`, and the cell menu's rating / flag / label scope end to end (without views).
@MainActor
final class PhotoActionTargetModelTests: XCTestCase {
    private var db: CatalogDatabase!
    private var ids: [Int64] = []
    private let suiteName = "PhotoActionTargetModelTests-\(UUID().uuidString)"

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...4).map { URL(fileURLWithPath: "/tmp/pat/t\($0).jpg") })
        ids = []
        for index in 1...4 {
            let row = try await db.photo(atPath: "/tmp/pat/t\(index).jpg")
            ids.append(try XCTUnwrap(row?.id))
        }
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        db = nil
    }

    private func makeModel() async throws -> CatalogModel {
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        await model.refresh()
        return model
    }

    func testSelectionTargetDropsGhostsAndHiddenPhotosFromTheVisibleCounts() async throws {
        _ = try await db.setRating(5, forPhotoIDs: [ids[0]])
        let model = try await makeModel()
        model.minimumRating = 3 // photo 1 (rating 5) shows; the others are hidden by the filter
        let shown = try XCTUnwrap(model.photos.first { $0.id == ids[0] })
        let hidden = try XCTUnwrap(model.photos.first { $0.id == ids[1] })
        model.setSelection([ids[0], ids[1], 99_999]) // 99_999 is a ghost: no such photo is loaded
        let cells = model.gridPhotos
        let selected = PhotoActionTarget.ghostFreeSelection(catalog: model, cells: cells)
        XCTAssertEqual(selected, [ids[0]], "no ghost, no filter-hidden photo")
        let target = PhotoActionTarget.selection(catalog: model, cells: cells, selectedIDs: selected, openEditKey: shown.editKey)
        XCTAssertEqual(target.count, model.selectedPhotos.count)
        XCTAssertEqual(target.count, 2, "count still holds the filter-hidden selected photo")
        XCTAssertEqual(target.visibleCount, model.selectedPhotosInDisplayedGrid.count)
        XCTAssertEqual(target.virtualCopyCount, model.selectedPhotosInDisplayedGrid.count)
        XCTAssertEqual(target.visibleCount, 1)
        XCTAssertEqual(target.ratings, [5])
        XCTAssertTrue(target.isOpenPhoto)
        let hiddenOpen = PhotoActionTarget.selection(catalog: model, cells: cells, selectedIDs: selected, openEditKey: hidden.editKey)
        XCTAssertFalse(hiddenOpen.isOpenPhoto, "the open photo is hidden by the filter, so it is not among the shown selection")
        model.setSelection([])
        XCTAssertEqual(PhotoActionTarget.selection(catalog: model, cells: cells, selectedIDs: [], openEditKey: nil), .empty)
    }

    /// The cell menu's flag on an UNSELECTED collapsed-stack cell changes the cover only (not every member, which would feed
    /// "Move Rejected to Trash"). Mirrors `LibraryGridView.runFromCell`: the plan decides the selection move and the written ids.
    func testFlagOnAnUnselectedCollapsedStackCellChangesTheCoverOnly() async throws {
        let model = try await makeModel()
        let members = ids.prefix(3).compactMap { id in model.photos.first { $0.id == id } }
        let item = StackGridItem(photo: members[0], role: .collapsedStack, stackID: 9, visibleMembers: members, hiddenMemberCount: 2, isCover: true)
        let selection = PhotoActionTarget.ghostFreeSelection(catalog: model, cells: [item])
        XCTAssertTrue(selection.isEmpty)
        let plan = PhotoActionMenu.cellPlan(for: item, hasCell: true, selection: selection)
        if plan.selectsCellFirst { model.selectOnlyGridCell(item) }
        XCTAssertEqual(model.selectedPhotoIDs, Set(ids.prefix(3)), "every other item now acts on the whole stack")
        let written = try await model.setFlagStatus(.rejected, forPhotoIDs: plan.batchIDs ?? model.selectedPhotosInDisplayedGrid.compactMap(\.id))
        XCTAssertEqual(written, [ids[0]])
        let flagged = Dictionary(uniqueKeysWithValues: model.photos.compactMap { p in p.id.map { ($0, p.flagStatus) } })
        XCTAssertEqual(flagged[ids[0]], .rejected)
        XCTAssertEqual(flagged[ids[1]], FlagStatus.none)
        XCTAssertEqual(flagged[ids[2]], FlagStatus.none)
    }

    /// A plain click on a collapsed stack selects every visible member; a right-click then Reject must still reject the cover only
    /// (like the X key), not the whole stack.
    func testClickThenRightClickRejectOnAStackRejectsTheCoverOnly() async throws {
        let model = try await makeModel()
        let members = ids.prefix(3).compactMap { id in model.photos.first { $0.id == id } }
        let item = StackGridItem(photo: members[0], role: .collapsedStack, stackID: 9, visibleMembers: members, hiddenMemberCount: 2, isCover: true)
        model.selectOnlyGridCell(item) // the click
        XCTAssertEqual(model.selectedPhotoIDs, Set(ids.prefix(3)))
        let selection = PhotoActionTarget.ghostFreeSelection(catalog: model, cells: [item])
        let selectionTarget = PhotoActionTarget.selection(catalog: model, cells: [item], selectedIDs: selection, openEditKey: nil)
        let target = PhotoActionTarget.forCell(item, isMissing: false, selection: selection, selectionTarget: selectionTarget, openEditKey: nil)
        let plan = PhotoActionMenu.cellPlan(for: item, hasCell: target.cell != nil, selection: selection)
        XCTAssertFalse(plan.selectsCellFirst)
        let written = try await model.setFlagStatus(.rejected, forPhotoIDs: plan.batchIDs ?? model.selectedPhotosInDisplayedGrid.compactMap(\.id))
        XCTAssertEqual(written, [ids[0]])
        let flagged = Dictionary(uniqueKeysWithValues: model.photos.compactMap { p in p.id.map { ($0, p.flagStatus) } })
        XCTAssertEqual(flagged[ids[0]], .rejected)
        XCTAssertEqual(flagged[ids[1]], FlagStatus.none)
        XCTAssertEqual(flagged[ids[2]], FlagStatus.none)
    }

    /// The selection bar's rating / flag / label (the performer with no clicked photo and no batch ids) writes every selected photo the
    /// grid SHOWS and none that the filters hide.
    func testBarCommandsWriteTheVisibleSelectionAndNotHiddenPhotos() async throws {
        _ = try await db.setRating(5, forPhotoIDs: [ids[0], ids[1]])
        let model = try await makeModel()
        model.minimumRating = 3 // photos 1 and 2 show; 3 and 4 are hidden
        model.setSelection([ids[0], ids[1], ids[2]]) // 3 is selected but hidden
        let performer = PhotoActionPerformer(
            catalog: model, document: ImageDocumentModel(), pasteModel: PasteSettingsModel(), renameModel: RenameModel(), showLibrary: true)
        performer.perform(.rate(2), clicked: nil)
        performer.perform(.flag(.rejected), clicked: nil)
        performer.perform(.label(.red), clicked: nil)
        // Poll the DATABASE row (the model updates its own list before the write lands).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let written = try await db.photo(atPath: "/tmp/pat/t2.jpg")
            if written?.colorLabel == .red && written?.rating == 2 && written?.flagStatus == .rejected { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        var rows: [Photo?] = []
        for n in 1...4 { rows.append(try await db.photo(atPath: "/tmp/pat/t\(n).jpg")) }
        for index in 0...1 {
            XCTAssertEqual(rows[index]?.rating, 2)
            XCTAssertEqual(rows[index]?.flagStatus, .rejected)
            XCTAssertEqual(rows[index]?.colorLabel, .red)
        }
        for index in 2...3 {
            XCTAssertEqual(rows[index]?.rating, 0, "hidden or unselected photos are untouched")
            XCTAssertEqual(rows[index]?.flagStatus, FlagStatus.none)
            XCTAssertEqual(rows[index]?.colorLabel, ColorLabel.none)
        }
    }
}
