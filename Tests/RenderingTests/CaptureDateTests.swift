import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

final class CaptureDateTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureDateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func utcDigits(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private func writeJPEG(
        _ name: String, exif: [CFString: Any]? = nil, tiff: [CFString: Any]? = nil, type: UTType = .jpeg
    ) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let url = tempDir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        if let tiff { props[kCGImagePropertyTIFFDictionary] = tiff }
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: Parsing

    func testParsesTheEXIFFormatAsWallClockDigits() throws {
        let date = try XCTUnwrap(CaptureDate.parseEXIFDate("2026:03:05 14:07:09"))
        XCTAssertEqual(utcDigits(date), "2026-03-05 14:07:09")
    }

    func testRejectsImpossibleAndLenientlyParsedDates() {
        // `Calendar` alone would happily roll these over into a neighbouring date.
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:02:30 10:00:00"))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:13:01 10:00:00"))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:03:05 24:00:00"))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:03:05 10:60:00"))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:03:05 10:00:60"))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:03:05 10:00")) // wrong length
        XCTAssertNil(CaptureDate.parseEXIFDate("2026:03:05T10:00:00")) // wrong separator
        XCTAssertNil(CaptureDate.parseEXIFDate("20a6:03:05 10:00:00")) // non-digit
        XCTAssertNotNil(CaptureDate.parseEXIFDate("2024:02:29 23:59:59")) // real leap day
        XCTAssertNil(CaptureDate.parseEXIFDate("2025:02:29 23:59:59")) // not a leap year
    }

    func testRejectsMalformedAndZeroPlaceholderDates() {
        XCTAssertNil(CaptureDate.parseEXIFDate("0000:00:00 00:00:00"))
        XCTAssertNil(CaptureDate.parseEXIFDate("not a date"))
        XCTAssertNil(CaptureDate.parseEXIFDate(""))
        XCTAssertNil(CaptureDate.parseEXIFDate("2026-03-05 14:07:09")) // wrong separators
    }

    func testWallClockShiftMakesLocalDigitsAppearAsUTCDigits() {
        // 2026-03-05 07:00:00 UTC is 14:00:00 in UTC+7 (Bangkok).
        let instant = Date(timeIntervalSince1970: 1_772_694_000)
        let tz = TimeZone(secondsFromGMT: 7 * 3600)!
        XCTAssertEqual(utcDigits(CaptureDate.wallClockDate(fromInstant: instant, in: tz)), "2026-03-05 14:00:00")
    }

    func testWallClockShiftUsesTheOffsetAtThatInstantNotTheOffsetNow() {
        // New York: EST (UTC-5) in January, EDT (UTC-4) in July. 12:00 UTC is 07:00 vs 08:00 local.
        let tz = TimeZone(identifier: "America/New_York")!
        let january = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00:00 UTC
        let july = Date(timeIntervalSince1970: 1_784_116_800) // 2026-07-15 12:00:00 UTC
        XCTAssertEqual(utcDigits(CaptureDate.wallClockDate(fromInstant: january, in: tz)), "2026-01-15 07:00:00")
        XCTAssertEqual(utcDigits(CaptureDate.wallClockDate(fromInstant: july, in: tz)), "2026-07-15 08:00:00")
    }

    // MARK: Reading

    func testReadsDateTimeOriginalFromEXIF() throws {
        let url = try writeJPEG("orig.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "2024:12:25 08:30:00"])
        let fallback = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(utcDigits(CaptureDate.read(from: url, fallback: fallback)), "2024-12-25 08:30:00")
    }

    func testPrefersDateTimeOriginalOverDigitizedAndTIFF() throws {
        let url = try writeJPEG(
            "all.jpg",
            exif: [kCGImagePropertyExifDateTimeOriginal: "2024:01:01 01:01:01",
                   kCGImagePropertyExifDateTimeDigitized: "2025:02:02 02:02:02"],
            tiff: [kCGImagePropertyTIFFDateTime: "2026:03:03 03:03:03"]
        )
        XCTAssertEqual(utcDigits(CaptureDate.read(from: url, fallback: Date())), "2024-01-01 01:01:01")
    }

    func testFallsBackToDigitizedThenTIFF() throws {
        let digitized = try writeJPEG("dig.jpg", exif: [kCGImagePropertyExifDateTimeDigitized: "2025:02:02 02:02:02"])
        XCTAssertEqual(utcDigits(CaptureDate.read(from: digitized, fallback: Date())), "2025-02-02 02:02:02")
        // A TIFF file carries a real TIFF dictionary (a JPEG's is dropped by ImageIO). ImageIO
        // may stamp its own DateTime whatever we pass, so assert that, with no EXIF dates at
        // all, `read` returns exactly what ImageIO itself reports for TIFF DateTime.
        let tiff = try writeJPEG("tiff.tiff", tiff: [kCGImagePropertyTIFFDateTime: "2026:03:03 03:03:03"], type: .tiff)
        // Make the file-creation fallback provably DIFFERENT from any TIFF stamp (both would
        // otherwise be "now" and could coincide to the second), so only the TIFF branch can pass.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: tiff.path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiffProps = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let stamped = try XCTUnwrap(tiffProps[kCGImagePropertyTIFFDateTime] as? String)
        let expected = try XCTUnwrap(CaptureDate.parseEXIFDate(stamped))
        XCTAssertEqual(CaptureDate.read(from: tiff, fallback: Date(timeIntervalSince1970: 0)), expected)
    }

    func testAnUnsetCameraClockFallsThroughToTheFileDate() throws {
        let url = try writeJPEG("zero.jpg", exif: [kCGImagePropertyExifDateTimeOriginal: "0000:00:00 00:00:00"])
        // Not vacuous: the placeholder really is in the file (else this would just be "no EXIF").
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exifProps = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exifProps[kCGImagePropertyExifDateTimeOriginal] as? String, "0000:00:00 00:00:00")
        let creation = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
        let read = CaptureDate.read(from: url, fallback: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(read, CaptureDate.wallClockDate(fromInstant: creation))
    }

    func testNoEXIFUsesTheFileCreationDate() throws {
        let url = try writeJPEG("plain.jpg")
        let creation = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
        XCTAssertEqual(CaptureDate.read(from: url, fallback: Date(timeIntervalSince1970: 0)),
                       CaptureDate.wallClockDate(fromInstant: creation))
    }

    func testMissingFileUsesTheFallback() {
        let missing = tempDir.appendingPathComponent("nope.jpg")
        let fallback = Date(timeIntervalSince1970: 1_772_694_000)
        XCTAssertEqual(CaptureDate.read(from: missing, fallback: fallback), CaptureDate.wallClockDate(fromInstant: fallback))
    }
}
