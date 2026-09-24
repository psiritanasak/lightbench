import XCTest
import CoreImage
@testable import PhotoApp

/// `PhotoExporter` reads real files (the source photo, its sidecar JSON)
/// and writes real files (the export output), so — like
/// `ThumbnailGeneratorTests` — these tests work against a real temp
/// directory rather than pure in-memory fixtures.
final class PhotoExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func solidColorImage(size: Int) -> CIImage {
        CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Writes a solid-color square JPEG of `size`x`size` pixels and
    /// returns its URL, mirroring `ThumbnailGeneratorTests`' PNG-writing
    /// helper but as a JPEG (a more realistic "source photo" format).
    private func writeSolidColorJPEG(size: Int, named name: String = "source.jpg") throws -> URL {
        let context = CIContext()
        let url = tempDir.appendingPathComponent(name)
        try context.writeJPEGRepresentation(
            of: solidColorImage(size: size),
            to: url,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return url
    }

    private func readPixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight as String] as? Int)
        return (width, height)
    }

    // MARK: - resized

    func testResizedScalesDownToFitMaxLongEdge() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(200))

        XCTAssertEqual(max(resized.extent.width, resized.extent.height), 200, accuracy: 0.5)
    }

    func testResizedDoesNotUpscaleBeyondSourceSize() {
        let image = solidColorImage(size: 50)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(200))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedOriginalLeavesImageUnchanged() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .original)

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedTreatsZeroMaxLongEdgeAsNoOp() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(0))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    func testResizedTreatsNegativeMaxLongEdgeAsNoOp() {
        let image = solidColorImage(size: 800)

        let resized = PhotoExporter.resized(image, option: .maxLongEdge(-100))

        XCTAssertEqual(resized.extent.size, image.extent.size)
    }

    // MARK: - uniqueDestinationURL

    private func makePhoto(filename: String) -> Photo {
        Photo(id: 1, path: "/tmp/\(filename)", filename: filename, fileSize: nil, importedAt: Date())
    }

    func testUniqueDestinationURLUsesPlainNameWhenNoCollision() {
        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.jpg")
    }

    func testUniqueDestinationURLAddsSuffixOnCollision() throws {
        let existing = tempDir.appendingPathComponent("IMG_0001.jpg")
        FileManager.default.createFile(atPath: existing.path, contents: Data())

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (2).jpg")
    }

    func testUniqueDestinationURLIncrementsSuffixPastMultipleCollisions() throws {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_0001.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_0001 (2).jpg").path, contents: Data())

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (3).jpg")
    }

    func testUniqueDestinationURLUsesTheRequestedFormatExtension() {
        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .png)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.png")
    }

    /// Added alongside `uniqueFileURL`'s own extraction (shared with
    /// `PhotoEnhancer`): a candidate whose FILE doesn't exist, but whose
    /// SIDECAR does (an orphan left behind by an earlier, since-deleted
    /// export/enhance at that name), must still be treated as taken —
    /// otherwise the next write at that name would silently inherit the
    /// orphan's stale edits.
    func testUniqueDestinationURLSkipsACandidateWithOnlyAnOrphanedSidecar() throws {
        let candidate = tempDir.appendingPathComponent("IMG_0001.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        let orphanSidecar = SidecarStore.sidecarURL(for: candidate)
        try JSONEncoder().encode(EditState()).write(to: orphanSidecar)

        let url = PhotoExporter.uniqueDestinationURL(for: makePhoto(filename: "IMG_0001.jpg"), in: tempDir, format: .jpeg)

        XCTAssertEqual(url.lastPathComponent, "IMG_0001 (2).jpg")
    }

    // MARK: - loadEditState

    func testLoadEditStateReturnsIdentityWhenNoSidecarExists() {
        let photo = makePhoto(filename: "no-sidecar.jpg")
        XCTAssertEqual(PhotoExporter.loadEditState(for: photo), .identity)
    }

    func testLoadEditStateDecodesARealSidecarFile() throws {
        let photoURL = tempDir.appendingPathComponent("edited.jpg")
        var state = EditState()
        state.exposureEV = 1.5
        let sidecarURL = ImageDocumentModel.sidecarURL(for: photoURL)
        try JSONEncoder().encode(state).write(to: sidecarURL)

        let photo = Photo(id: 1, path: photoURL.path, filename: "edited.jpg", fileSize: nil, importedAt: Date())
        let loaded = PhotoExporter.loadEditState(for: photo)

        XCTAssertEqual(loaded.exposureEV, 1.5)
    }

    // MARK: - export (end-to-end)

    func testExportWritesAReadableJPEGWithIdentityEditState() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 400)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings(format: .jpeg))

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertNotNil(CIImage(contentsOf: outputURL))
    }

    func testExportWritesPNGAndTIFF() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 200)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for format in [ExportFormat.png, .tiff] {
            let outputURL = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings(format: format))
            XCTAssertEqual(outputURL.pathExtension, format.fileExtension)
            XCTAssertNotNil(CIImage(contentsOf: outputURL))
        }
    }

    func testExportRespectsResizeSetting() async throws {
        let sourceURL = try writeSolidColorJPEG(size: 800)
        let photo = Photo(id: 1, path: sourceURL.path, filename: sourceURL.lastPathComponent, fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = try await PhotoExporter.export(
            photo,
            editState: .identity,
            to: outputDir,
            settings: ExportSettings(format: .png, resize: .maxLongEdge(200))
        )

        let size = try readPixelSize(of: outputURL)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 200)
    }

    func testExportThrowsForUnreadableSource() async throws {
        let photo = Photo(id: 1, path: "/tmp/does-not-exist-\(UUID().uuidString).jpg", filename: "missing.jpg", fileSize: nil, importedAt: Date())
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        do {
            _ = try await PhotoExporter.export(photo, editState: .identity, to: outputDir, settings: ExportSettings())
            XCTFail("expected export to throw for an unreadable source")
        } catch {
            // expected
        }
    }
}
