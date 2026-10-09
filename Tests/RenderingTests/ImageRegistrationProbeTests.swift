import CoreGraphics
import Vision
import XCTest

/// PERMANENT feasibility probe for HDR / panorama merge alignment (same role as `SkyMaskProbeTests`). Nothing in `Sources/`
/// uses it yet: it measures what Vision's two registration requests actually return on a KNOWN synthetic shift/rotation, so the
/// merge stages are built on measured facts (docs/ROADMAP_HISTORY.md "Photo Merge spike"). Skips only when a request ERRORS.
final class ImageRegistrationProbeTests: XCTestCase {
    /// Deterministic textured scene: a seeded set of coloured discs and bars over a gradient. `shift` moves the CONTENT right/down
    /// by that many pixels (so the shifted image shows the same scene translated); `degrees` rotates it about the centre.
    private static func scene(width: Int = 800, height: Int = 600, shift: CGPoint = .zero, degrees: CGFloat = 0) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: CGFloat(width) / 2 + shift.x, y: CGFloat(height) / 2 - shift.y) // CG origin is bottom-left
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFF) / 65535
        }
        for _ in 0..<160 {
            ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            let r = 6 + next() * 30
            let rect = CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: r * (0.5 + next()), height: r)
            if next() > 0.5 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Vision's translational request: which direction/sign does `alignmentTransform` use, and how accurate is it?
    /// Measured 2026-10-09 (Apple M1, macOS 27.0, 800x600 textured synthetic): content moved +13 right / 7 up (bottom-left origin) gave
    /// tx = -13.0, ty = -7.0 EXACTLY in 0.017 s — i.e. the transform maps the TARGET image onto the REFERENCE, in Core Image's
    /// bottom-left-origin coordinates (inferred from the sign of the result; applying it with `CIImage.transformed(by:)` is NOT yet verified).
    func testTranslationalRegistrationRecoversAKnownShift() throws {
        let reference = try Self.scene()
        let moved = try Self.scene(shift: CGPoint(x: 13, y: -7))
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: moved, options: [:])
        do { try VNSequenceRequestHandler().perform([request], on: reference) } catch { throw XCTSkip("registration failed: \(error)") }
        let t = try XCTUnwrap((request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform)
        print("PROBE translational: tx=\(t.tx) ty=\(t.ty) (content moved by +13,-7 in top-left pixel coords)")
        XCTAssertEqual(abs(t.tx), 13, accuracy: 1.0)
        XCTAssertEqual(abs(t.ty), 7, accuracy: 1.0)
    }

    /// Vision's homographic request on a pure shift plus a 2 degree rotation: matrix form and residual.
    /// Measured 2026-10-09 (same machine/fixture): columns (0.99883, -0.03497, ~0), (0.03462, 0.99890, ~0), (-23.38, 7.65, 1.00004) in
    /// 0.109 s — sin(2 deg) = 0.03490, so rotation is recovered to ~0.0001 and the matrix is a column-vector homography in pixel units.
    func testHomographicRegistrationRecoversShiftAndRotation() throws {
        let reference = try Self.scene()
        let moved = try Self.scene(shift: CGPoint(x: 13, y: -7), degrees: 2)
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: moved, options: [:])
        do { try VNSequenceRequestHandler().perform([request], on: reference) } catch { throw XCTSkip("registration failed: \(error)") }
        let w = try XCTUnwrap((request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform)
        print("PROBE homographic columns: \(w.columns.0) \(w.columns.1) \(w.columns.2)")
        // A rotation of 2 degrees has sin ~ 0.0349: the off-diagonal terms must be near that magnitude if the matrix is a similarity.
        XCTAssertEqual(abs(w.columns.0.y), 0.0349, accuracy: 0.01)
    }
}
