import XCTest
@testable import PhotoApp

/// D94: local-first setters used to start one free-running `Task.detached` per call, so two quick edits of the same row could reach
/// the database in reverse order. They now share ONE serial write chain; these tests make many back-to-back edits, wait for the
/// chain to drain, and assert the database holds the LAST value.
@MainActor
final class CatalogWriteOrderTests: XCTestCase {
    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<3).map { URL(fileURLWithPath: "/tmp/cwo\($0).jpg") })
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "CatalogWriteOrderTests-\(UUID().uuidString)") ?? .standard)
        await model.refresh()
        return (model, db, model.photos)
    }

    func testManyBackToBackInfoWritesLeaveTheLastTitle() async throws {
        let (model, db, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        for i in 0..<50 { model.setInfo(PhotoInfo(title: "title \(i)"), fields: .title, forPhotos: [target]) }
        await model.waitForPendingWrites()
        let stored = try await db.allInfo()[target.id ?? -1]
        XCTAssertEqual(stored?.title, "title 49")
        XCTAssertEqual(model.infoByPhotoID[target.id ?? -1]?.title, "title 49")
    }

    func testManyAlternatingRatingWritesLeaveTheLastRating() async throws {
        let (model, db, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        for i in 0..<50 { model.setRating(i % 2 == 0 ? 1 : 4, for: target) } // last (i = 49) is 4
        await model.waitForPendingWrites()
        let stored = try await db.allPhotos().first { $0.id == target.id }
        XCTAssertEqual(stored?.rating, 4)
    }

    func testFlagAndLabelWritesKeepTheirLastValue() async throws {
        let (model, db, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        for i in 0..<50 {
            model.setFlagStatus(i % 2 == 0 ? .picked : .rejected, for: target)
            model.setColorLabel(i % 2 == 0 ? .red : .green, for: target)
        }
        await model.waitForPendingWrites()
        let stored = try await db.allPhotos().first { $0.id == target.id }
        XCTAssertEqual(stored?.flagStatus, .rejected)
        XCTAssertEqual(stored?.colorLabel, .green)
    }

    func testMixedSingleAndBatchWritesLandInCallOrder() async throws {
        let (model, db, photos) = try await makeModel()
        let ids = photos.compactMap(\.id)
        let target = try XCTUnwrap(photos.first)
        for round in 0..<25 {
            model.setRating(1, for: target)                             // single
            _ = await model.setRating(2, forPhotoIDs: ids)              // batch
            model.setRating(round % 2 == 0 ? 3 : 5, for: target)       // single after the batch finished
        }
        // The final call of the loop (round 24) wrote 3 after everything else.
        await model.waitForPendingWrites()
        let stored = try await db.allPhotos()
        XCTAssertEqual(stored.first { $0.id == target.id }?.rating, 3)
        XCTAssertEqual(stored.first { $0.id == ids[1] }?.rating, 2)
    }

    func testSingleWriteQueuedAfterABatchWinsWithoutAwaitingTheBatch() async throws {
        let (model, db, photos) = try await makeModel()
        let ids = photos.compactMap(\.id)
        let target = try XCTUnwrap(photos.first)
        for _ in 0..<20 {
            model.setRating(0, for: target)
            let batch = Task { @MainActor in await model.setRating(2, forPhotoIDs: ids) }
            // The batch's local update and its enqueue run in one synchronous stretch, so once the screen state shows 2 it is queued.
            while model.photos.first(where: { $0.id == target.id })?.rating != 2 { await Task.yield() }
            model.setRating(5, for: target)
            _ = await batch.value
            await model.waitForPendingWrites()
            let stored = try await db.allPhotos().first { $0.id == target.id }
            XCTAssertEqual(stored?.rating, 5)
        }
    }

    func testKeywordAndMembershipWritesFollowCallOrder() async throws {
        let (model, db, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        let photoID = try XCTUnwrap(target.id)
        let collection = try await db.createCollection(name: "Album")
        let collectionID = try XCTUnwrap(collection.id)
        await model.refresh()
        model.addKeywords("alpha", to: [photoID])
        await model.waitForPendingWrites()
        let keyword = try XCTUnwrap(model.keywords.first { $0.name == "alpha" }?.id)
        // Quick remove / re-add and toggle in / out; the last keyword call is an add, the last toggle is an add (21 toggles in total).
        for _ in 0..<20 {
            model.removeKeyword(id: keyword, from: [photoID])
            model.addKeywords("alpha", to: [photoID])
            model.toggleMembership(of: target, in: collection)
        }
        model.toggleMembership(of: target, in: collection) // 21 toggles in total: the photo ends up a member
        await model.waitForPendingWrites()
        // Model state first, with no manual refresh: the scheduled refresh must have left the final state on screen.
        XCTAssertEqual(model.keywordIDsByPhotoID[photoID], [keyword])
        XCTAssertEqual(model.membershipsByPhotoID[photoID], [collectionID])
        let memberships = try await db.allMemberships()
        XCTAssertEqual(memberships.filter { $0.photoId == photoID }.map(\.collectionId), [collectionID])
    }

    // MARK: A refresh must not undo a later write's on-screen value

    private func screenRating(_ model: CatalogModel, _ photo: Photo) -> Int? {
        model.photos.first { $0.id == photo.id }?.rating
    }

    func testAddKeywordsThenRatingKeepsTheRatingOnScreen() async throws {
        let (model, db, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        model.addKeywords("alpha", to: [try XCTUnwrap(target.id)])
        model.setRating(5, for: target)
        await model.waitForPendingWrites()
        let stored = try await db.allPhotos().first { $0.id == target.id }
        XCTAssertEqual(stored?.rating, 5)
        XCTAssertEqual(screenRating(model, target), 5, "the refresh the keyword write asked for must not republish the older rating")
        XCTAssertEqual(model.keywordIDsByPhotoID[target.id ?? -1]?.count, 1)
    }

    func testApplyKeywordEditsThenRatingKeepsTheRatingOnScreen() async throws {
        let (model, _, photos) = try await makeModel()
        let target = try XCTUnwrap(photos.first)
        model.applyKeywordEdits(adding: ["beta"], removing: [], for: target)
        model.setRating(4, for: target)
        await model.waitForPendingWrites()
        XCTAssertEqual(screenRating(model, target), 4)
        XCTAssertEqual(model.keywordIDsByPhotoID[target.id ?? -1]?.count, 1)
    }

    func testToggleMembershipWhileViewingThenRatingKeepsTheRatingOnScreen() async throws {
        let (model, db, photos) = try await makeModel()
        let (first, second) = (photos[0], photos[1])
        let collection = try await db.createCollection(name: "Album")
        let collectionID = try XCTUnwrap(collection.id)
        try await db.setMembership(photoID: try XCTUnwrap(second.id), collectionID: collectionID, isMember: true)
        await model.refresh()
        model.selectedFilter = .collection(collectionID)
        let deadline = Date().addingTimeInterval(5)
        while model.photos.count != 1, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.photos.map(\.id), [second.id])
        model.toggleMembership(of: first, in: collection)   // adding while viewing asks for a re-read
        model.setRating(5, for: second)
        await model.waitForPendingWrites()
        XCTAssertEqual(Set(model.photos.compactMap(\.id)), Set([first.id, second.id].compactMap { $0 }), "the re-read brought the added photo in")
        XCTAssertEqual(screenRating(model, second), 5)
    }

    func testBatchWriteThenSingleWriteKeepsBothOnScreenAfterAFailureFreeRun() async throws {
        let (model, _, photos) = try await makeModel()
        let ids = photos.compactMap(\.id)
        let target = try XCTUnwrap(photos.first)
        model.addKeywords("alpha", to: [ids[0]])
        _ = await model.setColorLabel(.blue, forPhotoIDs: ids)
        model.setRating(3, for: target)
        await model.waitForPendingWrites()
        XCTAssertEqual(model.photos.first { $0.id == target.id }?.colorLabel, .blue)
        XCTAssertEqual(screenRating(model, target), 3)
    }
}
