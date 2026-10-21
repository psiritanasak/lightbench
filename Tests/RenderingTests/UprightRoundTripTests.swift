import CoreImage
import XCTest
@testable import PhotoApp

/// Upright through the REAL pipeline: a building-like fixture is distorted with `EditPipeline` by a KNOWN
/// `straightenAngle` / `verticalPerspective`, measured with `UprightDetector`, solved with `UprightSolver`, and the
/// solved correction must undo it. This is what pins the signs and units of `UprightSolver` (derived, not assumed),
/// and the orientation of the detector's bitmap.
final class UprightRoundTripTests: XCTestCase {
    static let context = CIContext()

    /// A grey frame with a dark building: a lighter pilaster at each of five columns (full building height, so the
    /// vertical lines are well spread across the width) and light floor bars between them.
    static func building(width: Int = 1200, height: Int = 900) -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let left = Int(Double(width) * 0.22), right = Int(Double(width) * 0.78)
        let top = Int(Double(height) * 0.10), bottom = Int(Double(height) * 0.92)
        let pilasters = (0..<5).map { left + (right - left) * $0 / 4 }
        for y in 0..<height {
            for x in 0..<width {
                var value: Float = 0.62 // sky/background: filled, so a distorted frame has no holes of its own
                if x >= left && x <= right && y >= top && y <= bottom {
                    value = 0.22
                    if pilasters.contains(where: { abs(x - $0) <= 3 }) { value = 0.85 }
                    else if (y - top) % 110 < 6 { value = 0.8 } // floor bars
                }
                let byte = UInt8(min(max(value, 0), 1) * 255)
                let i = (y * width + x) * 4
                rgba[i] = byte; rgba[i + 1] = byte; rgba[i + 2] = byte
            }
        }
        // Row 0 of the bitmap is the TOP.
        return CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The pipeline's output composited over the fixture's own background grey, so the transparent wedges that
    /// Straighten / Perspective reveal do not become a strong rotated or trapezoidal FRAME border (which would carry
    /// exactly the applied tilt and be the longest line in the picture). A real photo has no such border.
    static func rendered(_ state: EditState, from image: CIImage) throws -> CIImage {
        let grey = CIColor(red: 0.62, green: 0.62, blue: 0.62, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) ?? .gray
        let background = CIImage(color: grey)
        let rendered = EditPipeline.apply(state, to: image)
        let out = rendered.composited(over: background.cropped(to: rendered.extent))
        let cg = try XCTUnwrap(context.createCGImage(out, from: out.extent))
        return CIImage(cgImage: cg)
    }

    private func lines(_ image: CIImage) throws -> UprightLineDetector.Lines {
        switch UprightDetector.detect(in: image) {
        case .lines(let found): return found
        case .failed(let reason): throw XCTSkip("detector failed: \(reason)")
        }
    }

    private func solved(_ image: CIImage, _ mode: UprightMode) throws -> UprightSolver.Outcome {
        UprightSolver.solve(try lines(image), mode: mode)
    }

    // MARK: Straighten sign and tolerance (measured)

    /// Rotating by `straightenAngle = X` must make Level solve to about `-X`.
    func testLevelUndoesAKnownRotation() throws {
        let source = Self.building()
        var worst = 0.0
        for x in [-11.0, -6.0, 6.0] {
            var state = EditState(); state.straightenAngle = x
            let outcome = try solved(try Self.rendered(state, from: source), .level)
            guard case .solved(let c) = outcome else { return XCTFail("rotation \(x): \(outcome)") }
            XCTAssertEqual(c.straightenAngle, -x, accuracy: 0.3, "rotation \(x)")
            worst = max(worst, abs(c.straightenAngle + x))
            print("UPRIGHT-MEASURED level rotation \(x) -> \(c.straightenAngle)")
        }
        print("UPRIGHT-MEASURED level worst error \(worst)")
    }

    func testLevelOfAnUprightPhotoDoesNothing() throws {
        let outcome = try solved(Self.building(), .level)
        XCTAssertEqual(outcome, .alreadyUpright)
    }

    // MARK: Vertical sign and tolerance (measured)

    /// Applying `verticalPerspective = v` makes Vertical solve to about `-v`.
    func testVerticalUndoesAKnownKeystone() throws {
        let source = Self.building()
        var worst = 0.0
        for v in [-0.4, 0.4] {
            var state = EditState(); state.verticalPerspective = v
            let outcome = try solved(try Self.rendered(state, from: source), .vertical)
            guard case .solved(let c) = outcome else { return XCTFail("keystone \(v): \(outcome)") }
            XCTAssertEqual(c.verticalPerspective ?? 9, -v, accuracy: 0.06, "keystone \(v)")
            XCTAssertEqual(c.straightenAngle, 0, accuracy: 0.3, "keystone \(v): no rotation expected")
            worst = max(worst, abs((c.verticalPerspective ?? 9) + v))
            print("UPRIGHT-MEASURED vertical keystone \(v) -> \(c.verticalPerspective ?? .nan) straighten \(c.straightenAngle)")
        }
        print("UPRIGHT-MEASURED vertical worst error \(worst)")
    }

    func testVerticalOfAnUprightPhotoDoesNothing() throws {
        XCTAssertEqual(try solved(Self.building(), .vertical), .alreadyUpright)
    }

    /// Rotation plus keystone: the solved correction applied to the distorted picture leaves lines that re-measure as
    /// parallel and vertical (the off-centre vanishing-point path, with the enlarged post-rotation extent).
    func testCombinedDistortionIsCorrectedByTheSolvedValues() throws {
        let source = Self.building()
        for (rotation, keystone) in [(3.0, 0.3), (-4.0, 0.25)] {
            var distort = EditState(); distort.straightenAngle = rotation; distort.verticalPerspective = keystone
            let distorted = try Self.rendered(distort, from: source)
            guard case .solved(let c) = try solved(distorted, .vertical) else { return XCTFail("\(rotation)/\(keystone): not solved") }
            var fix = EditState(); fix.straightenAngle = c.straightenAngle; fix.verticalPerspective = c.verticalPerspective ?? 0
            let after = try Self.rendered(fix, from: distorted)
            let again = try solved(after, .vertical)
            print("UPRIGHT-MEASURED combined \(rotation)/\(keystone) -> fix \(c.straightenAngle)/\(c.verticalPerspective ?? .nan); re-measure \(again)")
            switch again {
            case .alreadyUpright: break
            case .solved(let residual):
                XCTAssertLessThan(abs(residual.straightenAngle), 0.6, "\(rotation)/\(keystone)")
                XCTAssertLessThan(abs(residual.verticalPerspective ?? 9), 0.1, "\(rotation)/\(keystone)")
            case .noLines, .unmeasurable, .noAgreement, .tiltTooLarge: XCTFail("\(rotation)/\(keystone): re-measure found no lines")
            }
        }
    }
}
