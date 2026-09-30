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

    /// `defaults` defaults to `.standard` — safe for every EXISTING test
    /// below, none of which touch `folderBookmarks`. Reviewer-caught (a
    /// REAL, not theoretical, incident — see `CatalogModel.folderBookmarks`'s
    /// own doc comment): `PhotoAppTests` is hosted inside the real
    /// `PhotoApp` app (`TEST_HOST`), so `.standard` here is NOT an isolated
    /// test store — it's the same preferences domain the real, installed
    /// app reads. Any test that seeds/reads `folderBookmarks` MUST pass an
    /// isolated `UserDefaults(suiteName:)` instead, cleaned up via
    /// `removePersistentDomain(forName:)` — see the `ensureAccessActive`
    /// tests below for the pattern (mirrors `SidecarFolderAccessTests`'s
    /// own, already-established one).
    private func makeModel(defaults: UserDefaults = .standard) async -> CatalogModel {
        let model = CatalogModel(database: database, defaults: defaults)
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

    /// Creates a real temp folder with a real, `chmod 000`'d file inside
    /// it — the fixture shape `ensureAccessActive`'s own tests need to
    /// simulate "exists but access denied," not "genuinely gone" (a bare,
    /// never-created path satisfies neither `FileManager.fileExists` nor
    /// the reachability the readable-file tests need — see
    /// `ensureAccessActive`'s own doc comment for why both existence AND
    /// readability are checked together). Caller should clean up via
    /// `cleanupUnreadableFileFixture(_:)` — restoring 644 before removal
    /// isn't strictly required (delete permission is governed by the
    /// PARENT folder's own write bit, not this file's mode, so a bare
    /// `removeItem` on the folder would work too), but it's harmless
    /// belt-and-braces and keeps every fixture's cleanup uniform.
    private func makeUnreadableFileFixture() throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([0x01])))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        return (folder, file)
    }

    private func cleanupUnreadableFileFixture(_ fixture: (folder: URL, file: URL)) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
        try? FileManager.default.removeItem(at: fixture.folder)
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

    func testSetColorLabelUpdatesPublishedPhotosSynchronouslyAndPersists() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)

        model.setColorLabel(.green, for: photo)

        XCTAssertEqual(model.photos.first?.colorLabel, .green)
        try await waitUntil("color label to reach the database") {
            try await self.database.allPhotos().first { $0.path == photo.path }?.colorLabel == .green
        }
    }

    func testClearLibraryFiltersResetsTheLabelFilter() async throws {
        let model = await makeModel()
        model.labelFilter = .red

        model.clearLibraryFilters()

        XCTAssertEqual(model.labelFilter, .all)
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

    func testSetFlagStatusUpdatesLocallyAndPersists() async throws {
        let model = await makeModel()
        let photo = try XCTUnwrap(model.photos.first)
        XCTAssertEqual(try XCTUnwrap(model.photos.first).flagStatus, FlagStatus.none)

        model.setFlagStatus(.rejected, for: photo)

        XCTAssertEqual(try XCTUnwrap(model.photos.first).flagStatus, .rejected)
        try await waitUntil("flag to reach the database") {
            try await self.database.allPhotos().first { $0.path == photo.path }?.flagStatus == .rejected
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

    /// IMPROVEMENTS.md D33 (reviewer-caught): pins the SAME accessor
    /// `ContentView.exportButtonTitle`/the Add-to-Collection menu's own
    /// count label now depend on (`selectedPhotos`), using the exact same
    /// ghost-selection setup as the test above — `selectedPhotoIDs` (the
    /// raw set) still contains the vanished photo's id, but `selectedPhotos`
    /// (photos.filter { isSelected($0) }) must not, since the photo is no
    /// longer part of `photos` at all.
    func testSelectedPhotosExcludesAGhostID() async throws {
        let trip = try await database.createCollection(name: "Trip")
        let tripID = try XCTUnwrap(trip.id)
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
        model.toggleMembership(of: photo, in: trip) // ghost-cell removal
        try await waitUntil("the photo to leave the grid") { model.photos.isEmpty }

        XCTAssertTrue(model.selectedPhotoIDs.contains(photoID), "precondition: still in the raw set")
        XCTAssertTrue(model.selectedPhotos.isEmpty, "a ghost id must not appear in the filtered accessor")
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

    // MARK: - ensureAccessActive (Library-driven open access self-healing)

    /// The common, already-working case: a root IS known AND still
    /// reachable on disk. Must stay completely silent — no prompt, no
    /// `folderBookmarks` read/write, no `activeFolders` mutation — since
    /// this is what happens on every ordinary Library/filmstrip/⌘←→ open
    /// today. Uses the default (`.standard`) `UserDefaults`: the reachable
    /// path never touches `folderBookmarks` at all, so there's nothing to
    /// isolate here (unlike the tests below).
    ///
    /// Reviewer-caught (round 1): an earlier version of this method
    /// re-resolved and re-started the bookmark UNCONDITIONALLY on every
    /// call, even when already active — leaking one unmatched
    /// `startAccessingSecurityScopedResource()` per open (no matching
    /// `stop` exists anywhere in this file, by design). This test's own
    /// `folderReGrantPrompt` would also catch a resurrected version of
    /// that bug indirectly, but the real guard against the LEAK itself is
    /// structural (see `ensureAccessActive`'s own doc comment) — this test
    /// only proves the OBSERVABLE behavior (silence) stays correct.
    ///
    /// Reviewer-noted (round 3): this test can't distinguish the current
    /// file-handle-open probe from the OLDER, insufficient
    /// `FileManager.fileExists` check it replaced — a real, readable file
    /// satisfies both. Only the live repro against this app's own real
    /// library (see `ensureAccessActive`'s own doc comment) actually
    /// exercises that specific difference; this test's job is narrower —
    /// pinning that the reachable/readable case stays silent, whichever
    /// probe implements it.
    func testEnsureAccessActiveStaysSilentWhenTheRootIsStillReachable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoURL = tempDir.appendingPathComponent("photo.jpg")
        // The readability probe opens the PHOTO's own path, not just its
        // folder (see `ensureAccessActive`'s own doc comment for why) — the
        // file must actually exist for this test to mean "still reachable"
        // rather than accidentally testing the unreachable path instead.
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data()))

        let model = await makeModel()
        model.activeFolders = [tempDir.path]
        model.folderReGrantPrompt = { _ in
            XCTFail("must not prompt when the root is still reachable")
            return nil
        }

        await model.ensureAccessActive(forPhotoAt: photoURL.path)

        XCTAssertNil(model.importStatusMessage)
        XCTAssertTrue(model.activeFolders.contains(tempDir.path))
    }

    /// The regression this method exists to fix: a root claims to be
    /// active (`activeFolders` still lists it) but the photo itself can no
    /// longer actually be READ — the exact "membership alone proves
    /// nothing" gap `isPhotoConfirmedMissing`'s own doc comment already
    /// names. With no bookmark on file either, this must fall back to the
    /// re-grant prompt with the RIGHT folder.
    ///
    /// Simulates "unreadable, but NOT deleted" via `chmod 000` on a REAL
    /// file, not by removing the containing folder — reviewer-caught
    /// (round 3): `ensureAccessActive`'s probe checks existence AND
    /// readability together specifically so a genuinely-DELETED file does
    /// NOT trigger this recovery path (see the sibling
    /// `testEnsureAccessActiveDoesNotRecoverForAGenuinelyMissingFile`
    /// below) — removing the whole folder here would make BOTH checks
    /// fail the same way a real deletion does, testing the wrong branch
    /// entirely. `chmod 000` keeps the file (and its folder) genuinely
    /// present while making it genuinely unopenable, which is what this
    /// test needs to mean "access lost, not gone."
    ///
    /// Doesn't assert a successful re-grant restores `activeFolders` —
    /// MEASURED (this test originally tried to): a URL just handed back
    /// from a fake prompt, never having round-tripped through a real
    /// `NSOpenPanel` pick or bookmark resolution, does NOT carry embedded
    /// security-scope data, so `startAccessingSecurityScopedResource()` on
    /// it genuinely (and correctly) returns `false` — this is true
    /// regardless of whether the CALLING process itself is sandboxed
    /// (reviewer-caught, round 3: an earlier version of this comment
    /// wrongly claimed `PhotoAppTests` isn't sandboxed at all, which
    /// contradicts `folderBookmarks`'s own doc comment — a test hosted
    /// inside the real `PhotoApp` app via `TEST_HOST` DOES run sandboxed;
    /// what actually matters here is the URL's own missing scope data, not
    /// the caller's sandbox status) — only a REAL panel pick (production)
    /// or a resolved bookmark can actually activate scope, so a fake
    /// prompt can only exercise the FAILURE/warning-propagation path, not
    /// a genuine success.
    func testEnsureAccessActiveRecoversWhenTheRootIsNoLongerReachable() async throws {
        let fixture = try makeUnreadableFileFixture()
        defer { cleanupUnreadableFileFixture(fixture) }
        let suiteName = "CatalogModelTests-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let model = await makeModel(defaults: isolatedDefaults)
        model.activeFolders = [fixture.folder.path] // stale claim — no matching bookmark below
        var promptedFolder: URL?
        model.folderReGrantPrompt = { folder in
            promptedFolder = folder
            return folder // echoed back verbatim — see the doc comment above for why this can't succeed here
        }

        await model.ensureAccessActive(forPhotoAt: fixture.file.path)

        XCTAssertEqual(promptedFolder?.path, fixture.folder.path, "must prompt for the STALE root, not some other path")
        // `activateFolderAccess`'s own warning must propagate through, and the root must NOT be
        // left in `activeFolders` on a failed activation — a false claim of live access would be
        // worse than an honest, visible failure.
        XCTAssertNotNil(model.importStatusMessage)
        XCTAssertFalse(model.activeFolders.contains(fixture.folder.path))
    }

    /// Reviewer-caught (round 3): a photo whose file has genuinely been
    /// DELETED (not merely access-denied) must NOT be treated as a
    /// lost-access recovery case — that would wrongly evict a still-good
    /// root from `activeFolders` (breaking `isPhotoConfirmedMissing` for
    /// every sibling photo in the same folder), leak an unmatched
    /// security-scope start for a recovery that can't possibly help, and
    /// show a re-grant panel that can't fix a deletion.
    /// `ImageDocumentModel.load(from:)`'s own existing "may be missing"
    /// error already covers a genuinely-gone file correctly on its own.
    func testEnsureAccessActiveDoesNotRecoverForAGenuinelyMissingFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // The FOLDER stays reachable — only the specific photo file was
        // never created (or was deleted), matching a real "this one photo
        // is gone" scenario rather than "the whole folder went away."

        let model = await makeModel()
        model.activeFolders = [tempDir.path]
        model.folderReGrantPrompt = { _ in
            XCTFail("a genuinely missing file must not trigger a re-grant prompt")
            return nil
        }

        await model.ensureAccessActive(forPhotoAt: tempDir.appendingPathComponent("never-existed.jpg").path)

        XCTAssertNil(model.importStatusMessage)
        XCTAssertTrue(model.activeFolders.contains(tempDir.path), "a genuinely missing file must not evict a still-good root")
    }

    /// LIVE-REPRODUCED (2026-09-25): `activeFolders` isn't just STALE for
    /// the photo's folder — it has NO entry for it at all. This exact
    /// state was reproduced against this app's own real library (this
    /// session's `folderBookmarks` had been left empty by an earlier,
    /// already-disclosed incident — NOT a demonstration of the ORIGINAL
    /// bug report's own trigger, which remains undiagnosed; see
    /// `ensureAccessActive`'s own doc comment for that distinction).
    /// `confirmedActiveFolderRoot` returns `nil` in this case, and an
    /// earlier draft of `ensureAccessActive` no-op'd right there —
    /// reproduced live: opening a real, already-catalogued photo failed
    /// silently with no re-grant prompt at all. Must fall back to the
    /// photo's own containing folder as the recovery candidate instead of
    /// giving up.
    func testEnsureAccessActiveFallsBackToThePhotosOwnFolderWhenNoRootIsTrackedAtAll() async throws {
        let fixture = try makeUnreadableFileFixture()
        defer { cleanupUnreadableFileFixture(fixture) }
        // Isolated, not `.standard` — unlike the sibling tests above that
        // stop at a decline/mismatch, this one echoes back a COVERING
        // folder, which reaches `activateFolderAccess`'s real
        // `folderBookmarks` write.
        let suiteName = "CatalogModelTests-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let model = await makeModel(defaults: isolatedDefaults) // `activeFolders` starts completely empty
        var promptedFolder: URL?
        model.folderReGrantPrompt = { folder in
            promptedFolder = folder
            return folder
        }

        await model.ensureAccessActive(forPhotoAt: fixture.file.path)

        XCTAssertEqual(
            promptedFolder?.path, fixture.folder.path,
            "with no tracked root at all, must fall back to the photo's own containing folder"
        )
        XCTAssertNotNil(model.importStatusMessage)
    }

    /// A declined re-grant must surface a warning and must NOT leave the
    /// root in `activeFolders`. Uses the default `UserDefaults`: this path
    /// never reaches `activateFolderAccess`'s own write, only a harmless
    /// read.
    func testEnsureAccessActiveSurfacesAWarningWhenReGrantIsDeclined() async throws {
        let fixture = try makeUnreadableFileFixture()
        defer { cleanupUnreadableFileFixture(fixture) }

        let model = await makeModel()
        model.activeFolders = [fixture.folder.path]
        model.folderReGrantPrompt = { _ in nil } // simulates a Cancel click

        await model.ensureAccessActive(forPhotoAt: fixture.file.path)

        XCTAssertNotNil(model.importStatusMessage)
        XCTAssertTrue(model.activeFolders.isEmpty)
    }

    /// Reviewer-caught (round 1): the re-grant prompt returning a folder
    /// that does NOT cover the requested root (the user navigated
    /// elsewhere in the panel and picked something unrelated) had no test
    /// at all. Must be treated the same as a decline, not silently
    /// accepted.
    func testEnsureAccessActiveSurfacesAWarningWhenReGrantIsMismatched() async throws {
        let fixture = try makeUnreadableFileFixture()
        defer { cleanupUnreadableFileFixture(fixture) }

        let model = await makeModel()
        model.activeFolders = [fixture.folder.path]
        model.folderReGrantPrompt = { _ in URL(fileURLWithPath: "/tmp/cm-completely-unrelated-\(UUID().uuidString)") }

        await model.ensureAccessActive(forPhotoAt: fixture.file.path)

        XCTAssertNotNil(model.importStatusMessage)
        XCTAssertFalse(model.activeFolders.contains(fixture.folder.path))
    }

    /// Reviewer-caught (round 1): an earlier version of this method
    /// deleted `folderBookmarks[root]` unconditionally before even trying
    /// the re-grant prompt — destroying a bookmark that might have been
    /// perfectly good again later (an external drive not currently
    /// mounted, a network share that's down) purely because of a
    /// TRANSIENT failure. Must leave a pre-existing (if currently
    /// unresolvable) bookmark entry untouched when the re-grant is
    /// declined, so a future attempt — once whatever's wrong resolves
    /// itself — isn't permanently worse off.
    func testEnsureAccessActiveDoesNotDeleteAnExistingBookmarkOnADeclinedReGrant() async throws {
        let fixture = try makeUnreadableFileFixture()
        defer { cleanupUnreadableFileFixture(fixture) }
        let suiteName = "CatalogModelTests-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        let model = await makeModel(defaults: isolatedDefaults)
        let root = fixture.folder.path
        model.activeFolders = [root]
        // Deliberately malformed — `URL(resolvingBookmarkData:)` fails to
        // decode it, exactly like a genuinely-transient real failure would
        // look from this method's own point of view, without depending on
        // real bookmark/volume semantics to force it.
        let originalBookmark = Data([0x00, 0x01, 0x02])
        model.folderBookmarks = [root: originalBookmark]
        model.folderReGrantPrompt = { _ in nil } // simulates a Cancel click

        await model.ensureAccessActive(forPhotoAt: fixture.file.path)

        XCTAssertNotNil(model.importStatusMessage)
        XCTAssertEqual(model.folderBookmarks[root], originalBookmark, "a declined re-grant must not destroy the existing bookmark entry")
    }

    /// Reviewer-caught (round 1): a rapid second navigation for the SAME
    /// stale root while the first call's re-grant prompt is still
    /// "in flight" must not race ahead independently — it must wait for
    /// the first attempt to finish, matching whatever that one decided,
    /// rather than the two interleaving unpredictably. This drives two
    /// concurrent calls through the SAME stale root and confirms the
    /// prompt fires exactly once, not twice.
    func testEnsureAccessActiveSerializesConcurrentCallsForTheSameStaleRoot() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Only ONE of these two ever actually runs the readability probe
        // (the second caller awaits the first's in-flight task instead —
        // that's the exact behavior this test exists to pin), but which
        // one wins the race isn't guaranteed, so both must be real,
        // unreadable files for the test to be deterministic either way.
        let fileA = folder.appendingPathComponent("a.jpg")
        let fileB = folder.appendingPathComponent("b.jpg")
        for file in [fileA, fileB] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([0x01])))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }
        defer {
            for file in [fileA, fileB] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }

        let model = await makeModel()
        model.activeFolders = [folder.path]
        var promptCount = 0
        model.folderReGrantPrompt = { _ in
            promptCount += 1
            return nil
        }

        async let first: Void = model.ensureAccessActive(forPhotoAt: fileA.path)
        async let second: Void = model.ensureAccessActive(forPhotoAt: fileB.path)
        _ = await (first, second)

        XCTAssertEqual(promptCount, 1, "two concurrent callers for the same stale root must serialize behind one attempt")
    }

    // MARK: - catalogedPhoto / registerEnhancedPhoto (Enhance/Super Resolution)

    func testCatalogedPhotoFindsAnAlreadyImportedPhoto() async throws {
        let model = await makeModel()

        let found = try await model.catalogedPhoto(atPath: Self.paths[0])

        XCTAssertEqual(found?.path, Self.paths[0])
    }

    func testCatalogedPhotoReturnsNilForAPhotoNeverImported() async throws {
        let model = await makeModel()

        let found = try await model.catalogedPhoto(atPath: "/tmp/never-imported.jpg")

        XCTAssertNil(found)
    }

    func testRegisterEnhancedPhotoMakesTheRowAppearInPhotos() async throws {
        let model = await makeModel()
        let newURL = URL(fileURLWithPath: "/tmp/cm/a-Enhanced-SR.jpg")
        XCTAssertFalse(model.photos.contains { $0.path == newURL.path })

        _ = try await model.registerEnhancedPhoto(at: newURL)

        XCTAssertTrue(model.photos.contains { $0.path == newURL.path }, "registerEnhancedPhoto must refresh() so the new row shows up without a separate manual refresh")
    }

    func testCatalogedPhotoFindsAPhotoJustRegisteredByEnhance() async throws {
        let model = await makeModel()
        let newURL = URL(fileURLWithPath: "/tmp/cm/a-Enhanced-SR.jpg")

        _ = try await model.registerEnhancedPhoto(at: newURL)
        let found = try await model.catalogedPhoto(atPath: newURL.path)

        XCTAssertEqual(found?.path, newURL.path)
    }
}
