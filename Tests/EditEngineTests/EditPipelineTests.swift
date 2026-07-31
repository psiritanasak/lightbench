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

    // MARK: - EditState

    func testEditStateDefaultIsIdentity() {
        XCTAssertEqual(EditState().exposureEV, 0)
        XCTAssertEqual(EditState().contrast, 0)
        XCTAssertEqual(EditState().whiteBalanceTemperature, 6500)
        XCTAssertEqual(EditState().whiteBalanceTint, 0)
        XCTAssertEqual(EditState().curvesShadows, 0)
        XCTAssertEqual(EditState().curvesHighlights, 0)

        let input = solidColorImage(0.35)
        let output = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(linearPixel(of: output).r, linearPixel(of: input).r, accuracy: accuracy)
    }

    func testEditStateCodableRoundTrip() throws {
        let original = EditState(
            whiteBalanceTemperature: 5200,
            whiteBalanceTint: -10,
            exposureEV: 1.37,
            contrast: -0.4,
            curvesShadows: 0.6,
            curvesHighlights: -0.2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
