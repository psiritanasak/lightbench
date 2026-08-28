import XCTest
import CoreImage
@testable import PhotoApp

/// Exercises `ThumbnailCache`'s caching, in-flight de-duplication,
/// invalidation, and — the point of this file's existence — that decodes
/// actually run CONCURRENTLY rather than serialized on the actor.
///
/// Like `ThumbnailGeneratorTests`, these need real files on disk (the cache
/// decodes via ImageIO and reads sidecars via `PhotoExporter.loadEditState`),
/// so each test writes into its own temp directory.
final class ThumbnailCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// A solid-color PNG — cheap to write and decode, for the correctness
    /// tests where decode COST is irrelevant.
    @discardableResult
    private func writeSolidColorPNG(size: Int, named name: String) throws -> URL {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let url = tempDir.appendingPathComponent(name)
        try CIContext().writePNGRepresentation(
            of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    /// A NOISE PNG — deliberately incompressible, so the file is large and
    /// ImageIO genuinely has to decode it (a solid-color PNG decodes far too
    /// fast to time meaningfully). Used only by the parallelism test.
    private func writeNoisePNG(size: Int, named name: String) throws -> URL {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let url = tempDir.appendingPathComponent(name)
        try CIContext().writePNGRepresentation(
            of: noise, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    private func photo(at url: URL) -> Photo {
        Photo(id: nil, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date())
    }

    /// Center-pixel RGB of an RGBA8 `CGImage`, matching the sampling
    /// `ThumbnailGeneratorTests` already uses.
    private func centerPixel(of image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    // MARK: - Caching and de-duplication

    /// Deliberately asserts EQUIVALENCE, not instance identity. `NSCache`
    /// gives no residency guarantee — it may evict at any moment, including
    /// immediately, so a re-request is always free to re-decode. An earlier
    /// draft of this test asserted `first === second` and passed in
    /// isolation but FAILED in a full-suite run, where other tests' memory
    /// pressure evicted the entry between the two calls. Re-decoding there
    /// is correct behavior, not a bug, so the test asserts what must hold
    /// either way.
    func testRepeatRequestReturnsAnEquivalentImage() async throws {
        let url = try writeSolidColorPNG(size: 200, named: "a.png")
        let cache = ThumbnailCache()
        let subject = photo(at: url)

        let firstResult = await cache.thumbnail(for: subject)
        let secondResult = await cache.thumbnail(for: subject)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
    }

    func testConcurrentRequestsForTheSamePathBothResolve() async throws {
        let url = try writeSolidColorPNG(size: 200, named: "a.png")
        let cache = ThumbnailCache()
        let subject = photo(at: url)

        async let firstRequest = cache.thumbnail(for: subject)
        async let secondRequest = cache.thumbnail(for: subject)
        let firstResult = await firstRequest
        let secondResult = await secondRequest
        let a = try XCTUnwrap(firstResult)
        let b = try XCTUnwrap(secondResult)

        // In-flight de-duplication is a best-effort optimization, not a
        // guarantee — see `testRepeatRequestReturnsAnEquivalentImage` on
        // why `NSCache` eviction makes instance identity unassertable. What
        // must always hold is that both concurrent requests resolve to the
        // same image, rather than one of them failing or racing to a
        // corrupted result.
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
    }

    func testInvalidateForcesAFreshDecode() async throws {
        let url = try writeSolidColorPNG(size: 200, named: "a.png")
        let cache = ThumbnailCache()
        let subject = photo(at: url)

        let beforeResult = await cache.thumbnail(for: subject)
        let before = try XCTUnwrap(beforeResult)
        await cache.invalidate(path: url.path)
        let afterResult = await cache.thumbnail(for: subject)
        let after = try XCTUnwrap(afterResult)

        XCTAssertFalse(before === after, "invalidate must drop the cached entry so the next request re-decodes")
    }

    func testConcurrentRequestsForDistinctPathsAllSucceed() async throws {
        let count = 16
        let photos = try (0..<count).map { photo(at: try writeSolidColorPNG(size: 200, named: "img\($0).png")) }
        let cache = ThumbnailCache()

        let results = await withTaskGroup(of: CGImage?.self) { group in
            for subject in photos { group.addTask { await cache.thumbnail(for: subject) } }
            var collected: [CGImage] = []
            for await result in group { if let result { collected.append(result) } }
            return collected
        }

        XCTAssertEqual(results.count, count, "every concurrent request must resolve")
        let distinct = Set(results.map(ObjectIdentifier.init))
        XCTAssertEqual(distinct.count, count, "distinct paths must not share cache entries")
    }

    // MARK: - Saved edits still applied

    /// The decode runs off this actor inside a plain `Task { }`; this
    /// proves the sidecar → `EditPipeline` path still runs within it. A
    /// solid-RED source forced to black & white must come back with
    /// r == g == b — the same structural assertion
    /// `ThumbnailGeneratorTests` uses.
    func testSavedEditsAreStillAppliedThroughTheCache() async throws {
        let url = try writeSolidColorPNG(size: 200, named: "edited.png")
        var editState = EditState()
        editState.blackAndWhite = true
        try JSONEncoder().encode(editState).write(to: ImageDocumentModel.sidecarURL(for: url))

        let cache = ThumbnailCache()
        let thumbnailResult = await cache.thumbnail(for: photo(at: url))
        let thumbnail = try XCTUnwrap(thumbnailResult)

        let pixel = try centerPixel(of: thumbnail)
        XCTAssertEqual(pixel.r, pixel.g)
        XCTAssertEqual(pixel.g, pixel.b)
    }

    // MARK: - Parallelism

    /// Pins down that thumbnail decodes genuinely run CONCURRENTLY, which
    /// this cache has always done — the `Task { }` in `thumbnail(for:)`
    /// does not, in practice, pin the decode to the actor's executor.
    /// This test exists because the opposite was plausibly argued from the
    /// `@_inheritActorContext` semantics and written up as a performance
    /// bug; it measured 0.32 both before and after a `Task.detached`
    /// rewrite, which is what retired that theory. It now guards against a
    /// future change that WOULD serialize decoding (e.g. making the decode
    /// actor-isolated), which would push the ratio toward 1.0.
    ///
    /// The one TIMING-SENSITIVE test in this file. Self-calibrating — it
    /// measures its own serial baseline rather than asserting an absolute
    /// duration, so it adapts to machine speed. The CONCURRENT pass runs
    /// FIRST on purpose: the serial pass then benefits from a warm
    /// filesystem cache, which biases the comparison AGAINST the
    /// assertion, never for it. Measured ratio ~0.32 on an 8-image set;
    /// the 0.8 threshold is deliberately loose. If this ever flakes on a
    /// loaded or single-core machine, relax or delete it rather than
    /// chasing it.
    func testDecodesRunInParallel() async throws {
        let count = 8
        let urls = try (0..<count).map { try writeNoisePNG(size: 1600, named: "noise\($0).png") }
        let photos = urls.map { photo(at: $0) }

        let concurrentCache = ThumbnailCache()
        let concurrentStart = CFAbsoluteTimeGetCurrent()
        await withTaskGroup(of: CGImage?.self) { group in
            for subject in photos { group.addTask { await concurrentCache.thumbnail(for: subject) } }
            for await _ in group {}
        }
        let concurrentElapsed = CFAbsoluteTimeGetCurrent() - concurrentStart

        let serialCache = ThumbnailCache()
        let serialStart = CFAbsoluteTimeGetCurrent()
        for subject in photos { _ = await serialCache.thumbnail(for: subject) }
        let serialElapsed = CFAbsoluteTimeGetCurrent() - serialStart

        print(String(
            format: "[ThumbnailCache] concurrent %.3fs vs serial %.3fs (ratio %.2f) over %d images",
            concurrentElapsed, serialElapsed, concurrentElapsed / serialElapsed, count
        ))
        XCTAssertLessThan(
            concurrentElapsed, serialElapsed * 0.8,
            "thumbnail decodes appear to have become serialized on the actor"
        )
    }
    /// The companion guarantee to `testDecodesRunInParallel`: a cache HIT
    /// must not be stuck behind decodes that are currently in flight. This
    /// is the Library's responsiveness property — already-decoded cells
    /// keep rendering while new ones are still being read.
    ///
    /// Measured at 0.0 ms against in-flight decodes of 8 large images, so
    /// the 50 ms bound below is enormous headroom for an in-memory
    /// `NSCache` lookup; it is a smoke alarm, not a benchmark.
    func testCacheHitIsNotBlockedByInFlightDecodes() async throws {
        let smallURL = try writeSolidColorPNG(size: 200, named: "small.png")
        let cache = ThumbnailCache()
        let small = photo(at: smallURL)
        _ = await cache.thumbnail(for: small) // warm the cache entry

        let noise = try (0..<8).map { photo(at: try writeNoisePNG(size: 1600, named: "n\($0).png")) }

        async let bulk: Void = withTaskGroup(of: CGImage?.self) { group in
            for subject in noise { group.addTask { await cache.thumbnail(for: subject) } }
            for await _ in group {}
        }
        try await Task.sleep(nanoseconds: 3_000_000) // let the decodes get going

        let hitStart = CFAbsoluteTimeGetCurrent()
        let hit = await cache.thumbnail(for: small)
        let hitElapsed = CFAbsoluteTimeGetCurrent() - hitStart
        await bulk

        XCTAssertNotNil(hit)
        XCTAssertLessThan(hitElapsed, 0.050, "a cache hit stalled behind in-flight decodes")
    }
}
