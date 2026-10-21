import XCTest
@testable import PhotoApp

final class ImportCopiedFilesTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Photos/Library", isDirectory: true)

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testPhotosJoinTheCollectionOfTheirDirectFolderAndTheChainBelowRootIsMirrored() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let result = try await db.importCopiedFiles(
            [url("/Photos/Library/2026/10-19/a.jpg"), url("/Photos/Library/2026/10-19/b.jpg"), url("/Photos/Library/2026/10-20/c.jpg")],
            under: root
        )
        XCTAssertEqual(result.inserted, 3)
        let collections = try await db.allCollections()
        let byPath = Dictionary(uniqueKeysWithValues: collections.compactMap { c in c.folderPath.map { ($0, c) } })
        XCTAssertNotNil(byPath["/Photos/Library"])
        XCTAssertNil(byPath["/Photos/Library"]?.parentId)
        XCTAssertEqual(byPath["/Photos/Library/2026"]?.parentId, byPath["/Photos/Library"]?.id)
        XCTAssertEqual(byPath["/Photos/Library/2026/10-19"]?.parentId, byPath["/Photos/Library/2026"]?.id)
        XCTAssertNil(byPath["/Photos"], "nothing above the destination root is mirrored")
        let day19 = try await db.photos(inCollection: try XCTUnwrap(byPath["/Photos/Library/2026/10-19"]?.id))
        XCTAssertEqual(day19.map(\.filename).sorted(), ["a.jpg", "b.jpg"])
    }

    func testRunningItAgainIsIdempotent() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let files = [url("/Photos/Library/a.jpg"), url("/Photos/Library/sub/b.jpg")]
        _ = try await db.importCopiedFiles(files, under: root)
        let again = try await db.importCopiedFiles(files, under: root)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.skipped, 2)
        let photoCount = try await db.allPhotos().count
        let collectionCount = try await db.allCollections().count
        XCTAssertEqual(photoCount, 2)
        XCTAssertEqual(collectionCount, 2) // root + sub
    }

    func testOnlyTheGivenFilesAreRegistered() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importCopiedFiles([url("/Photos/Library/new.jpg")], under: root)
        let names = try await db.allPhotos().map(\.filename)
        XCTAssertEqual(names, ["new.jpg"])
    }
}
