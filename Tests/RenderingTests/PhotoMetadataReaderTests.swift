import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// `PhotoMetadataReader`: the pure dictionary parse, and a real synthetic JPEG/TIFF written with chosen EXIF. No test reads
/// the user's own files (a protected-folder read can hang the test host on a privacy prompt).
final class PhotoMetadataReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("md-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func write(_ name: String, exif: [CFString: Any], tiff: [CFString: Any], type: UTType = .jpeg) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let url = tempDir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [
            kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: Pure parse

    func testParsesEveryFieldFromAPropertiesDictionary() {
        let props: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 6016, kCGImagePropertyPixelHeight: 4016,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2023:03:14 09:30:15",
                kCGImagePropertyExifISOSpeedRatings: [800],
                kCGImagePropertyExifFNumber: 1.8, kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFocalLength: 50.0, kCGImagePropertyExifLensModel: "50.0 mm f/1.8"
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON D610"
            ] as [CFString: Any]
        ]
        let f = PhotoMetadataReader.fields(from: props)
        XCTAssertEqual(f.iso, 800)
        XCTAssertEqual(f.aperture, 1.8)
        XCTAssertEqual(f.shutter, 0.004)
        XCTAssertEqual(f.focalLength, 50)
        XCTAssertEqual(f.lens, "50.0 mm f/1.8")
        XCTAssertEqual(f.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(f.cameraModel, "NIKON D610")
        XCTAssertEqual(f.pixelWidth, 6016)
        XCTAssertEqual(f.pixelHeight, 4016)
        // 2023-03-14 09:30:15 UTC digits.
        XCTAssertEqual(f.captureDate, CaptureDate.parseEXIFDate("2023:03:14 09:30:15")?.timeIntervalSince1970)
        XCTAssertEqual(f.captureDate, 1_678_786_215)
    }

    func testAnEmptyDictionaryGivesAnAllNilResult() {
        XCTAssertEqual(PhotoMetadataReader.fields(from: [:]), .empty)
    }

    func testZeroNegativeAndBlankValuesBecomeNil() {
        let props: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 0,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "0000:00:00 00:00:00",
                kCGImagePropertyExifISOSpeedRatings: [0],
                kCGImagePropertyExifFNumber: 0.0, kCGImagePropertyExifExposureTime: -1.0,
                kCGImagePropertyExifFocalLength: Double.nan, kCGImagePropertyExifLensModel: "   "
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "", kCGImagePropertyTIFFModel: "\0\0"
            ] as [CFString: Any]
        ]
        XCTAssertEqual(PhotoMetadataReader.fields(from: props), .empty)
    }

    func testISOTakesTheFirstPositiveRatingAndFallsBackToISOSpeed() {
        let first: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [0, 250, 500]] as [CFString: Any]]
        XCTAssertEqual(PhotoMetadataReader.fields(from: first).iso, 250)
        let speed: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeed: 3200] as [CFString: Any]]
        XCTAssertEqual(PhotoMetadataReader.fields(from: speed).iso, 3200)
    }

    func testISOOfExactly65535MeansLookAtISOSpeed() {
        let exif: [CFString: Any] = [kCGImagePropertyExifISOSpeedRatings: [65535], kCGImagePropertyExifISOSpeed: 102_400]
        XCTAssertEqual(PhotoMetadataReader.fields(from: [kCGImagePropertyExifDictionary: exif]).iso, 102_400)
        let only: [CFString: Any] = [kCGImagePropertyExifISOSpeedRatings: [65535]]
        XCTAssertEqual(PhotoMetadataReader.fields(from: [kCGImagePropertyExifDictionary: only]).iso, 65535, "nothing better to use")
    }

    func testTextIsCutAtTheFirstNULAndLensFallsBackToTheAuxDictionary() {
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "NIKON D610\0junk"] as [CFString: Any],
            kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxLensModel: "AF-S NIKKOR 50mm f/1.8G"] as [CFString: Any]
        ]
        let f = PhotoMetadataReader.fields(from: props)
        XCTAssertEqual(f.cameraModel, "NIKON D610")
        XCTAssertEqual(f.lens, "AF-S NIKKOR 50mm f/1.8G")
        let both: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Exif lens"] as [CFString: Any],
            kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxLensModel: "Aux lens"] as [CFString: Any]
        ]
        XCTAssertEqual(PhotoMetadataReader.fields(from: both).lens, "Exif lens", "EXIF wins over the maker-note value")
    }

    func testTextIsTrimmed() {
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "  X100V \n"] as [CFString: Any]]
        XCTAssertEqual(PhotoMetadataReader.fields(from: props).cameraModel, "X100V")
    }

    func testTheCaptureDateHasNoFileDateFallback() throws {
        // A photo with no EXIF date must read as nil, not as its file's creation date.
        let url = try write("nodate.jpg", exif: [kCGImagePropertyExifISOSpeedRatings: [100]], tiff: [:])
        let f = try XCTUnwrap(PhotoMetadataReader.read(from: url))
        XCTAssertNil(f.captureDate)
        XCTAssertEqual(f.iso, 100)
    }

    // MARK: Real files

    func testReadsAWrittenJPEGEndToEnd() throws {
        let url = try write(
            "full.jpg",
            exif: [kCGImagePropertyExifDateTimeOriginal: "2024:12:25 08:30:00",
                   kCGImagePropertyExifISOSpeedRatings: [1600], kCGImagePropertyExifFNumber: 2.8,
                   kCGImagePropertyExifExposureTime: 0.5, kCGImagePropertyExifFocalLength: 85.0,
                   kCGImagePropertyExifLensModel: "AF-S 85mm f/1.8G"],
            tiff: [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON D610"]
        )
        let f = try XCTUnwrap(PhotoMetadataReader.read(from: url))
        XCTAssertEqual(f.iso, 1600)
        XCTAssertEqual(f.aperture, 2.8)
        XCTAssertEqual(f.shutter, 0.5)
        XCTAssertEqual(f.focalLength, 85)
        XCTAssertEqual(f.lens, "AF-S 85mm f/1.8G")
        XCTAssertEqual(f.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(f.cameraModel, "NIKON D610")
        XCTAssertEqual(f.pixelWidth, 8)
        XCTAssertEqual(f.pixelHeight, 6)
        XCTAssertEqual(f.captureDate, CaptureDate.parseEXIFDate("2024:12:25 08:30:00")?.timeIntervalSince1970)
    }

    func testANonImageFileIsNil() throws {
        let url = tempDir.appendingPathComponent("not-an-image.jpg")
        try Data("hello".utf8).write(to: url)
        XCTAssertNil(PhotoMetadataReader.read(from: url))
        XCTAssertNil(PhotoMetadataReader.read(from: tempDir.appendingPathComponent("missing.jpg")))
    }
}
