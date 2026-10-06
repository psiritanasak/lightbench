import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import PhotoApp

final class FeaturePrintMathTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FeaturePrintMathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func image(seed: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<8 {
            ctx.setFillColor(CGColor(red: CGFloat((seed * 37 + i * 53) % 255) / 255, green: CGFloat((seed * 91 + i * 29) % 255) / 255,
                                     blue: CGFloat((seed * 17 + i * 71) % 255) / 255, alpha: 1))
            ctx.fill(CGRect(x: (i * 11 + seed) % 70, y: (i * 7 + seed * 3) % 40, width: 25, height: 20))
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: Euclidean == Vision (the premise that lets cached blobs be compared without Vision)

    func testEuclideanDistanceOnTheStoredBlobEqualsVisionsComputeDistance() throws {
        var observations: [VNFeaturePrintObservation] = []
        for seed in [3, 8, 21] {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = FeaturePrintGenerator.revision
            try VNImageRequestHandler(cgImage: image(seed: seed), orientation: .up).perform([request])
            observations.append(try XCTUnwrap(request.results?.first))
        }
        for (a, b) in [(0, 1), (0, 2), (1, 2), (0, 0)] {
            var vision: Float = 0
            try observations[a].computeDistance(&vision, to: observations[b])
            let ours = FeaturePrintVector.distance(try XCTUnwrap(FeaturePrintVector.vector(from: observations[a].data)),
                                                   try XCTUnwrap(FeaturePrintVector.vector(from: observations[b].data)))
            XCTAssertEqual(ours, vision, accuracy: 1e-4, "pair \(a),\(b)")
        }
    }

    func testFingerprintOfAFileIsAUsableDeterministicBlob() throws {
        let url = dir.appendingPathComponent("a.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try image(seed: 5), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let first = try XCTUnwrap(FeaturePrintGenerator.fingerprint(ofFileAt: url))
        XCTAssertNotNil(FeaturePrintVector.vector(from: first))
        XCTAssertEqual(first, FeaturePrintGenerator.fingerprint(ofFileAt: url))
        XCTAssertNil(FeaturePrintGenerator.fingerprint(ofFileAt: dir.appendingPathComponent("missing.png")))
        let junk = dir.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertNil(FeaturePrintGenerator.fingerprint(ofFileAt: junk))
    }

    /// A JPEG carrying a small embedded thumbnail must still be printed from a real ~512 px image, not the EXIF thumbnail.
    func testAJPEGWithAnEmbeddedThumbnailIsNotPrintedFromTheTinyThumbnail() throws {
        let big = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        big.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); big.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        big.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)); big.fill(CGRect(x: 300, y: 200, width: 700, height: 500))
        let url = dir.appendingPathComponent("embedded.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(big.makeImage()), [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let image = try XCTUnwrap(FeaturePrintGenerator.thumbnail(ofFileAt: url))
        XCTAssertGreaterThanOrEqual(max(image.width, image.height), FeaturePrintGenerator.maxPixelSize * 9 / 10,
                                    "printed from \(image.width)x\(image.height)")
    }

    /// The retry that regenerates a too-small thumbnail must never apply to RAW (it would be a full RAW decode outside the
    /// gate). Pinned through the same predicate the generator uses.
    func testRawExtensionsAreRecognisedSoTheThumbnailRetryIsSkippedForThem() {
        for name in ["a.NEF", "b.nef", "c.CR2", "d.arw", "e.dng"] {
            XCTAssertTrue(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.jpg", "b.png", "c.heic", "d.tif"] {
            XCTAssertFalse(RawDecoder.isRaw(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    // MARK: FileHasher

    func testSHA256MatchesKnownVectorsAndTheOneShotDigestAcrossChunkBoundaries() throws {
        let abc = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(FileHasher.sha256Hex(ofFileAt: abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(FileHasher.sha256Hex(ofFileAt: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        for size in [FileHasher.chunkSize - 1, FileHasher.chunkSize, FileHasher.chunkSize + 1, 3 * FileHasher.chunkSize + 17] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let url = dir.appendingPathComponent("f\(size)")
            try data.write(to: url)
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(FileHasher.sha256Hex(ofFileAt: url), expected, "size \(size)")
        }
        XCTAssertNil(FileHasher.sha256Hex(ofFileAt: dir.appendingPathComponent("missing")))
    }
}
