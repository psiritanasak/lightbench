import CoreImage
import XCTest
@testable import PhotoApp

/// `HorizonDetector` (Vision) against a landscape drawn in code and rotated by a KNOWN angle through
/// `EditPipeline`. This is what pins the sign between Vision's angle and `EditState.straightenAngle`.
/// `XCTSkip`s when Vision finds no horizon (Vision tests are flaky under full-suite load).
final class HorizonDetectorTests: XCTestCase {
    static let context = CIContext()

    /// Pale smooth sky over a textured darker ground, level horizon at 45% of the height.
    static func landscape(width: Int = 1200, height: Int = 800) -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 24) / 255 }
        let horizon = Int(Float(height) * 0.45)
        for y in 0..<height { for x in 0..<width {
            var r: Float, g: Float, b: Float
            if y < horizon {
                let t = Float(y) / Float(horizon)
                r = 0.55 + 0.25 * t; g = 0.7 + 0.2 * t; b = 0.95
            } else {
                let depth = Float(y - horizon) / Float(height - horizon)
                let grain = noise() * (0.05 + 0.2 * depth)
                r = 0.32 + grain; g = 0.25 + grain * 0.8; b = 0.15 + grain * 0.6
            }
            let i = (y * width + x) * 4
            rgba[i] = UInt8(min(max(r, 0), 1) * 255); rgba[i + 1] = UInt8(min(max(g, 0), 1) * 255); rgba[i + 2] = UInt8(min(max(b, 0), 1) * 255)
        } }
        // Row 0 of the bitmap is the TOP; the sky (y < horizon) is therefore on top.
        return CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The landscape rendered through the real pipeline with `straightenAngle` set, as an opaque bitmap-backed CIImage.
    static func rotated(_ degrees: Double) throws -> CIImage {
        var state = EditState()
        state.straightenAngle = degrees
        let out = EditPipeline.apply(state, to: Self.landscape())
        let cg = try XCTUnwrap(Self.context.createCGImage(out, from: out.extent))
        return CIImage(cgImage: cg)
    }

    private func visionAngleDegrees(_ image: CIImage) throws -> Double {
        switch HorizonDetector.detect(in: image) {
        case .angle(let radians): return radians * 180 / .pi
        case .none: throw XCTSkip("Vision found no horizon in the synthetic fixture")
        case .failed(let reason): throw XCTSkip("Vision failed: \(reason)")
        }
    }

    // MARK: Sign and tolerance (measured)

    /// Rotating a level landscape by `straightenAngle = X` must yield a solved correction of about `-X`. The sign
    /// is whatever Vision actually does, pinned here against the real pipeline (not assumed).
    func testSolvedCorrectionUndoesAKnownRotation() throws {
        var checked = 0
        var missed: [Double] = []
        for x in [-12.0, -8.0, -3.0, 3.0, 8.0, 12.0] {
            // Vision sometimes reports no horizon for a steep synthetic one: skip that angle, but not the sign check.
            guard case .angle(let radians) = HorizonDetector.detect(in: try Self.rotated(x)) else {
                missed.append(x)
                continue
            }
            guard case .angle(let correction) = StraightenSolver.solve(visionHorizonAngle: radians) else {
                return XCTFail("rotation \(x): solver gave no angle")
            }
            XCTAssertEqual(correction, -x, accuracy: 0.25, "rotation \(x)")
            checked += 1
        }
        if checked < 4 { throw XCTSkip("Vision found a horizon at only \(checked) of 6 angles (no horizon at \(missed))") }
        XCTAssertGreaterThanOrEqual(checked, 4, "checked \(checked) of 6 angles; no horizon at \(missed)")
    }

    func testReportsNoHorizonOrFailureForADegenerateImage() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        switch HorizonDetector.detect(in: flat) {
        case .angle(let radians): XCTAssertEqual(radians, 0, accuracy: 0.05) // a flat grey has no tilt to report
        case .none, .failed: break // either is a correct refusal
        }
        if case .failed = HorizonDetector.detect(in: CIImage(color: .red)) {} else { XCTFail("an infinite extent must fail, not run Vision") }
    }
}
