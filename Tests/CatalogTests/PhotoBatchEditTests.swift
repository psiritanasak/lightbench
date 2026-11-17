import Combine
import XCTest
@testable import PhotoApp

/// `CatalogDatabase.setRating/setColorLabel(_:forPhotoIDs:)` and the `CatalogModel` batch versions: stale ids, clamping, the 500-id
/// chunk boundary, ONE publish of `photos` per batch, and one re-read when the write fails.
@MainActor
final class PhotoBatchEditTests: XCTestCase {
    private let suiteName = "PhotoBatchEditTests-\(UUID().uuidString)"

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeDatabase(photos count: Int = 4) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/pbe\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id).sorted()
        return (db, ids)
    }

    private func makeModel(_ db: CatalogDatabase) async -> CatalogModel {
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        await model.refresh()
        return model
    }

    // MARK: Database

    func testBatchRatingSkipsStaleIDsAndClamps() async throws {
        let (db, ids) = try await makeDatabase()
        let changed = try await db.setRating(9, forPhotoIDs: [ids[0], 9_999, ids[2]])
        XCTAssertEqual(changed, [ids[0], ids[2]])
        var byID = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.id!, $0.rating) })
        XCTAssertEqual(byID[ids[0]], 5, "clamped to 5")
        XCTAssertEqual(byID[ids[1]], 0)
        _ = try await db.setRating(-3, forPhotoIDs: [ids[0]])
        byID = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.id!, $0.rating) })
        XCTAssertEqual(byID[ids[0]], 0, "clamped to 0")
        let none = try await db.setRating(3, forPhotoIDs: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testBatchLabelSkipsStaleIDs() async throws {
        let (db, ids) = try await makeDatabase()
        let changed = try await db.setColorLabel(.purple, forPhotoIDs: [ids[1], 9_999])
        XCTAssertEqual(changed, [ids[1]])
        let byID = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.id!, $0.colorLabel) })
        XCTAssertEqual(byID[ids[1]], .purple)
        XCTAssertEqual(byID[ids[0]], ColorLabel.none)
    }

    func testBatchRatingAndLabelCrossTheChunkBoundary() async throws {
        let (db, ids) = try await makeDatabase(photos: 1203)
        let rated = try await db.setRating(4, forPhotoIDs: ids)
        XCTAssertEqual(rated.count, 1203)
        let labelled = try await db.setColorLabel(.green, forPhotoIDs: ids)
        XCTAssertEqual(labelled.count, 1203)
        let all = try await db.allPhotos()
        XCTAssertEqual(all.filter { $0.rating == 4 && $0.colorLabel == .green }.count, 1203)
    }

    // MARK: Model

    private func publishCount(_ model: CatalogModel, during work: () async -> Void) async -> Int {
        var count = 0
        let sink = model.$photos.dropFirst().sink { _ in count += 1 }
        await work()
        sink.cancel()
        return count
    }

    func testModelBatchesPublishPhotosOnceAndUpdateLocalAndStoredState() async throws {
        let (db, ids) = try await makeDatabase()
        let model = await makeModel(db)
        var result: Set<Int64>?
        let ratingPublishes = await publishCount(model) { result = await model.setRating(3, forPhotoIDs: [ids[0], ids[1], ids[2], 9_999]) }
        XCTAssertEqual(ratingPublishes, 1)
        XCTAssertEqual(result, [ids[0], ids[1], ids[2]])
        let labelPublishes = await publishCount(model) { result = await model.setColorLabel(.red, forPhotoIDs: ids) }
        XCTAssertEqual(labelPublishes, 1)
        XCTAssertEqual(result, Set(ids))
        let flagPublishes = await publishCount(model) { result = await model.setFlagStatus(.rejected, forPhotoIDs: ids) }
        XCTAssertEqual(flagPublishes, 1, "the existing flag batch now publishes once too")
        XCTAssertEqual(model.photos.first { $0.id == ids[0] }?.rating, 3)
        XCTAssertEqual(model.photos.first { $0.id == ids[3] }?.rating, 0)
        XCTAssertTrue(model.photos.allSatisfy { $0.colorLabel == .red && $0.flagStatus == .rejected })
        let stored = try await db.allPhotos()
        XCTAssertEqual(stored.first { $0.id == ids[1] }?.rating, 3)
        XCTAssertTrue(stored.allSatisfy { $0.colorLabel == .red && $0.flagStatus == .rejected })
    }

    func testModelBatchClampsLikeTheDatabase() async throws {
        let (db, ids) = try await makeDatabase()
        let model = await makeModel(db)
        _ = await model.setRating(12, forPhotoIDs: [ids[0]])
        XCTAssertEqual(model.photos.first { $0.id == ids[0] }?.rating, 5)
        let stored = try await db.allPhotos()
        XCTAssertEqual(stored.first { $0.id == ids[0] }?.rating, 5)
    }

    func testAnEmptyBatchIsSuccessAndPublishesNothing() async throws {
        let (db, _) = try await makeDatabase()
        let model = await makeModel(db)
        var result: Set<Int64>?
        let publishes = await publishCount(model) { result = await model.setRating(2, forPhotoIDs: []) }
        XCTAssertEqual(result, [])
        XCTAssertEqual(publishes, 0)
    }

    func testAFailedWriteReturnsNilAndTheLocalStateIsReReadFromTheDatabase() async throws {
        let (db, ids) = try await makeDatabase()
        let model = await makeModel(db)
        try await db.dbQueue.write { try $0.execute(sql: """
            CREATE TRIGGER refuse_photo_update BEFORE UPDATE ON photo BEGIN SELECT RAISE(ABORT, 'refused'); END
            """) }
        var result: Set<Int64>?
        let publishes = await publishCount(model) { result = await model.setRating(4, forPhotoIDs: ids) }
        XCTAssertNil(result)
        // One local update, then the re-read (refresh publishes `photos` once).
        XCTAssertEqual(publishes, 2, "local update + exactly one refresh")
        XCTAssertTrue(model.photos.allSatisfy { $0.rating == 0 }, "the refresh restored the stored values")
        let label = await model.setColorLabel(.blue, forPhotoIDs: ids)
        XCTAssertNil(label)
        XCTAssertTrue(model.photos.allSatisfy { $0.colorLabel == ColorLabel.none })
    }
}
