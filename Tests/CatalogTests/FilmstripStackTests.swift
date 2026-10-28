import XCTest
@testable import PhotoApp

/// The Editor filmstrip's cells (`CatalogModel.filmstripItems`) and ⌘←/⌘→ over them. In-memory catalog.
@MainActor
final class FilmstripStackTests: XCTestCase {
    private var db: CatalogDatabase!
    private var ids: [Int64] = []
    private let suiteName = "FilmstripStackTests-\(UUID().uuidString)"

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...6).map { URL(fileURLWithPath: "/tmp/fst/s\($0).jpg") })
        ids = []
        for index in 1...6 { ids.append(try need(try await db.photo(atPath: "/tmp/fst/s\(index).jpg")?.id)) }
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

    private func key(_ model: CatalogModel, _ index: Int) throws -> String {
        try XCTUnwrap(model.photos.first { $0.id == ids[index - 1] }).editKey
    }

    private func cellIDs(_ items: [StackGridItem]) -> [Int64] { items.compactMap(\.photo.id) }

    func testWithoutStacksTheStripIsTheFlatList() async throws {
        let model = await makeModel()
        XCTAssertEqual(cellIDs(model.filmstripItems(openEditKey: nil)), model.displayedPhotos.compactMap(\.id))
        XCTAssertTrue(model.filmstripItems(openEditKey: nil).allSatisfy { $0.role == .plain })
    }

    func testACollapsedStackIsOneCellWhenAnotherPhotoIsOpen() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2], ids[3]], manual: true, cover: ids[2])
        let model = await makeModel()
        let items = model.filmstripItems(openEditKey: try key(model, 1))
        XCTAssertEqual(cellIDs(items), [ids[0], ids[2], ids[4], ids[5]])
        XCTAssertEqual(items[1].role, .collapsedStack)
        XCTAssertEqual(StackCellPresentation.badge(for: items[1]), .count(3))
    }

    func testOpeningAHiddenMemberExpandsItsStackLocallyOnly() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[1], ids[2], ids[3]], manual: true, cover: ids[2]))
        let model = await makeModel()
        let items = model.filmstripItems(openEditKey: try key(model, 4))
        XCTAssertEqual(cellIDs(items), [ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]])
        XCTAssertEqual(items.filter { $0.role == .expandedMember }.count, 3)
        XCTAssertTrue(model.expandedStackIDs.isEmpty, "the grid's expansion is not changed")
        XCTAssertEqual(model.gridPhotos.count, 4, "the grid still shows the stack collapsed")
        _ = stackID
    }

    func testOpeningTheCoverAlsoExpandsItsStack() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2]], manual: true, cover: ids[1])
        let model = await makeModel()
        let items = model.filmstripItems(openEditKey: try key(model, 2))
        XCTAssertEqual(items.filter { $0.role == .expandedMember }.count, 2)
    }

    func testOtherStacksStayCollapsedAndTheGridsExpandedOnesStayExpanded() async throws {
        let first = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        try await db.createStack(photoIDs: [ids[3], ids[4]], manual: true)
        let model = await makeModel()
        model.toggleExpanded(stackID: first)
        let items = model.filmstripItems(openEditKey: try key(model, 3))
        XCTAssertEqual(items.map(\.role), [.expandedMember, .expandedMember, .plain, .collapsedStack, .plain])
    }

    func testTheOpenPhotoOutsideTheDisplayedListExpandsNothing() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2]], manual: true)
        let model = await makeModel()
        let items = model.filmstripItems(openEditKey: "/not/in/the/library.jpg")
        XCTAssertEqual(items.filter { $0.role == .collapsedStack }.count, 1)
    }

    func testCellIDsAreStackAwareAndUnique() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2]], manual: true)
        let model = await makeModel()
        let collapsed = model.filmstripItems(openEditKey: nil).map(\.cellID)
        let expanded = model.filmstripItems(openEditKey: try key(model, 2)).map(\.cellID)
        XCTAssertEqual(Set(collapsed).count, collapsed.count)
        XCTAssertEqual(Set(expanded).count, expanded.count)
        let stackCollapsed = collapsed.filter { $0.hasPrefix("collapsed") }
        XCTAssertEqual(stackCollapsed.count, 1)
        XCTAssertTrue(expanded.filter { $0.hasPrefix("expanded") }.count == 2 && Set(stackCollapsed).isDisjoint(with: expanded),
                      "a photo that changes role gets a new cell id, so its view is rebuilt")
    }

    func testDisplayedPhotosAndSelectionStayFlat() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2]], manual: true)
        let model = await makeModel()
        _ = model.filmstripItems(openEditKey: try key(model, 2))
        XCTAssertEqual(model.displayedPhotos.count, 6)
        // The stack's cover cell is collapsed in the grid, yet every selected photo (hidden member included) is in the flat selection lists.
        model.select([ids[1], ids[2], ids[4]])
        XCTAssertEqual(Set(model.selectedPhotos.compactMap(\.id)), Set([ids[1], ids[2], ids[4]]))
        XCTAssertEqual(Set(model.selectedPhotosInDisplayedGrid.compactMap(\.id)), Set([ids[1], ids[2], ids[4]]))
        XCTAssertEqual(model.gridPhotos.count, 5, "the grid itself folds the stack")
    }

    func testWithNoStacksTheCheapPathStillMatchesStackDisplay() async throws {
        let model = await makeModel()
        XCTAssertEqual(model.filmstripItems(openEditKey: nil),
                       StackDisplay.apply(displayed: model.displayedPhotos, stacks: [], expandedIDs: []))
    }

    func testTheFlatListDefinitionsStayFlat() throws {
        let catalog = try source("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(catalog.contains("var selectedPhotos: [Photo] {\n        photos.filter { isSelected($0) }"))
        XCTAssertTrue(catalog.contains("let visible = Set(displayedPhotos.compactMap(\\.id))\n        return selectedPhotos.filter"))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("else { return catalog.smartCollectionSourcePhotos }"),
                      "Export's empty-selection fallback")
    }

    // MARK: ⌘←/⌘→

    func testNeighboursWalkTheCells() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2], ids[3]], manual: true, cover: ids[1])
        let model = await makeModel()
        // Photo 1 open: the stack is collapsed, so the next cell is the stack's cover (photo 2), not photo 3.
        var cells = model.filmstripItems(openEditKey: try key(model, 1)).map(\.photo)
        var n = LibraryNavigation.neighbors(ofEditKey: try key(model, 1), in: cells)
        XCTAssertEqual(n.next?.id, ids[1])
        // Photo 5 open: the previous cell is the stack's cover, not its last member.
        cells = model.filmstripItems(openEditKey: try key(model, 5)).map(\.photo)
        n = LibraryNavigation.neighbors(ofEditKey: try key(model, 5), in: cells)
        XCTAssertEqual(n.previous?.id, ids[1], "the open photo is not in the stack: its stack stays collapsed, the cover is the cell")
    }

    func testNeighboursInsideAnOpenStackWalkItsMembers() async throws {
        try await db.createStack(photoIDs: [ids[1], ids[2], ids[3]], manual: true, cover: ids[1])
        let model = await makeModel()
        let open = try key(model, 3)
        let cells = model.filmstripItems(openEditKey: open).map(\.photo)
        let n = LibraryNavigation.neighbors(ofEditKey: open, in: cells)
        XCTAssertEqual(n.previous?.id, ids[1])
        XCTAssertEqual(n.next?.id, ids[3])
    }

    // MARK: Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheFilmstripViewAndNeighboursUseTheCells() throws {
        let film = try source("Sources/UI/EditorFilmstripView.swift")
        XCTAssertTrue(film.contains("catalog.filmstripItems(openEditKey:"))
        XCTAssertTrue(film.contains(".id(item.cellID)"))
        XCTAssertFalse(film.contains(".id(photo.editKey)"), "an editKey id would keep a stale badge across a role change")
        XCTAssertFalse(film.contains("catalog.displayedPhotos"))
        XCTAssertTrue(film.contains("StackCellPresentation.badge(for:"))
        XCTAssertTrue(film.contains("StackCellPresentation.scrollTarget(forFocusedKey:"))
        XCTAssertTrue(film.contains("item.photo.editKey == currentEditKey"))
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("catalog.filmstripItems(openEditKey: currentKey).map(\\.photo)"))
    }
}

private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
