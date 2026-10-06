import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
@testable import PhotoApp

/// Permanent probe for duplicate detection (spike 2026-10-06, numbers in docs/ROADMAP_HISTORY.md): pins the OS facts the
/// design rests on — `VNGenerateImageFeaturePrintRequest` revision 2 is available and yields 768 floats, an image is at
/// distance 0 from itself and deterministic. Synthetic scenes only (the real-photo numbers were measured once by hand and
/// recorded in the docs; no photo fixtures live in the repo).
final class FeaturePrintProbeTests: XCTestCase {
    /// A deterministic "scene": a sky/ground gradient plus seeded coloured rectangles.
    private func scene(seed: UInt64, side: Int = 512) -> CGImage {
        var rng = SplitMix(seed)
        let ctx = CGContext(data: nil, width: side, height: side * 2 / 3, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let h = CGFloat(side * 2 / 3)
        let sky = CGColor(red: rng.unit() * 0.5, green: rng.unit() * 0.5 + 0.3, blue: 0.8, alpha: 1)
        let ground = CGColor(red: rng.unit() * 0.6 + 0.2, green: rng.unit() * 0.4, blue: rng.unit() * 0.3, alpha: 1)
        ctx.setFillColor(sky); ctx.fill(CGRect(x: 0, y: h / 2, width: CGFloat(side), height: h / 2))
        ctx.setFillColor(ground); ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: h / 2))
        for _ in 0..<12 {
            ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fill(CGRect(x: rng.unit() * CGFloat(side) * 0.8, y: rng.unit() * h * 0.8, width: 20 + rng.unit() * 120, height: 20 + rng.unit() * 90))
        }
        return ctx.makeImage()!
    }

    private func resampled(_ image: CGImage, to width: Int) -> CGImage {
        let height = image.height * width / image.width
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func jpegRoundTrip(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return try XCTUnwrap(request.results?.first)
    }

    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) throws -> Float {
        var d: Float = 0
        try a.computeDistance(&d, to: b)
        return d
    }

    func testRevisionTwoIsSupportedAndProducesA768FloatVector() throws {
        XCTAssertTrue(VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(VNGenerateImageFeaturePrintRequestRevision2))
        let print = try featurePrint(scene(seed: 1))
        XCTAssertEqual(print.elementCount, 768)
        XCTAssertEqual(print.elementType, .float)
        XCTAssertEqual(print.data.count, 768 * MemoryLayout<Float>.size, "the blob a fingerprint cache would store")
    }

    /// NEGATIVE FINDING (measured 2026-10-06): abstract synthetic scenes are NOT a valid proxy for real photos — here a
    /// resized copy was 0.307, a q0.4 re-encode 0.454 and an unrelated scene 0.346 from the original (no separation), while
    /// real photos separated cleanly (resize 0.09, exact 0.000, unrelated >= 0.89; see docs/ROADMAP_HISTORY.md). So this
    /// suite asserts only what holds for ANY image (self-distance 0, determinism) and never tests thresholds on synthetic
    /// scenes; the grouping logic is tested on injected distances instead.
    func testIdenticalImageIsAtDistanceZeroAndTheFingerprintIsDeterministic() throws {
        let a = scene(seed: 7)
        let pa = try featurePrint(a)
        XCTAssertEqual(try distance(pa, pa), 0, accuracy: 1e-6)
        XCTAssertEqual(try distance(pa, featurePrint(a)), 0, accuracy: 1e-6, "same pixels, separate request: same print")
        let dSmall = try distance(pa, featurePrint(resampled(a, to: 256)))
        let dRecompressed = try distance(pa, featurePrint(jpegRoundTrip(a, quality: 0.4)))
        let dOther = try distance(pa, featurePrint(scene(seed: 99)))
        print("FEATUREPRINT synthetic (not a threshold proxy): resized=\(dSmall) recompressed=\(dRecompressed) unrelated=\(dOther)")
    }

    func testDistanceIsSymmetric() throws {
        let a = try featurePrint(scene(seed: 3)), b = try featurePrint(scene(seed: 4))
        XCTAssertEqual(try distance(a, b), try distance(b, a), accuracy: 1e-5)
    }
}

/// Tiny deterministic generator so the fixtures are identical on every run.
private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}
