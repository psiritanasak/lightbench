import CoreGraphics
import CoreImage
import Vision
import XCTest

/// PERMANENT feasibility probe (same role as `SuperResolutionUpscalerTests.testMetalFXSpatialScalerProbe`):
/// pins the facts a future AI "Subject" mask would rely on from
/// `VNGenerateForegroundInstanceMaskRequest`, measured on this project's dev machine
/// (Apple M1, see docs/ROADMAP_HISTORY.md "Vision subject-mask spike"). Nothing in `Sources/`
/// uses Vision yet — this is a spike, not a shipped mask kind.
///
/// `XCTSkip`s (not fails) when Vision can't run the request or finds no subject in the synthetic
/// fixture: a real, hardware/OS-dependent outcome, and a signal the spike's GO decision must be
/// re-checked there.
final class VisionSubjectMaskProbeTests: XCTestCase {
    private static let width = 1500
    private static let height = 1000

    /// A gradient background; optionally a red "body" + skin-tone "head" in the LEFT third.
    private static func fixture(subject: Bool) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.55, green: 0.7, blue: 0.85, alpha: 1),
                     CGColor(red: 0.35, green: 0.5, blue: 0.3, alpha: 1)] as CFArray,
            locations: [0, 1]))
        let w = CGFloat(width), h = CGFloat(height)
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        if subject {
            ctx.setFillColor(CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.2, width: w * 0.26, height: h * 0.5))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.18, y: h * 0.62, width: w * 0.14, height: h * 0.2))
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func observation(for image: CGImage) throws -> (VNInstanceMaskObservation, VNImageRequestHandler)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do { try handler.perform([request]) } catch {
            throw XCTSkip("VNGenerateForegroundInstanceMaskRequest failed on this machine: \(error)")
        }
        guard let first = request.results?.first else { return nil }
        return (first, handler)
    }

    /// Mean mask value over the left and right halves of a scaled float mask (sampled on a grid).
    private func halfMasses(_ buffer: CVPixelBuffer) -> (left: Double, right: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0) }
        var left = 0.0, right = 0.0
        for y in stride(from: 0, to: h, by: 5) {
            for x in stride(from: 0, to: w, by: 5) {
                let v = Double(base.advanced(by: y * bpr + x * 4).assumingMemoryBound(to: Float32.self).pointee)
                if x < w / 2 { left += v } else { right += v }
            }
        }
        return (left, right)
    }

    func testSubjectIsFoundAtInputExtentAndOnTheCorrectSide() throws {
        let image = try Self.fixture(subject: true)
        guard let (obs, handler) = try observation(for: image) else {
            throw XCTSkip("Vision found no foreground subject in the synthetic fixture.")
        }
        XCTAssertEqual(obs.allInstances.count, 1)
        // Native mask is a fixed small raster (measured 512x512), NOT input-sized.
        let native = obs.instanceMask
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(native), kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(CVPixelBufferGetWidth(native), 512)
        XCTAssertEqual(CVPixelBufferGetHeight(native), 512)

        let scaled = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        XCTAssertEqual(CVPixelBufferGetWidth(scaled), image.width)
        XCTAssertEqual(CVPixelBufferGetHeight(scaled), image.height)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(scaled), kCVPixelFormatType_OneComponent32Float)

        // Orientation-preserving: the figure is drawn in the left third, so ALL mask mass must be left.
        let (left, right) = halfMasses(scaled)
        XCTAssertGreaterThan(left, 1000, "subject mass should be substantial on the left")
        XCTAssertEqual(right, 0, accuracy: left * 0.01, "no meaningful mask mass on the right half")
    }

    func testFeaturelessImageYieldsNoObservationWithoutThrowing() throws {
        // Guard against vacuity: if Vision finds nothing for the SUBJECT fixture either, nil proves nothing.
        guard try observation(for: try Self.fixture(subject: true)) != nil else {
            throw XCTSkip("Vision found no foreground subject in the synthetic fixture.")
        }
        let image = try Self.fixture(subject: false)
        let result = try observation(for: image)
        XCTAssertNil(result, "a featureless gradient must be the 'nothing found' path (nil), not an error")
    }

    func testRepeatedRunsAreBitIdentical() throws {
        let image = try Self.fixture(subject: true)
        var runs: [[UInt8]] = []
        for _ in 0..<3 {
            guard let (obs, _) = try observation(for: image) else {
                throw XCTSkip("Vision found no foreground subject in the synthetic fixture.")
            }
            let buffer = obs.instanceMask
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            var bytes: [UInt8] = []  // visible bytes only — row padding is not guaranteed initialized
            for row in 0..<CVPixelBufferGetHeight(buffer) {
                bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * rowBytes, count: width))
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            runs.append(bytes)
        }
        XCTAssertFalse(runs[0].allSatisfy { $0 == 0 }, "mask must not be all-zero (would make equality vacuous)")
        XCTAssertEqual(runs[1], runs[0])
        XCTAssertEqual(runs[2], runs[0])
    }
}
