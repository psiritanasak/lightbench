import CoreImage
import XCTest
@testable import PhotoApp

final class CullPreviewCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullPreviewCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    /// A real PNG on disk wrapped in the catalog row the cache takes.
    private func makePhoto(_ id: Int64, size: Int = 1600) throws -> Photo {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size * 2 / 3))
        let url = tempDir.appendingPathComponent("p\(id).png")
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
    }

    /// Polls until the decode is actually running (deterministic, unlike a fixed sleep); fails if it never starts.
    private func waitUntilDecoding(_ cache: CullPreviewCache, _ photo: Photo) async throws {
        for _ in 0..<2000 {
            if await cache.isDecoding(photo, pixelSize: 2304) { return }
            try await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("the decode never started")
    }

    // MARK: Pure sizing

    func testTargetPixelSizeIsViewTimesScaleWithinTheFloorAndCap() {
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 1000, scale: 2), 2048, "2000 rounds up to the next 256 step")
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 1024, scale: 2), 2048)
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 1025, scale: 2), 2304)
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 2000, scale: 2), CullPreviewCache.maxPixelSize, "capped")
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 100, scale: 1), CullPreviewCache.minPixelSize, "floored")
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: .nan, scale: 2), CullPreviewCache.minPixelSize)
        XCTAssertEqual(CullPreviewCache.targetPixelSize(viewLongEdge: 800, scale: 0), CullPreviewCache.minPixelSize)
    }

    // MARK: Decode + cache

    func testAPreviewIsNoLargerThanRequestedAndIsCached() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1)
        let preview = await cache.preview(for: photo, pixelSize: 800)
        let image = try XCTUnwrap(preview)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 800)
        XCTAssertGreaterThan(image.width, 400, "a real preview, not a thumbnail")
        let hit = await cache.cached(for: photo, pixelSize: 800)
        XCTAssertTrue(hit === image, "the same object comes back from the cache")
        let again = await cache.preview(for: photo, pixelSize: 800)
        XCTAssertTrue(again === image)
    }

    func testTheCacheIsKeyedBySizeSoALargerRequestIsNotServedASmallerImage() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1, size: 2400)
        let smallPreview = await cache.preview(for: photo, pixelSize: 600)
        let bigPreview = await cache.preview(for: photo, pixelSize: 1800)
        let small = try XCTUnwrap(smallPreview), big = try XCTUnwrap(bigPreview)
        XCTAssertLessThanOrEqual(max(small.width, small.height), 600)
        XCTAssertGreaterThan(max(big.width, big.height), 1200)
        let none = await cache.cached(for: photo, pixelSize: 1200)
        XCTAssertNil(none, "an unrequested size is not cached")
    }

    func testConcurrentRequestsShareOneDecode() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1)
        async let a = cache.preview(for: photo, pixelSize: 1000)
        async let b = cache.preview(for: photo, pixelSize: 1000)
        let (x, y) = await (a, b)
        let first = try XCTUnwrap(x), second = try XCTUnwrap(y)
        XCTAssertTrue(first === second, "both callers awaited the same decode")
    }

    func testAMissingFileGivesNilAndIsNotCached() async {
        let cache = CullPreviewCache()
        let ghost = Photo(id: 9, path: tempDir.appendingPathComponent("nope.png").path, filename: "nope.png", fileSize: nil,
                          importedAt: Date(timeIntervalSince1970: 0))
        let preview = await cache.preview(for: ghost, pixelSize: 800)
        XCTAssertNil(preview)
        let hit = await cache.cached(for: ghost, pixelSize: 800)
        XCTAssertNil(hit)
    }

    func testInvalidateDropsTheCachedPreview() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1)
        // Arbitrary sizes (what a real window produces), not just the floor and the cap.
        for size in [700, 1000, 2304] { _ = await cache.preview(for: photo, pixelSize: size) }
        let before = await cache.cached(for: photo, pixelSize: 1000)
        XCTAssertNotNil(before)
        await cache.invalidate(path: photo.path)
        for size in [700, 1000, 2304] {
            let after = await cache.cached(for: photo, pixelSize: size)
            XCTAssertNil(after, "size \(size)")
        }
    }

    /// A decode still running when `invalidate` / `removeAll` runs must not write its result into the cache afterwards.
    func testADecodeInFlightDuringInvalidateOrRemoveAllIsNotCached() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1, size: 2400)
        let running = Task { await cache.preview(for: photo, pixelSize: 2304) }
        try await waitUntilDecoding(cache, photo)
        await cache.invalidate(path: photo.path)
        _ = await running.value
        let afterInvalidate = await cache.cached(for: photo, pixelSize: 2304)
        XCTAssertNil(afterInvalidate)

        let running2 = Task { await cache.preview(for: photo, pixelSize: 2304) }
        try await waitUntilDecoding(cache, photo)
        await cache.removeAll()
        _ = await running2.value
        let afterRemoveAll = await cache.cached(for: photo, pixelSize: 2304)
        XCTAssertNil(afterRemoveAll)
    }

    // MARK: Prefetch

    func testPrefetchWarmsTheWantedPhotos() async throws {
        let cache = CullPreviewCache()
        let photos = try (1...3).map { try makePhoto(Int64($0), size: 900) }
        await cache.setWanted(photos, pixelSize: 700)
        await cache.idle()
        for photo in photos {
            let hit = await cache.cached(for: photo, pixelSize: 700)
            XCTAssertNotNil(hit, photo.filename)
        }
    }

    /// A newer wanted set stops the older one before its next photo: cancelling straight away leaves most of a long list undecoded.
    func testANewWantedSetAbandonsTheStaleOne() async throws {
        let cache = CullPreviewCache()
        // 7 photos: under the cache's count limit of 8, so every completed decode would still be resident and counted.
        let photos = try (1...7).map { try makePhoto(Int64($0), size: 1200) }
        await cache.setWanted(photos, pixelSize: 1000)
        await cache.setWanted([], pixelSize: 1000)
        await cache.idle()
        var decoded = 0
        for photo in photos { if await cache.cached(for: photo, pixelSize: 1000) != nil { decoded += 1 } }
        XCTAssertLessThanOrEqual(decoded, 2, "the stale prefetch stopped almost at once (at most the decode already running)")
    }

    func testRemoveAllEmptiesTheCache() async throws {
        let cache = CullPreviewCache()
        let photo = try makePhoto(1)
        _ = await cache.preview(for: photo, pixelSize: 800)
        await cache.removeAll()
        let hit = await cache.cached(for: photo, pixelSize: 800)
        XCTAssertNil(hit)
    }
}
