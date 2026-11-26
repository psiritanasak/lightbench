import XCTest
@testable import PhotoApp

/// The off-main smart-collection counts: right while a plain collection is viewed (when `photos` is only that collection),
/// following local edits there, and absent (not 0) until computed.
@MainActor
final class CatalogModelSidebarCountsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    /// Four photos (a-d); the album holds a and b; the smart collection is "4+ stars", of which c is one.
    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, album: PhotoCollection, smart: SmartCollection, photos: [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        let node = FolderScanNode(url: URL(fileURLWithPath: "/tmp/ssc"),
                                  imageFiles: ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/tmp/ssc/\($0).jpg") }, children: [])
        _ = try await db.importFolderTree(node)
        let photos = try await db.allPhotos().sorted { $0.filename < $1.filename }
        let album = try await db.createCollection(name: "Album")
        try await db.addPhotos(photos.prefix(2).compactMap(\.id), toCollection: try XCTUnwrap(album.id))
        try await db.setRating(5, for: try XCTUnwrap(photos[2].id))
        var criteria = SmartCollectionCriteria(); criteria.minimumRating = 4
        let smart = try await db.createSmartCollection(name: "Best", criteria: criteria)
        let name = "CatalogModelSidebarCountsTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        await model.refresh()
        return (model, db, album, smart, photos)
    }

    func testCountIsAbsentUntilComputedThenCorrectInAllPhotos() async throws {
        let (model, _, _, smart, _) = try await makeModel()
        let id = try XCTUnwrap(smart.id)
        try await waitUntil("count") { model.smartCollectionCounts[id] != nil }
        XCTAssertEqual(model.smartCollectionCounts[id], 1)
    }

    func testCountsStayCorrectWhileAPlainCollectionIsViewedAndFollowLocalEdits() async throws {
        let (model, _, album, smart, _) = try await makeModel()
        let smartID = try XCTUnwrap(smart.id)
        model.selectedFilter = .collection(try XCTUnwrap(album.id))
        try await waitUntil("album shown") { model.photos.count == 2 }
        try await waitUntil("base list read") { model.smartCountBasePhotos?.count == 4 }
        // Photo c (outside the album) is the one 4+ star photo; the viewed list holds only a and b.
        try await waitUntil("count over the whole catalog") { model.smartCollectionCounts[smartID] == 1 }

        model.setRating(5, for: model.photos[0])
        try await waitUntil("count follows the rating") { model.smartCollectionCounts[smartID] == 2 }
        XCTAssertEqual(model.smartCollectionCounts[smartID], 2)
    }

    func testNoTaskAndNoCountsWithoutSmartCollections() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let name = "CatalogModelSidebarCountsTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        await model.refresh()
        XCTAssertNil(model.smartCountTask)
        XCTAssertTrue(model.smartCollectionCounts.isEmpty)
        XCTAssertNil(model.smartCountBasePhotos)
    }

    func testSwitchingFromACollectionToAllPhotosNeverCountsOverTheCollectionAlone() async throws {
        let (model, _, album, smart, _) = try await makeModel()
        let smartID = try XCTUnwrap(smart.id)
        model.selectedFilter = .collection(try XCTUnwrap(album.id))
        try await waitUntil("album shown") { model.photos.count == 2 }
        try await waitUntil("count") { model.smartCollectionCounts[smartID] == 1 }
        model.selectedFilter = .allPhotos
        try await waitUntil("all photos shown") { model.photos.count == 4 }
        XCTAssertTrue(model.photosAreWholeCatalog)
        XCTAssertNil(model.smartCountBasePhotos)
        try await waitUntil("count settles") { model.smartCollectionCounts[smartID] == 1 }
        // The collection-only list (a, b) holds no 4+ star photo: a count of 0 here would be the wrong-list bug.
        XCTAssertEqual(model.smartCollectionCounts[smartID], 1)
    }

    /// A collection is shown and no complete list is known (the base read failed): counts clear, never run over the collection.
    func testCountsClearWhenNoCompleteListIsKnown() async throws {
        let (model, _, _, smart, _) = try await makeModel()
        let smartID = try XCTUnwrap(smart.id)
        try await waitUntil("count") { model.smartCollectionCounts[smartID] != nil }
        model.photosAreWholeCatalog = false
        model.smartCountBasePhotos = nil
        model.scheduleSmartCollectionCounts()
        try await waitUntil("cleared") { model.smartCollectionCounts.isEmpty }
    }

    func testCountsEqualTheShownSmartCollectionWithVirtualCopiesAndSearch() async throws {
        let (model, db, _, rated, photos) = try await makeModel()
        let master = try XCTUnwrap(photos.first)
        _ = try await db.createVirtualCopy(of: master, versionKey: String(repeating: "a", count: SidecarStore.versionKeyLength))
        try await db.setInfo(PhotoInfo(title: "Harbour", caption: "", creator: "", copyright: ""),
                             forPhotoIDs: [try XCTUnwrap(master.id)], fields: .title)
        var search = SmartCollectionCriteria(); search.searchQuery = "harbour"
        var unknown = SmartCollectionCriteria(); unknown.hasUnrecognizedCriterion = true
        let titled = try await db.createSmartCollection(name: "Titled", criteria: search)
        let odd = try await db.createSmartCollection(name: "Odd", criteria: unknown)
        await model.refresh()
        let all = [rated, titled, odd]
        try await waitUntil("counts") { all.allSatisfy { model.smartCollectionCounts[$0.id ?? 0] != nil } }
        for smart in all {
            let id = try XCTUnwrap(smart.id)
            model.selectedFilter = .smartCollection(id)
            try await waitUntil("smart list shown") { model.photos.count == 5 }
            try await waitUntil("count matches the list") { model.smartCollectionCounts[id] == model.smartCollectionSourcePhotos.count }
            XCTAssertEqual(model.smartCollectionCounts[id], model.smartCollectionSourcePhotos.count, smart.name)
        }
        XCTAssertEqual(model.smartCollectionCounts[try XCTUnwrap(titled.id)], 2, "the master and its virtual copy")
    }
}
