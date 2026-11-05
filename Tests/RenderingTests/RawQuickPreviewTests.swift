import XCTest
import CoreImage
@testable import PhotoApp

/// The Library grid's quick stand-in for a RAW photo's thumbnail (`ThumbnailGenerator.embeddedPreview`, `ThumbnailCache.quickPreview`,
/// `AppPreferences.quickRawPreviews`). The repo has no real RAW fixture, so a JPEG written under a `.nef` name stands in: `RawDecoder.isRaw`
/// goes by extension, and ImageIO sniffs the real bytes. These tests pin the GATES (RAW only, unedited only, switchable, never cached);
/// the real embedded preview of a D610 NEF was checked live (see docs/ROADMAP_HISTORY.md, "Quick RAW previews").
final class RawQuickPreviewTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RawQuickPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func writeJPEG(named name: String, size: Int = 600) throws -> URL {
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let url = tempDir.appendingPathComponent(name)
        try CIContext().writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpaceCreateDeviceRGB())
        return url
    }

    private func photo(at url: URL) -> Photo {
        Photo(id: nil, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date())
    }

    func testEmbeddedPreviewIsOnlyForRawFiles() throws {
        let raw = try writeJPEG(named: "a.nef")
        let jpg = try writeJPEG(named: "a.jpg")
        let preview = try XCTUnwrap(ThumbnailGenerator.embeddedPreview(for: raw, maxPixelSize: 240))
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 240)
        XCTAssertNil(ThumbnailGenerator.embeddedPreview(for: jpg, maxPixelSize: 240), "a non-RAW file is already fast: no stand-in")
        XCTAssertNil(ThumbnailGenerator.embeddedPreview(for: tempDir.appendingPathComponent("missing.nef"), maxPixelSize: 240))
    }

    func testQuickPreviewIsGivenForAnUneditedRawOnly() async throws {
        let raw = try writeJPEG(named: "b.nef")
        let jpg = try writeJPEG(named: "b.jpg")
        let cache = ThumbnailCache()
        let rawPreview = await cache.quickPreview(for: photo(at: raw))
        XCTAssertNotNil(rawPreview)
        let jpgPreview = await cache.quickPreview(for: photo(at: jpg))
        XCTAssertNil(jpgPreview)
    }

    func testQuickPreviewIsNotGivenForAnEditedRaw() async throws {
        let raw = try writeJPEG(named: "c.nef")
        var state = EditState()
        state.exposureEV = 1
        try JSONEncoder().encode(state).write(to: ImageDocumentModel.sidecarURL(for: raw))
        let preview = await ThumbnailCache().quickPreview(for: photo(at: raw))
        XCTAssertNil(preview, "an edited photo must not flash its unedited look")
    }

    func testAPinnedButUneditedRawStillGetsAQuickPreview() async throws {
        // Any RAW opened in the Editor and saved carries `rawDecoderVersionPin` with every slider at identity: that is still an UNEDITED photo.
        let raw = try writeJPEG(named: "e.nef")
        var state = EditState()
        state.rawDecoderVersionPin = "test-pin"
        try JSONEncoder().encode(state).write(to: ImageDocumentModel.sidecarURL(for: raw))
        let preview = await ThumbnailCache().quickPreview(for: photo(at: raw))
        XCTAssertNotNil(preview, "a decoder-version pin alone is not an edit (EditState.isEffectivelyIdentity)")
    }

    func testQuickPreviewIsNeverStoredInTheThumbnailCache() async throws {
        // `quickPreview` returns nil when the final thumbnail is already cached, so a SECOND non-nil answer proves the first call stored nothing.
        let raw = try writeJPEG(named: "d.nef")
        let cache = ThumbnailCache()
        let first = await cache.quickPreview(for: photo(at: raw))
        let second = await cache.quickPreview(for: photo(at: raw))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "the stand-in was not cached as if it were the final thumbnail")
    }

    func testPreferenceDefaultsOnAndIsPersisted() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "RawQuickPreviewTests-\(UUID().uuidString)"))
        let prefs = AppPreferences(defaults: suite)
        XCTAssertTrue(prefs.quickRawPreviews, "on by default; a missing key reads as the default")
        prefs.quickRawPreviews = false
        XCTAssertFalse(AppPreferences(defaults: suite).quickRawPreviews)
    }

    func testTheGridCellOnlyFillsAnEmptyCellAndTheCatalogHonoursThePreference() throws {
        func text(_ relative: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        let grid = try text("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains("if image == nil, let quick = await catalog.quickThumbnailPreview(for: photo), !Task.isCancelled, image == nil"))
        XCTAssertTrue(try text("Sources/UI/CatalogModel.swift").contains("guard preferences.quickRawPreviews, !Task.isCancelled, RawDecoder.isRaw(URL(fileURLWithPath: photo.path)) else { return nil }"))
    }
}
