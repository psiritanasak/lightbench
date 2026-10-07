import CoreGraphics
import CoreImage
import Vision
import XCTest

/// Permanent probe for Styles v3 (skin-tone protection; spike 2026-10-07, numbers in docs/ROADMAP_HISTORY.md): pins the OS facts
/// the go/no-go rests on, with synthetic images only (no photo fixtures live in the repo; the real-photo numbers were measured
/// once by hand and recorded in the docs — they are RECORDED facts, not re-checked here). Detector "C" is the skin-coloured
/// pixels INSIDE a Vision person-segmentation mask.
final class SkinProtectionProbeTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The YCbCr skin window the spike used for detector A (Y>40, Cb 77-127, Cr 133-173), on 0...255 sRGB components.
    private func inSkinWindow(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
        let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
        return y > 40 && cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173
    }

    /// A warm desert-like scene with NO person: a sand-coloured gradient with a rock-coloured block — colours that fall inside
    /// the colour window (`testTheDesertSceneColoursFoolTheColourWindow`); on real non-person photos the window alone marked
    /// 18-52% of the pixels.
    private func desertScene(width: Int = 384, height: Int = 288) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<height {
            ctx.setFillColor(CGColor(red: 0.80 - CGFloat(y) / CGFloat(height) * 0.15, green: 0.62, blue: 0.45, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        ctx.setFillColor(CGColor(red: 0.70, green: 0.42, blue: 0.32, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func segment(_ image: CGImage) throws -> [UInt8] {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return [] }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                         count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)))
    }

    func testPersonSegmentationRevisionOneIsAvailable() {
        // Observed 2026-10-07 on the session's macOS 27: the only supported revision is 1.
        XCTAssertTrue(VNGeneratePersonSegmentationRequest.supportedRevisions.contains(1),
                      "supported: \(VNGeneratePersonSegmentationRequest.supportedRevisions)")
    }

    /// Premise of the whole design: the colours of a desert/rock scene lie INSIDE the skin window, so the window alone would mark
    /// them. (Pure arithmetic; the sand and rock colours below are the ones `desertScene()` draws.)
    func testTheDesertSceneColoursFoolTheColourWindow() {
        XCTAssertTrue(inSkinWindow(0.80 * 255, 0.62 * 255, 0.45 * 255), "sand")
        XCTAssertTrue(inSkinWindow(0.70 * 255, 0.42 * 255, 0.32 * 255), "rock")
        XCTAssertFalse(inSkinWindow(0.1 * 255, 0.3 * 255, 0.9 * 255), "blue sky is not skin-coloured")
    }

    /// Why detector C (colour window AND person mask) beats the colour window alone: on the five real non-person scenes the
    /// person mask marked 0.0% (to one decimal) while the window alone marked 18-52%. Here: a synthetic person-free scene gives
    /// an empty mask.
    func testASceneWithNoPersonProducesAnEmptyPersonMask() throws {
        let mask = try segment(try desertScene())
        XCTAssertFalse(mask.isEmpty, "the request returned a mask buffer")
        XCTAssertEqual(mask.filter { $0 > 127 }.count, 0, "no person -> no person pixels, however skin-coloured the scene")
    }

    /// Pins only that an EMPTY mask stays empty and byte-identical across runs: the input has no person (the previous test), so
    /// this does NOT show determinism on a real person mask — that was measured once by hand on a real photo (5 runs
    /// bit-identical) and is recorded in the docs. Vision is not guaranteed stable across OS versions, which is why a render-time
    /// call would break replay determinism (the Subject mask is PERSISTED for that reason).
    func testAnEmptyPersonMaskIsByteIdenticalAcrossRuns() throws {
        let image = try desertScene()
        let runs = try (0..<5).map { _ in try segment(image) }
        XCTAssertTrue(runs.dropFirst().allSatisfy { $0 == runs[0] }, "5 runs must match byte for byte")
    }
}
