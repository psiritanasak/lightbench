import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// `.subject` mask rendering: a persisted grayscale raster, stretched over the unedited source and
/// carried through the photo's own geometry chain. Rasters here are synthetic (left half selected).
final class SubjectMaskPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf
    ])
    private let accuracy: Float = 0.01

    /// 0.2 linear gray; +2 EV selects to 0.8.
    private func gray(size: Int = 400, height: Int? = nil) -> CIImage {
        let color = CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: height ?? size))
    }

    /// 8-bit grayscale PNG, 64x64, `value(x)` per column (x = 0 is the LEFT edge).
    private func png(width: Int = 64, height: Int = 64, value: (Int) -> UInt8) throws -> Data {
        try png2D(width: width, height: height) { x, _ in value(x) }
    }

    /// `value(x, y)`: y = 0 is the TOP row (raster convention).
    private func png2D(width: Int = 64, height: Int = 64, value: (Int, Int) -> UInt8) throws -> Data {
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

    private func leftHalfPNG() throws -> Data { try png { $0 < 32 ? 255 : 0 } }

    private func subjectMask(_ png: Data?, exposureEV: Double = 2, invert: Bool = false) -> Mask {
        Mask(kind: .subject, exposureEV: exposureEV, subjectMaskPNG: png, subjectMaskRevision: 1, invertSelection: invert)
    }

    private func red(_ image: CIImage, atFractionX fx: Double, y fy: Double) -> Float {
        let e = image.extent
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: e.minX + (e.width * fx).rounded(.down), y: e.minY + (e.height * fy).rounded(.down), width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace)
        return buffer[0]
    }

    private let unedited: Float = 0.2
    private let boosted: Float = 0.8

    // MARK: Selection follows the raster

    func testOnlyTheRasterSelectedHalfIsAdjusted() throws {
        let out = EditPipeline.apply(EditState(masks: [subjectMask(try leftHalfPNG())]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), unedited, accuracy: accuracy)
    }

    func testInvertSelectsTheComplement() throws {
        let out = EditPipeline.apply(EditState(masks: [subjectMask(try leftHalfPNG(), invert: true)]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), unedited, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), boosted, accuracy: accuracy)
    }

    /// Raster value 128 must blend at ~0.5 coverage (0.2 + 0.502 * 0.6 = 0.501): a color-managed decode
    /// would gamma-shift the coverage away from that.
    func testRasterValuesAreUnmanagedCoverage() throws {
        let half = try png { _ in 128 }
        let out = EditPipeline.apply(EditState(masks: [subjectMask(half)]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.5), 0.501, accuracy: 0.01)
    }

    // MARK: Edges, origin, orientation

    /// A fully selected raster must select the OUTERMOST pixels at full strength (resampling must not
    /// fade the border). Behavior guard: a mutation moving the clamp after the transforms did NOT fail
    /// it (see the comment in `subjectMaskImages`).
    func testFullRasterSelectsTheOutermostPixelsAtFullStrength() throws {
        let out = EditPipeline.apply(EditState(masks: [subjectMask(try png { _ in 255 })]), to: gray())
        for (fx, fy) in [(0.0, 0.5), (0.9999, 0.5), (0.5, 0.0), (0.5, 0.9999)] {
            XCTAssertEqual(red(out, atFractionX: fx, y: fy), boosted, accuracy: 0.005, "edge (\(fx), \(fy))")
        }
    }

    func testInvertedFullRasterLeavesTheOutermostPixelsUnselected() throws {
        let out = EditPipeline.apply(EditState(masks: [subjectMask(try png { _ in 255 }, invert: true)]), to: gray())
        for (fx, fy) in [(0.0, 0.5), (0.9999, 0.5), (0.5, 0.0), (0.5, 0.9999)] {
            XCTAssertEqual(red(out, atFractionX: fx, y: fy), unedited, accuracy: 0.005, "edge (\(fx), \(fy))")
        }
    }

    func testNonZeroSourceOriginStillAlignsTheSelection() throws {
        let shifted = gray().transformed(by: CGAffineTransform(translationX: 500, y: 300))
        let out = EditPipeline.apply(EditState(masks: [subjectMask(try leftHalfPNG())]), to: shifted)
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), unedited, accuracy: accuracy)
    }

    /// Raster row 0 is the TOP of the photo (CIImage y is up): a top-half raster must brighten the top.
    func testTopHalfRasterSelectsTheTopOfThePhoto() throws {
        let topHalf = try png2D { _, y in y < 32 ? 255 : 0 }
        let out = EditPipeline.apply(EditState(masks: [subjectMask(topHalf)]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.9), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.1), unedited, accuracy: accuracy)
    }

    func testVerticalFlipMovesTheSelectionToTheBottom() throws {
        let topHalf = try png2D { _, y in y < 32 ? 255 : 0 }
        var state = EditState(masks: [subjectMask(topHalf)])
        state.flipVertical = true
        let out = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.9), unedited, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.1), boosted, accuracy: accuracy)
    }

    // MARK: Follows geometry

    func testHorizontalFlipMovesTheSelectionWithThePhoto() throws {
        var state = EditState(masks: [subjectMask(try leftHalfPNG())])
        state.flipHorizontal = true
        let out = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), unedited, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), boosted, accuracy: accuracy)
    }

    /// Crop the MIDDLE half: the visible frame is source x 100..300, so the raster's left-half edge
    /// (source x = 200) must land at the visible frame's centre. NOTE (measured by mutation): crop
    /// keeps the source coordinate origin, so this passes even if the mask skipped geometry — it guards
    /// crop's behavior, it does not prove the geometry chain runs (the flip/scale/straighten tests do).
    func testCropMovesTheSelectionEdgeWithThePhoto() throws {
        var state = EditState(masks: [subjectMask(try leftHalfPNG())])
        state.cropInsetLeft = 0.25
        state.cropInsetRight = 0.25
        let out = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(out.extent.width, 200, accuracy: 1)
        XCTAssertEqual(red(out, atFractionX: 0.2, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.8, y: 0.5), unedited, accuracy: accuracy)
    }

    func testCropExcludingTheSubjectLeavesTheVisibleFrameUntouched() throws {
        // Raster selects the left 40% (x < 160 of 400); the crop keeps x >= 180.
        var state = EditState(masks: [subjectMask(try png { $0 < 26 ? 255 : 0 })])
        state.cropInsetLeft = 0.45
        let out = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), unedited, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), unedited, accuracy: accuracy)
    }

    /// transformScale 1.5 shows the central 2/3 of the photo (source x 66..333). The raster selects
    /// source x < 100: fx 0.05 -> x 79 (selected), fx 0.2 -> x 119 (NOT). A mask that skipped geometry
    /// would still select at fx 0.2 (x 80).
    func testTransformScaleMovesTheSelectionWithThePhoto() throws {
        var state = EditState(masks: [subjectMask(try png { $0 < 16 ? 255 : 0 })])
        state.transformScale = 1.5
        let out = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.05, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.2, y: 0.5), unedited, accuracy: accuracy)
    }

    func testSelectionIsProxyScaleInvariant() throws {
        let state = EditState(masks: [subjectMask(try leftHalfPNG())])
        // Deliberately NOT exactly the same aspect (a proxy's rounded dimensions): 401x299 vs 100x75.
        let big = EditPipeline.apply(state, to: gray(size: 401, height: 299))
        let small = EditPipeline.apply(state, to: gray(size: 100, height: 75))
        for fx in [0.1, 0.4, 0.6, 0.9] {
            XCTAssertEqual(red(big, atFractionX: fx, y: 0.5), red(small, atFractionX: fx, y: 0.5), accuracy: accuracy, "fx \(fx)")
        }
    }

    /// Inversion of a fully selected raster, under a straighten (geometry chain active) — interior only;
    /// the revealed wedge is covered by `testInvertSelectsTheTransparentWedgeStraightenReveals`.
    func testInvertOfAFullRasterSelectsNothingInsideTheFrameUnderStraighten() throws {
        var plain = EditState(masks: [subjectMask(try png { _ in 255 })])
        plain.straightenAngle = 20
        var inverted = plain
        inverted.masks[0].invertSelection = true
        let a = EditPipeline.apply(plain, to: gray())
        let b = EditPipeline.apply(inverted, to: gray())
        // Whole raster selected: non-inverted boosts the interior, inverted leaves it alone.
        XCTAssertEqual(red(a, atFractionX: 0.5, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(b, atFractionX: 0.5, y: 0.5), unedited, accuracy: accuracy)
    }

    // The wedge a straighten reveals is transparent in the photo, so the selection there is not
    // observable in rendered output (a gain on transparent is transparent) — inversion's wedge
    // semantics rest on `invertedMaskImage`'s own tests plus the interior check above.

    // MARK: No-ops and failure

    func testZeroAdjustmentSubjectMaskIsByteIdenticalToNoMask() throws {
        let with = EditPipeline.apply(EditState(masks: [subjectMask(try leftHalfPNG(), exposureEV: 0)]), to: gray())
        let without = EditPipeline.apply(EditState(), to: gray())
        XCTAssertEqual(red(with, atFractionX: 0.1, y: 0.5), red(without, atFractionX: 0.1, y: 0.5))
    }

    func testMissingOrUndecodableRasterSelectsNothingEvenWhenInverted() throws {
        for invert in [false, true] {
            for bad in [nil, Data([1, 2, 3, 4, 5])] as [Data?] {
                let out = EditPipeline.apply(EditState(masks: [subjectMask(bad, invert: invert)]), to: gray())
                XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.5), unedited, accuracy: accuracy, "invert \(invert), data \(String(describing: bad))")
            }
        }
    }

    // MARK: Combine

    /// A zero-adjustment subject mask is a legal combine operand: Exposure everywhere EXCEPT the subject.
    func testZeroAdjustmentSubjectMaskWorksAsASubtractOperand() throws {
        let operand = subjectMask(try leftHalfPNG(), exposureEV: 0)
        var everywhere = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2, radiusY: 2, rotationDegrees: 0, feather: 0.5, exposureEV: 2)
        everywhere.combineMode = .subtract
        everywhere.combineWithMaskID = operand.id
        let out = EditPipeline.apply(EditState(masks: [operand, everywhere]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.1, y: 0.5), unedited, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.9, y: 0.5), boosted, accuracy: accuracy)
    }

    func testSubjectMaskIntersectedWithARadialMask() throws {
        var subject = subjectMask(try png { _ in 255 })
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.15, radiusY: 0.15, rotationDegrees: 0, feather: 0.1)
        subject.combineMode = .intersect
        subject.combineWithMaskID = operand.id
        let out = EditPipeline.apply(EditState(masks: [subject, operand]), to: gray())
        XCTAssertEqual(red(out, atFractionX: 0.5, y: 0.5), boosted, accuracy: accuracy)
        XCTAssertEqual(red(out, atFractionX: 0.05, y: 0.05), unedited, accuracy: accuracy)
    }
}
