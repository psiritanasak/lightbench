import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// Click-on-image subject picking: which stored subject instance lies under a click on the DISPLAYED photo.
/// Fixture: instance 0 = the LEFT half of the source; instance 1 = the TOP-RIGHT quadrant; the bottom-right quadrant
/// belongs to no subject. Every geometry case below is a whole-frame render (never a 1x1 image).
final class SubjectInstancePickerTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func gray(size: Int = 400) -> CIImage {
        let color = CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: linear)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// `value(x, y)`: y = 0 is the TOP row.
    private func png(width: Int = 64, height: Int = 64, value: (Int, Int) -> UInt8) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = value(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func state(enabled: [Bool] = [], configure: (inout EditState) -> Void = { _ in }) throws -> (EditState, UUID) {
        var mask = Mask()
        mask.kind = .subject
        mask.subjectInstancePNGs = [
            try png { x, _ in x < 32 ? 255 : 0 },
            try png { x, y in x >= 32 && y < 32 ? 255 : 0 },
        ]
        mask.subjectInstanceEnabled = enabled
        mask.subjectMaskRevision = 1
        var s = EditState()
        s.masks = [mask]
        configure(&s)
        return (s, mask.id)
    }

    private func hit(_ s: EditState, _ id: UUID, _ x: Double, _ y: Double) -> Int? {
        SubjectInstancePicker.hit(state: s, maskID: id, source: gray(), normalizedX: x, normalizedY: y)
    }

    // MARK: - Plain frame

    func testClicksLandOnTheRightSubjectOrNone() throws {
        let (s, id) = try state()
        XCTAssertEqual(hit(s, id, 0.25, 0.5), 0)
        XCTAssertEqual(hit(s, id, 0.25, 0.9), 0)
        XCTAssertEqual(hit(s, id, 0.75, 0.25), 1, "top-right quadrant (SwiftUI y is DOWN, so 0.25 is the upper half)")
        XCTAssertNil(hit(s, id, 0.75, 0.75), "bottom-right belongs to no subject")
    }

    func testDisabledInstancesAreStillHitSoTheyCanBeTurnedBackOn() throws {
        let (s, id) = try state(enabled: [false, true])
        XCTAssertEqual(hit(s, id, 0.25, 0.5), 0)
    }

    func testOutOfRangeNonFiniteOrUnknownMaskIsNil() throws {
        let (s, id) = try state()
        XCTAssertNil(hit(s, id, -0.1, 0.5))
        XCTAssertNil(hit(s, id, 0.5, 1.2))
        XCTAssertNil(hit(s, id, .nan, 0.5))
        XCTAssertNil(hit(s, UUID(), 0.25, 0.5))
    }

    // MARK: - Geometry: the click is in the DISPLAYED frame

    func testHorizontalFlipMovesTheSubjectsAndTheClickFollows() throws {
        let (s, id) = try state { $0.flipHorizontal = true }
        XCTAssertEqual(hit(s, id, 0.75, 0.5), 0, "the left subject is now on the right")
        XCTAssertEqual(hit(s, id, 0.25, 0.25), 1, "the top-right subject is now top-LEFT")
        XCTAssertNil(hit(s, id, 0.25, 0.75))
    }

    func testVerticalFlipMovesTheSubjectsAndTheClickFollows() throws {
        let (s, id) = try state { $0.flipVertical = true }
        XCTAssertEqual(hit(s, id, 0.75, 0.75), 1, "the top-right subject is now bottom-right")
        XCTAssertNil(hit(s, id, 0.75, 0.25))
        XCTAssertEqual(hit(s, id, 0.25, 0.1), 0)
    }

    func testCropRemapsTheClickToTheCroppedFrame() throws {
        // Crop 40% off the LEFT (a 0.5 inset is clamped to 0.45 by the pipeline, which a probe showed: extent started
        // at 180 of 400). Displayed x maps to source x = 0.4 + 0.6 * x.
        let (s, id) = try state { $0.cropInsetLeft = 0.4 }
        XCTAssertEqual(hit(s, id, 0.05, 0.5), 0, "displayed 0.05 is source 0.43, still inside the left subject")
        XCTAssertEqual(hit(s, id, 0.4, 0.25), 1, "displayed (0.4, 0.25) is source (0.64, 0.25)")
        XCTAssertNil(hit(s, id, 0.4, 0.75))
        XCTAssertNil(hit(s, id, 0.3, 0.75), "displayed (0.3, 0.75) is source (0.58, 0.75): bottom-right, no subject (and not the left one)")
    }

    /// Values read from a probe grid (20 degrees): the same displayed points hit different things than at 0 degrees.
    func testStraightenRemapsTheClick() throws {
        let (flat, flatID) = try state()
        let (tilted, tiltedID) = try state { $0.straightenAngle = 20 }
        // Top-left corner: subject 0 unrotated, but the rotation has swung transparent margin (no subject) there.
        XCTAssertEqual(hit(flat, flatID, 0.05, 0.05), 0)
        XCTAssertNil(hit(tilted, tiltedID, 0.05, 0.05))
        // Right edge, mid-height: the top-right subject unrotated, margin once rotated.
        XCTAssertEqual(hit(flat, flatID, 0.85, 0.45), 1)
        XCTAssertNil(hit(tilted, tiltedID, 0.85, 0.45))
        // Well inside the left subject it still hits subject 0 after rotating.
        XCTAssertEqual(hit(tilted, tiltedID, 0.15, 0.25), 0)
        XCTAssertEqual(hit(tilted, tiltedID, 0.35, 0.15), 0)
    }

    func testScaleOutShrinksTheSubjectsIntoTheMiddleOfTheFrame() throws {
        let (s, id) = try state { $0.transformScale = 0.5 }
        // Displayed x maps to source x = (x - 0.25) / 0.5 (same for y), so the margin around the shrunk photo is empty.
        XCTAssertEqual(hit(s, id, 0.4, 0.5), 0, "source (0.3, 0.5) is inside the left subject")
        XCTAssertEqual(hit(s, id, 0.6, 0.4), 1, "source (0.7, 0.3) is inside the top-right subject")
        XCTAssertNil(hit(s, id, 0.1, 0.5), "the transparent margin is no subject")
    }

    func testAClickOnTheVeryLastRowAndColumnStillHits() throws {
        let (s, id) = try state()
        XCTAssertEqual(hit(s, id, 0.0, 1.0), 0, "bottom-left corner pixel")
        XCTAssertEqual(hit(s, id, 1.0, 0.0), 1, "top-right corner pixel")
    }

    // MARK: - Pure selection

    func testBestPicksHighestCoverageAtOrAboveTheThresholdAndLowestIndexOnATie() {
        XCTAssertNil(SubjectInstancePicker.best(of: []))
        XCTAssertNil(SubjectInstancePicker.best(of: [0.49, 0.1]))
        XCTAssertEqual(SubjectInstancePicker.best(of: [0.5, 0.2]), 0)
        XCTAssertEqual(SubjectInstancePicker.best(of: [0.6, 0.9]), 1)
        XCTAssertEqual(SubjectInstancePicker.best(of: [0.9, 0.9]), 0)
    }
}
