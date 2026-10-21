import XCTest
@testable import PhotoApp

/// "Show photos from subfolders": the descendant walk, the grid reload when the flag flips, membership edits while a subtree is shown and
/// the scope name the Trash confirmation uses. Every model here gets its own `UserDefaults` suite (the test host is the real app).
@MainActor
final class ShowPhotosInSubfoldersTests: XCTestCase {
    private var suiteNames: [String] = []
    private var defaults: UserDefaults?

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
        defaults = nil
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ShowPhotosInSubfoldersTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let made = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults = made
        return made
    }

    private func collection(_ id: Int64, folder: Bool = true, parent: Int64? = nil) -> PhotoCollection {
        PhotoCollection(id: id, name: "c\(id)", createdAt: Date(timeIntervalSince1970: 0), parentId: parent, isFolder: folder, folderPath: nil)
    }

    private func node(_ path: String, files: [String], children: [FolderScanNode] = []) -> FolderScanNode {
        FolderScanNode(url: URL(fileURLWithPath: path), imageFiles: files.map { URL(fileURLWithPath: "\(path)/\($0)") }, children: children)
    }

    /// 2024 (r.jpg) > Trip (group.jpg) > Day1 (1.jpg), plus a separate root Other (o.jpg).
    private func makeModel(flag: Bool = false) async throws -> (CatalogModel, CatalogDatabase, [String: Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        let day = node("/tmp/sps/2024/Trip/Day1", files: ["1.jpg"])
        let trip = node("/tmp/sps/2024/Trip", files: ["group.jpg"], children: [day])
        _ = try await db.importFolderTree(node("/tmp/sps/2024", files: ["r.jpg"], children: [trip]))
        _ = try await db.importFolderTree(node("/tmp/sps/Other", files: ["o.jpg"]))
        let suite = try makeDefaults()
        if flag { AppPreferences(defaults: suite).showPhotosInSubfolders = true }
        let model = CatalogModel(database: db, defaults: suite)
        await model.refresh()
        var ids: [String: Int64] = [:]
        for collection in model.collections { if let id = collection.id { ids[collection.name] = id } }
        return (model, db, ids)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func names(_ model: CatalogModel) -> Set<String> { Set(model.photos.map(\.filename)) }

    // MARK: descendants

    func testDescendantsAreBreadthFirstOverFolderRowsOnly() {
        let cols = [collection(1), collection(2, parent: 1), collection(3, parent: 2), collection(4, parent: 1), collection(5),
                    collection(6, folder: false, parent: 1)]
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 1, in: cols), [1, 2, 3, 4], "a non-folder row below a folder is not a subfolder")
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 2, in: cols), [2, 3])
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 5, in: cols), [5])
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 99, in: cols), [99], "an unknown folder still contains itself")
    }

    func testDescendantsTerminateOnAParentCycle() {
        let cols = [collection(1, parent: 2), collection(2, parent: 1), collection(3, parent: 3)]
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 1, in: cols), [1, 2])
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: 3, in: cols), [3])
    }

    /// KNOWN GAP (documented, not fixed): a folder imported BEFORE its parent stays a separate root, so the parent never includes it.
    func testAFolderImportedBeforeItsParentIsNotBelowThatParent() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importFolderTree(node("/tmp/rev/Trip", files: ["t.jpg"]))
        _ = try await db.importFolderTree(node("/tmp/rev", files: ["p.jpg"], children: [node("/tmp/rev/Trip", files: ["t.jpg"])]))
        let collections = try await db.allCollections()
        let trip = try XCTUnwrap(collections.first { $0.name == "Trip" })
        let parent = try XCTUnwrap(collections.first { $0.name == "rev" })
        XCTAssertNil(trip.parentId, "findOrCreateFolderCollection never re-parents an existing root")
        let parentID = try XCTUnwrap(parent.id)
        XCTAssertEqual(CatalogModel.descendantFolderIDs(of: parentID, in: collections), [parentID], "so the parent does not include it")
    }

    // MARK: flag and grid

    func testFlagDefaultsOffAndIsSeededFromPreferences() async throws {
        let (off, _, _) = try await makeModel()
        XCTAssertFalse(off.showPhotosInSubfolders)
        let (on, _, _) = try await makeModel(flag: true)
        XCTAssertTrue(on.showPhotosInSubfolders)
    }

    func testTurningTheFlagOnShowsTheSubtreeAndOffRestoresDirectOnly() async throws {
        let (model, _, ids) = try await makeModel()
        let suite = try XCTUnwrap(defaults)
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        try await waitUntil("direct photos") { self.names(model) == ["r.jpg"] }

        model.showPhotosInSubfolders = true
        try await waitUntil("the subtree") { self.names(model) == ["r.jpg", "group.jpg", "1.jpg"] }
        XCTAssertEqual(model.photos.count, 3)
        XCTAssertTrue(AppPreferences(defaults: suite).showPhotosInSubfolders, "the change is persisted")

        model.showPhotosInSubfolders = false
        try await waitUntil("direct only again") { self.names(model) == ["r.jpg"] }
        XCTAssertFalse(AppPreferences(defaults: suite).showPhotosInSubfolders)
    }

    func testAMiddleFolderShowsOnlyItsOwnSubtreeAndASiblingRootIsUntouched() async throws {
        let (model, _, ids) = try await makeModel(flag: true)
        model.selectedFilter = .collection(try XCTUnwrap(ids["Trip"]))
        try await waitUntil("Trip's subtree") { self.names(model) == ["group.jpg", "1.jpg"] }
        model.selectedFilter = .collection(try XCTUnwrap(ids["Other"]))
        try await waitUntil("Other") { self.names(model) == ["o.jpg"] }
    }

    func testTheFlagNeverAffectsAnAlbumOrAllPhotos() async throws {
        let (model, db, _) = try await makeModel(flag: true)
        let album = try await db.createCollection(name: "Album")
        let albumID = try XCTUnwrap(album.id)
        let photoID = try XCTUnwrap(model.photos.first { $0.filename == "o.jpg" }?.id)
        try await db.setMembership(photoID: photoID, collectionID: albumID, isMember: true)
        await model.refresh()
        model.selectedFilter = .collection(albumID)
        try await waitUntil("the album") { self.names(model) == ["o.jpg"] }
        XCTAssertEqual(model.viewedCollectionIDs, [albumID])
        model.selectedFilter = .allPhotos
        try await waitUntil("all photos") { model.photos.count == 4 }
        XCTAssertEqual(model.viewedCollectionIDs, [])
    }

    func testFlippingTheFlagWhileViewingAnAlbumDoesNotClearTheSelection() async throws {
        let (model, db, _) = try await makeModel()
        let album = try await db.createCollection(name: "Album")
        let albumID = try XCTUnwrap(album.id)
        let photo = try XCTUnwrap(model.photos.first)
        let photoID = try XCTUnwrap(photo.id)
        try await db.setMembership(photoID: photoID, collectionID: albumID, isMember: true)
        await model.refresh()
        model.selectedFilter = .collection(albumID)
        try await waitUntil("the album") { model.photos.count == 1 }
        model.toggleSelection(of: photo)
        model.showPhotosInSubfolders = true
        XCTAssertEqual(model.selectedPhotoIDs, [photoID])
    }

    // MARK: membership with descendants

    func testRemovingAPhotoFromAVisibleSubfolderLeavesTheGridWhenItIsInNoOtherViewedFolder() async throws {
        let (model, db, ids) = try await makeModel(flag: true)
        let dayCollection = try XCTUnwrap(model.collections.first { $0.name == "Day1" })
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        try await waitUntil("subtree") { model.photos.count == 3 }
        let dayPhoto = try XCTUnwrap(model.photos.first { $0.filename == "1.jpg" })

        model.toggleMembership(of: dayPhoto, in: dayCollection)

        XCTAssertFalse(model.photos.contains { $0.id == dayPhoto.id }, "no ghost cell for a photo removed from a visible descendant")
        let dayID = try XCTUnwrap(dayCollection.id)
        try await waitUntil("the write") { try await db.photos(inCollection: dayID).isEmpty }
    }

    func testRemovingAPhotoFromOneViewedFolderKeepsItWhileAnotherViewedFolderHoldsIt() async throws {
        let (model, _, ids) = try await makeModel(flag: true)
        let trip = try XCTUnwrap(model.collections.first { $0.name == "Trip" })
        let day = try XCTUnwrap(model.collections.first { $0.name == "Day1" })
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        try await waitUntil("subtree") { model.photos.count == 3 }
        let groupPhoto = try XCTUnwrap(model.photos.first { $0.filename == "group.jpg" })
        let groupID = try XCTUnwrap(groupPhoto.id)
        let dayID = try XCTUnwrap(day.id)
        model.toggleMembership(of: groupPhoto, in: day) // now in Trip and Day1
        XCTAssertTrue(model.membershipsByPhotoID[groupID, default: []].contains(dayID))

        model.toggleMembership(of: groupPhoto, in: trip)

        XCTAssertTrue(model.photos.contains { $0.id == groupPhoto.id }, "still a member of Day1, which is shown")
    }

    func testTheGridIgnoresAMembershipChangeInADescendantWhileTheFlagIsOff() async throws {
        let (model, _, ids) = try await makeModel()
        let day = try XCTUnwrap(model.collections.first { $0.name == "Day1" })
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        try await waitUntil("direct") { model.photos.count == 1 }
        let rootPhoto = try XCTUnwrap(model.photos.first)
        XCTAssertEqual(model.viewedCollectionIDs, [try XCTUnwrap(ids["2024"])])
        model.toggleMembership(of: rootPhoto, in: day)
        model.toggleMembership(of: rootPhoto, in: day) // adding then removing a collection that is not shown must not drop the row
        XCTAssertTrue(model.photos.contains { $0.id == rootPhoto.id })
    }

    func testAddingAPhotoToAViewedSubfolderWhileViewingTheParentRefreshesTheGrid() async throws {
        let (model, db, ids) = try await makeModel(flag: true)
        let day = try XCTUnwrap(model.collections.first { $0.name == "Day1" })
        let allPhotos = try await db.allPhotos()
        let otherPhoto = try XCTUnwrap(allPhotos.first { $0.filename == "o.jpg" })
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        try await waitUntil("subtree") { model.photos.count == 3 }

        model.toggleMembership(of: otherPhoto, in: day)

        try await waitUntil("the added photo appears under the parent") { model.photos.contains { $0.filename == "o.jpg" } }
    }

    // MARK: scope name

    func testScopeNameSaysSubfoldersOnlyForAFolderWithTheFlagOn() async throws {
        let (model, db, ids) = try await makeModel()
        model.selectedFilter = .collection(try XCTUnwrap(ids["2024"]))
        XCTAssertEqual(model.currentScopeName, "“2024”")
        model.showPhotosInSubfolders = true
        XCTAssertEqual(model.currentScopeName, "“2024” and its subfolders")
        let album = try await db.createCollection(name: "Album")
        await model.refresh()
        model.selectedFilter = .collection(try XCTUnwrap(album.id))
        XCTAssertEqual(model.currentScopeName, "“Album”", "an album has no subfolders")
        model.selectedFilter = .allPhotos
        XCTAssertEqual(model.currentScopeName, "All Photos")
    }

    // MARK: stored folder counts

    func testStoredFolderCountsFollowMembershipChangesAndTheFlag() async throws {
        let (model, _, ids) = try await makeModel()
        let year = try XCTUnwrap(ids["2024"])
        let tripID = try XCTUnwrap(ids["Trip"])
        let dayID = try XCTUnwrap(ids["Day1"])
        XCTAssertEqual(model.folderPhotoCounts[year], 1)
        XCTAssertEqual(model.folderPhotoCounts[tripID], 1)
        XCTAssertEqual(model.folderPhotoCounts[dayID], 1)

        model.showPhotosInSubfolders = true
        XCTAssertEqual(model.folderPhotoCounts[year], 3, "the subtree total while the flag is on")
        XCTAssertEqual(model.folderPhotoCounts[tripID], 2)
        XCTAssertEqual(model.folderPhotoCounts[dayID], 1)

        let day = try XCTUnwrap(model.collections.first { $0.name == "Day1" })
        let other = try XCTUnwrap(model.photos.first { $0.filename == "o.jpg" })
        model.toggleMembership(of: other, in: day)
        XCTAssertEqual(model.folderPhotoCounts[dayID], 2, "updated synchronously with the local membership change")
        XCTAssertEqual(model.folderPhotoCounts[year], 4)

        model.toggleMembership(of: other, in: day)
        XCTAssertEqual(model.folderPhotoCounts[year], 3)

        model.showPhotosInSubfolders = false
        XCTAssertEqual(model.folderPhotoCounts[year], 1)
    }

    func testScopeNameAndEmptyStateOnlyMentionSubfoldersWhenThereAreSome() async throws {
        let (model, _, ids) = try await makeModel(flag: true)
        model.selectedFilter = .collection(try XCTUnwrap(ids["Day1"]))
        XCTAssertEqual(model.currentScopeName, "“Day1”", "a leaf folder has no subfolders to name")
        XCTAssertEqual(model.viewedCollectionIDs.count, 1)
        model.selectedFilter = .collection(try XCTUnwrap(ids["Trip"]))
        XCTAssertEqual(model.currentScopeName, "“Trip” and its subfolders")
    }
}
