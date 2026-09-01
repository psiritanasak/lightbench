import XCTest
@testable import PhotoApp

/// Covers `CatalogModel`'s tap mutators, which update local state directly
/// rather than re-reading the whole catalog. Uses the `init(database:)`
/// testing seam with an in-memory catalog, so nothing here touches
/// `UserDefaults`, the sandbox, or the on-disk library.
@MainActor
final class CatalogModelTests: XCTestCase {
    private var database: CatalogDatabase!

    private static let paths = ["/tmp/cm/a.jpg", "/tmp/cm/b.jpg", "/tmp/cm/c.jpg"]

    override func setUp() async throws {
        database = try CatalogDatabase(inMemory: true)
        _ = try await database.importPhotos(at: Self.paths.map { URL(fileURLWithPath: $0) })
    }

    override func tearDown() async throws {
        database = nil
    }

    private func makeModel() async -> CatalogModel {
        let model = CatalogModel(database: database)
        await model.refresh()
        return model
    }

    /// Polls until `condition` holds, so tests can wait on the fire-and-forget
    /// `Task.detached` database writes without hard-coding a sleep long enough
    /// to be slow but short enough to flake.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func storedRating(forPath path: String) async throws -> Int? {
        try await database.allPhotos().first { $0.path == path }?.rating
    }

    // MARK: - Local-first updates

    func testSetRatingUpdatesPublishedPhotosSynchronously() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.setRating(4, for: photo)

        // No await: the local update must already be visible when the call
        // returns, since that is what keeps taps ordered.
        XCTAssertEqual(model.photos.first?.rating, 4)
    }

    /// The regression test for the documented Phase 4 slice 3 bug: rapid
    /// repeated taps could transiently display a stale rating, because each
    /// tap kicked off an independent `refresh()` and an older one could
    /// publish after a newer one.
    ///
    /// Deliberately asserts only the DISPLAYED value. The database writes are
    /// still independent `Task.detached` calls that could reach GRDB's queue
    /// out of order, so asserting the STORED value after two near-instant taps
    /// would be asserting something this change does not promise — see the
    /// known limitation recorded in PROGRESS.md.
    func testRapidRepeatedRatingTapsShowTheLastValue() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.setRating(1, for: photo)
        model.setRating(2, for: photo)
        model.setRating(5, for: photo)

        XCTAssertEqual(model.photos.first?.rating, 5, "the grid must show the most recent tap")
    }

    func testSetRatingPersistsToTheCatalog() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.setRating(3, for: photo)

        try await waitUntil("rating 3 to reach the database") {
            try await self.storedRating(forPath: photo.path) == 3
        }
    }

    /// `CatalogDatabase.setRating` clamps to 0...5 independently; the local
    /// update mirrors that clamp so the grid can never show a value the
    /// catalog rejected.
    func testRatingIsClampedLocallyAndInTheCatalog() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.setRating(99, for: photo)

        XCTAssertEqual(model.photos.first?.rating, 5)
        try await waitUntil("clamped rating to reach the database") {
            try await self.storedRating(forPath: photo.path) == 5
        }
    }

    func testSetFlaggedUpdatesLocallyAndPersists() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        XCTAssertFalse(try XCTUnwrap(model.photos.first).isFlagged)

        model.setFlagged(true, for: photo)

        XCTAssertTrue(try XCTUnwrap(model.photos.first).isFlagged)
        try await waitUntil("flag to reach the database") {
            try await self.database.allPhotos().first { $0.path == photo.path }?.isFlagged == true
        }
    }

    // MARK: - Removal (D5, IMPROVEMENTS.md)

    func testRemovePhotoUpdatesPublishedPhotosSynchronously() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        let remainingCount = model.photos.count - 1

        model.removePhoto(photo)

        // No await: same discipline as the rating tests — the local
        // removal must already be visible when the call returns.
        XCTAssertEqual(model.photos.count, remainingCount)
        XCTAssertFalse(model.photos.contains { $0.id == photo.id })
    }

    /// Permanent removal is the one case where an un-pruned
    /// `selectedPhotoIDs` entry would linger forever (unlike the OTHER
    /// mutators' transient ghost-cell cases, which resolve on the next
    /// `refresh()`) — this is the regression test for that.
    func testRemovePhotoPrunesSelection() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        let photoID = try XCTUnwrap(photo.id)
        model.toggleSelection(of: photo)
        XCTAssertTrue(model.selectedPhotoIDs.contains(photoID))

        model.removePhoto(photo)

        XCTAssertFalse(model.selectedPhotoIDs.contains(photoID))
    }

    func testRemovePhotoPersistsToTheCatalog() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.removePhoto(photo)

        try await waitUntil("removal to reach the database") {
            try await !self.database.allPhotos().contains { $0.path == photo.path }
        }
    }

    // MARK: - Presets (Phase 5 slice 2)

    func testCreatePresetPersistsAndAppearsInThePublishedList() async throws {
        let model = await makeModel()
        var state = EditState()
        state.exposureEV = 1.2

        model.createPreset(name: "Moody", editState: state)

        try await waitUntil("the preset to appear in the published list") {
            await model.presets.contains { $0.name == "Moody" }
        }
        let stored = try await database.allPresets()
        XCTAssertEqual(stored.first?.editState.exposureEV, 1.2)
    }

    func testDeletePresetPrunesLocalStateSynchronously() async throws {
        let model = await makeModel()
        model.createPreset(name: "Moody", editState: EditState())
        try await waitUntil("the preset to appear before deleting it") {
            await !model.presets.isEmpty
        }
        let preset = try XCTUnwrap(model.presets.first)

        model.deletePreset(preset)

        // No await: local-first, same discipline as removePhoto's own test.
        XCTAssertTrue(model.presets.isEmpty)
        try await waitUntil("the deletion to reach the database") {
            try await self.database.allPresets().isEmpty
        }
    }

    // MARK: - Collection membership

    func testToggleMembershipUpdatesTheMembershipMapSynchronously() async throws {
        let collection = try await database.createCollection(name: "Trip")
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        let photoID = try XCTUnwrap(photo.id)
        let collectionID = try XCTUnwrap(collection.id)

        model.toggleMembership(of: photo, in: collection)

        XCTAssertTrue(model.membershipsByPhotoID[photoID, default: []].contains(collectionID))
        try await waitUntil("membership to reach the database") {
            try await self.database.photos(inCollection: collectionID).contains { $0.id == photoID }
        }
    }

    /// The ghost-cell case: while the grid is filtered to a collection,
    /// `photos` IS that collection's membership list, so removing a photo
    /// from it must drop the row from `photos` too — not just from the
    /// membership map, which would leave the cell visibly stranded.
    func testRemovingFromTheCurrentlyViewedCollectionDropsThePhotoFromTheGrid() async throws {
        let collection = try await database.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        let photoID = try XCTUnwrap(photo.id)

        model.toggleMembership(of: photo, in: collection)
        try await waitUntil("membership to reach the database") {
            try await self.database.photos(inCollection: collectionID).contains { $0.id == photoID }
        }

        model.selectedFilter = .collection(collectionID)
        try await waitUntil("the grid to show the collection") { model.photos.count == 1 }

        model.toggleMembership(of: photo, in: collection)

        XCTAssertFalse(
            model.photos.contains { $0.id == photoID },
            "a photo removed from the collection being viewed must leave the grid immediately"
        )
        XCTAssertFalse(model.membershipsByPhotoID[photoID, default: []].contains(collectionID))
    }
}
