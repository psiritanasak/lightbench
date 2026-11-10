import Combine
import XCTest
@testable import PhotoApp

/// `CatalogModel`'s grid selection store (`CatalogModel+GridSelection`): the anchor's lifetime and the setters. In-memory catalog.
@MainActor
final class CatalogModelGridSelectionTests: XCTestCase {
    private var db: CatalogDatabase!
    private var ids: [Int64] = []
    private let suiteName = "CatalogModelGridSelectionTests-\(UUID().uuidString)"

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...6).map { URL(fileURLWithPath: "/tmp/gsel/s\($0).jpg") })
        ids = []
        for index in 1...6 { let row = try await db.photo(atPath: "/tmp/gsel/s\(index).jpg")
            ids.append(try XCTUnwrap(row?.id)) }
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

    func testChangingTheSidebarFilterClearsTheSelectionAndTheAnchor() async throws {
        let model = try await makeModel()
        model.selectOnlyGridCell(try XCTUnwrap(model.gridPhotos.first))
        XCTAssertFalse(model.selectedPhotoIDs.isEmpty)
        XCTAssertNotNil(model.gridSelectionAnchor)
        model.selectedFilter = .collection(999)
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
        XCTAssertNil(model.gridSelectionAnchor)
    }

    func testClearSelectionDropsTheAnchor() async throws {
        let model = try await makeModel()
        model.selectOnlyGridCell(try XCTUnwrap(model.gridPhotos.first))
        model.clearSelection()
        XCTAssertNil(model.gridSelectionAnchor)
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    }

    func testTheCheckboxToggleSetsTheAnchorLikeACommandClick() async throws {
        let model = try await makeModel()
        let cells = model.gridPhotos
        model.toggleSelection(of: cells[1])
        XCTAssertEqual(model.selectedPhotoIDs, [try XCTUnwrap(cells[1].photo.id)])
        XCTAssertEqual(model.gridSelectionAnchor?.key, cells[1].photo.editKey)
        XCTAssertEqual(model.gridSelectionAnchor?.base, [])
        model.toggleSelection(of: cells[1])
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
    }

    func testExtendWritesSelectionFocusAndAnchor() async throws {
        let model = try await makeModel()
        let cells = model.gridPhotos
        model.selectOnlyGridCell(cells[1])
        XCTAssertTrue(model.extendGridSelection(toCellAt: 3, in: cells))
        XCTAssertEqual(model.selectedPhotoIDs, Set(cells[1...3].compactMap(\.photo.id)))
        XCTAssertEqual(model.focusedPhotoPath, cells[3].photo.editKey)
        XCTAssertEqual(model.gridSelectionAnchor?.key, cells[1].photo.editKey)
        XCTAssertFalse(model.extendGridSelection(toCellAt: 99, in: cells))
    }

    func testAPlainArrowStyleMoveReplacesAMultiSelection() async throws {
        let model = try await makeModel()
        let cells = model.gridPhotos
        model.selectOnlyGridCell(cells[0])
        model.extendGridSelection(toCellAt: 3, in: cells)
        XCTAssertEqual(model.selectedPhotoIDs.count, 4)
        model.selectOnlyGridCell(cells[4])
        XCTAssertEqual(model.selectedPhotoIDs, [try XCTUnwrap(cells[4].photo.id)])
        XCTAssertEqual(model.focusedPhotoPath, cells[4].photo.editKey)
        XCTAssertTrue(model.extendGridSelection(toCellAt: 5, in: cells))
        XCTAssertEqual(model.selectedPhotoIDs, Set(cells[4...5].compactMap(\.photo.id)))
    }

    func testSelectAllGridCellsSelectsExactlyTheDisplayedPhotos() async throws {
        let model = try await makeModel()
        _ = try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        await model.refresh()
        XCTAssertLessThan(model.gridPhotos.count, model.displayedPhotos.count)
        model.selectAllGridCells(in: model.gridPhotos)
        XCTAssertEqual(model.selectedPhotoIDs, Set(model.displayedPhotos.compactMap(\.id)))
        XCTAssertNil(model.gridSelectionAnchor)
    }

    func testSelectionReadersKeepTheirMeaning() async throws {
        let model = try await makeModel()
        model.setRating(5, for: try XCTUnwrap(model.photos.first { $0.id == ids[0] }))
        model.setRating(5, for: try XCTUnwrap(model.photos.first { $0.id == ids[1] }))
        model.minimumRating = 5
        XCTAssertEqual(model.displayedPhotos.count, 2)
        model.selectAllGridCells(in: model.gridPhotos)
        XCTAssertEqual(model.selectedPhotosInDisplayedGrid.compactMap(\.id).sorted(), model.displayedPhotos.compactMap(\.id).sorted())
        XCTAssertTrue(Set(model.selectedPhotos.compactMap(\.id)).isSubset(of: Set(model.photos.compactMap(\.id))))
    }

    func testSetSelectionDoesNotPublishWhenUnchanged() async throws {
        let model = try await makeModel()
        model.setSelection([ids[0]])
        var emissions = 0
        let sub = model.objectWillChange.sink { emissions += 1 }
        model.setSelection([ids[0]])
        XCTAssertEqual(emissions, 0)
        model.setSelection([ids[1]])
        XCTAssertEqual(emissions, 1)
        sub.cancel()
    }

    func testClearGridSelectionReportsWhetherAnythingWasSelected() async throws {
        let model = try await makeModel()
        XCTAssertFalse(model.clearGridSelection())
        model.setSelection([ids[0]])
        XCTAssertTrue(model.clearGridSelection())
    }
}
