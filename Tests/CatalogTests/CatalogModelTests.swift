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

    func testAddSelectedPhotosUpdatesMembershipMapSynchronously() async throws {
        let collection = try await database.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        let model = await makeModel()
        let photoA = try XCTUnwrap(model.photos.first)
        let photoB = try XCTUnwrap(model.photos.dropFirst().first)
        let idA = try XCTUnwrap(photoA.id)
        let idB = try XCTUnwrap(photoB.id)
        model.toggleSelection(of: photoA)
        model.toggleSelection(of: photoB)

        model.addSelectedPhotos(to: collection)

        // No await: local-first, same discipline as toggleMembership's own test.
        XCTAssertTrue(model.membershipsByPhotoID[idA, default: []].contains(collectionID))
        XCTAssertTrue(model.membershipsByPhotoID[idB, default: []].contains(collectionID))
        try await waitUntil("both memberships to reach the database") {
            let inCollection = Set(try await self.database.photos(inCollection: collectionID).map(\.id))
            return inCollection.isSuperset(of: [idA, idB])
        }
    }

    /// Reviewer-caught regression test: `toggleMembership` removes a photo
    /// from `photos` when it's toggled OUT of the currently-viewed
    /// collection (the ghost-cell case,
    /// `testRemovingFromTheCurrentlyViewedCollectionDropsThePhotoFromTheGrid`
    /// above), but it does NOT prune that photo's ID from
    /// `selectedPhotoIDs` — unlike `removePhoto`, which does. So a photo
    /// can be selected, then silently vanish from the grid while STAYING
    /// selected. Without intersecting against `photos`, a later
    /// `addSelectedPhotos` would silently re-add that now-invisible photo
    /// to whatever collection it was toggled out of — this pins that it
    /// does not.
    func testAddSelectedPhotosExcludesAPhotoNoLongerVisibleInTheGrid() async throws {
        let trip = try await database.createCollection(name: "Trip")
        let tripID = try XCTUnwrap(trip.id)
        let other = try await database.createCollection(name: "Other")
        let otherID = try XCTUnwrap(other.id)
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        let photoID = try XCTUnwrap(photo.id)

        model.toggleMembership(of: photo, in: trip)
        try await waitUntil("membership to reach the database") {
            try await self.database.photos(inCollection: tripID).contains { $0.id == photoID }
        }
        model.selectedFilter = .collection(tripID)
        try await waitUntil("the grid to show the collection") { model.photos.count == 1 }
        model.toggleSelection(of: photo)
        model.toggleMembership(of: photo, in: trip) // ghost-cell removal — photo vanishes from `photos`...
        try await waitUntil("the photo to leave the grid") { model.photos.isEmpty }
        XCTAssertTrue(
            model.selectedPhotoIDs.contains(photoID),
            "precondition: toggleMembership must not prune the selection on its own"
        )

        model.addSelectedPhotos(to: other)

        // No await: the guard against an empty intersection is synchronous.
        XCTAssertFalse(
            model.membershipsByPhotoID[photoID, default: []].contains(otherID),
            "a photo no longer visible in the grid must not be silently re-added via a stale selection"
        )
    }

    // MARK: - Collections (D5, IMPROVEMENTS.md)

    func testRenameCollectionRefreshesTheList() async throws {
        _ = try await database.createCollection(name: "Trip")
        let model = await makeModel()
        let collection = try XCTUnwrap(model.collections.first)

        model.renameCollection(collection, to: "Vacation")

        try await waitUntil("the rename to reach the published list") {
            await model.collections.contains { $0.name == "Vacation" }
        }
    }

    func testDeleteCollectionPrunesLocalStateSynchronously() async throws {
        let collection = try await database.createCollection(name: "Trip")
        let model = await makeModel()

        model.deleteCollection(collection)

        // No await: local-first, same discipline as removePhoto's/
        // deletePreset's own tests.
        XCTAssertTrue(model.collections.isEmpty)
        try await waitUntil("the deletion to reach the database") {
            try await self.database.allCollections().isEmpty
        }
    }

    func testDeletingTheCurrentlyViewedCollectionResetsToAllPhotos() async throws {
        let collection = try await database.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)
        let model = await makeModel()
        model.selectedFilter = .collection(collectionID)
        try await waitUntil("the filter change to settle") {
            await model.selectedFilter == .collection(collectionID)
        }

        model.deleteCollection(collection)

        // The real regression this test exists to catch, per
        // `deleteCollection`'s own doc comment: the filter must NOT flip
        // synchronously, only after the delete write has landed —
        // reviewer-caught that asserting solely on the EVENTUAL value
        // below doesn't pin this, since a synchronous-reset version
        // satisfies "eventually .allPhotos" too, just sooner. Checked
        // immediately, with no `await` in between `deleteCollection`'s
        // call and this line, so nothing could have let the write
        // complete yet.
        XCTAssertEqual(
            model.selectedFilter, .collection(collectionID),
            "the filter must not flip until the delete write has landed"
        )

        try await waitUntil("selectedFilter to fall back to .allPhotos") {
            await model.selectedFilter == .allPhotos
        }
    }

    // MARK: - Missing-file detection (D5, IMPROVEMENTS.md)

    /// End-to-end coverage for the composite gate `isPhotoConfirmedMissing`
    /// applies — `PhotoImporterTests` already pins the pure prefix-match
    /// alone, but not the root-liveness check layered on top of it
    /// (reviewer-caught: `activeFolders` is insert-only, so a root that
    /// was active but is no longer reachable — an ejected volume, a
    /// deleted/renamed import folder — must not make every photo under it
    /// read as individually deleted).
    func testIsPhotoConfirmedMissingRequiresBothAnActiveRootAndAnAbsentFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let presentURL = tempDir.appendingPathComponent("present.jpg")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: presentURL.path, contents: Data()),
            "test fixture setup must actually create the file"
        )
        let missingURL = tempDir.appendingPathComponent("gone.jpg") // catalogued, never actually created

        _ = try await database.importPhotos(at: [presentURL, missingURL])
        let model = await makeModel()
        model.activeFolders = [tempDir.path]
        let present = try XCTUnwrap(model.photos.first { $0.filename == "present.jpg" })
        let missing = try XCTUnwrap(model.photos.first { $0.filename == "gone.jpg" })

        var isMissing = await model.isPhotoConfirmedMissing(present)
        XCTAssertFalse(isMissing, "a photo whose file exists must never be reported missing")

        isMissing = await model.isPhotoConfirmedMissing(missing)
        XCTAssertTrue(isMissing, "a photo under an active, reachable root with no file on disk IS missing")

        // The regression this test exists to pin: the root itself becomes
        // unreachable (simulating an ejected volume / deleted import
        // folder) while `activeFolders` still lists it (never pruned).
        try FileManager.default.removeItem(at: tempDir)
        isMissing = await model.isPhotoConfirmedMissing(missing)
        XCTAssertFalse(
            isMissing,
            "an unreachable ROOT must not make its photos read as individually deleted"
        )
    }
}
