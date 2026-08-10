import XCTest
@testable import PhotoApp

/// Exercises `CatalogDatabase` against an in-memory GRDB queue — fast,
/// disk/network-free, matching this project's existing math/logic-focused
/// test convention (`EditHistoryTests`, `EditStateCodableTests`, etc.).
final class CatalogDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase(inMemory: true)
    }

    func testImportInsertsNewPhotos() async throws {
        let db = try makeDatabase()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.png")
        ]

        let result = try await db.importPhotos(at: urls)

        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.skipped, 0)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 2)
    }

    func testReimportingSamePathsIsIdempotent() async throws {
        let db = try makeDatabase()
        let urls = [URL(fileURLWithPath: "/tmp/a.jpg")]

        _ = try await db.importPhotos(at: urls)
        let second = try await db.importPhotos(at: urls)

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.skipped, 1)
        let count = try await db.photoCount()
        XCTAssertEqual(count, 1, "re-importing the same path must not create a duplicate row")
    }

    func testMixedNewAndExistingPathsReportsBothCounts() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])

        let result = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/c.heic")
        ])

        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    func testInsertedFieldsRoundTripThroughFetch() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/IMG_0001.jpg")])

        let photos = try await db.allPhotos()

        XCTAssertEqual(photos.count, 1)
        let photo = try XCTUnwrap(photos.first)
        XCTAssertNotNil(photo.id, "GRDB should assign the autoincremented rowid on insert")
        XCTAssertEqual(photo.path, "/tmp/IMG_0001.jpg")
        XCTAssertEqual(photo.filename, "IMG_0001.jpg")
    }

    func testAllPhotosOrdersByImportedAt() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/first.jpg")])
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/second.jpg")])

        let photos = try await db.allPhotos()

        XCTAssertEqual(photos.map(\.filename), ["first.jpg", "second.jpg"])
    }

    // MARK: - Ratings and flags (Phase 4 slice 3)

    func testNewlyImportedPhotoDefaultsToUnratedAndUnflagged() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)

        XCTAssertEqual(photo.rating, 0)
        XCTAssertFalse(photo.isFlagged)
    }

    func testSetRatingUpdatesTheStoredValue() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(3, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 3)
    }

    func testSetRatingClampsAboveFive() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(99, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 5)
    }

    func testSetRatingClampsBelowZero() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setRating(-1, for: id)

        let photos = try await db.allPhotos()
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 0)
    }

    func testSetFlaggedTogglesTheStoredValue() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let importedPhotos = try await db.allPhotos()
        let id = try XCTUnwrap(importedPhotos.first?.id)

        try await db.setFlagged(true, for: id)
        let flaggedPhotos = try await db.allPhotos()
        let flaggedPhoto = try XCTUnwrap(flaggedPhotos.first)
        XCTAssertTrue(flaggedPhoto.isFlagged)

        try await db.setFlagged(false, for: id)
        let unflaggedPhotos = try await db.allPhotos()
        let unflaggedPhoto = try XCTUnwrap(unflaggedPhotos.first)
        XCTAssertFalse(unflaggedPhoto.isFlagged)
    }

    // MARK: - Collections (Phase 4 slice 4)

    func testCreateCollectionAssignsAnID() async throws {
        let db = try makeDatabase()

        let collection = try await db.createCollection(name: "Trip")

        XCTAssertNotNil(collection.id)
        XCTAssertEqual(collection.name, "Trip")
    }

    func testAllCollectionsOrdersByName() async throws {
        let db = try makeDatabase()
        _ = try await db.createCollection(name: "Zebra")
        _ = try await db.createCollection(name: "Apple")

        let collections = try await db.allCollections()

        XCTAssertEqual(collections.map(\.name), ["Apple", "Zebra"])
    }

    func testSetMembershipAddsPhotoToCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg")
        ])
        let photos = try await db.allPhotos()
        let targetID = try XCTUnwrap(photos.first(where: { $0.filename == "a.jpg" })?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: targetID, collectionID: collectionID, isMember: true)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(inCollection.map(\.filename), ["a.jpg"])

        // Collections don't affect the base library.
        let all = try await db.allPhotos()
        XCTAssertEqual(all.count, 2)
    }

    func testSetMembershipIsIdempotent() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertEqual(inCollection.count, 1, "adding the same membership twice must not duplicate the row")
    }

    func testSetMembershipRemovesPhotoFromCollection() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)
        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: false)

        let inCollection = try await db.photos(inCollection: collectionID)
        XCTAssertTrue(inCollection.isEmpty)
    }

    func testAllMembershipsReflectsCurrentState() async throws {
        let db = try makeDatabase()
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let collection = try await db.createCollection(name: "Trip")
        let collectionID = try XCTUnwrap(collection.id)

        try await db.setMembership(photoID: photoID, collectionID: collectionID, isMember: true)

        let memberships = try await db.allMemberships()
        XCTAssertEqual(memberships, [CollectionPhoto(collectionId: collectionID, photoId: photoID)])
    }
}
