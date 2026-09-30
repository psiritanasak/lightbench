import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// D37 (IMPROVEMENTS.md): `SourceIntegrity` flags a truncated JPEG/PNG so the
/// write paths can refuse it. The helper is deliberately one-sided — these
/// tests pin both halves: positive evidence of truncation is `.truncated`,
/// and everything valid or unrecognized is never `.truncated`.
final class SourceIntegrityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Noisy pixels so the compressed stream has real entropy across the frame
    /// (a flat image compresses to almost nothing and hides cut points).
    private func encoded(_ type: UTType, properties: [CFString: Any]? = nil) throws -> Data {
        let (w, h) = (300, 200)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for i in 0..<(ctx.bytesPerRow * h) {
            seed = seed &* 1664525 &+ 1013904223
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    // MARK: JPEG

    func testCompleteJPEGIsComplete() throws {
        XCTAssertEqual(SourceIntegrity.verdict(for: try encoded(.jpeg)), .complete)
    }

    func testJPEGCutAtManyPointsIsTruncated() throws {
        let data = try encoded(.jpeg)
        for fraction in [0.05, 0.1, 0.5, 0.9, 0.99] {
            let cut = data.prefix(Int(Double(data.count) * fraction))
            XCTAssertEqual(SourceIntegrity.verdict(for: Data(cut)), .truncated, "cut at \(fraction)")
        }
    }

    func testJPEGMissingOnlyTheFinalEOIByteIsTruncated() throws {
        let data = try encoded(.jpeg)
        XCTAssertEqual(Array(data.suffix(2)), [0xFF, 0xD9])
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.dropLast(1))), .truncated)
    }

    /// A valid file may carry data after its own EOI (MPO second image, a
    /// motion-photo video, vendor trailers) — must not be refused.
    func testJPEGWithTrailerDataAfterEOIIsStillComplete() throws {
        var data = try encoded(.jpeg)
        data.append(Data(repeating: 0xAB, count: 5000))
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .complete)
    }

    /// A truncated camera JPEG still contains its EXIF thumbnail's own EOI far
    /// from the end; an "EOI anywhere" scan would call it complete. Crafted:
    /// an APP1 segment whose payload contains `FF D9`, then EOF.
    func testAnFFD9InsideAnAppSegmentDoesNotCountAsTheEndOfTheImage() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, 0xFF, 0xD9, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .truncated)
    }

    func testJPEGSegmentLengthOverrunningTheFileIsTruncated() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x00, 0x01, 0x02])
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .truncated)
    }

    func testJPEGWithEXIFOrientationSegmentCompleteAndTruncated() throws {
        let data = try encoded(.jpeg, properties: [kCGImagePropertyOrientation: 6])
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .complete)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.prefix(data.count / 2))), .truncated)
    }

    /// Multi-scan (progressive) JPEG: the walker must return from each scan to
    /// the segment walk and keep going until the real EOI.
    func testProgressiveJPEGIsCompleteAndItsCutVariantsAreTruncated() throws {
        let data = try encoded(.jpeg, properties: [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]])
        let scans = data.indices.dropLast().filter { data[$0] == 0xFF && data[$0 + 1] == 0xDA }.count
        try XCTSkipUnless(scans > 1, "ImageIO did not produce a multi-scan JPEG on this system")
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .complete)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.prefix(data.count / 2))), .truncated)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.dropLast(2))), .truncated)
    }

    /// Pins the KNOWN, ACCEPTED false-refusal class documented on
    /// `SourceIntegrity`: complete pixel data but no final EOI reads as truncated.
    func testJPEGWithCompleteScanButNoEOIIsTreatedAsTruncatedByDesign() throws {
        let data = try encoded(.jpeg)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.dropLast(2))), .truncated)
    }

    // MARK: Crafted `.unknown` branches (each must NEVER become `.truncated`)

    func testJPEGStuffedZeroOutsideAScanIsUnknown() {
        XCTAssertEqual(SourceIntegrity.verdict(for: Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02])), .unknown)
    }

    func testJPEGSegmentLengthBelowTwoIsUnknown() {
        XCTAssertEqual(SourceIntegrity.verdict(for: Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01, 0x00, 0x00])), .unknown)
    }

    func testJPEGGarbageBetweenSegmentsIsUnknown() {
        // Valid APP0 segment, then a non-0xFF byte where a marker must start.
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0x12, 0x34, 0x56])
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .unknown)
    }

    func testPNGChunkLengthAboveInt32MaxIsUnknown() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let data = Data(signature + [0xFF, 0xFF, 0xFF, 0xFF, 0x49, 0x44, 0x41, 0x54])
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .unknown)
    }

    func testFileWithJPEGExtensionButTIFFContentIsUnknownViaTheFilePath() throws {
        // The real-library case: a TIFF named .jpg. Goes through the 8-byte peek.
        let url = try write(Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00]), named: "tiff-as.jpg")
        XCTAssertEqual(SourceIntegrity.verdict(forFileAt: url), .unknown)
    }

    func testVerdictForFileAtReadsTruncatedAndCompleteFiles() throws {
        let full = try encoded(.jpeg)
        XCTAssertEqual(SourceIntegrity.verdict(forFileAt: try write(full, named: "f.jpg")), .complete)
        XCTAssertEqual(SourceIntegrity.verdict(forFileAt: try write(Data(full.prefix(full.count / 2)), named: "c.jpg")), .truncated)
    }

    // MARK: PNG

    func testCompletePNGIsComplete() throws {
        XCTAssertEqual(SourceIntegrity.verdict(for: try encoded(.png)), .complete)
    }

    func testPNGCutAtManyPointsIsTruncated() throws {
        let data = try encoded(.png)
        for fraction in [0.05, 0.1, 0.5, 0.9, 0.99] {
            XCTAssertEqual(
                SourceIntegrity.verdict(for: Data(data.prefix(Int(Double(data.count) * fraction)))), .truncated,
                "cut at \(fraction)"
            )
        }
    }

    func testPNGWithTrailerDataAfterIENDIsStillComplete() throws {
        var data = try encoded(.png)
        data.append(Data(repeating: 0x00, count: 300))
        XCTAssertEqual(SourceIntegrity.verdict(for: data), .complete)
    }

    func testPNGMissingOnlyTheFinalIENDChunkIsTruncated() throws {
        let data = try encoded(.png)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data(data.dropLast(12))), .truncated) // IEND = 12 bytes
    }

    // MARK: Never a false refusal

    func testUnrecognizedAndEmptyDataIsUnknownNotTruncated() {
        XCTAssertEqual(SourceIntegrity.verdict(for: Data()), .unknown)
        XCTAssertEqual(SourceIntegrity.verdict(for: Data("not an image at all".utf8)), .unknown)
        // TIFF header (real library file: a TIFF named .jpg) — not measured, never refused.
        XCTAssertEqual(SourceIntegrity.verdict(for: Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])), .unknown)
    }

    func testMissingFileIsUnknown() {
        XCTAssertEqual(SourceIntegrity.verdict(forFileAt: tempDir.appendingPathComponent("nope.jpg")), .unknown)
    }

    // MARK: Wired into the write paths

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testExportRefusesATruncatedJPEGAndWritesNothing() async throws {
        let full = try encoded(.jpeg)
        let url = try write(Data(full.prefix(full.count / 2)), named: "cut.jpg")
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let photo = Photo(id: 1, path: url.path, filename: "cut.jpg", fileSize: nil, importedAt: Date())

        do {
            _ = try await PhotoExporter.export(photo, editState: .identity, to: out, settings: ExportSettings())
            XCTFail("expected export to refuse a truncated source")
        } catch let error as PhotoExportError {
            guard case .incompleteSource(let path) = error else { return XCTFail("expected .incompleteSource, got \(error)") }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testExportStillWorksForACompleteJPEG() async throws {
        let url = try write(try encoded(.jpeg), named: "ok.jpg")
        let out = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let photo = Photo(id: 1, path: url.path, filename: "ok.jpg", fileSize: nil, importedAt: Date())
        let written = try await PhotoExporter.export(photo, editState: .identity, to: out, settings: ExportSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testEnhanceRefusesATruncatedPNG() async throws {
        let full = try encoded(.png)
        let url = try write(Data(full.prefix(full.count / 2)), named: "cut.png")
        do {
            _ = try await PhotoEnhancer.enhance(sourceURL: url, editState: .identity, into: tempDir)
            XCTFail("expected enhance to refuse a truncated source")
        } catch let error as PhotoEnhanceError {
            guard case .incompleteSource(let path) = error else { return XCTFail("expected .incompleteSource, got \(error)") }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["cut.png"])
    }
}
