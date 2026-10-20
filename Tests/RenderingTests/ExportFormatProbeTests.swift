import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// HEIC export, plus a record-only probe of which further formats ImageIO can WRITE on this machine (AVIF/WebP).
final class ExportFormatProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportFormatProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func gradient() throws -> CIImage {
        let filter = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 400, y: 300),
            "inputColor0": CIColor(red: 0.8, green: 0.1, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.9)]))
        return try XCTUnwrap(filter.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    // MARK: - HEIC

    func testHEICIsAHEICFileOfTheRightSizeAndColour() throws {
        let color = try XCTUnwrap(CIColor(red: 0.2, green: 0.5, blue: 0.7, colorSpace: srgb))
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = dir.appendingPathComponent("flat.heic")
        try PhotoExporter.write(image, format: .heic, quality: 0.9, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: decoded), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 32, y: 24, width: 1, height: 1),
                           format: .RGBA8, colorSpace: srgb)
        // Lossy: expected sRGB (51, 128, 179); a measured run read back (51, 127, 178). Tolerance 4 / 255.
        for (value, expected) in zip(pixel.prefix(3), [51, 128, 179]) {
            XCTAssertEqual(Int(value), expected, accuracy: 4)
        }
    }

    /// HEIC flattens transparency exactly like JPEG (over opaque black) and reads back opaque.
    func testHEICFlattensTransparencyLikeJPEG() throws {
        let color = try XCTUnwrap(CIColor(red: 1, green: 0, blue: 0, alpha: 0.5, colorSpace: srgb))
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        func readBack(_ format: ExportFormat) throws -> (pixel: [Int], alpha: CGImageAlphaInfo) {
            let url = dir.appendingPathComponent("alpha.\(format.fileExtension)")
            try PhotoExporter.write(image, format: format, quality: 1, to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: decoded), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 16, y: 16, width: 1, height: 1),
                               format: .RGBA8, colorSpace: srgb)
            return (pixel.map(Int.init), decoded.alphaInfo)
        }
        let jpeg = try readBack(.jpeg), heic = try readBack(.heic)
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        XCTAssertTrue(opaque.contains(heic.alpha), "HEIC reads back with no alpha (got \(heic.alpha.rawValue))")
        XCTAssertEqual(heic.pixel[3], 255)
        for channel in 0..<3 {
            XCTAssertEqual(heic.pixel[channel], jpeg.pixel[channel], accuracy: 4, "channel \(channel): JPEG \(jpeg.pixel) HEIC \(heic.pixel)")
        }
        XCTAssertLessThan(heic.pixel[0], 160, "flattened over black, not left bright red (\(heic.pixel))")
    }

    func testHEICQualityChangesTheFileSize() throws {
        let image = try gradient()
        var sizes: [Int] = []
        for quality in [0.3, 1.0] as [CGFloat] {
            let url = dir.appendingPathComponent("q\(quality).heic")
            try PhotoExporter.write(image, format: .heic, quality: quality, to: url)
            sizes.append(try Data(contentsOf: url).count)
        }
        XCTAssertLessThan(sizes[0], sizes[1], "quality 0.3 must give a smaller file than 1.0: \(sizes)")
    }

    func testOnlyJPEGAndHEICAreLossy() {
        XCTAssertEqual(ExportFormat.allCases.filter(\.isLossy), [.jpeg, .heic])
        XCTAssertEqual(ExportFormat.heic.fileExtension, "heic")
    }

    func testUnknownStoredFormatFallsBackAndHEICIsRemembered() throws {
        let suite = "ExportFormatProbeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(format: .heic))
        XCTAssertEqual(store.load().format, .heic)
        defaults.set(Data(#"{"format":"avif"}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(store.load().format, .jpeg, "a format this build lacks resets that field only")
    }

    // MARK: - AVIF / WebP probe (record-only)

    /// Records what this machine can write. Asserts only what holds on every Mac with a working ImageIO (JPEG/PNG/HEIC
    /// are writable); AVIF and WebP are reported, never required. AVIF is NOT offered as an export format by this app.
    func testWhichExtraFormatsImageIOCanWriteHere() throws {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        for required in [UTType.jpeg, .png, .tiff, .heic] {
            XCTAssertTrue(identifiers.contains(required.identifier), "\(required.identifier) must be writable")
        }
        let avif = identifiers.contains("public.avif")
        let webp = identifiers.contains("org.webmproject.webp")
        print("PROBE AVIF writable: \(avif), WebP writable: \(webp)")
        guard avif else { throw XCTSkip("AVIF is not writable on this machine") }

        let cg = try XCTUnwrap(CIContext().createCGImage(try gradient(), from: CGRect(x: 0, y: 0, width: 400, height: 300)))
        let url = dir.appendingPathComponent("probe.avif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.avif" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        var decodedSize = "n/a"
        if finalized, let source = CGImageSourceCreateWithURL(url as CFURL, nil), let back = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            decodedSize = "\(back.width)x\(back.height)"
        }
        print("PROBE AVIF write finalized: \(finalized), read back: \(decodedSize)")
    }
}
