import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// The camera-data scan wired into `CatalogModel`: real (synthetic, temp-dir) JPEGs with chosen EXIF go through the real
/// importer, scanner and search. No test reads the user's own files.
@MainActor
final class CatalogModelMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeJPEG(_ name: String, iso: Int?, model: String?, date: String?) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var exif: [CFString: Any] = [:]
        if let iso { exif[kCGImagePropertyExifISOSpeedRatings] = [iso] }
        if let date { exif[kCGImagePropertyExifDateTimeOriginal] = date }
        var tiff: [CFString: Any] = [:]
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [
            kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeCatalog() throws -> (CatalogModel, CatalogDatabase) {
        let db = try CatalogDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "CatalogModelMetadataTests-\(UUID().uuidString)")!
        return (CatalogModel(database: db, defaults: defaults), db)
    }

    private func settle(_ catalog: CatalogModel) async {
        await catalog.metadataScanTask?.value
    }

    func testRefreshScansTheLibraryAndFieldSearchFindsThePhotos() async throws {
        let (catalog, db) = try makeCatalog()
        let a = try writeJPEG("a.jpg", iso: 200, model: "NIKON D610", date: "2023:03:14 09:30:15")
        let b = try writeJPEG("b.jpg", iso: 3200, model: "Canon EOS R5", date: "2024:07:01 18:00:00")
        _ = try await db.importPhotos(at: [a, b])
        await catalog.refresh()
        await settle(catalog)

        XCTAssertNil(catalog.metadataScanProgress, "the status clears when the scan ends")
        XCTAssertNil(catalog.metadataScanStatusText)
        XCTAssertEqual(catalog.metadataByPhotoID.count, 2)
        catalog.searchText = "iso:>800"
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), ["b.jpg"])
        catalog.searchText = "camera:d610 date:2023"
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), ["a.jpg"])
        catalog.searchText = "date:2024-07"
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), ["b.jpg"])
        catalog.searchText = "camera:nikon iso:>800"
        XCTAssertTrue(catalog.displayedPhotos.isEmpty)
        catalog.searchText = ""
        catalog.sortOption = .captureNewest
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), ["b.jpg", "a.jpg"])
        catalog.sortOption = .captureOldest
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), ["a.jpg", "b.jpg"])
    }

    func testAnUnchangedLibraryDoesNotRescanOnEveryRefresh() async throws {
        let (catalog, db) = try makeCatalog()
        _ = try await db.importPhotos(at: [try writeJPEG("a.jpg", iso: 100, model: nil, date: nil)])
        await catalog.refresh()
        await settle(catalog)
        XCTAssertNil(catalog.metadataScanTask)
        await catalog.refresh()
        XCTAssertNil(catalog.metadataScanTask, "same photo count, full pass already done: no new scan")
    }

    func testAnImportedPhotoTriggersAScanThatReadsOnlyWhatIsNew() async throws {
        let (catalog, db) = try makeCatalog()
        _ = try await db.importPhotos(at: [try writeJPEG("a.jpg", iso: 100, model: nil, date: nil)])
        await catalog.refresh()
        await settle(catalog)
        let before = try await db.allMetadata()
        let scannedAt = try XCTUnwrap(before.values.first?.scannedAt)
        _ = try await db.importPhotos(at: [try writeJPEG("b.jpg", iso: 400, model: nil, date: nil)])
        await catalog.refresh()
        XCTAssertNotNil(catalog.metadataScanTask, "the photo count changed")
        await settle(catalog)
        XCTAssertEqual(catalog.metadataByPhotoID.count, 2)
        let old = try XCTUnwrap(catalog.metadataByPhotoID.values.first { $0.iso == 100 })
        XCTAssertEqual(old.scannedAt.timeIntervalSince1970, scannedAt.timeIntervalSince1970, accuracy: 0.01, "the existing row was reused")
    }

    func testASkippedPhotoIsRetriedAfterFolderAccessIsActivatedAgain() async throws {
        let (catalog, db) = try makeCatalog()
        let url = dir.appendingPathComponent("late.jpg")
        _ = try await db.importPhotos(at: [url])           // the file does not exist yet (stands in for "no access")
        await catalog.refresh()
        await settle(catalog)
        XCTAssertTrue(catalog.metadataByPhotoID.isEmpty, "skipped, nothing stored")
        _ = try writeJPEG("late.jpg", iso: 640, model: nil, date: nil)   // now it can be read
        await catalog.refresh()
        XCTAssertNil(catalog.metadataScanTask, "same photo count and no retry request: nothing starts by itself")
        catalog.requestMetadataRetry()                      // what activating folder access does
        await catalog.refresh()
        XCTAssertNotNil(catalog.metadataScanTask, "the retry request starts a scan even though the photo count is unchanged")
        await settle(catalog)
        XCTAssertEqual(catalog.metadataByPhotoID.values.first?.iso, 640)
        await catalog.refresh()
        XCTAssertNil(catalog.metadataScanTask, "the request is consumed: no endless rescans")
    }

    func testFolderAccessActivationRequestsARetry() throws {
        // `activateFolderAccess` is private (it needs a real security-scoped folder), so pin the wiring in the source.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/CatalogModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func activateFolderAccess(for folder: URL) -> String? {"))
        let body = String(source[start.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("requestMetadataRetry()"), "activating folder access must request a camera-data retry")
    }

    func testPhotosWithoutExifGetNoCameraDataButStillListAndFilterByName() async throws {
        let (catalog, db) = try makeCatalog()
        _ = try await db.importPhotos(at: [try writeJPEG("plain.jpg", iso: nil, model: nil, date: nil)])
        await catalog.refresh()
        await settle(catalog)
        catalog.searchText = "plain"
        XCTAssertEqual(catalog.displayedPhotos.count, 1)
        catalog.searchText = "iso:>0"
        XCTAssertTrue(catalog.displayedPhotos.isEmpty)
    }

    func testPhotosWhoseFilesAreMissingAreSkippedWithoutBreakingTheScan() async throws {
        let (catalog, db) = try makeCatalog()
        let real = try writeJPEG("real.jpg", iso: 800, model: nil, date: nil)
        _ = try await db.importPhotos(at: [real, dir.appendingPathComponent("gone.jpg")])
        await catalog.refresh()
        await settle(catalog)
        XCTAssertEqual(catalog.metadataByPhotoID.count, 1)
        XCTAssertNil(catalog.metadataScanProgress)
    }

    func testRemovingAPhotoDropsItsCameraData() async throws {
        let (catalog, db) = try makeCatalog()
        _ = try await db.importPhotos(at: [try writeJPEG("a.jpg", iso: 100, model: nil, date: nil)])
        await catalog.refresh()
        await settle(catalog)
        XCTAssertEqual(catalog.metadataByPhotoID.count, 1, "the scan produced the row first")
        let photo = try XCTUnwrap(catalog.photos.first)
        catalog.removePhoto(photo)
        XCTAssertTrue(catalog.metadataByPhotoID.isEmpty)
    }

    func testASavedQueryCollectionShowsExactlyWhatTheSearchShowed() async throws {
        let (catalog, db) = try makeCatalog()
        _ = try await db.importPhotos(at: [
            try writeJPEG("a.jpg", iso: 200, model: "NIKON D610", date: "2023:03:14 09:30:15"),
            try writeJPEG("b.jpg", iso: 3200, model: "NIKON D610", date: "2023:03:15 09:30:15"),
            try writeJPEG("c.jpg", iso: 3200, model: "Canon EOS R5", date: "2024:07:01 18:00:00")
        ])
        await catalog.refresh()
        await settle(catalog)
        catalog.searchText = "camera:d610 iso:>800"
        let shown = catalog.displayedPhotos.map(\.filename)
        XCTAssertEqual(shown, ["b.jpg"])
        let saved = await catalog.saveFiltersAsSmartCollection(name: "D610 high ISO")
        XCTAssertTrue(saved)
        XCTAssertEqual(catalog.searchText, "")
        XCTAssertEqual(catalog.displayedPhotos.map(\.filename), shown, "the collection shows what the search showed")
        XCTAssertEqual(catalog.selectedSmartCollectionQuery, "camera:d610 iso:>800")
        // The bar's own search still narrows INSIDE the collection.
        catalog.searchText = "zzz"
        XCTAssertTrue(catalog.displayedPhotos.isEmpty)
        catalog.searchText = ""
        // Back to All Photos: the query no longer applies.
        catalog.selectedFilter = .allPhotos
        XCTAssertEqual(catalog.displayedPhotos.count, 3)
        XCTAssertEqual(catalog.selectedSmartCollectionQuery, "")
    }

    func testTheSearchHelpCoversEveryFieldAndEveryExampleParses() {
        XCTAssertEqual(Set(SearchHelp.rows.map(\.field)), Set(SearchQuery.Field.allCases.map(\.rawValue)))
        for row in SearchHelp.rows {
            let query = SearchQuery(parsing: row.example)
            XCTAssertEqual(query.terms.count, 1, row.example)
            XCTAssertTrue(query.invalidTerms.isEmpty, row.example)
            XCTAssertTrue(row.example.hasPrefix(row.field + ":"), row.example)
        }
    }
}
