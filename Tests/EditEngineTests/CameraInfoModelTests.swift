import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

@MainActor
final class CameraInfoModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CameraInfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeJPEG(_ name: String, iso: Int) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [iso], kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFocalLength: 50.0] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON D610"] as [CFString: Any]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testRefreshReadsTheOpenPhotosExif() async throws {
        let url = try writeJPEG("a.jpg", iso: 800)
        let doc = ImageDocumentModel()
        doc.simulateLoadFinishedForTesting(url: url, ownedKey: nil)
        await doc.refreshCameraInfo().value
        XCTAssertEqual(doc.cameraInfo?.iso, 800)
        XCTAssertEqual(ExifStripText.exposureLine(try XCTUnwrap(doc.cameraInfo)), "ISO 800 · 50 mm · f/2.8 · 1/250 s")
    }

    func testResultForAPhotoThatIsNoLongerOpenIsDropped() async throws {
        let a = try writeJPEG("a.jpg", iso: 100)
        let b = try writeJPEG("b.jpg", iso: 200)
        let doc = ImageDocumentModel()
        doc.simulateLoadFinishedForTesting(url: a, ownedKey: nil)
        let task = doc.refreshCameraInfo(read: { url in
            Thread.sleep(forTimeInterval: 0.2) // the read is still running when the user moves on
            return PhotoMetadataReader.read(from: url)
        })
        doc.simulateLoadFinishedForTesting(url: b, ownedKey: nil)
        await task.value
        XCTAssertNil(doc.cameraInfo, "A's late result must not be shown while B is open")
    }

    func testUnreadableFileLeavesNoInfo() async {
        let doc = ImageDocumentModel()
        doc.simulateLoadFinishedForTesting(url: dir.appendingPathComponent("missing.jpg"), ownedKey: nil)
        await doc.refreshCameraInfo().value
        XCTAssertNil(doc.cameraInfo)
    }

    /// A failed load leaves the old photo open, so its EXIF must stay; a successful load of B swaps in B's (cleared at the commit point).
    func testFailedLoadKeepsInfoAndSuccessfulLoadSwapsIt() async throws {
        let a = try writeJPEG("a.jpg", iso: 800)
        let b = try writeJPEG("b.jpg", iso: 200)
        let doc = ImageDocumentModel()
        await doc.load(from: a)
        try await waitForInfo(doc, iso: 800)
        await doc.load(from: dir.appendingPathComponent("does-not-exist.jpg"))
        XCTAssertEqual(doc.cameraInfo?.iso, 800, "a failed load keeps showing the photo that is still open")
        await doc.load(from: b)
        XCTAssertNotEqual(doc.cameraInfo?.iso, 800, "never B's pixels with A's EXIF once B is committed")
        try await waitForInfo(doc, iso: 200)
    }

    private func waitForInfo(_ doc: ImageDocumentModel, iso: Int) async throws {
        for _ in 0..<100 where doc.cameraInfo?.iso != iso { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(doc.cameraInfo?.iso, iso)
    }
}
