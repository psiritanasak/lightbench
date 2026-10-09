import CoreGraphics
import simd
import Vision
import XCTest

/// PERMANENT feasibility probe for panorama merge (same role as `HDRMergeProbeTests`). Nothing in `Sources/` uses it yet.
/// Frames come from a rotating PINHOLE camera (pure yaw, no translation) over a synthetic textured sphere, so the exact homography between
/// any two frames is known (H = K R K^-1). It measures how closely Vision's homographic registration, and a CHAIN of them, match that truth
/// (docs/ROADMAP_HISTORY.md "Photo Merge spike").
final class PanoramaRegistrationProbeTests: XCTestCase {
    private static let width = 480, height = 320
    private static let focal: Float = 480 / 2 / tan(30 * .pi / 180) // 60 degree horizontal field of view

    private struct Blob { let lon: Float, lat: Float, size: Float, value: Float }
    private static let blobs: [Blob] = {
        var seed: UInt64 = 0xC0FFEE1234567
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float((seed >> 33) & 0xFFFF) / 65535 }
        return (0..<400).map { _ in Blob(lon: (next() - 0.5) * 2.2, lat: (next() - 0.5) * 0.9, size: 0.012 + next() * 0.03, value: next()) }
    }()

    private static func rotationY(_ radians: Float) -> simd_float3x3 {
        let c = cos(radians), s = sin(radians)
        return simd_float3x3(columns: (SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c)))
    }

    private static var intrinsics: simd_float3x3 {
        simd_float3x3(columns: (SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(Float(width) / 2, Float(height) / 2, 1)))
    }

    /// Camera at `yaw` radians. Pixel coordinates are top-left origin, y down (the camera looks along +z, image y down).
    private static func frame(yaw: Float) throws -> CGImage {
        let r = rotationY(yaw), kInv = intrinsics.inverse
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let d = r * (kInv * SIMD3(Float(x), Float(y), 1))
            let lon = atan2(d.x, d.z), lat = atan2(-d.y, hypot(d.x, d.z))
            var v: Float = 0.15
            for b in blobs {
                let dl = lon - b.lon, dt = lat - b.lat
                let q = (dl * dl + dt * dt) / (b.size * b.size)
                if q < 9 { v += (b.value - 0.15) * exp(-q) }
            }
            pixels[y * width + x] = UInt8(min(max(v, 0), 1) * 255)
        } }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent))
    }

    /// The exact map from pixels of the camera at yaw `from` to pixels of the camera at yaw `to` (top-left origin).
    private static func trueHomography(from: Float, to: Float) -> simd_float3x3 {
        intrinsics * rotationY(to).transpose * rotationY(from) * intrinsics.inverse
    }

    private static func apply(_ h: simd_float3x3, _ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = h * SIMD3(p.x, p.y, 1)
        return SIMD2(q.x / q.z, q.y / q.z)
    }

    /// Vision works in bottom-left-origin image space; convert a top-left homography to that space and back.
    private static func flipY(_ h: simd_float3x3) -> simd_float3x3 {
        let f = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, Float(height), 1)))
        return f * h * f
    }

    /// Grid of sample points in the TARGET frame (top-left coordinates) whose true image lies inside the reference frame.
    private static func samples(truth: simd_float3x3) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for y in stride(from: 20, to: height - 20, by: 40) { for x in stride(from: 20, to: width - 20, by: 40) {
            let p = SIMD2(Float(x), Float(y)), q = apply(truth, p)
            if q.x > 10, q.x < Float(width) - 10, q.y > 10, q.y < Float(height) - 10 { out.append(p) }
        } }
        return out
    }

    private static func register(target: CGImage, onto reference: CGImage) throws -> simd_float3x3 {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: target, options: [:])
        do { try VNSequenceRequestHandler().perform([request], on: reference) } catch { throw XCTSkip("registration failed: \(error)") }
        let w = try XCTUnwrap((request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform)
        return flipY(w) // back to top-left coordinates
    }

    /// Level-pan pipeline (measured 2026-10-09, see docs/ROADMAP_HISTORY.md 'Photo Merge spike'): coarse horizontal-only translation (dy forced to 0), shift, then homographic refinement; returns the
    /// composed target -> reference map in top-left pixel coordinates.
    private static func registerLevelPan(target: CGImage, onto reference: CGImage) throws -> simd_float3x3 {
        let tReq = VNTranslationalImageRegistrationRequest(targetedCGImage: target, options: [:])
        do { try VNSequenceRequestHandler().perform([tReq], on: reference) } catch { throw XCTSkip("registration failed: \(error)") }
        let t = try XCTUnwrap((tReq.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform)
        let dx = Int(t.tx.rounded())
        let coarse = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(dx), 0, 1)))
        let refine = try register(target: try shifted(target, dx: dx, dy: 0), onto: reference)
        return refine * coarse
    }

    private static func maxError(_ h: simd_float3x3, truth: simd_float3x3) -> (max: Float, mean: Float, n: Int) {
        let pts = samples(truth: truth)
        let errs = pts.map { simd_distance(apply(h, $0), apply(truth, $0)) }
        return (errs.max() ?? .nan, errs.reduce(0, +) / Float(max(errs.count, 1)), pts.count)
    }

    /// SANITY: the exact homography really maps B pixels onto the same scene content in A (pixel values agree at mapped points).
    func testTrueHomographyMapsMatchingContent() throws {
        let yaw: Float = 20 * .pi / 180
        let a = try Self.frame(yaw: 0), b = try Self.frame(yaw: yaw)
        func gray(_ image: CGImage) -> [UInt8] {
            let data = image.dataProvider?.data as Data?
            return [UInt8](data ?? Data())
        }
        let ga = gray(a), gb = gray(b)
        XCTAssertEqual(ga.count, Self.width * Self.height)
        let truth = Self.trueHomography(from: yaw, to: 0)
        var worst = 0, n = 0, sum = 0
        for p in Self.samples(truth: truth) {
            let q = Self.apply(truth, p)
            let vb = Int(gb[Int(p.y.rounded()) * Self.width + Int(p.x.rounded())])
            let va = Int(ga[Int(q.y.rounded()) * Self.width + Int(q.x.rounded())])
            worst = max(worst, abs(va - vb)); sum += abs(va - vb); n += 1
        }
        print("PROBE truth sanity: points=\(n) meanAbsPixelDiff=\(Double(sum) / Double(max(n, 1))) worst=\(worst)")
        XCTAssertLessThan(Double(sum) / Double(max(n, 1)), 6)
    }

    /// Shift an image by (dx, dy) in TOP-LEFT pixel units (content moves right/down), filling with mid-gray.
    private static func shifted(_ image: CGImage, dx: Int, dy: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: dx, y: -dy, width: width, height: height)) // CG y is up
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Plain homographic registration at a SMALL step (1 degree, about 8 px of shift): the only regime where it was measured accurate.
    /// Measured 2026-10-09 (Apple M1, macOS 27.0; 480x320 frames, 60 degree FOV, exact K R K^-1 truth, convention flip(W) = target -> reference
    /// in top-left coordinates): 1 deg mean 0.055 px / max 0.116; 2 deg 3.6 px; 4 deg 17.8 px; 6 deg 43.8 px; 10 deg 76 px; 20 deg 136 px — i.e.
    /// `VNHomographicImageRegistrationRequest` is a SMALL-MOTION (video-stabilisation style) API and is useless on its own for panorama steps.
    func testHomographyMatchesTheTrueRotationHomography() throws {
        let yaw: Float = 1 * .pi / 180
        let a = try Self.frame(yaw: 0), b = try Self.frame(yaw: yaw)
        let truth = Self.trueHomography(from: yaw, to: 0)
        let h = try Self.register(target: b, onto: a)
        let e = Self.maxError(h, truth: truth)
        print("PROBE panorama single pair, 1 deg yaw: points=\(e.n) maxErr=\(e.max)px meanErr=\(e.mean)px")
        XCTAssertGreaterThan(e.n, 20)
        XCTAssertLessThan(e.mean, 0.5)
    }

    /// Chain of two level-pan registrations (frame 2 -> 1 -> 0) vs the exact frame-2 -> frame-0 homography, yaw 0, 15, 30 degrees.
    func testChainedLevelPanErrorStaysSmall() throws {
        let y1: Float = 15 * .pi / 180, y2: Float = 30 * .pi / 180
        let f0 = try Self.frame(yaw: 0), f1 = try Self.frame(yaw: y1), f2 = try Self.frame(yaw: y2)
        let h10 = try Self.registerLevelPan(target: f1, onto: f0)
        let h21 = try Self.registerLevelPan(target: f2, onto: f1)
        let e1 = Self.maxError(h10, truth: Self.trueHomography(from: y1, to: 0))
        let e2 = Self.maxError(h21, truth: Self.trueHomography(from: y2, to: y1))
        let chained = Self.maxError(h10 * h21, truth: Self.trueHomography(from: y2, to: 0))
        print("PROBE panorama level-pan chain 0-15-30 deg: 1->0 mean=\(e1.mean)px; 2->1 mean=\(e2.mean)px; chained 2->0 n=\(chained.n) mean=\(chained.mean)px max=\(chained.max)px")
        XCTAssertGreaterThan(chained.n, 0)
        XCTAssertLessThan(e1.mean, 2)
        XCTAssertLessThan(e2.mean, 2)
    }
}
