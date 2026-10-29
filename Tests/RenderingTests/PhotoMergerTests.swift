import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

final class PhotoMergerTests: XCTestCase {
    private static let width = 480, height = 360
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: Fixture — a textured scene with true radiance up to 4.0, shot at several exposures with small camera shifts

    private static let blobs: [(x: Float, y: Float, size: Float, value: Float)] = {
        var s: UInt64 = 0xFEEDFACE
        func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 33) & 0xFFFF) / 65535 }
        return (0..<260).map { _ in (next() * 700, next() * 700, 4 + next() * 9, 0.02 + next() * 3.98) }
    }()
    private static let tint = SIMD3<Float>(1, 0.8, 0.6)

    /// True scene radiance (linear) at world position (x, y).
    private static func radiance(_ x: Float, _ y: Float) -> Float {
        var v: Float = 0.03 + 0.5 * (x / 700)
        for b in blobs {
            let q = ((x - b.x) * (x - b.x) + (y - b.y) * (y - b.y)) / (b.size * b.size)
            if q < 9 { v += (b.value - v) * exp(-q) }
        }
        return v
    }

    /// Rendering a frame is slow (hundreds of blobs per pixel), so each distinct frame is encoded once per test run and re-written from memory.
    nonisolated(unsafe) private static var encodedFrames: [String: Data] = [:]

    private func writeFrame(_ name: String, ev: Float, shift: (Int, Int), exposureTime: Double?) throws -> URL {
        let key = "\(ev)|\(shift.0),\(shift.1)|\(exposureTime.map { "\($0)" } ?? "none")"
        let url = folder.appendingPathComponent(name)
        if let cached = Self.encodedFrames[key] { try cached.write(to: url); return url }
        var rgba = [UInt8](repeating: 255, count: Self.width * Self.height * 4)
        let gain = pow(2, ev)
        for y in 0..<Self.height { for x in 0..<Self.width {
            let r = Self.radiance(Float(x + shift.0 + 40), Float(y + shift.1 + 40))
            for c in 0..<3 {
                let lin = min(max(r * Self.tint[c] * gain, 0), 1)
                rgba[(y * Self.width + x) * 4 + c] = UInt8((HDRMergeMath.srgbEncode(lin) * 255).rounded())
            }
        } }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var exif: [CFString: Any] = [kCGImagePropertyExifFNumber: 8.0, kCGImagePropertyExifISOSpeedRatings: [100]]
        if let t = exposureTime { exif[kCGImagePropertyExifExposureTime] = t }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: exif, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        Self.encodedFrames[key] = try Data(contentsOf: url)
        return url
    }

    /// -2 / 0 / +2 EV, the dark and bright frames shifted a few pixels from the middle one (listed out of order on purpose).
    private func bracket(shifted: Bool = true) throws -> [URL] {
        [try writeFrame("bright.jpg", ev: 2, shift: shifted ? (-5, 3) : (0, 0), exposureTime: 1.0 / 25),
         try writeFrame("dark.jpg", ev: -2, shift: shifted ? (7, -4) : (0, 0), exposureTime: 1.0 / 400),
         try writeFrame("mid.jpg", ev: 0, shift: (0, 0), exposureTime: 1.0 / 100)]
    }

    private func readOutput(_ url: URL) async throws -> (pixels: [Float], width: Int, height: Int) {
        let decodedOptional = await RawDecoder.decode(contentsOf: url, editState: EditState())
        let decoded = try XCTUnwrap(decodedOptional)
        let w = Int(decoded.extent.width), h = Int(decoded.extent.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        PhotoExporter.context.render(decoded, toBitmap: &buffer, rowBytes: w * 16, bounds: decoded.extent, format: .RGBAf, colorSpace: linear)
        return (buffer, w, h)
    }

    /// Mean relative error of the merged red channel against the true radiance over the interior, plus how many true-highlight (>1) pixels came back above 1.
    private func compare(_ out: (pixels: [Float], width: Int, height: Int)) -> (meanRelError: Float, highlightRecovered: Float, highlightCount: Int) {
        var errSum: Float = 0, n = 0, hi = 0, hiOK = 0
        for y in 30..<(out.height - 30) { for x in 30..<(out.width - 30) {
            let truth = Self.radiance(Float(x + 40), Float(y + 40))
            let got = out.pixels[(y * out.width + x) * 4]
            if truth > 0.01 { errSum += abs(got - truth) / truth; n += 1 }
            if truth > 1.2 { hi += 1; if got > 1.0 { hiOK += 1 } }
        } }
        return (errSum / Float(max(n, 1)), Float(hiOK) / Float(max(hi, 1)), hi)
    }

    // MARK: Tests

    func testMergesAnAlignedBracketAndRecoversHighlightsAboveOne() async throws {
        let urls = try bracket()
        let before = try urls.map { try Data(contentsOf: $0) }
        let outcome = try await PhotoMerger.mergeHDR(sourceURLs: urls, into: folder)
        XCTAssertEqual(outcome.url.lastPathComponent, "mid-HDR.tiff", "named after the middle-exposure (reference) frame")
        XCTAssertEqual(outcome.referenceName, "mid.jpg")
        XCTAssertEqual(outcome.alignment.count, 2)
        // NOTE: the -2 EV frame registers with only a few more inliers than the matcher's floor (12) on this fixture; a matcher or fixture change that
        // loses them surfaces as an `alignmentFailed` throw, not as this assertion.
        XCTAssertTrue(outcome.alignment.allSatisfy { $0.inlierCount * 2 >= $0.matchCount }, "most matches should be inliers: \(outcome.alignment)")
        let c = compare(try await readOutput(outcome.url))
        print("PROBE merge end-to-end aligned: meanRelError \(c.meanRelError) highlights>1.2: \(c.highlightCount), recovered above 1: \(c.highlightRecovered), inliers \(outcome.alignment.map(\.inlierCount))")
        XCTAssertGreaterThan(c.highlightCount, 500, "fixture must contain real highlights")
        XCTAssertGreaterThan(c.highlightRecovered, 0.9, "highlights above 1.0 must survive the merge AND the float TIFF")
        XCTAssertLessThan(c.meanRelError, 0.08)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before, "sources must be byte-identical afterwards")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }.isEmpty, "no temp file left behind")
    }

    /// Real cameras are not as exact as their EXIF: a real D610 pair measured 12% off. Here the bright frame's EXIF claims 15% more exposure than
    /// the frame really has; the merge must measure the true gain from the pixels, so the result stays accurate and the correction is reported.
    func testMeasuresTheRealGainWhenExifIsWrongByFifteenPercent() async throws {
        let urls = [try writeFrame("bright.jpg", ev: 2, shift: (0, 0), exposureTime: 1.0 / 25 * 1.15),
                    try writeFrame("dark.jpg", ev: -2, shift: (0, 0), exposureTime: 1.0 / 400),
                    try writeFrame("mid.jpg", ev: 0, shift: (0, 0), exposureTime: 1.0 / 100)]
        let outcome = try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, into: folder)
        let bright = try XCTUnwrap(outcome.gains.first { $0.name == "bright.jpg" })
        XCTAssertEqual(bright.exifGain, 4 * 1.15, accuracy: 0.01)
        XCTAssertEqual(bright.usedGain, 4, accuracy: 0.15, "the gain is measured from the pixels")
        XCTAssertEqual(bright.correction, -0.13, accuracy: 0.04)
        let dark = try XCTUnwrap(outcome.gains.first { $0.name == "dark.jpg" })
        XCTAssertEqual(abs(dark.correction), 0, accuracy: 0.03, "a correct EXIF is left essentially alone")
        let c = compare(try await readOutput(outcome.url))
        print("PROBE merge with 15% wrong EXIF: gains \(outcome.gains.map { "\($0.name) exif \($0.exifGain) used \($0.usedGain)" }), meanRelError \(c.meanRelError)")
        XCTAssertLessThan(c.meanRelError, 0.04)
    }

    /// The aligned measurement path: the frames are SHIFTED, so the gain can only be measured correctly if the proxy is warped by the right
    /// homography first (reviewer-found gap: only align:false was covered, so a missing or inverted proxy warp passed). EXIF is 15% wrong for the bright frame.
    func testMeasuresTheRealGainOnAlignedProxiesWhenFramesAreShifted() async throws {
        // 30 px shifts across a brightness gradient: measured on UNALIGNED proxies the per-pixel ratios would be biased by the gradient.
        let urls = [try writeFrame("bright.jpg", ev: 2, shift: (-30, 0), exposureTime: 1.0 / 25 * 1.15),
                    try writeFrame("dark.jpg", ev: -2, shift: (30, 0), exposureTime: 1.0 / 400),
                    try writeFrame("mid.jpg", ev: 0, shift: (0, 0), exposureTime: 1.0 / 100)]
        let outcome = try await PhotoMerger.mergeHDR(sourceURLs: urls, into: folder)
        XCTAssertEqual(outcome.alignment.count, 2, "registered")
        let bright = try XCTUnwrap(outcome.gains.first { $0.name == "bright.jpg" })
        XCTAssertEqual(bright.usedGain, 4, accuracy: 0.08)
        let c = compare(try await readOutput(outcome.url))
        print("PROBE merge shifted + 15% wrong EXIF: used \(bright.usedGain) (exif \(bright.exifGain)), meanRelError \(c.meanRelError)")
        XCTAssertLessThan(c.meanRelError, 0.05)
    }

    func testSkippingAlignmentOnATripodBracketIsAccurateAndDoesNotRegister() async throws {
        let outcome = try await PhotoMerger.mergeHDR(sourceURLs: try bracket(shifted: false), align: false, into: folder)
        XCTAssertTrue(outcome.alignment.isEmpty)
        let c = compare(try await readOutput(outcome.url))
        XCTAssertLessThan(c.meanRelError, 0.05)
        XCTAssertGreaterThan(c.highlightRecovered, 0.9)
    }

    func testShiftedFramesWithoutAlignmentAreWorseThanWithIt() async throws {
        let urls = try bracket()
        let aligned = compare(try await readOutput(try await PhotoMerger.mergeHDR(sourceURLs: urls, into: folder).url))
        let unaligned = compare(try await readOutput(try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, into: folder).url))
        print("PROBE merge aligned vs unaligned mean rel error: \(aligned.meanRelError) vs \(unaligned.meanRelError)")
        XCTAssertLessThan(aligned.meanRelError, unaligned.meanRelError, "alignment must actually help on shifted frames")
    }

    /// The RAW decode settings are tone-neutral (proportional-to-exposure values), pinned field by field. A default `EditState` would turn the camera
    /// tone curve on (`boostAmount` 1) — the failure the reviewer found.
    func testRawDecodeStateNeutralisesToneShaping() {
        let s = PhotoMerger.linearDecodeState
        XCTAssertEqual(s.boostAmount, 0)
        XCTAssertEqual(s.shadowBoostScale, 0)
        XCTAssertEqual(s.rawSharpnessScale, 0)
        XCTAssertEqual(s.rawContrastAdjust, -1)
        XCTAssertEqual(s.rawDetailAdjust, -3)
        XCTAssertEqual(s.rawExposureEV, 0, "no exposure shift: gains come from EXIF")
        XCTAssertEqual(EditState().boostAmount, 1, "a default decode would have the tone curve on")
    }

    func testLinearLumaUnpremultipliesAndReportsCoverage() {
        // Two pixels: fully covered (0.2, 0.2, 0.2, a 1) and half covered premultiplied (0.1, 0.1, 0.1, a 0.5) => straight 0.2; a third uncovered.
        let rgba: [Float] = [0.2, 0.2, 0.2, 1, 0.1, 0.1, 0.1, 0.5, 0, 0, 0, 0]
        let r = MergeAlignment.linearLumaAndValidity(rgbaFloat: rgba, width: 3, height: 1)
        XCTAssertEqual(r?.luma[0] ?? -1, 0.2, accuracy: 1e-6)
        XCTAssertEqual(r?.luma[1] ?? -1, 0.2, accuracy: 1e-6, "premultiplied colour is divided back by alpha")
        XCTAssertEqual(r?.validity ?? [], [1, 0.5, 0])
        XCTAssertEqual(r?.peak[1] ?? -1, 0.2, accuracy: 1e-6, "the largest channel is un-premultiplied too")
        XCTAssertNil(MergeAlignment.linearLumaAndValidity(rgbaFloat: rgba, width: 4, height: 1))
    }

    func testSecondMergeNeverOverwritesTheFirst() async throws {
        let urls = try bracket(shifted: false)
        let first = try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, into: folder)
        let second = try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, into: folder)
        XCTAssertEqual(first.url.lastPathComponent, "mid-HDR.tiff")
        XCTAssertEqual(second.url.lastPathComponent, "mid-HDR (2).tiff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
    }

    func testMissingExposureDataAndNoBracketAreRefusedWithoutWritingAnything() async throws {
        let a = try writeFrame("a.jpg", ev: 0, shift: (0, 0), exposureTime: 1.0 / 100)
        let noExif = try writeFrame("b.jpg", ev: 1, shift: (0, 0), exposureTime: nil)
        let same = try writeFrame("c.jpg", ev: 0, shift: (0, 0), exposureTime: 1.0 / 100)
        let names = { try FileManager.default.contentsOfDirectory(atPath: self.folder.path).sorted() }
        let initial = try names()
        do { _ = try await PhotoMerger.mergeHDR(sourceURLs: [a, noExif], into: folder); XCTFail("expected a missing-exposure error") } catch PhotoMergeError.plan(let e) {
            XCTAssertEqual(e, .missingExposureData(frameIndex: 1))
        }
        do { _ = try await PhotoMerger.mergeHDR(sourceURLs: [a, same], into: folder); XCTFail("expected a no-bracket error") } catch PhotoMergeError.plan(let e) {
            XCTAssertEqual(e, .noExposureDifference)
        }
        XCTAssertEqual(try names(), initial, "a refused merge writes nothing")
    }

    func testFramesOfDifferentSizeAreRefused() async throws {
        let urls = try bracket(shifted: false)
        // Replace the dark frame with a smaller JPEG that carries the same EXIF exposure (1/400 s, f/8, ISO 100).
        let small = folder.appendingPathComponent("dark.jpg")
        var rgba = [UInt8](repeating: 128, count: 100 * 80 * 4)
        for i in 0..<(100 * 80) { rgba[i * 4 + 3] = 255 }
        let image = CGImage(width: 100, height: 80, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(small as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 1.0 / 400, kCGImagePropertyExifFNumber: 8.0, kCGImagePropertyExifISOSpeedRatings: [100]]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        do { _ = try await PhotoMerger.mergeHDR(sourceURLs: urls, into: folder); XCTFail("expected a size-mismatch error") } catch PhotoMergeError.sizeMismatch(let name) {
            XCTAssertEqual(name, "dark.jpg")
        }
    }

    // MARK: Orientation (turn / flip edits)

    /// Baseline merge (no orientation) of the aligned bracket, as the reference every orientation test is compared with.
    private func baseline(_ urls: [URL]) async throws -> (pixels: [Float], width: Int, height: Int) {
        try await readOutput(PhotoMerger.mergeHDR(sourceURLs: urls, align: false, into: folder).url)
    }

    /// Mean absolute difference of the red channel between `out` and `expected(x, y)` over the whole picture.
    private func meanDiff(_ out: (pixels: [Float], width: Int, height: Int), _ expected: (Int, Int) -> Float) -> Float {
        var sum: Float = 0
        for y in 0..<out.height { for x in 0..<out.width { sum += abs(out.pixels[(y * out.width + x) * 4] - expected(x, y)) } }
        return sum / Float(out.width * out.height)
    }

    func testAllFramesTurnedOneQuarterTurnGiveTheTurnedBaseline() async throws {
        let urls = try bracket(shifted: false)
        let base = try await baseline(urls)
        let turned = try await readOutput(PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: Array(repeating: PhotoOrientation(quarterTurns: 1), count: 3), into: folder).url)
        XCTAssertEqual(turned.width, base.height)
        XCTAssertEqual(turned.height, base.width)
        guard turned.width == base.height, turned.height == base.width else { return } // the indexing below needs swapped dimensions
        // clockwise: new(x', y') = old(x: y', y: H - 1 - x')
        let diff = meanDiff(turned) { x, y in base.pixels[((base.height - 1 - x) * base.width + y) * 4] }
        XCTAssertLessThan(diff, 0.01, "the merge of turned frames is the turned merge")
        XCTAssertGreaterThan(meanDiff(turned) { x, y in base.pixels[(min(y, base.height - 1) * base.width + min(x, base.width - 1)) * 4] }, 0.05, "and it is NOT the unturned picture")
    }

    func testFlippedFramesGiveTheFlippedBaseline() async throws {
        let urls = try bracket(shifted: false)
        let base = try await baseline(urls)
        let flipped = try await readOutput(PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: Array(repeating: PhotoOrientation(flipHorizontal: true), count: 3), into: folder).url)
        XCTAssertEqual(flipped.width, base.width)
        XCTAssertLessThan(meanDiff(flipped) { x, y in base.pixels[(y * base.width + (base.width - 1 - x)) * 4] }, 0.01)
    }

    /// Turn first, flip later (the pipeline's order): the two orders give different pictures.
    func testATurnAndAFlipApplyInThePipelinesOrder() async throws {
        let urls = try bracket(shifted: false)
        let base = try await baseline(urls)
        let o = PhotoOrientation(quarterTurns: 1, flipHorizontal: true)
        let out = try await readOutput(PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: Array(repeating: o, count: 3), into: folder).url)
        XCTAssertEqual(out.width, base.height)
        guard out.width == base.height, out.height == base.width else { return }
        // turned(x', y') = base(y', H - 1 - x'); then mirrored left-right: out(x', y') = turned(W' - 1 - x', y')
        let diff = meanDiff(out) { x, y in base.pixels[((base.height - 1 - (out.width - 1 - x)) * base.width + y) * 4] }
        XCTAssertLessThan(diff, 0.01)
    }

    /// The turn happens BEFORE the size check: one frame turned makes it a different size from the others.
    func testTheSizeCheckSeesTheTurnedFrames() async throws {
        let urls = try bracket(shifted: false)
        do {
            _ = try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: [.identity, PhotoOrientation(quarterTurns: 1), .identity], into: folder)
            XCTFail("expected a size mismatch")
        } catch PhotoMergeError.sizeMismatch(let name) {
            XCTAssertEqual(name, "dark.jpg")
            XCTAssertFalse((PhotoMergeError.sizeMismatch(name).errorDescription ?? "").contains("HDR"), "the wording is shared with panoramas")
        }
    }

    func testAnOrientationListOfTheWrongLengthIsRefusedNotIgnored() async throws {
        let urls = try bracket(shifted: false)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        do {
            _ = try await PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: [PhotoOrientation(quarterTurns: 1)], into: folder)
            XCTFail("expected a refusal")
        } catch PhotoMergeError.orientationCountMismatch {
            XCTAssertFalse((PhotoMergeError.orientationCountMismatch.errorDescription ?? "").isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before, "nothing written")
    }

    func testNoOrientationsMeansTheSameAsAllIdentity() async throws {
        let urls = try bracket(shifted: false)
        let base = try await baseline(urls)
        let same = try await readOutput(PhotoMerger.mergeHDR(sourceURLs: urls, align: false, orientations: Array(repeating: .identity, count: 3), into: folder).url)
        XCTAssertEqual(same.pixels, base.pixels)
    }
}
