import XCTest
import CoreImage
@testable import PhotoApp

/// `ThumbnailGenerator.thumbnail(for:maxPixelSize:)` reads a real file via
/// ImageIO, so unlike the other `Sources/Rendering` helpers (which operate
/// on in-memory `CIImage`s) these tests write a small real image to a temp
/// file first.
final class ThumbnailGeneratorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes a solid-color square PNG of `size`x`size` pixels and returns
    /// its URL.
    private func writeSolidColorPNG(size: Int, named name: String = "test.png") throws -> URL {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let context = CIContext()
        let url = tempDir.appendingPathComponent(name)
        try context.writePNGRepresentation(
            of: image,
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    func testReturnsAThumbnailNoLargerThanRequested() throws {
        let url = try writeSolidColorPNG(size: 800)

        let thumbnail = ThumbnailGenerator.thumbnail(for: url, maxPixelSize: 200)

        let image = try XCTUnwrap(thumbnail)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 200)
    }

    func testSmallSourceImageIsNotUpscaledBeyondItsOwnSize() throws {
        let url = try writeSolidColorPNG(size: 50)

        let thumbnail = ThumbnailGenerator.thumbnail(for: url, maxPixelSize: 200)

        let image = try XCTUnwrap(thumbnail)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 50)
    }

    func testNonexistentFileReturnsNil() {
        let missing = tempDir.appendingPathComponent("does-not-exist.png")
        XCTAssertNil(ThumbnailGenerator.thumbnail(for: missing, maxPixelSize: 200))
    }

    func testNonImageFileReturnsNil() throws {
        let url = tempDir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ThumbnailGenerator.thumbnail(for: url, maxPixelSize: 200))
    }

    // MARK: - thumbnail(for:maxPixelSize:editState:) — edit-aware thumbnails

    func testIdentityEditStateReturnsAThumbnailOfTheRequestedSize() throws {
        let url = try writeSolidColorPNG(size: 800)

        let thumbnail = ThumbnailGenerator.thumbnail(for: url, maxPixelSize: 200, editState: .identity)

        let image = try XCTUnwrap(thumbnail)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 200)
    }

    /// A real, visible adjustment must actually run through `EditPipeline`
    /// — proven structurally (r == g == b on a known-colored, non-gray
    /// source), the same style of assertion this project's own
    /// `EditPipelineTests` already uses for Black & White, rather than a
    /// fabricated exact pixel value.
    func testNonIdentityEditStateActuallyAppliesTheAdjustment() throws {
        let url = try writeSolidColorPNG(size: 200) // solid red — r != g, r != b

        var editState = EditState()
        editState.blackAndWhite = true
        let thumbnail = try XCTUnwrap(ThumbnailGenerator.thumbnail(for: url, maxPixelSize: 200, editState: editState))

        let data = try XCTUnwrap(thumbnail.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)
        let bytesPerRow = thumbnail.bytesPerRow
        // Sample the center pixel — RGBA8, so 4 bytes/pixel.
        let x = thumbnail.width / 2
        let y = thumbnail.height / 2
        let offset = y * bytesPerRow + x * 4
        let r = bytes?[offset]
        let g = bytes?[offset + 1]
        let b = bytes?[offset + 2]
        XCTAssertEqual(r, g)
        XCTAssertEqual(g, b)
    }

    func testEditAwareThumbnailOfNonexistentFileReturnsNil() {
        let missing = tempDir.appendingPathComponent("does-not-exist.png")
        XCTAssertNil(ThumbnailGenerator.thumbnail(for: missing, maxPixelSize: 200, editState: .identity))
    }
}
