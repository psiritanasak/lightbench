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
}
