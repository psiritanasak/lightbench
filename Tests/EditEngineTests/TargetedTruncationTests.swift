import XCTest
import CoreImage
@testable import PhotoApp

/// The Targeted adjustment tool samples at a stage's own INPUT through `ColorSampleTruncation` (`.beforePointCurve`,
/// `.beforeSelectiveColor`, `.beforeGrayMix`). Each case must return exactly what the untruncated pipeline would have handed that
/// stage, in the perceptual domain, and must not change the untruncated path.
final class TargetedTruncationTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    private func solid(r: Double, g: Double, b: Double) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func pixel(_ image: CIImage) -> (r: Float, g: Float, b: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linearSpace)
        return (buffer[0], buffer[1], buffer[2])
    }

    private func encoded(_ image: CIImage) -> CIImage {
        let filter = CIFilter.linearToSRGBToneCurve()
        filter.inputImage = image
        return filter.outputImage!
    }

    private func assertEqual(_ a: (r: Float, g: Float, b: Float), _ b: (r: Float, g: Float, b: Float),
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r, b.r, accuracy: 0.002, message, file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: 0.002, message, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: 0.002, message, file: file, line: line)
    }

    private let input = (r: 0.5, g: 0.2, b: 0.1)

    /// Before the point curve: every earlier stage (here Contrast and Whites) is in the sample, the point curve is not, and the
    /// truncated value equals the untruncated pipeline of the state WITHOUT any point curve.
    func testBeforePointCurveStopsAtTheCurveInput() {
        var state = EditState()
        state.contrast = 0.3
        state.whites = 0.2
        state.toneCurvePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.8), ToneCurvePoint(x: 1, y: 1)]
        var curveless = state
        curveless.toneCurvePoints = []
        let image = solid(r: input.r, g: input.g, b: input.b)

        let truncated = pixel(EditPipeline.apply(state, to: image, truncatingColorAt: .beforePointCurve))
        let expected = pixel(encoded(EditPipeline.apply(curveless, to: image)))
        assertEqual(truncated, expected, "sample must be the perceptual value the point curve receives")
        let withCurve = pixel(encoded(EditPipeline.apply(state, to: image)))
        XCTAssertGreaterThan(abs(withCurve.g - truncated.g), 0.01, "the curve must NOT be in the sample")
    }

    /// Before Selective Color: global Hue (earlier) is in, Selective Color is not.
    func testBeforeSelectiveColorStopsAtTheBandInput() {
        var state = EditState()
        state.hslHue = 0.2
        state.redSaturation = -1
        state.redHue = 1
        var without = state
        without.redSaturation = 0
        without.redHue = 0
        let image = solid(r: input.r, g: input.g, b: input.b)

        let truncated = pixel(EditPipeline.apply(state, to: image, truncatingColorAt: .beforeSelectiveColor))
        let expected = pixel(encoded(EditPipeline.apply(without, to: image)))
        assertEqual(truncated, expected, "sample must be the perceptual value Selective Color receives")
        let full = pixel(encoded(EditPipeline.apply(state, to: image)))
        XCTAssertGreaterThan(abs(full.r - truncated.r) + abs(full.g - truncated.g) + abs(full.b - truncated.b), 0.02)
    }

    /// Before B&W Mix: Vibrance (earlier) is in and the sample is still COLOUR (the desaturation has not run).
    func testBeforeGrayMixSamplesTheColourBeforeDesaturation() {
        var state = EditState()
        state.blackAndWhite = true
        state.vibrance = 0.5
        state.grayMixRed = 1
        var colourOnly = state
        colourOnly.blackAndWhite = false
        colourOnly.grayMixRed = 0
        let image = solid(r: input.r, g: input.g, b: input.b)

        let truncated = pixel(EditPipeline.apply(state, to: image, truncatingColorAt: .beforeGrayMix))
        let expected = pixel(encoded(EditPipeline.apply(colourOnly, to: image)))
        assertEqual(truncated, expected, "sample must be the colour the Mix kernel reads")
        XCTAssertGreaterThan(abs(truncated.r - truncated.b), 0.05, "still colour, not grey")
    }

    /// Truncation must not apply to a state where the stage's own control is inactive either: an all-identity state still
    /// returns the PERCEPTUAL image (the domain must not depend on unrelated sliders).
    func testIdentityStateStillReturnsPerceptualDomain() {
        let image = solid(r: input.r, g: input.g, b: input.b)
        for truncation: EditPipeline.ColorSampleTruncation in [.beforePointCurve, .beforeSelectiveColor, .beforeGrayMix] {
            let sample = pixel(EditPipeline.apply(EditState(), to: image, truncatingColorAt: truncation))
            assertEqual(sample, pixel(encoded(image)), "\(truncation)")
        }
    }

    /// A pinned untruncated render through the three stages that now have stop points (point curve, Selective Color, B&W Mix).
    /// The expected value was RECORDED from this build (0.6085025 on all three channels) with the new stops present but not
    /// requested: it is NOT a pre-change measurement, so it guards future drift of the nil path, not this change itself.
    func testUntruncatedRenderThroughTheNewStopStagesIsPinned() {
        var state = EditState()
        state.toneCurvePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.7), ToneCurvePoint(x: 1, y: 1)]
        state.redSaturation = 0.5
        state.blackAndWhite = true
        state.grayMixRed = 0.5
        let p = pixel(EditPipeline.apply(state, to: solid(r: input.r, g: input.g, b: input.b), truncatingColorAt: nil))
        XCTAssertEqual(p.r, 0.6085025, accuracy: 0.002)
        XCTAssertEqual(p.g, 0.6085025, accuracy: 0.002)
        XCTAssertEqual(p.b, 0.6085025, accuracy: 0.002)
    }
}
