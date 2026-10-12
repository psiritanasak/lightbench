import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// `.depthRange` mask rendering: a persisted nearness raster windowed by `DepthWindow.cikernel`, stretched over the unedited source and carried
/// through the photo's own geometry chain. Rasters are synthetic ramps so the expected weight at every byte is known exactly from `DepthRangeSelection`.
final class DepthRangeMaskPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    /// 0.2 linear gray; +2 EV adjusts a fully selected pixel to 0.8 and the blend is linear in the selection weight: 0.2 + 0.6 w.
    private func gray(width: Int = 512, height: Int = 8) -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func png2D(width: Int, height: Int, value: (Int, Int) -> UInt8) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = value(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A 256-wide raster whose column `x` holds nearness byte `x` (so the 512-px photo shows byte `x` in columns `2x` and `2x + 1`).
    private func rampPNG() throws -> Data { try png2D(width: 256, height: 4) { x, _ in UInt8(x) } }

    private func mask(_ png: Data?, far: Double = 0.3, near: Double = 0.6, feather: Double = 0, invert: Bool = false, ev: Double = 2) -> Mask {
        Mask(kind: .depthRange, exposureEV: ev, invertSelection: invert,
             depthRasterPNG: png, depthSource: DepthSourceTag.embedded, depthFarLimit: far, depthNearLimit: near, depthFeather: feather)
    }

    private func red(_ image: CIImage, x: Int, y: Int) -> Float {
        let e = image.extent
        var buffer = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: e.minX + CGFloat(x), y: e.minY + CGFloat(y), width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return buffer[0]
    }

    private func expected(byte: Int, window: DepthRangeSelection.Window) -> Float { 0.2 + 0.6 * DepthRangeSelection.weight(nearness: Float(byte) / 255, window: window) }

    // MARK: The GPU window equals the pure maths

    func testKernelMatchesTheReferenceWeightsAtManyBytes() throws {
        for (far, near, feather) in [(0.3, 0.6, 0.0), (0.3, 0.6, 0.5), (0.0, 0.4, 1.0), (0.5, 1.0, 0.1), (0.7, 0.7, 0.3)] {
            let out = EditPipeline.apply(EditState(masks: [mask(try rampPNG(), far: far, near: near, feather: feather)]), to: gray(width: 256))
            let window = DepthRangeSelection.window(farLimit: far, nearLimit: near, feather: feather)
            for byte in stride(from: 3, through: 252, by: 7) {
                // The photo is as wide as the raster (256), so photo column `byte` is exactly raster byte `byte`: no bilinear blending, the comparison is
                // exact up to half-float rounding.
                XCTAssertEqual(red(out, x: byte, y: 4), expected(byte: byte, window: window), accuracy: 0.005, "byte \(byte) window \(far)...\(near) feather \(feather)")
            }
        }
    }

    /// The exact boundary bytes of the 0.3...0.6 window (0.3 * 255 = 76.5, 0.6 * 255 = 153): byte 76 is too far, 77 is in; 153 is in, 154 is out. Covers the
    /// comparison and the half-float rounding at `n >= low` / `n <= high`.
    func testHardWindowBoundaryBytes() throws {
        let out = EditPipeline.apply(EditState(masks: [mask(try rampPNG(), far: 0.3, near: 0.6)]), to: gray(width: 256)) // 1:1 sampling, see above
        XCTAssertEqual(red(out, x: 76, y: 4), 0.2, accuracy: 0.005, "byte 76 (0.298) is below the window")
        XCTAssertEqual(red(out, x: 77, y: 4), 0.8, accuracy: 0.005, "byte 77 (0.302) is inside")
        XCTAssertEqual(red(out, x: 153, y: 4), 0.8, accuracy: 0.005, "byte 153 (0.600) is inside")
        XCTAssertEqual(red(out, x: 154, y: 4), 0.2, accuracy: 0.005, "byte 154 (0.604) is above the window")
    }

    func testHardWindowSelectsOnlyTheNearnessRange() throws {
        let out = EditPipeline.apply(EditState(masks: [mask(try rampPNG(), far: 0.3, near: 0.6)]), to: gray())
        XCTAssertEqual(red(out, x: 2 * 40, y: 4), 0.2, accuracy: 0.01, "nearness 0.16: too far")
        XCTAssertEqual(red(out, x: 2 * 100, y: 4), 0.8, accuracy: 0.01, "nearness 0.39: inside")
        XCTAssertEqual(red(out, x: 2 * 140, y: 4), 0.8, accuracy: 0.01, "nearness 0.55: inside")
        XCTAssertEqual(red(out, x: 2 * 220, y: 4), 0.2, accuracy: 0.01, "nearness 0.86: too near")
    }

    func testInvertSelectsTheComplement() throws {
        let out = EditPipeline.apply(EditState(masks: [mask(try rampPNG(), invert: true)]), to: gray())
        XCTAssertEqual(red(out, x: 2 * 40, y: 4), 0.8, accuracy: 0.01)
        XCTAssertEqual(red(out, x: 2 * 100, y: 4), 0.2, accuracy: 0.01)
    }

    /// Raster value 128 (nearness 0.502) inside a 0.4...0.6 window must select FULLY: a colour-managed decode would gamma-shift 128 to ~0.215 (outside).
    func testRasterBytesAreUnmanagedNearness() throws {
        let flat = try png2D(width: 8, height: 8) { _, _ in 128 }
        let out = EditPipeline.apply(EditState(masks: [mask(flat, far: 0.4, near: 0.6)]), to: gray())
        XCTAssertEqual(red(out, x: 256, y: 4), 0.8, accuracy: 0.01)
    }

    // MARK: No raster selects nothing

    func testNoRasterSelectsNothingEvenWhenInverted() throws {
        for invert in [false, true] {
            let out = EditPipeline.apply(EditState(masks: [mask(nil, invert: invert)]), to: gray())
            XCTAssertEqual(red(out, x: 100, y: 4), 0.2, accuracy: 0.005, "invert \(invert)")
        }
        let garbage = EditPipeline.apply(EditState(masks: [mask(Data([1, 2, 3]), invert: true)]), to: gray())
        XCTAssertEqual(red(garbage, x: 100, y: 4), 0.2, accuracy: 0.005, "an undecodable raster selects nothing too")
    }

    // MARK: Geometry, origin, orientation

    func testSelectionFollowsAHorizontalFlip() throws {
        var state = EditState(masks: [mask(try rampPNG(), far: 0.0, near: 0.3)]) // selects the FAR (left, low-byte) part
        let plain = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(plain, x: 20, y: 4), 0.8, accuracy: 0.01)
        XCTAssertEqual(red(plain, x: 480, y: 4), 0.2, accuracy: 0.01)
        state.flipHorizontal = true
        let flipped = EditPipeline.apply(state, to: gray())
        XCTAssertEqual(red(flipped, x: 20, y: 4), 0.2, accuracy: 0.01, "the selected region moved to the right with the photo")
        XCTAssertEqual(red(flipped, x: 480, y: 4), 0.8, accuracy: 0.01)
    }

    func testNonZeroSourceOriginStillAlignsTheSelection() throws {
        let shifted = gray().transformed(by: CGAffineTransform(translationX: 500, y: 300))
        let out = EditPipeline.apply(EditState(masks: [mask(try rampPNG(), far: 0.0, near: 0.3)]), to: shifted)
        XCTAssertEqual(red(out, x: 20, y: 4), 0.8, accuracy: 0.01)
        XCTAssertEqual(red(out, x: 480, y: 4), 0.2, accuracy: 0.01)
    }

    /// Raster row 0 is the TOP of the photo (CIImage y is up): a raster that is near at the top must brighten the top rows.
    func testRasterRowZeroIsTheTopOfThePhoto() throws {
        let vertical = try png2D(width: 8, height: 64) { _, y in y < 32 ? 255 : 0 } // near on top
        let out = EditPipeline.apply(EditState(masks: [mask(vertical, far: 0.5, near: 1)]), to: gray(width: 64, height: 64))
        XCTAssertEqual(red(out, x: 32, y: 56), 0.8, accuracy: 0.01, "CIImage y = 56 is near the TOP edge")
        XCTAssertEqual(red(out, x: 32, y: 8), 0.2, accuracy: 0.01, "y = 8 is near the bottom")
    }

    /// A fully-near raster with a window that includes nearness 1 must select the OUTERMOST pixels at full strength (the stretch must not fade the border).
    func testFullRasterSelectsTheOutermostPixels() throws {
        let all = try png2D(width: 16, height: 16) { _, _ in 255 }
        let out = EditPipeline.apply(EditState(masks: [mask(all, far: 0.5, near: 1)]), to: gray(width: 100, height: 100))
        for (x, y) in [(0, 50), (99, 50), (50, 0), (50, 99)] { XCTAssertEqual(red(out, x: x, y: y), 0.8, accuracy: 0.005, "edge (\(x), \(y))") }
    }

    /// "Show Selection" must show what the mask will EDIT: with Invert on, the preview is the complement (and matches what the pipeline adjusts).
    func testPreviewAppliesInvertSoTheTintShowsWhatWillBeEdited() throws {
        var m = mask(try rampPNG(), far: 0.0, near: 0.3) // selects the far (left) part
        let plain = EditState(masks: [m])
        let previewPlain = try XCTUnwrap(EditPipeline.depthMaskPreviewImage(plain, maskID: m.id, source: gray(width: 256)))
        XCTAssertEqual(red(previewPlain, x: 20, y: 4), 1, accuracy: 0.01)
        XCTAssertEqual(red(previewPlain, x: 240, y: 4), 0, accuracy: 0.01)
        m.invertSelection = true
        let inverted = EditState(masks: [m])
        let preview = try XCTUnwrap(EditPipeline.depthMaskPreviewImage(inverted, maskID: m.id, source: gray(width: 256)))
        XCTAssertEqual(red(preview, x: 20, y: 4), 0, accuracy: 0.01, "inverted: the far part is no longer selected")
        XCTAssertEqual(red(preview, x: 240, y: 4), 1, accuracy: 0.01)
        // And it agrees with the pixels the pipeline actually adjusts.
        let out = EditPipeline.apply(inverted, to: gray(width: 256))
        XCTAssertEqual(red(out, x: 20, y: 4), 0.2, accuracy: 0.01)
        XCTAssertEqual(red(out, x: 240, y: 4), 0.8, accuracy: 0.01)
    }

    func testMaskImageIsAbsentForNoRasterAndPreviewMatchesThePipelineSelection() throws {
        let m = mask(try rampPNG(), far: 0.0, near: 0.3)
        let state = EditState(masks: [m])
        let preview = try XCTUnwrap(EditPipeline.depthMaskPreviewImage(state, maskID: m.id, source: gray()))
        XCTAssertEqual(red(preview, x: 20, y: 4), 1, accuracy: 0.01, "weight 1 where selected (RGB == alpha == weight)")
        XCTAssertEqual(red(preview, x: 480, y: 4), 0, accuracy: 0.01)
        XCTAssertNil(EditPipeline.depthMaskPreviewImage(EditState(masks: [mask(nil)]), maskID: state.masks[0].id, source: gray()))
    }
}
