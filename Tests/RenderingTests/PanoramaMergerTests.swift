import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

final class PanoramaMergerTests: XCTestCase {
    private static let fw = 480, fh = 360
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pano-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: Fixture — one textured world, three overlapping windows with vertical jitter and exposure drift

    private static let blobs: [(x: Float, y: Float, size: Float, value: Float)] = {
        var s: UInt64 = 0xBADC0FFEE
        func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 33) & 0xFFFF) / 65535 }
        return (0..<420).map { _ in (next() * 960, next() * 400, 3 + next() * 8, 0.05 + next() * 0.75) }
    }()
    private static let tint = SIMD3<Float>(1, 0.8, 0.6)

    private static func world(_ x: Float, _ y: Float) -> Float {
        var v: Float = 0.08 + 0.2 * (x / 960)
        for b in blobs {
            let q = ((x - b.x) * (x - b.x) + (y - b.y) * (y - b.y)) / (b.size * b.size)
            if q < 9 { v += (b.value - v) * exp(-q) }
        }
        return v
    }

    /// Window origins in world coordinates, in SHOOTING order, and the exposure multiplier of each frame.
    private static let origins: [(x: Int, y: Int)] = [(0, 10), (220, 16), (440, 6)]
    private static let exposures: [Float] = [1.0, 1.12, 0.9]

    nonisolated(unsafe) private static var encoded: [String: Data] = [:]

    /// Writes shooting-order frame `index` as `name`, with an EXIF capture time `index * 5` s after 10:00:00.
    private func writeFrame(_ index: Int, as name: String, withDate: Bool = true) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let key = "\(index)|\(withDate)"
        if let cached = Self.encoded[key] { try cached.write(to: url); return url }
        var rgba = [UInt8](repeating: 255, count: Self.fw * Self.fh * 4)
        let o = Self.origins[index], e = Self.exposures[index]
        for y in 0..<Self.fh { for x in 0..<Self.fw {
            let r = Self.world(Float(o.x + x), Float(o.y + y)) * e
            for c in 0..<3 { rgba[(y * Self.fw + x) * 4 + c] = UInt8((HDRMergeMath.srgbEncode(min(max(r * Self.tint[c], 0), 1)) * 255).rounded()) }
        } }
        let image = CGImage(width: Self.fw, height: Self.fh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.fw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var exif: [CFString: Any] = [:]
        if withDate { exif[kCGImagePropertyExifDateTimeOriginal] = String(format: "2024:05:01 10:00:%02d", index * 5) }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: exif, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        Self.encoded[key] = try Data(contentsOf: url)
        return url
    }

    private func readOutput(_ url: URL) async throws -> (pixels: [Float], width: Int, height: Int) {
        let decodedOptional = await RawDecoder.decode(contentsOf: url, editState: EditState())
        let decoded = try XCTUnwrap(decodedOptional)
        let w = Int(decoded.extent.width), h = Int(decoded.extent.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        PhotoExporter.context.render(decoded, toBitmap: &buffer, rowBytes: w * 16, bounds: decoded.extent, format: .RGBAf, colorSpace: linear)
        return (buffer, w, h)
    }

    /// Relative error of the output's red channel against the true world (at the MIDDLE frame's exposure), minimised over the (unknown) integer offset
    /// of the output inside the world (searched in a small window around where the crop can start), as (median, mean, offset).
    private func bestError(_ out: (pixels: [Float], width: Int, height: Int)) -> (median: Float, mean: Float, ox: Int, oy: Int) {
        let e = Self.exposures[1]
        var best: (Float, Float, Int, Int) = (.infinity, .infinity, 0, 0)
        for oy in 8...32 { for ox in 0...40 {
            var errors: [Float] = []
            for sy in stride(from: 10, to: out.height - 10, by: 17) { for sx in stride(from: 10, to: out.width - 10, by: 13) {
                let truth = Self.world(Float(ox + sx), Float(oy + sy)) * e
                guard truth > 0.03 else { continue }
                errors.append(abs(out.pixels[(sy * out.width + sx) * 4] - truth) / truth)
            } }
            guard errors.count > 20 else { continue }
            let sorted = errors.sorted(), median = sorted[sorted.count / 2], mean = errors.reduce(0, +) / Float(errors.count)
            if median < best.0 { best = (median, mean, ox, oy) }
        } }
        return (best.0, best.1, best.2, best.3)
    }

    // MARK: Tests

    func testStitchesThreeShuffledNamedFramesInShootingOrderWithExposureDrift() async throws {
        // File-name order is middle, first, last — which would pair frames 0 and 2 (only 40 px of overlap) and fail: only the EXIF capture times give the
        // real shooting order.
        let urls = [try writeFrame(2, as: "c_last.jpg"), try writeFrame(0, as: "b_first.jpg"), try writeFrame(1, as: "a_mid.jpg")]
        let before = try urls.map { try Data(contentsOf: $0) }
        let outcome = try await PanoramaMerger.mergePanorama(sourceURLs: urls, into: folder)
        XCTAssertEqual(outcome.mode, .panorama)
        XCTAssertEqual(outcome.url.lastPathComponent, "c_last-Pano.tiff", "named after the first SELECTED photo (the folder it is written into), not the first in shooting order")
        XCTAssertEqual(outcome.referenceName, "a_mid.jpg", "the middle frame in shooting order is the reference")
        XCTAssertEqual(outcome.alignment.count, 2)
        XCTAssertTrue(outcome.cropped)
        let out = try await readOutput(outcome.url)
        XCTAssertEqual(CGFloat(out.width), outcome.size.width); XCTAssertEqual(CGFloat(out.height), outcome.size.height)
        // The world is 920 wide (frames at 0, 220, 440 + 480); the crop must keep most of it and lose only the vertical jitter (at most ~16 rows).
        XCTAssertGreaterThan(out.width, 880); XCTAssertLessThanOrEqual(out.width, 920)
        XCTAssertGreaterThan(out.height, 330); XCTAssertLessThan(out.height, 360)
        let fit = bestError(out)
        print("PROBE panorama end-to-end: size \(out.width)x\(out.height), best offset (\(fit.ox), \(fit.oy)), median rel error \(fit.median), mean \(fit.mean), gains \(outcome.gains.map { "\($0.name) \($0.usedGain)" }), inliers \(outcome.alignment.map(\.inlierCount))")
        XCTAssertLessThan(fit.median, 0.03, "most pixels match the true world once exposure is compensated")
        XCTAssertLessThan(fit.mean, 0.08)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before, "sources are byte-identical afterwards")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }.isEmpty, "no temp file left behind")
    }

    func testExposureDriftIsMeasuredAndCompensatedBetweenNeighbours() async throws {
        let urls = [try writeFrame(0, as: "f0.jpg"), try writeFrame(1, as: "f1.jpg"), try writeFrame(2, as: "f2.jpg")]
        let outcome = try await PanoramaMerger.mergePanorama(sourceURLs: urls, into: folder)
        // Reference is frame 1 (exposure 1.12): frame 0 is 1/1.12 = 0.893 as bright, frame 2 is 0.9/1.12 = 0.804.
        let g0 = try XCTUnwrap(outcome.gains.first { $0.name == "f0.jpg" }), g2 = try XCTUnwrap(outcome.gains.first { $0.name == "f2.jpg" })
        XCTAssertEqual(g0.usedGain, 1 / 1.12, accuracy: 0.03)
        XCTAssertEqual(g2.usedGain, 0.9 / 1.12, accuracy: 0.03)
    }

    func testNotCroppingKeepsTheRaggedCanvasAndIsLarger() async throws {
        let urls = [try writeFrame(0, as: "f0.jpg"), try writeFrame(1, as: "f1.jpg"), try writeFrame(2, as: "f2.jpg")]
        let cropped = try await PanoramaMerger.mergePanorama(sourceURLs: urls, cropToFill: true, into: folder)
        let full = try await PanoramaMerger.mergePanorama(sourceURLs: urls, cropToFill: false, into: folder)
        XCTAssertFalse(full.cropped)
        XCTAssertGreaterThan(full.size.height, cropped.size.height, "the uncropped canvas includes the rows only some frames cover")
        XCTAssertEqual(full.url.lastPathComponent, "f0-Pano (2).tiff", "a second panorama never overwrites the first")
    }

    func testUnrelatedPhotosAreRefusedWithAClearErrorAndWriteNothing() async throws {
        let a = try writeFrame(0, as: "a.jpg")
        // A frame of a DIFFERENT scene: the same renderer with the world shifted far away would still match, so use flat grey instead.
        var grey = [UInt8](repeating: 128, count: Self.fw * Self.fh * 4)
        for i in 0..<(Self.fw * Self.fh) { grey[i * 4 + 3] = 255 }
        let image = CGImage(width: Self.fw, height: Self.fh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.fw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(grey) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let b = folder.appendingPathComponent("b.jpg")
        let dest = CGImageDestinationCreateWithURL(b as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let initial = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        do { _ = try await PanoramaMerger.mergePanorama(sourceURLs: [a, b], into: folder); XCTFail("expected a no-overlap error") } catch PhotoMergeError.noOverlap(let first, let second) {
            XCTAssertEqual(Set([first, second]), ["a.jpg", "b.jpg"])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), initial, "a refused panorama writes nothing")
    }

    func testTooFewAndTooManyFramesAreRefused() async throws {
        let one = try writeFrame(0, as: "one.jpg")
        do { _ = try await PanoramaMerger.mergePanorama(sourceURLs: [one], into: folder); XCTFail() } catch PhotoMergeError.panorama(let e) { XCTAssertEqual(e, .tooFewFrames) }
        let many = [URL](repeating: one, count: PanoramaPlan.maxFrames + 1)
        do { _ = try await PanoramaMerger.mergePanorama(sourceURLs: many, into: folder); XCTFail() } catch PhotoMergeError.panorama(let e) {
            XCTAssertEqual(e, .tooManyFrames(limit: PanoramaPlan.maxFrames))
        }
    }

    // MARK: Orientation (turn / flip edits)

    /// Every frame is stored landscape but turned a quarter turn in the Library: the sweep becomes vertical, so the panorama is TALL.
    func testFramesTurnedInTheLibraryMakeATallPanorama() async throws {
        let urls = [try writeFrame(2, as: "c_last.jpg"), try writeFrame(0, as: "b_first.jpg"), try writeFrame(1, as: "a_mid.jpg")]
        let outcome = try await PanoramaMerger.mergePanorama(sourceURLs: urls, orientations: Array(repeating: PhotoOrientation(quarterTurns: 1), count: 3), into: folder)
        let out = try await readOutput(outcome.url)
        XCTAssertGreaterThan(out.height, 880)
        XCTAssertLessThanOrEqual(out.height, 920)
        XCTAssertGreaterThan(out.width, 330)
        XCTAssertLessThan(out.width, 360)
        XCTAssertEqual(outcome.referenceName, "a_mid.jpg")
    }

    /// `orientations` follow the files as the caller listed them, NOT the shooting order: turning only the FIRST LISTED file (the last shot) makes
    /// THAT file the one whose size no longer matches. Without the reordering the first shot would be blamed instead.
    func testOrientationsFollowTheirFilesThroughTheShootingOrder() async throws {
        let urls = [try writeFrame(2, as: "c_last.jpg"), try writeFrame(0, as: "b_first.jpg"), try writeFrame(1, as: "a_mid.jpg")]
        do {
            _ = try await PanoramaMerger.mergePanorama(sourceURLs: urls, orientations: [PhotoOrientation(quarterTurns: 1), .identity, .identity], into: folder)
            XCTFail("expected a size mismatch")
        } catch PhotoMergeError.sizeMismatch(let name) {
            XCTAssertEqual(name, "c_last.jpg")
        }
    }

    func testAnOrientationListOfTheWrongLengthIsRefusedNotIgnored() async throws {
        let urls = [try writeFrame(0, as: "a.jpg"), try writeFrame(1, as: "b.jpg"), try writeFrame(2, as: "c.jpg")]
        do {
            _ = try await PanoramaMerger.mergePanorama(sourceURLs: urls, orientations: [PhotoOrientation(quarterTurns: 1)], into: folder)
            XCTFail("expected a refusal")
        } catch PhotoMergeError.orientationCountMismatch {
        }
    }

    // MARK: Pure helpers

    func testFeatherMaskRampsFromZeroAtTheEdgesToOneInTheMiddle() {
        let mask = PanoramaMerger.featherMask(size: CGSize(width: 200, height: 100), ramp: 40)
        func alpha(_ x: Int, _ y: Int) -> Float {
            var px = [Float](repeating: 0, count: 4)
            PhotoExporter.context.render(mask, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            return px[3]
        }
        XCTAssertEqual(alpha(100, 50), 1, accuracy: 1e-3, "the centre is full weight")
        XCTAssertLessThan(alpha(1, 50), 0.05, "the left edge is nearly zero")
        XCTAssertLessThan(alpha(198, 50), 0.05, "the right edge")
        XCTAssertLessThan(alpha(100, 1), 0.05, "the bottom edge")
        XCTAssertLessThan(alpha(100, 98), 0.05, "the top edge")
        XCTAssertEqual(alpha(20, 50), 0.5, accuracy: 0.05, "halfway up the 40 px left ramp")
        XCTAssertEqual(alpha(20, 20), 0.5, accuracy: 0.05, "the weight is the MINIMUM of the four ramps: at (20, 20) left is 0.5 and bottom is 0.5")
        XCTAssertEqual(alpha(10, 30), 0.25, accuracy: 0.05, "left ramp 0.25 is the smaller of the two")
    }

    func testScaleExposureMultipliesColourAndLeavesAlpha() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.1, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let scaled = PanoramaMerger.scaleExposure(image, by: 2)
        var px = [Float](repeating: 0, count: 4)
        PhotoExporter.context.render(scaled, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        XCTAssertEqual(px[0], 0.4, accuracy: 1e-3); XCTAssertEqual(px[1], 0.8, accuracy: 1e-3); XCTAssertEqual(px[2], 0.2, accuracy: 1e-3); XCTAssertEqual(px[3], 1, accuracy: 1e-6)
    }
}
