import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// Dragging thumbnails onto a sidebar collection: the pure rules, the payload type, and the model's add path.
final class SidebarDropTests: XCTestCase {
    private func photo(_ id: Int64) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: 1, importedAt: Date(timeIntervalSince1970: 0), rating: 0)
    }
    private func plain(_ id: Int64) -> StackGridItem {
        StackGridItem(photo: photo(id), role: .plain, stackID: nil, visibleMembers: [], hiddenMemberCount: 0, isCover: false)
    }
    private func collapsed(cover: Int64, members: [Int64]) -> StackGridItem {
        StackGridItem(photo: photo(cover), role: .collapsedStack, stackID: 1, visibleMembers: members.map(photo),
                      hiddenMemberCount: members.count - 1, isCover: true)
    }

    // MARK: What is dragged

    func testASelectedCellDragsTheWholeSelectionSorted() {
        XCTAssertEqual(SidebarDrop.draggedIDs(for: plain(5), selection: [9, 5, 2]), [2, 5, 9])
    }

    func testAnUnselectedCellDragsOnlyItself() {
        XCTAssertEqual(SidebarDrop.draggedIDs(for: plain(7), selection: [9, 5, 2]), [7])
    }

    func testACollapsedStackDragsAllItsVisibleMembers() {
        XCTAssertEqual(SidebarDrop.draggedIDs(for: collapsed(cover: 2, members: [2, 3, 4]), selection: []), [2, 3, 4])
    }

    func testAPartlySelectedStackCountsAsUnselected() {
        XCTAssertEqual(SidebarDrop.draggedIDs(for: collapsed(cover: 2, members: [2, 3]), selection: [2, 8]), [2, 3])
    }

    func testAgreesWithTheRightClickTarget() {
        for selection: Set<Int64> in [[], [1], [2, 3], [2, 3, 9], [3]] {
            let item = collapsed(cover: 2, members: [2, 3])
            let target = PhotoActionMenu.clickTarget(cellIDs: StackSelection.ids(for: item), selection: selection)
            let dragged = SidebarDrop.draggedIDs(for: item, selection: selection)
            switch target {
            case .selection: XCTAssertEqual(dragged, selection.sorted(), "\(selection)")
            case .cell(let ids): XCTAssertEqual(dragged, ids, "\(selection)")
            }
        }
    }

    // MARK: Where it can be dropped

    func testOnlyAPlainCollectionAccepts() {
        let album = PhotoCollection(id: 1, name: "A", createdAt: Date())
        let folder = PhotoCollection(id: 2, name: "F", createdAt: Date(), parentId: nil, isFolder: true, folderPath: "/f")
        let smart = SmartCollection(id: 3, name: "S", criteria: SmartCollectionCriteria(), createdAt: Date())
        let rows = SidebarRows.rows(collections: [album, folder], smartCollections: [smart], expandedFolders: [], editing: .newCollection)
        func accepts(_ id: String) -> Bool { rows.first { $0.id == id }.map(SidebarDrop.accepts) ?? true }
        XCTAssertTrue(accepts("collection-1"))
        XCTAssertFalse(accepts("all"))
        XCTAssertFalse(accepts("smart-3"))
        XCTAssertFalse(accepts("folder-2"))
        XCTAssertFalse(accepts("header-collections"))
        XCTAssertFalse(accepts(SidebarRows.draftCollectionID))
    }

    // MARK: Result and feedback

    func testResultSplitsAddedAlreadyInAndMissing() {
        let result = SidebarDrop.result(dragged: [1, 2, 3, 4, 4], existingMembers: [2], knownIDs: [1, 2, 3])
        XCTAssertEqual(result, SidebarDrop.Result(added: [1, 3], alreadyIn: 1, missing: 1))
    }

    func testFeedbackKindsComeFromTheClassifier() {
        let done = SidebarDrop.feedback(.init(added: [1, 2, 3], alreadyIn: 2, missing: 0), collectionName: "Trips")
        XCTAssertEqual(done.kind, .done)
        XCTAssertEqual(done.message, "Added 3 photos to \u{201C}Trips\u{201D}. (2 were already in it)")
        let none = SidebarDrop.feedback(.init(added: [], alreadyIn: 2, missing: 0), collectionName: "Trips")
        XCTAssertEqual(none.kind, .nothingToDo)
        let incomplete = SidebarDrop.feedback(.init(added: [1], alreadyIn: 0, missing: 1), collectionName: "Trips")
        XCTAssertEqual(incomplete.kind, .incomplete)
        XCTAssertEqual(incomplete.presentation, .alert, "anything not written is an alert")
    }

    // MARK: Payload type

    func testThePayloadIsNeverAURLFileOrImage() {
        let type = UTType.lightbenchLibraryPhotos
        XCTAssertFalse(type.conforms(to: .url))
        XCTAssertFalse(type.conforms(to: .fileURL))
        XCTAssertFalse(type.conforms(to: .image))
        XCTAssertTrue(type.conforms(to: .data))
    }

    func testThePayloadIsVisibleOnlyInsideThisApp() throws {
        // Without `.ownProcess` Finder accepts the drag and creates an unopenable file on the Desktop (found by hand 2026-11-27).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/UI/LibraryPhotoDrag.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".visibility(.ownProcess)"))
    }

    func testTheTypeIsDeclaredInProjectYml() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let plist = try String(contentsOf: root.appendingPathComponent("Sources/App/Info.plist"), encoding: .utf8)
        XCTAssertTrue(yml.contains("com.photoapp.PhotoApp.library-photos"))
        XCTAssertTrue(plist.contains("com.photoapp.PhotoApp.library-photos"), "Info.plist and project.yml must stay in step")
    }

    // MARK: Wiring

    func testDraggableAppearsOnceAndTheGridHasNoDragGesture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let grid = try String(contentsOf: root.appendingPathComponent("Sources/UI/LibraryGridView.swift"), encoding: .utf8)
        XCTAssertEqual(grid.components(separatedBy: ".draggable(").count - 1, 1)
        XCTAssertFalse(grid.contains("DragGesture"))
    }
}

/// The model's add path: counts at once, the result posted only after the write lands.
@MainActor
final class CatalogModelAddPhotosTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, PhotoCollection, [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        let node = FolderScanNode(url: URL(fileURLWithPath: "/tmp/drop"),
                                  imageFiles: ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/drop/\($0).jpg") }, children: [])
        _ = try await db.importFolderTree(node)
        let photos = try await db.allPhotos().sorted { $0.filename < $1.filename }
        let album = try await db.createCollection(name: "Album")
        suiteName = "CatalogModelAddPhotosTests-\(UUID().uuidString)"
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        await model.refresh()
        return (model, db, album, photos)
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testDropUpdatesTheCountAtOnceAndPostsDoneAfterTheWrite() async throws {
        let (model, db, album, photos) = try await makeModel()
        let albumID = try XCTUnwrap(album.id)
        model.addPhotos(ids: photos.compactMap(\.id), to: album)
        XCTAssertEqual(model.collectionPhotoCounts[albumID], 3, "the number changes at once")
        try await waitUntil("the feedback") { !model.postedFeedback.isEmpty }
        XCTAssertEqual(model.postedFeedback.last?.kind, .done)
        let stored = try await db.photos(inCollection: albumID)
        XCTAssertEqual(stored.count, 3, "posted only after the write landed")
    }

    func testDroppingPhotosAlreadyInPostsNothingToDo() async throws {
        let (model, _, album, photos) = try await makeModel()
        model.addPhotos(ids: photos.compactMap(\.id), to: album)
        try await waitUntil("first feedback") { !model.postedFeedback.isEmpty }
        model.addPhotos(ids: photos.compactMap(\.id), to: album)
        try await waitUntil("second feedback") { model.postedFeedback.count == 2 }
        XCTAssertEqual(model.postedFeedback.last?.kind, .nothingToDo)
    }

    func testAnUnknownPhotoIsReportedAsNotAdded() async throws {
        let (model, _, album, photos) = try await makeModel()
        model.addPhotos(ids: [photos[0].id ?? 0, 999_999], to: album)
        try await waitUntil("feedback") { !model.postedFeedback.isEmpty }
        XCTAssertEqual(model.postedFeedback.last?.kind, .incomplete)
    }

    func testTheSelectionWrapperStaysSilent() async throws {
        let (model, db, album, photos) = try await makeModel()
        model.setSelection(Set(photos.compactMap(\.id)))
        model.addSelectedPhotos(to: album)
        let albumID = try XCTUnwrap(album.id)
        try await waitUntil("the write") { try await db.photos(inCollection: albumID).count == 3 }
        XCTAssertTrue(model.postedFeedback.isEmpty)
    }
}
