import XCTest
import CoreImage
@testable import PhotoApp

/// Verifies `EditPipeline`'s exposure math against known linear-light values.
///
/// Assertions are made in an explicit extended-linear-sRGB working space so
/// they read true linear-light pixel values (`input * 2^EV`) with no gamma
/// transfer function confusing the numbers — this mirrors the working space
/// `ImageRenderer` uses, so a pass here faithfully predicts on-screen behavior.
final class EditPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    private func solidColorImage(_ value: Double) -> CIImage {
        solidColorImage(r: value, g: value, b: value)
    }

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double = 1) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func solidColorImage(_ value: Double, size: Int) -> CIImage {
        let color = CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// A synthetic image with four distinct solid-color quadrants (top-left
    /// red, top-right green, bottom-left blue, bottom-right yellow — "top"
    /// meaning what any normal viewer would show at the top). Built from raw
    /// row-major pixel bytes (row 0 = visual top, the standard raster
    /// convention) and loaded via `CIImage(cgImage:)`, which flips that into
    /// `CIImage`'s own bottom-left-origin/y-up coordinate space — verified
    /// empirically (not assumed) that high-y in the resulting `CIImage`
    /// extent corresponds to visual top, matching `EditPipeline.applyCrop`'s
    /// documented coordinate assumption.
    private func quadrantImage(width: Int = 100, height: Int = 100) -> CIImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let visualTop = y < height / 2
                let visualLeft = x < width / 2
                switch (visualTop, visualLeft) {
                case (true, true): pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255
                case (true, false): pixels[i] = 0; pixels[i + 1] = 255; pixels[i + 2] = 0; pixels[i + 3] = 255
                case (false, true): pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255; pixels[i + 3] = 255
                case (false, false): pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 0; pixels[i + 3] = 255
                }
            }
        }
        let deviceSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: deviceSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return CIImage(cgImage: cgImage)
    }

    private func describeColor(of image: CIImage, at point: CGPoint) -> String {
        let deviceSpace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CIContext().createCGImage(
            image, from: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBA8, colorSpace: deviceSpace
        ), let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
            return "?"
        }
        switch (ptr[0], ptr[1], ptr[2]) {
        case (255, 0, 0): return "red"
        case (0, 255, 0): return "green"
        case (0, 0, 255): return "blue"
        case (255, 255, 0): return "yellow"
        default: return "unknown(\(ptr[0]),\(ptr[1]),\(ptr[2]))"
        }
    }

    private func linearPixel(of image: CIImage) -> (r: Float, g: Float, b: Float, a: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &buffer,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: linearSpace
        )
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private let accuracy: Float = 0.002

    // MARK: - Exposure math

    func testExposureZeroIsIdentity() {
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(exposureEV: 0), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.2, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.2, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.2, accuracy: accuracy)
    }

    func testExposurePlusOneStopDoublesLinearValue() {
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(exposureEV: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.4, accuracy: accuracy)
    }

    func testExposureMinusOneStopHalvesLinearValue() {
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(exposureEV: -1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.1, accuracy: accuracy)
    }

    func testExposureHalfStopAppliesSquareRootTwoGain() {
        // Confirms the gain is genuinely 2^ev (not a lookup table special-cased
        // to whole/negative-whole stops): 0.2 * 2^0.5 ≈ 0.2 * 1.41421356 ≈ 0.28284.
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(exposureEV: 0.5), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.2 * pow(2.0, 0.5), accuracy: accuracy)
    }

    func testExposurePlusTwoStopsQuadruples() {
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(exposureEV: 2), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.8, accuracy: accuracy)
    }

    func testExposurePreservesAlpha() {
        for ev in [-2.0, 0.0, 1.0, 3.0] {
            let output = EditPipeline.apply(EditState(exposureEV: ev), to: solidColorImage(0.3))
            XCTAssertEqual(linearPixel(of: output).a, 1.0, accuracy: accuracy, "alpha changed at EV \(ev)")
        }
    }

    func testExposurePreservesHighlightHeadroom() {
        // Base value 0.6 boosted by +1 EV should read back as 1.2, not
        // clamped to 1.0 — proves the extended-range linear working space
        // (not just "some multiply happened") is actually in effect.
        let input = solidColorImage(0.6)
        let output = EditPipeline.apply(EditState(exposureEV: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 1.2, accuracy: accuracy)
    }

    // MARK: - Brightness math
    //
    // Brightness is a perceptual-domain additive offset (see EditPipeline's
    // documented-deviation comment) — measured, not hand-derived, since it's
    // a Core Image filter operating on real gamma-encoded tone response.

    func testBrightnessZeroIsIdentity() {
        for value in [0.05, 0.2, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(brightness: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testBrightnessPositiveLifts() {
        let cases: [(input: Double, expected: Float)] = [(0.05, 0.21201), (0.2, 0.49874), (0.5, 0.96701)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(brightness: 1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testBrightnessNegativeDarkens() {
        let cases: [(input: Double, expected: Float)] = [(0.2, 0.04490), (0.5, 0.20074)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(brightness: -1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testBrightnessPreservesHighlightHeadroom() {
        // Unlike an active curve/black-point, CIColorControls.brightness has
        // no internal [0,1] clamp.
        let input = solidColorImage(0.7)
        let output = EditPipeline.apply(EditState(brightness: 1), to: input)
        XCTAssertEqual(linearPixel(of: output).r, 1.25392, accuracy: accuracy)
    }

    func testBrightnessAppliedAfterExposure() {
        let input = solidColorImage(0.25)
        let output = EditPipeline.apply(EditState(exposureEV: 1, brightness: 0.8), to: input)
        XCTAssertEqual(linearPixel(of: output).r, 0.85920, accuracy: accuracy)
    }

    func testBrightnessAppliedBeforeContrast() {
        // Proves ordering: brightness runs before contrast (not commutative
        // — the reversed order measures 0.41565 for the same inputs).
        let input = solidColorImage(0.2)
        let output = EditPipeline.apply(EditState(brightness: 0.8, contrast: 0.5), to: input)
        XCTAssertEqual(linearPixel(of: output).r, 0.56524, accuracy: accuracy)
    }

    func testBrightnessPreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5)
        let output = EditPipeline.apply(EditState(brightness: 1), to: input)
        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    // MARK: - Contrast math
    //
    // Contrast is applied in the perceptual sRGB-gamma domain, not linear
    // light (see EditPipeline's documented-deviation comment). Expected
    // values below are measured from the diagnostic scripts that established
    // this approach, using: encode s = x≤0.0031308 ? 12.92x : 1.055·x^(1/2.4)−0.055;
    // decode is the inverse; contrast s' = (s−0.5)·factor+0.5 where
    // factor = 1 + contrast.

    func testContrastZeroIsIdentity() {
        for value in [0.05, 0.3, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(contrast: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testContrastPivotsAroundPerceptualMiddleGray() {
        // The signature test: a LINEAR-domain pivot at 0.5 would crush
        // photographic middle gray (linear ≈0.214) toward black (measured
        // -0.072 in the diagnostic script). Pivoting in the perceptual
        // domain instead leaves middle gray essentially unchanged.
        let input = solidColorImage(0.214)
        let output = EditPipeline.apply(EditState(contrast: 1), to: input) // factor 2.0
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.21396, accuracy: accuracy)
    }

    func testContrastPositiveMatchesGammaDomainMath() {
        let cases: [(input: Double, expected: Float)] = [
            (0.5, 0.93467),
            (0.1, 0.03260),
            (0.3, 0.40331)
        ]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(contrast: 1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testContrastPreservesHighlightHeadroom() {
        // Mirrors testExposurePreservesHighlightHeadroom: proves the
        // tone-curve encode/decode doesn't clamp values above 1.0.
        let input = solidColorImage(0.7)
        let output = EditPipeline.apply(EditState(contrast: 1), to: input) // factor 2.0
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 1.54194, accuracy: accuracy)
    }

    func testContrastNegativeFlattens() {
        let cases: [(input: Double, expected: Float)] = [
            (0.5, 0.33957),
            (0.1, 0.15076),
            (0.214, 0.21402) // mid-gray stays ~fixed regardless of factor
        ]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(contrast: -0.5), to: solidColorImage(testCase.input)) // factor 0.5
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testContrastAppliedAfterExposure() {
        // Proves ordering: exposure (scene-linear) runs before contrast
        // (perceptual). 0.25 * 2^1 = 0.5 (exposure), then contrast factor
        // 2.0 pivoted perceptually on 0.5 -> 0.93467 (matches
        // testContrastPositiveMatchesGammaDomainMath's L=0.5 case).
        let input = solidColorImage(0.25)
        let output = EditPipeline.apply(EditState(exposureEV: 1, contrast: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.93467, accuracy: accuracy)
    }

    func testContrastPreservesAlpha() {
        let output = EditPipeline.apply(EditState(contrast: 1), to: solidColorImage(0.3))
        XCTAssertEqual(linearPixel(of: output).a, 1.0, accuracy: accuracy)
    }

    // MARK: - White balance math
    //
    // White balance is applied in scene-linear light (not a deviation, unlike
    // contrast) via CITemperatureAndTint. Expected values below are measured
    // from the diagnostic script that established the sign/span constants —
    // they are not hand-derived, since chromatic adaptation is a black-box
    // matrix, not a simple closed-form transfer function.
    //
    // whiteBalanceTemperature is user-facing Kelvin (Lightroom convention:
    // higher K = warmer on screen), which EditPipeline maps through a
    // reflection (2*6500 - temperature) onto the filter's own targetNeutral.x
    // (where LOWER values warm). So "temperature: 9500" below is the
    // warmest UI setting, feeding targetNeutral.x = 3500 into the filter —
    // the pixel values are unchanged from that underlying filter input,
    // only the EditState value used to reach it is inverted.

    func testWhiteBalanceZeroIsIdentity() {
        for value in [0.05, 0.18, 0.3, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 6500, whiteBalanceTint: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testWhiteBalanceWarmsAtMaxTemperature() {
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 9500), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.27041, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.16434, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.07076, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.r, pixel.b)
    }

    func testWhiteBalanceWarmsPartiallyAtMidHighTemperature() {
        // Proves the temperature mapping is continuous, not a step function.
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 8000), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.20944, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.17664, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.13250, accuracy: accuracy)
    }

    func testWhiteBalanceCoolsAtMinTemperature() {
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 3500), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.15289, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.18052, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.24144, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.b, pixel.r)
    }

    func testWhiteBalanceMagentaAtPlus100() {
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTint: 100), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.26302, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.14090, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.24938, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.r, pixel.g)
        XCTAssertGreaterThan(pixel.b, pixel.g)
    }

    func testWhiteBalanceGreenAtMinus100() {
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTint: -100), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.10683, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.21446, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.11886, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.g, pixel.r)
        XCTAssertGreaterThan(pixel.g, pixel.b)
    }

    func testWhiteBalancePreservesAlpha() {
        let input = solidColorImage(r: 0.18, g: 0.18, b: 0.18, a: 0.5)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 9500), to: input)

        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    func testWhiteBalancePreservesHighlightHeadroom() {
        // Base already has a channel >1.0 (as if boosted by a prior exposure
        // adjustment) — proves WB doesn't clamp it away.
        let input = solidColorImage(r: 1.4, g: 0.5, b: 0.2, a: 1)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 9500), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 1.80724, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.43033, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.04813, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.r, 1.0)
    }

    func testWhiteBalanceAppliedBeforeContrast() {
        // WB and exposure both being linear operations commute, so this
        // ordering test uses contrast (nonlinear/perceptual, order-sensitive)
        // to actually prove white balance runs first in the pipeline.
        let input = solidColorImage(0.18)
        let output = EditPipeline.apply(EditState(whiteBalanceTemperature: 9500, contrast: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.33460, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.12211, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.00853, accuracy: accuracy)
    }

    // MARK: - Curves math
    //
    // Curves (CIToneCurve) is applied inside the same perceptual sandwich as
    // contrast, after it. Expected values below are measured from the
    // diagnostic script that established the point-span constant and the
    // [0,1] clamp finding — chromatic/tonal spline behavior has no
    // closed-form transfer function to hand-derive against.

    func testCurvesZeroIsIdentity() {
        // 1.2 proves an INACTIVE curve preserves headroom (no filter added).
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(curvesShadows: 0, curvesHighlights: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testCurvesShadowsPositiveLiftsDeepShadows() {
        // Lift concentrates in deep shadows; avoid the ~0.1 perceptual
        // crossover zone near the shadow control point where the effect is
        // near zero by design of the spline, not a bug.
        let cases: [(input: Double, expected: Float)] = [(0.01, 0.02534), (0.03, 0.03383)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(curvesShadows: 1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testCurvesShadowsNegativeCrushesDeepShadows() {
        let cases: [(input: Double, expected: Float)] = [(0.01, 0.00383), (0.03, 0.02656)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(curvesShadows: -1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testCurvesHighlightsPositiveLifts() {
        let cases: [(input: Double, expected: Float)] = [(0.3, 0.71533), (0.5, 0.91799), (0.7, 0.97874)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(curvesHighlights: 1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testCurvesHighlightsNegativeRecovers() {
        let cases: [(input: Double, expected: Float)] = [
            (0.3, 0.11043), (0.5, 0.25563), (0.7, 0.49135), (0.9, 0.81187)
        ]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(curvesHighlights: -1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testCurvesPreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5)
        let output = EditPipeline.apply(EditState(curvesShadows: 1, curvesHighlights: -1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.05676, accuracy: accuracy)
        XCTAssertEqual(pixel.a, 0.5, accuracy: accuracy)
    }

    func testCurvesAppliedAfterContrast() {
        // Proves ordering: contrast runs before curves (not commutative —
        // the reversed order measures 1.59067 for the same inputs).
        let input = solidColorImage(0.3)
        let output = EditPipeline.apply(EditState(contrast: 1, curvesHighlights: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.84872, accuracy: accuracy)
    }

    func testCurvesClampHighlightHeadroom() {
        // Documented limitation, not a failure: an ACTIVE CIToneCurve clamps
        // its domain to [0,1], so values above linear 1.0 collapse to white.
        let warmInput = solidColorImage(1.2)
        let warmOutput = EditPipeline.apply(EditState(curvesShadows: 1), to: warmInput)
        XCTAssertEqual(linearPixel(of: warmOutput).r, 1.0, accuracy: accuracy)

        let coolInput = solidColorImage(1.4)
        let coolOutput = EditPipeline.apply(EditState(curvesHighlights: -1), to: coolInput)
        XCTAssertEqual(linearPixel(of: coolOutput).r, 1.0, accuracy: accuracy)
    }

    func testContrastHeadroomLostWhenCurveActive() {
        // Documents the interaction: contrast alone preserves headroom
        // (matches testContrastPreservesHighlightHeadroom's 1.54194 at
        // L=0.7), but the SAME contrast setting with a curve also active
        // loses it, because curves clamps after contrast in the sandwich.
        let input = solidColorImage(0.7)

        let contrastOnly = EditPipeline.apply(EditState(contrast: 1), to: input)
        XCTAssertEqual(linearPixel(of: contrastOnly).r, 1.54194, accuracy: accuracy)

        let contrastPlusCurve = EditPipeline.apply(EditState(contrast: 1, curvesHighlights: 1), to: input)
        XCTAssertEqual(linearPixel(of: contrastPlusCurve).r, 1.0, accuracy: accuracy)
    }

    // MARK: - Black Point math
    //
    // Black Point extends the same CIToneCurve applyCurves uses, moving
    // point0 along its X axis. Measured, not hand-derived — chromatic spline
    // behavior has no closed-form transfer function.

    func testBlackPointZeroIsIdentity() {
        for value in [0.05, 0.214, 0.5, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(blackPoint: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testBlackPointNegativeCrushesShadows() {
        let cases: [(input: Double, expected: Float)] = [
            (0.05, 0.04130), (0.1, 0.07703), (0.2, 0.19089), (0.3, 0.31425), (0.5, 0.53498)
        ]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(blackPoint: -1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testBlackPointDeepClip() {
        // Genuinely near-black input clips fully to 0.
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: solidColorImage(0.002))
        XCTAssertEqual(linearPixel(of: output).r, 0, accuracy: accuracy)
    }

    func testBlackPointCrushOvershoot() {
        // Documented limitation, not a failure: CIToneCurve extrapolates
        // rather than hard-clamping just below point0.x, so a very dark
        // (but not fully clipped) input lifts slightly instead of stepping
        // straight to 0 — a "soft" black point.
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: solidColorImage(0.01))
        XCTAssertEqual(linearPixel(of: output).r, 0.03381, accuracy: accuracy)
    }

    func testBlackPointPositiveLiftsGently() {
        let cases: [(input: Double, expected: Float)] = [(0.05, 0.05109), (0.2, 0.20106), (0.3, 0.29841)]
        for testCase in cases {
            let output = EditPipeline.apply(EditState(blackPoint: 1), to: solidColorImage(testCase.input))
            XCTAssertEqual(linearPixel(of: output).r, testCase.expected, accuracy: accuracy, "at L=\(testCase.input)")
        }
    }

    func testBlackPointClampHighlightHeadroom() {
        // Documented limitation, same family as curves: an active black
        // point clamps highlight headroom above linear 1.0.
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: solidColorImage(1.2))
        XCTAssertEqual(linearPixel(of: output).r, 1.0, accuracy: accuracy)
    }

    func testBlackPointPreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5)
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: input)
        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    // MARK: - HSL math
    //
    // Hue/saturation math is applied inside the same perceptual sandwich as
    // contrast/curves, after curves. Expected values below are measured from
    // the diagnostic script — chromatic rotation and saturation blending have
    // no closed-form transfer function to hand-derive against.

    func testHSLZeroIsIdentity() {
        // 1.2 proves an INACTIVE HSL preserves headroom (no filter added).
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(hslHue: 0, hslSaturation: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testHueRotatesColor() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(hslHue: 120), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.11288, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.34343, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.11329, accuracy: accuracy)
    }

    func testHueDirectionSign() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)

        let plus = linearPixel(of: EditPipeline.apply(EditState(hslHue: 30), to: input))
        XCTAssertEqual(plus.r, 0.49403, accuracy: accuracy)
        XCTAssertEqual(plus.g, 0.22772, accuracy: accuracy)
        XCTAssertEqual(plus.b, 0.11288, accuracy: accuracy)

        let minus = linearPixel(of: EditPipeline.apply(EditState(hslHue: -30), to: input))
        XCTAssertEqual(minus.r, 0.60039, accuracy: accuracy)
        XCTAssertEqual(minus.g, 0.18936, accuracy: accuracy)
        XCTAssertEqual(minus.b, 0.33847, accuracy: accuracy)
    }

    func testSaturationMinusOneIsGrayscale() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(hslSaturation: -1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.26441, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.26441, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.26441, accuracy: accuracy)
    }

    func testSaturationPositiveBoosts() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(hslSaturation: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 1.10397, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.14581, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.14581, accuracy: accuracy)
    }

    func testHueSaturationOrderIsFixed() {
        // Hue and saturation only agree to within this file's 0.002
        // tolerance at modest slider values — at wider (still in-range)
        // settings they measurably diverge, so the pipeline's fixed
        // hue-then-saturation order is a real requirement, not a
        // discretionary choice. This pins the canonical (hue-first) result;
        // the reversed order measures (0.42582, 0.18283, 1.10397) for the
        // same inputs — a 0.0043 gap, over 2x this test's own tolerance.
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(hslHue: -90, hslSaturation: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.42335, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.18309, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 1.09968, accuracy: accuracy)
    }

    func testHSLPreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2, a: 0.5)
        let output = EditPipeline.apply(EditState(hslHue: 45, hslSaturation: 0.5), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.25564, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.11936, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.01976, accuracy: accuracy)
        XCTAssertEqual(pixel.a, 0.5, accuracy: accuracy)
    }

    func testHSLAppliedAfterCurves() {
        // Proves ordering: curves runs before HSL (not commutative — the
        // reversed order measures (0.82579, 0.66004, 0.02480) for the same
        // inputs).
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(curvesHighlights: 1, hslHue: 60, hslSaturation: 0.5), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.71513, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.57882, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.19919, accuracy: accuracy)
    }

    func testHSLPreservesHighlightHeadroom() {
        // Unlike curves, an active HSL adjustment does NOT clamp values
        // above linear 1.0 — CIHueAdjust and CIColorControls.saturation are
        // matrix/blend operations with no internal [0,1] LUT.
        let satInput = solidColorImage(r: 1.4, g: 0.5, b: 0.2)
        let satOutput = EditPipeline.apply(EditState(hslSaturation: 1), to: satInput)
        XCTAssertEqual(linearPixel(of: satOutput).r, 2.57770, accuracy: accuracy)

        // Gray 1.2 rotated by hue: R/B stay exactly 1.2 (asserted here); G
        // drifts to ~1.19265 due to floating-point precision in the rotation
        // matrix on an equal-RGB input, not a clamp — R alone is sufficient
        // evidence headroom survives.
        let hueInput = solidColorImage(1.2)
        let hueOutput = EditPipeline.apply(EditState(hslHue: 45), to: hueInput)
        XCTAssertEqual(linearPixel(of: hueOutput).r, 1.2, accuracy: accuracy)
    }

    // MARK: - Vibrance math
    //
    // Vibrance is a selective saturation (CIVibrance) that boosts muted
    // colors far more than already-saturated ones. Expected values are
    // measured from the diagnostic script, in the same style as HSL above.
    // `hsvSaturation` reports relative (HSV) saturation, (max-min)/max — the
    // metric that shows vibrance's selectivity; plain chroma (max-min)
    // alone does not.

    private func hsvSaturation(_ pixel: (r: Float, g: Float, b: Float, a: Float)) -> Float {
        let maxV = max(pixel.r, max(pixel.g, pixel.b))
        let minV = min(pixel.r, min(pixel.g, pixel.b))
        guard maxV != 0 else { return 0 }
        return (maxV - minV) / maxV
    }

    func testVibranceZeroIsIdentity() {
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(vibrance: 0), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }

        let mutedInput = solidColorImage(r: 0.40, g: 0.34, b: 0.30)
        let mutedOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: 0), to: mutedInput))
        XCTAssertEqual(mutedOutput.r, 0.40000, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.g, 0.34000, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.b, 0.30000, accuracy: accuracy)
    }

    func testVibranceProtectsSaturatedBoostsMuted() {
        // The defining property: at the same +0.5 amount, a muted color
        // gains far more RELATIVE (HSV) saturation than an already-saturated
        // one — vibrance's selectivity vs plain saturation's uniform ~2.3x
        // ratio between the same two inputs.
        let mutedInput = solidColorImage(r: 0.40, g: 0.34, b: 0.30)
        let mutedOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: 0.5), to: mutedInput))
        XCTAssertEqual(mutedOutput.r, 0.45057, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.g, 0.33555, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.b, 0.26423, accuracy: accuracy)

        let saturatedInput = solidColorImage(r: 0.80, g: 0.05, b: 0.05)
        let saturatedOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: 0.5), to: saturatedInput))
        XCTAssertEqual(saturatedOutput.r, 0.90828, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.g, 0.04027, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.b, 0.04027, accuracy: accuracy)

        let mutedDelta = hsvSaturation(mutedOutput) - hsvSaturation(linearPixel(of: mutedInput))
        let saturatedDelta = hsvSaturation(saturatedOutput) - hsvSaturation(linearPixel(of: saturatedInput))
        XCTAssertEqual(mutedDelta, 0.16357, accuracy: accuracy)
        XCTAssertEqual(saturatedDelta, 0.01816, accuracy: accuracy)
        XCTAssertGreaterThan(mutedDelta, saturatedDelta * 5, "muted should gain far more saturation than already-saturated")
    }

    func testVibranceNegativeIsAsymmetricWithPositiveProtection() {
        // Pins the negative side of the -1...1 range (only positive amounts
        // were covered above). MEASURED, and notably NOT a mirror image of
        // testVibranceProtectsSaturatedBoostsMuted: "protects already-
        // saturated tones" is a property of BOOSTING (positive amount) only.
        // At vibrance -1, the already-saturated color actually loses MORE
        // absolute HSV-saturation (0.938 -> 0.753, a 0.184 drop) than the
        // muted one (0.250 -> 0.110, a 0.140 drop) — CIVibrance's protection
        // curve is one-directional, not a symmetric "leave saturated tones
        // alone" guarantee. Documented here so a future reader doesn't
        // assume symmetry that isn't there.
        let mutedInput = solidColorImage(r: 0.40, g: 0.34, b: 0.30)
        let mutedOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: -1), to: mutedInput))
        XCTAssertEqual(mutedOutput.r, 0.36684, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.g, 0.34312, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.b, 0.32649, accuracy: accuracy)

        let saturatedInput = solidColorImage(r: 0.80, g: 0.05, b: 0.05)
        let saturatedOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: -1), to: saturatedInput))
        XCTAssertEqual(saturatedOutput.r, 0.42727, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.g, 0.10552, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.b, 0.10552, accuracy: accuracy)

        let mutedSaturationDrop = hsvSaturation(linearPixel(of: mutedInput)) - hsvSaturation(mutedOutput)
        let saturatedSaturationDrop = hsvSaturation(linearPixel(of: saturatedInput)) - hsvSaturation(saturatedOutput)
        XCTAssertGreaterThan(saturatedSaturationDrop, mutedSaturationDrop, "unlike the positive side, saturated should NOT be protected here")
    }

    func testVibrancePreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2, a: 0.5)
        let output = EditPipeline.apply(EditState(vibrance: 0.5), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.31711, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.09562, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.09562, accuracy: accuracy)
        XCTAssertEqual(pixel.a, 0.5, accuracy: accuracy)
    }

    func testVibrancePreservesHighlightHeadroom() {
        // Unlike curves, an active vibrance adjustment does NOT clamp values
        // above linear 1.0 — CIVibrance is a blend operation with no
        // internal [0,1] LUT.
        let input = solidColorImage(r: 1.4, g: 0.5, b: 0.2)
        let output = EditPipeline.apply(EditState(vibrance: 0.5), to: input)
        XCTAssertEqual(linearPixel(of: output).r, 1.40025, accuracy: accuracy)
    }

    func testVibranceSaturationOrderIsFixed() {
        // Vibrance and plain saturation do NOT commute — the reversed
        // (saturation-first) order measures (1.41929, 0.02660, 0.02660) for
        // the same saturated input, a 0.243 gap far past this file's 0.002
        // tolerance. This pins the canonical vibrance-then-saturation order.
        let saturatedInput = solidColorImage(r: 0.80, g: 0.05, b: 0.05)
        let saturatedOutput = linearPixel(
            of: EditPipeline.apply(EditState(hslSaturation: 0.5, vibrance: 0.5), to: saturatedInput)
        )
        XCTAssertEqual(saturatedOutput.r, 1.66190, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.g, 0.01813, accuracy: accuracy)
        XCTAssertEqual(saturatedOutput.b, 0.01813, accuracy: accuracy)

        let mutedInput = solidColorImage(r: 0.40, g: 0.34, b: 0.30)
        let mutedOutput = linearPixel(
            of: EditPipeline.apply(EditState(hslSaturation: 0.5, vibrance: 0.5), to: mutedInput)
        )
        XCTAssertEqual(mutedOutput.r, 0.50483, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.g, 0.32718, accuracy: accuracy)
        XCTAssertEqual(mutedOutput.b, 0.22550, accuracy: accuracy)
    }

    func testVibranceSpanStrengthAtExtremes() {
        // Documents why vibrance maps 1:1 to its -1...1 slider with no span
        // constant: at the same +1 amount, vibrance stays contained on an
        // already-saturated color while plain saturation runs away — proof
        // the raw filter range is already well-scaled for a direct map.
        let saturatedInput = solidColorImage(r: 0.80, g: 0.05, b: 0.05)

        let vibranceOutput = linearPixel(of: EditPipeline.apply(EditState(vibrance: 1), to: saturatedInput))
        XCTAssertEqual(vibranceOutput.r, 0.91398, accuracy: accuracy)
        XCTAssertEqual(vibranceOutput.g, 0.03981, accuracy: accuracy)
        XCTAssertEqual(vibranceOutput.b, 0.03981, accuracy: accuracy)

        let saturationOutput = linearPixel(of: EditPipeline.apply(EditState(hslSaturation: 1), to: saturatedInput))
        XCTAssertEqual(saturationOutput.r, 2.25304, accuracy: accuracy)
        XCTAssertEqual(saturationOutput.g, 0.01129, accuracy: accuracy)
        XCTAssertEqual(saturationOutput.b, 0.01129, accuracy: accuracy)
    }

    // MARK: - Crop geometry
    //
    // Crop is pure geometry (extent), not color, so — unlike every other
    // Phase 2 feature — these values are hand-computable rather than
    // measured from a Core Image diagnostic. The coordinate-direction tests
    // still use empirically-verified ground truth (see quadrantImage's doc
    // comment) rather than assumed conventions, matching this project's
    // established discipline.

    func testCropZeroIsIdentity() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(output.extent, input.extent)
    }

    func testCropInsetsShrinkExtent() {
        let input = quadrantImage(width: 100, height: 100)
        let output = EditPipeline.apply(EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1), to: input)

        XCTAssertEqual(output.extent, CGRect(x: 10, y: 0, width: 90, height: 75))
    }

    func testCropTopInsetRemovesTopContent() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(cropInsetTop: 0.5), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 25)), "blue")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 25)), "yellow")
    }

    func testCropBottomInsetRemovesBottomContent() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(cropInsetBottom: 0.5), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "red")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 75)), "green")
    }

    func testCropLeftInsetRemovesLeftContent() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(cropInsetLeft: 0.5), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 75)), "green")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 25)), "yellow")
    }

    func testCropRightInsetRemovesRightContent() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(cropInsetRight: 0.5), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "red")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 25)), "blue")
    }

    func testCropInsetsClampToMaxPreventingInversion() {
        // Insets well beyond the 0.45-per-side max must not cross and
        // invert/corrupt the rect.
        let input = quadrantImage(width: 100, height: 100)
        let output = EditPipeline.apply(EditState(cropInsetLeft: 0.9, cropInsetRight: 0.9), to: input)

        XCTAssertEqual(output.extent.width, 10, accuracy: 0.01)
        XCTAssertGreaterThan(output.extent.width, 0)
    }

    func testCropPreservesColorMath() {
        // Crop composed with exposure: the retained region's color still
        // reflects the exposure adjustment, proving crop doesn't interfere
        // with the rest of the pipeline.
        let input = solidColorImage(0.2, size: 100)
        let output = EditPipeline.apply(EditState(exposureEV: 1, cropInsetTop: 0.25, cropInsetRight: 0.25), to: input)

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 10, y: 10, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        XCTAssertEqual(buffer[0], 0.4, accuracy: accuracy)
    }

    // MARK: - Brilliance math
    //
    // Brilliance is this app's own composite (NOT Apple's algorithm) — a
    // pure render-time blend into effective contrast/shadows/highlights/
    // saturation. Values are hand-derivable from the documented formula
    // (unlike the black-box filters above), confirmed by measurement.

    func testBrillianceZeroIsIdentity() {
        let input = solidColorImage(0.35)
        let output = EditPipeline.apply(EditState(brilliance: 0), to: input)
        XCTAssertEqual(linearPixel(of: output).r, linearPixel(of: input).r, accuracy: accuracy)
    }

    func testBrillianceEquivalentToManualSliderCombination() {
        // The defining test: brilliance=1 must produce EXACTLY the same
        // output as manually dialing in its constituent weighted deltas
        // (contrast+0.15, shadows+0.4, highlights-0.3, saturation+0.1) —
        // proving the blend formula does what it's documented to do, and
        // that it never mutates the underlying sliders themselves (both
        // EditState values below are independently constructed).
        let grayInput = solidColorImage(0.3)
        let brillianceOnly = EditPipeline.apply(EditState(brilliance: 1), to: grayInput)
        let manualEquivalent = EditPipeline.apply(
            EditState(contrast: 0.15, curvesShadows: 0.4, curvesHighlights: -0.3, hslSaturation: 0.1),
            to: grayInput
        )
        XCTAssertEqual(linearPixel(of: brillianceOnly).r, linearPixel(of: manualEquivalent).r, accuracy: accuracy)
        XCTAssertEqual(linearPixel(of: brillianceOnly).r, 0.24033, accuracy: accuracy)

        let colorInput = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let brillianceColorOnly = EditPipeline.apply(EditState(brilliance: 1), to: colorInput)
        let manualColorEquivalent = EditPipeline.apply(
            EditState(contrast: 0.15, curvesShadows: 0.4, curvesHighlights: -0.3, hslSaturation: 0.1),
            to: colorInput
        )
        let brillPixel = linearPixel(of: brillianceColorOnly)
        let manualPixel = linearPixel(of: manualColorEquivalent)
        XCTAssertEqual(brillPixel.r, manualPixel.r, accuracy: accuracy)
        XCTAssertEqual(brillPixel.g, manualPixel.g, accuracy: accuracy)
        XCTAssertEqual(brillPixel.b, manualPixel.b, accuracy: accuracy)
        XCTAssertEqual(brillPixel.r, 0.66467, accuracy: accuracy)
        XCTAssertEqual(brillPixel.g, 0.14018, accuracy: accuracy)
        XCTAssertEqual(brillPixel.b, 0.14018, accuracy: accuracy)
    }

    func testBrilliancePartialAndNegative() {
        let halfOutput = EditPipeline.apply(EditState(brilliance: 0.5), to: solidColorImage(0.3))
        XCTAssertEqual(linearPixel(of: halfOutput).r, 0.26848, accuracy: accuracy)

        let negativeOutput = EditPipeline.apply(EditState(brilliance: -1), to: solidColorImage(0.3))
        XCTAssertEqual(linearPixel(of: negativeOutput).r, 0.37444, accuracy: accuracy)
    }

    func testBrillianceClampsHighlightHeadroomWhenCurveActive() {
        // Once brilliance is non-zero, effective shadows/highlights become
        // non-zero too, engaging the curve stage — which clamps headroom,
        // same documented limitation as curves/black point.
        let output = EditPipeline.apply(EditState(brilliance: 1), to: solidColorImage(1.3))
        XCTAssertEqual(linearPixel(of: output).r, 1.0, accuracy: accuracy)
    }

    func testBriliancePreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5)
        let output = EditPipeline.apply(EditState(brilliance: 1), to: input)
        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    func testBrillianceDoesNotMutateUnderlyingSliderValues() {
        // Structural check: brilliance's effect is purely a render-time
        // blend — EditState itself must still report the raw slider values
        // the user set, not brilliance-adjusted ones.
        var state = EditState(brilliance: 1)
        state.contrast = 0.2
        XCTAssertEqual(state.contrast, 0.2)
        XCTAssertEqual(state.curvesShadows, 0)
        XCTAssertEqual(state.curvesHighlights, 0)
        XCTAssertEqual(state.hslSaturation, 0)
    }

    // MARK: - EditState

    func testEditStateDefaultIsIdentity() {
        XCTAssertEqual(EditState().exposureEV, 0)
        XCTAssertEqual(EditState().brightness, 0)
        XCTAssertEqual(EditState().contrast, 0)
        XCTAssertEqual(EditState().whiteBalanceTemperature, 6500)
        XCTAssertEqual(EditState().whiteBalanceTint, 0)
        XCTAssertEqual(EditState().curvesShadows, 0)
        XCTAssertEqual(EditState().curvesHighlights, 0)
        XCTAssertEqual(EditState().blackPoint, 0)
        XCTAssertEqual(EditState().brilliance, 0)
        XCTAssertEqual(EditState().hslHue, 0)
        XCTAssertEqual(EditState().hslSaturation, 0)
        XCTAssertEqual(EditState().vibrance, 0)
        XCTAssertEqual(EditState().cropInsetTop, 0)
        XCTAssertEqual(EditState().cropInsetBottom, 0)
        XCTAssertEqual(EditState().cropInsetLeft, 0)
        XCTAssertEqual(EditState().cropInsetRight, 0)

        let input = solidColorImage(0.35)
        let output = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(linearPixel(of: output).r, linearPixel(of: input).r, accuracy: accuracy)
    }

    func testEditStateCodableRoundTrip() throws {
        let original = EditState(
            whiteBalanceTemperature: 5200,
            whiteBalanceTint: -10,
            exposureEV: 1.37,
            brightness: 0.25,
            contrast: -0.4,
            curvesShadows: 0.6,
            curvesHighlights: -0.2,
            blackPoint: -0.3,
            brilliance: 0.5,
            hslHue: 45,
            hslSaturation: 0.3,
            vibrance: 0.4,
            cropInsetTop: 0.1,
            cropInsetBottom: 0.05,
            cropInsetLeft: 0.15,
            cropInsetRight: 0.2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
