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

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double, size: Int) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// A square image with a sharp vertical step edge at x = size/2: the
    /// low-x half is `lo`, the high-x half is `hi` (true linear values, no
    /// 8-bit gamma quantization, unlike `quadrantImage`'s device-RGB
    /// construction — needed for sub-0.002 sharpening assertions).
    /// Sharpening needs a real edge to measure — a flat solid shows zero
    /// effect — and a step gives a hand-checkable overshoot/undershoot.
    private func stepEdgeImage(lo: Double, hi: Double, size: Int, alpha: Double = 1) -> CIImage {
        let left = CIColor(red: lo, green: lo, blue: lo, alpha: alpha, colorSpace: linearSpace)!
        let right = CIColor(red: hi, green: hi, blue: hi, alpha: alpha, colorSpace: linearSpace)!
        let leftHalf = CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: size / 2, height: size))
        let rightHalf = CIImage(color: right).cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return leftHalf.composited(over: rightHalf)
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
        case (0, 0, 0): return "black"
        default: return "unknown(\(ptr[0]),\(ptr[1]),\(ptr[2]))"
        }
    }

    /// Composites `image` over an opaque black background matching its own
    /// extent — mirrors `ImageRenderer`'s own black-background composite, so
    /// a spatial transform's undefined/transparent regions (e.g. the
    /// corners a perspective taper reveals) read as "black" via
    /// `describeColor` instead of an ambiguous "unknown(0,0,0,a=0)".
    private func overBlack(_ image: CIImage) -> CIImage {
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: image.extent)
        return image.composited(over: background)
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

    /// Samples an arbitrary single pixel of a (typically multi-pixel, sized)
    /// image at integer coordinates in `CIImage`'s own coordinate space —
    /// used for spatial filters like vignette where `linearPixel(of:)`'s
    /// fixed origin-pixel sample can't show radial variation.
    private func pixel(of image: CIImage, at x: Int, _ y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &buffer,
            rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
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

    // MARK: - Levels math
    //
    // Levels (CIColorMatrix -> CIColorClamp -> CIGammaAdjust) is the first
    // stage in the perceptual sandwich — genuine new filter math, so these
    // values are measured against the real chain, not hand-derived. Inputs
    // below are LINEAR solid colors; `levelsBlackPoint`/`levelsWhitePoint`/
    // `levelsGamma` are PERCEPTUAL-domain thresholds (same convention as
    // Black Point/Contrast/Brightness's own tests), so e.g. a linear 0.5
    // input is already well above a perceptual white point of 0.7 once
    // sRGB-encoded — not a bug, just the sRGB gamma curve.

    func testLevelsIdentityIsNoOp() {
        // Identity (0, 1, 1) must be an exact no-op, INCLUDING headroom —
        // this specifically exercises the `levelsActive` guard: calling the
        // raw filter chain unconditionally would clip 1.2/1.4 to 1.0 even
        // at identity params (CIColorClamp always runs), so this also
        // proves the guard is wired correctly, not just present.
        for value in [0.05, 0.214, 0.5, 0.7, 1.0, 1.2, 1.4] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "value \(value)")
        }
    }

    func testLevelsBlackPointCrushesShadows() {
        let state = EditState(levelsBlackPoint: 0.3)
        let expected: [Double: Float] = [
            0.0: 0.0, 0.1: 0.00601, 0.2: 0.05650, 0.5: 0.34476, 0.8: 0.72215
        ]
        for (value, expectedOutput) in expected {
            let output = EditPipeline.apply(state, to: solidColorImage(value))
            XCTAssertEqual(linearPixel(of: output).r, expectedOutput, accuracy: accuracy, "value \(value)")
        }
    }

    func testLevelsWhitePointClampsHighlights() {
        let state = EditState(levelsWhitePoint: 0.7)
        let expected: [Double: Float] = [0.0: 0.0, 0.2: 0.43694, 0.5: 1.0, 1.0: 1.0]
        for (value, expectedOutput) in expected {
            let output = EditPipeline.apply(state, to: solidColorImage(value))
            XCTAssertEqual(linearPixel(of: output).r, expectedOutput, accuracy: accuracy, "value \(value)")
        }
    }

    func testLevelsGammaBrightensMidtones() {
        // The sign-convention test: this is what would catch an inverted
        // `power = 1/gamma` (a mistake would darken where it should
        // brighten and vice versa).
        let input = solidColorImage(0.5)
        let brighter = EditPipeline.apply(EditState(levelsGamma: 2.0), to: input)
        let darker = EditPipeline.apply(EditState(levelsGamma: 0.5), to: input)

        XCTAssertEqual(linearPixel(of: brighter).r, 0.70597, accuracy: accuracy)
        XCTAssertEqual(linearPixel(of: darker).r, 0.25372, accuracy: accuracy)
        XCTAssertGreaterThan(linearPixel(of: brighter).r, 0.5, "gamma > 1 should brighten")
        XCTAssertLessThan(linearPixel(of: darker).r, 0.5, "gamma < 1 should darken")
    }

    func testLevelsClampsHighlightHeadroom() {
        // UNLIKE most adjustments in this app, Levels intentionally clips
        // highlight headroom once active — that's what a white point does.
        let state = EditState(levelsWhitePoint: 0.9)
        for value in [1.0, 1.2, 1.4] {
            let output = EditPipeline.apply(state, to: solidColorImage(value))
            XCTAssertEqual(linearPixel(of: output).r, 1.0, accuracy: accuracy, "value \(value)")
        }
    }

    func testLevelsPreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.6, b: 0.6, a: 0.5)
        let output = EditPipeline.apply(
            EditState(levelsBlackPoint: 0.2, levelsWhitePoint: 0.8, levelsGamma: 1.5),
            to: input
        )
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.a, 0.5, accuracy: accuracy)
        XCTAssertEqual(pixel.r, 0.49714, accuracy: accuracy)
        XCTAssertTrue(pixel.r.isFinite)
    }

    func testLevelsBlackWhiteDegenerateIsSafe() {
        // Proves `kMinLevelsGap` prevents Inf/NaN: black == white, and a
        // fully inverted black > white, both stay finite (if extreme).
        let equal = EditPipeline.apply(EditState(levelsBlackPoint: 0.5, levelsWhitePoint: 0.5), to: solidColorImage(0.5))
        XCTAssertTrue(linearPixel(of: equal).r.isFinite)

        let inverted = EditState(levelsBlackPoint: 0.7, levelsWhitePoint: 0.3)
        let expected: [Double: Float] = [0.0: 0.0, 0.2: 0.0, 0.5: 1.0, 0.8: 1.0, 1.0: 1.0]
        for (value, expectedOutput) in expected {
            let output = EditPipeline.apply(inverted, to: solidColorImage(value))
            let pixel = linearPixel(of: output)
            XCTAssertTrue(pixel.r.isFinite, "value \(value)")
            XCTAssertEqual(pixel.r, expectedOutput, accuracy: accuracy, "value \(value)")
        }
    }

    func testLevelsNegativeRemapNoNaN() {
        // Core NaN-safety proof: an input well below the black point,
        // combined with a fractional gamma power (gamma=3 -> power=1/3),
        // would be `pow(negative, 1/3)` (NaN) if the clamp ran AFTER gamma
        // instead of before. Measured: exact, finite 0.0.
        let state = EditState(levelsBlackPoint: 0.5, levelsGamma: 3.0)
        let output = EditPipeline.apply(state, to: solidColorImage(0.2))
        let pixel = linearPixel(of: output)

        XCTAssertTrue(pixel.r.isFinite)
        XCTAssertFalse(pixel.r.isNaN)
        XCTAssertEqual(pixel.r, 0.0, accuracy: accuracy)
    }

    func testLevelsRunsBeforeBrightness() {
        // Proves pipeline ORDERING (Levels, then Brightness), not just each
        // stage in isolation — MEASURED non-commuting (0.0119 gap between
        // the two orders), the same real-requirement pattern as
        // testBrightnessAppliedBeforeContrast/testWhiteBalanceAppliedBeforeContrast.
        let input = solidColorImage(0.3)
        let output = EditPipeline.apply(
            EditState(levelsBlackPoint: 0.1, levelsWhitePoint: 0.9, levelsGamma: 1.5, brightness: 0.5),
            to: input
        )
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.67415, accuracy: accuracy)
        XCTAssertNotEqual(pixel.r, 0.66228, accuracy: accuracy, "should not match the reversed (brightness-then-levels) order")
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
    // Curves is applied inside the same perceptual sandwich as contrast,
    // after it. Expected values below are measured from the diagnostic
    // script that established the point-span constant — chromatic/tonal
    // spline behavior has no closed-form transfer function to hand-derive
    // against. Every one of them is UNCHANGED by Curves v2 slice 1's
    // replacement of CIToneCurve with ToneCurve.cikernel: that replacement
    // is byte-exact in-domain by construction, and these assertions are the
    // regression gate that proves it. Only the above-1.0 headroom cases
    // moved — see testCurvesPreserveHighlightHeadroom.

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

    func testCurvesPreserveHighlightHeadroom() {
        // THE Curves v2 slice-1 fix, and the only intended behaviour change
        // in replacing CIToneCurve with ToneCurve.cikernel. Both assertions
        // read exactly 1.0 against the OLD path — CIToneCurve hard-clamped
        // its domain to [0,1] once active, collapsing to white every value
        // above linear 1.0 that Exposure had legitimately created. This test
        // is written to FAIL against that path, not merely to pass here.
        let warmInput = solidColorImage(1.2)
        let warmOutput = EditPipeline.apply(EditState(curvesShadows: 1), to: warmInput)
        XCTAssertEqual(linearPixel(of: warmOutput).r, 1.18620, accuracy: accuracy)

        // Above the last control point the curve extrapolates LINEARLY along
        // its own end slope, so a highlight-recovery curve — whose final
        // segment climbs steeply from point3 (0.75, 0.60) to point4 (1, 1) —
        // AMPLIFIES headroom rather than merely passing it through. That is
        // the honest consequence of a C1-continuous extrapolation, not a
        // bug: the alternative (clamping) is the defect being fixed.
        let coolInput = solidColorImage(1.4)
        let coolOutput = EditPipeline.apply(EditState(curvesHighlights: -1), to: coolInput)
        XCTAssertEqual(linearPixel(of: coolOutput).r, 1.90490, accuracy: accuracy)
    }

    func testCurvesHeadroomIsContinuousAcrossTheExtrapolationBoundary() {
        // Guards the seam the fix introduces: the linear extrapolation must
        // MEET the spline at the last control point, not step at it. A
        // discontinuity here would show up on a real photo as a hard banding
        // edge in the brightest tones. Values either side of the boundary
        // must stay within a hair of each other and keep climbing.
        let below = linearPixel(of: EditPipeline.apply(EditState(curvesShadows: 1), to: solidColorImage(0.999))).r
        let at = linearPixel(of: EditPipeline.apply(EditState(curvesShadows: 1), to: solidColorImage(1.0))).r
        let above = linearPixel(of: EditPipeline.apply(EditState(curvesShadows: 1), to: solidColorImage(1.001))).r

        XCTAssertEqual(at, 1.0, accuracy: accuracy)
        XCTAssertEqual(below, at, accuracy: 0.005)
        XCTAssertEqual(above, at, accuracy: 0.005)
        XCTAssertLessThan(below, at)
        XCTAssertLessThan(at, above)
    }

    func testContrastHeadroomSurvivesAnActiveCurve() {
        // The interaction that used to be the sharp edge of the defect:
        // contrast alone preserves headroom (matches
        // testContrastPreservesHighlightHeadroom's 1.54194 at L=0.7), and
        // adding a curve no longer destroys it. Against the old path the
        // second assertion read exactly 1.0 — enabling a slider silently
        // revoked another stage's documented guarantee.
        //
        // It is still COMPRESSED rather than passed through unchanged: a
        // highlights +1 curve flattens hard near its top end, so its end
        // slope is shallow and the extrapolation above it is shallow too.
        // Compressing headroom is the curve doing its job; discarding it
        // was the bug.
        let input = solidColorImage(0.7)

        let contrastOnly = EditPipeline.apply(EditState(contrast: 1), to: input)
        XCTAssertEqual(linearPixel(of: contrastOnly).r, 1.54194, accuracy: accuracy)

        let contrastPlusCurve = EditPipeline.apply(EditState(contrast: 1, curvesHighlights: 1), to: input)
        XCTAssertEqual(linearPixel(of: contrastPlusCurve).r, 1.01613, accuracy: accuracy)
        XCTAssertGreaterThan(linearPixel(of: contrastPlusCurve).r, 1.0)
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

    func testBlackPointPreservesHighlightHeadroom() {
        // Same fix reaching Black Point, which shares applyCurves' spline:
        // clamping the SHADOW end (what point0 is for) must not also clamp
        // the highlight end. Read exactly 1.0 against the old path.
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: solidColorImage(1.2))
        XCTAssertEqual(linearPixel(of: output).r, 1.17330, accuracy: accuracy)
    }

    func testBlackPointPreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5)
        let output = EditPipeline.apply(EditState(blackPoint: -1), to: input)
        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    // MARK: - Point Curve (Curves v2) math
    //
    // The user's freely-placed point curve is a SEPARATE, ADDITIVE stage
    // running immediately after the parametric curve above, inside the same
    // perceptual sandwich. Monotone cubic (Fritsch-Carlson), unlike the
    // parametric layer's natural cubic — see `MonotoneToneCurve`.

    private func curvePoints(_ pairs: [(Double, Double)]) -> [ToneCurvePoint] {
        pairs.map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }

    func testEmptyPointCurveIsByteIdenticalToTheParametricCurveAlone() {
        // THE regression gate for the whole "additive second stage"
        // decision: adding this field must not perturb a single existing
        // render. Compares a fully-populated parametric curve against
        // itself with the new field explicitly empty.
        for value in [0.01, 0.05, 0.214, 0.5, 0.7, 1.2] {
            let parametric = EditState(curvesShadows: 0.6, curvesHighlights: -0.4, blackPoint: -0.5)
            var withEmptyCurve = parametric
            withEmptyCurve.toneCurvePoints = []

            let a = linearPixel(of: EditPipeline.apply(parametric, to: solidColorImage(value))).r
            let b = linearPixel(of: EditPipeline.apply(withEmptyCurve, to: solidColorImage(value))).r
            XCTAssertEqual(a, b, accuracy: 0, "byte-exact required, at L=\(value)")
        }
    }

    func testIdentityShapedPointCurveRendersIdentity() {
        // Collinear control points reduce to the straight line exactly (see
        // MonotoneToneCurve's collinearity identity), so an identity-shaped
        // curve is a true no-op rather than merely close to one — which is
        // why `pointCurveActive` doesn't need identity-shape detection.
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let state = EditState(toneCurvePoints: curvePoints([(0, 0), (0.25, 0.25), (0.75, 0.75), (1, 1)]))
            let output = EditPipeline.apply(state, to: solidColorImage(value))
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "at L=\(value)")
        }
    }

    func testPointCurveAloneActivatesThePerceptualSandwich() {
        // Guards the early-return `guard` in applyPerceptualAdjustments. If
        // the point curve is missing from that list, a photo whose ONLY
        // edit is a curve skips the entire sandwich and renders unedited —
        // a silent no-op with the same signature as a missing .cikernel.
        let state = EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.72), (1, 1)]))
        let output = EditPipeline.apply(state, to: solidColorImage(0.25))
        XCTAssertGreaterThan(linearPixel(of: output).r, 0.30, "a lifting curve must visibly lift")
    }

    func testPointCurveLiftsAndLowersInTheExpectedDirection() {
        let lifted = EditPipeline.apply(
            EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.72), (1, 1)])), to: solidColorImage(0.214)
        )
        let lowered = EditPipeline.apply(
            EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.28), (1, 1)])), to: solidColorImage(0.214)
        )
        XCTAssertGreaterThan(linearPixel(of: lifted).r, 0.214)
        XCTAssertLessThan(linearPixel(of: lowered).r, 0.214)
    }

    func testPointCurvePreservesHighlightHeadroom() {
        // The same guarantee slice 1 established for the parametric layer,
        // now required of the new stage too: values above linear 1.0 must
        // survive, via linear extrapolation along the curve's end tangent.
        let state = EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.6), (1, 1)]))
        let output = EditPipeline.apply(state, to: solidColorImage(1.3))
        XCTAssertGreaterThan(linearPixel(of: output).r, 1.0, "headroom must not be crushed")
    }

    func testPointCurveClampsBelowItsFirstPoint() {
        // The deliberately asymmetric low end: the leftmost point is a
        // black point, so everything below it clamps rather than
        // extrapolating negative.
        let state = EditState(toneCurvePoints: curvePoints([(0.35, 0), (0.7, 0.7), (1, 1)]))
        let output = EditPipeline.apply(state, to: solidColorImage(0.002))
        XCTAssertEqual(linearPixel(of: output).r, 0, accuracy: accuracy)
    }

    func testPointCurveComposesWithTheParametricCurve() {
        // Both stages active must differ from either alone — the concrete
        // statement of "additive second stage".
        let input = solidColorImage(0.3)
        let curveOnly = EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.68), (1, 1)]))
        let parametricOnly = EditState(curvesShadows: 0.8)
        var both = parametricOnly
        both.toneCurvePoints = curveOnly.toneCurvePoints

        let a = linearPixel(of: EditPipeline.apply(curveOnly, to: input)).r
        let b = linearPixel(of: EditPipeline.apply(parametricOnly, to: input)).r
        let c = linearPixel(of: EditPipeline.apply(both, to: input)).r
        XCTAssertNotEqual(c, a, accuracy: accuracy)
        XCTAssertNotEqual(c, b, accuracy: accuracy)
    }

    func testPointCurveOrderRelativeToTheParametricCurveIsFixed() {
        // Proves ordering: the parametric curve runs BEFORE the point curve,
        // and they do not commute. MEASURED by swapping the two stages and
        // re-rendering — the reversed order gives 0.399974 here against
        // 0.325295, a 0.07468 gap at linear 0.214 (photographic middle
        // gray), ~37x this file's 0.002 tolerance. A real requirement, not
        // a convention.
        var state = EditState(curvesShadows: 0.7, curvesHighlights: -0.5, blackPoint: -0.4)
        state.toneCurvePoints = curvePoints([(0, 0.04), (0.3, 0.18), (0.7, 0.85), (1, 0.97)])

        let output = EditPipeline.apply(state, to: solidColorImage(0.214))
        XCTAssertEqual(linearPixel(of: output).r, 0.325295, accuracy: accuracy)
    }

    func testMalformedPointCurveRendersUntouchedRatherThanGarbage() {
        // MonotoneToneCurve.init? rejects these; applyPointCurve then leaves
        // the image alone. Renders IDENTITY (visibly wrong) rather than NaN
        // pixels or silently dropped points (invisibly wrong).
        let malformed: [[ToneCurvePoint]] = [
            curvePoints([(0, 0)]),
            curvePoints([(0, 0), (0, 1)]),
            curvePoints([(0, 0), (.nan, 0.5), (1, 1)])
        ]
        for pointSet in malformed {
            let output = EditPipeline.apply(EditState(toneCurvePoints: pointSet), to: solidColorImage(0.5))
            XCTAssertEqual(linearPixel(of: output).r, 0.5, accuracy: accuracy, "for \(pointSet)")
        }
    }

    /// Pins the shipped composite-then-red order — see the doc comment on
    /// `applyPerceptualAdjustments`'s point-curve block for the measured
    /// delta (0.04702, ~23.5x this file's 0.002 tolerance) that makes this
    /// a requirement, not a convention.
    func testCompositeAndChannelCurveOrderIsFixed() {
        var state = EditState()
        state.toneCurvePoints = curvePoints([(0, 0.02), (0.4, 0.2), (0.7, 0.75), (1, 0.98)])
        state.toneCurvePointsRed = curvePoints([(0, 0), (0.5, 0.8), (1, 1)])
        let output = linearPixel(of: EditPipeline.apply(state, to: solidColorImage(0.214)))
        XCTAssertEqual(output.r, 0.75570166, accuracy: accuracy)
    }

    /// Unlike composite-vs-channel order, R/G/B mutual order does not need
    /// to be pinned — measured bit-identical regardless of which runs
    /// first (temporarily moved the Blue pass before Red in
    /// `applyPerceptualAdjustments`, rebuilt, re-ran this fixture: r/g/b
    /// landed on the exact same three constants below at `accuracy: 0`),
    /// since each pass writes only its own channel. Rather than re-pin
    /// those three constants under only ONE order (which would silently
    /// pass even if red and blue secretly interfered, as long as neither
    /// regressed on its own), this test checks the actual CLAIM —
    /// red-and-blue-together equals red-alone composed with blue-alone,
    /// each channel taken from whichever single-curve render owns it —
    /// through the public API, so a future accidental cross-channel
    /// dependency fails here without needing another internal reorder.
    func testPerChannelCurvesComposeIndependentlyOfTheirOwnOrder() {
        var combined = EditState()
        combined.toneCurvePointsRed = curvePoints([(0, 0), (0.5, 0.8), (1, 1)])
        combined.toneCurvePointsBlue = curvePoints([(0, 0), (0.5, 0.15), (1, 1)])
        let redOnly = EditState(toneCurvePointsRed: combined.toneCurvePointsRed)
        let blueOnly = EditState(toneCurvePointsBlue: combined.toneCurvePointsBlue)

        let input = solidColorImage(0.214)
        let combinedOutput = linearPixel(of: EditPipeline.apply(combined, to: input))
        let redOnlyOutput = linearPixel(of: EditPipeline.apply(redOnly, to: input))
        let blueOnlyOutput = linearPixel(of: EditPipeline.apply(blueOnly, to: input))

        XCTAssertEqual(combinedOutput.r, redOnlyOutput.r, accuracy: 0)
        XCTAssertEqual(combinedOutput.b, blueOnlyOutput.b, accuracy: 0)
        // Green untouched — no green curve active in any of the three states.
        XCTAssertEqual(combinedOutput.g, redOnlyOutput.g, accuracy: 0)
        XCTAssertEqual(combinedOutput.g, blueOnlyOutput.g, accuracy: 0)
    }

    /// Deliberately uses IDENTITY-SHAPED channel curves, not empty ones —
    /// `EditState(toneCurvePoints:)` alone vs. a copy with all three
    /// channel fields also set is otherwise `==` before this pipeline ever
    /// runs, which would make the assertion below true by construction
    /// regardless of any regression in the three extra kernel passes this
    /// case is meant to exercise.
    ///
    /// NOT `accuracy: 0` — measured, not assumed: unlike an EMPTY channel
    /// field (which skips `pointCurveValue` entirely, see
    /// `pointCurveActive`/the kernel's ternary), an identity-SHAPED curve
    /// still runs the full `pointCurveValue` sRGB-encode/pow/decode chain
    /// and lands only ~1e-6 from the untouched value (measured: 0.5937605
    /// vs. 0.59376013 at linear 0.5, 0.96001905 vs. 0.9600181 at linear
    /// 0.95) — real floating-point round-trip noise, not a bug, and this
    /// test's own reason to exist rather than reusing the accuracy-0
    /// tolerance of the actual empty-field byte-exactness gate,
    /// `PointToneCurveKernelTests.testCompositeCurveRenderIsUnchangedByTheChannelMaskArgument`.
    func testIdentityShapedChannelCurvesMatchTheCompositeCurveAlone() {
        let compositeOnly = EditState(toneCurvePoints: curvePoints([(0, 0), (0.5, 0.6), (1, 1)]))
        let identityShape = curvePoints([(0, 0), (1, 1)])
        var withIdentityChannels = compositeOnly
        withIdentityChannels.toneCurvePointsRed = identityShape
        withIdentityChannels.toneCurvePointsGreen = identityShape
        withIdentityChannels.toneCurvePointsBlue = identityShape
        XCTAssertNotEqual(compositeOnly, withIdentityChannels, "the fixture must actually differ, or this proves nothing")
        for input in [0.05, 0.214, 0.5, 0.95] {
            let a = linearPixel(of: EditPipeline.apply(compositeOnly, to: solidColorImage(input)))
            let b = linearPixel(of: EditPipeline.apply(withIdentityChannels, to: solidColorImage(input)))
            XCTAssertEqual(Double(a.r), Double(b.r), accuracy: 1e-5, "at linear \(input)")
        }
    }

    func testEachChannelCurveAloneActivatesThePerceptualSandwich() {
        // The `pointCurveActive` guard, once per new field — a photo whose
        // ONLY edit is a single-channel curve must not silently render
        // unedited, the same silent no-op this app has been bitten by
        // before with a missing/forgotten `.cikernel`.
        let input = solidColorImage(0.3)
        let untouched = linearPixel(of: EditPipeline.apply(EditState(), to: input))

        var redOnly = EditState(); redOnly.toneCurvePointsRed = curvePoints([(0, 0), (0.5, 0.9), (1, 1)])
        XCTAssertNotEqual(linearPixel(of: EditPipeline.apply(redOnly, to: input)).r, untouched.r, accuracy: accuracy)

        var greenOnly = EditState(); greenOnly.toneCurvePointsGreen = curvePoints([(0, 0), (0.5, 0.9), (1, 1)])
        XCTAssertNotEqual(linearPixel(of: EditPipeline.apply(greenOnly, to: input)).g, untouched.g, accuracy: accuracy)

        var blueOnly = EditState(); blueOnly.toneCurvePointsBlue = curvePoints([(0, 0), (0.5, 0.9), (1, 1)])
        XCTAssertNotEqual(linearPixel(of: EditPipeline.apply(blueOnly, to: input)).b, untouched.b, accuracy: accuracy)
    }

    func testIdentityShapedPerChannelCurveRendersIdentity() {
        let identityShape = curvePoints([(0, 0), (1, 1)])
        var state = EditState()
        state.toneCurvePointsRed = identityShape
        state.toneCurvePointsGreen = identityShape
        state.toneCurvePointsBlue = identityShape
        for input in [0.05, 0.214, 0.5, 0.95] {
            let output = linearPixel(of: EditPipeline.apply(state, to: solidColorImage(input)))
            XCTAssertEqual(Double(output.r), input, accuracy: Double(accuracy), "at linear \(input)")
        }
    }

    func testAMalformedChannelCurveLeavesOnlyItsOwnChannelUntouched() {
        // Same MonotoneToneCurve.init? rejection MonotoneToneCurve /
        // testMalformedPointCurveRendersUntouchedRatherThanGarbage already
        // covers for the composite curve — once per new field, and
        // confirming it degrades to just that channel doing nothing, not
        // the whole render.
        var state = EditState()
        state.toneCurvePointsRed = curvePoints([(0, 0), (.nan, 0.5), (1, 1)])
        state.toneCurvePointsGreen = curvePoints([(0, 0), (0.5, 0.9), (1, 1)])
        let output = linearPixel(of: EditPipeline.apply(state, to: solidColorImage(0.5)))
        let untouchedGreen = linearPixel(of: EditPipeline.apply(
            EditState(toneCurvePointsGreen: curvePoints([(0, 0), (0.5, 0.9), (1, 1)])), to: solidColorImage(0.5)
        ))
        XCTAssertEqual(output.r, 0.5, accuracy: accuracy, "the malformed red curve renders untouched, not garbage")
        XCTAssertEqual(output.g, untouchedGreen.g, accuracy: 0, "green is unaffected by red's malformed curve")
    }

    func testMasksAreUnaffectedByThePointCurveField() {
        // Confirms the per-mask path deliberately does NOT gain the point
        // curve in this slice: a mask's own Shadows/Highlights must render
        // the same whether or not a global point curve is present.
        let input = solidColorImage(r: 0.4, g: 0.4, b: 0.4, a: 1, size: 400)
        let withoutCurve = EditPipeline.apply(EditState(masks: [fullyCoveringMask(shadows: 0.5)]), to: input)

        var state = EditState(masks: [fullyCoveringMask(shadows: 0.5)])
        state.toneCurvePoints = curvePoints([(0, 0), (0.5, 0.5), (1, 1)])
        let withIdentityCurve = EditPipeline.apply(state, to: input)

        XCTAssertEqual(
            pixel(of: withoutCurve, at: 200, 200).r, pixel(of: withIdentityCurve, at: 200, 200).r,
            accuracy: accuracy
        )
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

    // MARK: - Selective Color math (HSL v2, per-band)
    //
    // The first custom Core Image kernel in this codebase — genuinely new
    // math with no closed-form transfer function, so every value below was
    // measured against the real compiled kernel (both in isolation and
    // wired into the full perceptual sandwich exactly as `EditPipeline`
    // integrates it), not hand-derived. See `EditPipeline.applySelectiveColor`
    // and `Sources/Rendering/Shaders/SelectiveColor.cikernel`.

    func testSelectiveColorZeroIsExactNoOp() {
        // Includes 1.2 to prove an inactive stage preserves headroom (no
        // kernel invocation at all — the `selectiveColorActive` guard).
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "value \(value)")
        }
    }

    func testSelectiveColorRedHueShiftsRedPixel() {
        let input = solidColorImage(r: 0.6, g: 0.05, b: 0.05)
        let output = EditPipeline.apply(EditState(redHue: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.6, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.13728, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.05, accuracy: accuracy)
    }

    func testSelectiveColorBandIsolation() {
        // A blue pixel is far outside the Red band's falloff window at the
        // default Range — redHue active must leave it (essentially)
        // untouched, proving the band selects by hue, not globally.
        let input = solidColorImage(r: 0.05, g: 0.05, b: 0.6)
        let output = EditPipeline.apply(EditState(redHue: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.05, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.05, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.6, accuracy: accuracy)
    }

    func testSelectiveColorSaturationReducesBand() {
        // Not asserted as exactly achromatic: this test color isn't
        // precisely centered on the Orange band, so `orangeSaturation: -1`
        // measurably REDUCES saturation rather than zeroing it exactly —
        // the correct, expected behavior of a soft-falloff band, verified
        // via `hsvSaturation` rather than an (incorrect) r≈g≈b assumption.
        let input = solidColorImage(r: 0.6, g: 0.3, b: 0.05)
        let output = EditPipeline.apply(EditState(orangeSaturation: -1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.37509, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.26345, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.13244, accuracy: accuracy)
        XCTAssertLessThan(hsvSaturation(pixel), hsvSaturation(linearPixel(of: input)))
    }

    func testSelectiveColorLuminanceShiftsBand() {
        let input = solidColorImage(r: 0.6, g: 0.6, b: 0.05)

        let bright = linearPixel(of: EditPipeline.apply(EditState(yellowLuminance: 1), to: input))
        XCTAssertEqual(bright.r, 0.70831, accuracy: accuracy)
        XCTAssertEqual(bright.g, 0.70831, accuracy: accuracy)
        XCTAssertEqual(bright.b, 0.19149, accuracy: accuracy)

        let dark = linearPixel(of: EditPipeline.apply(EditState(yellowLuminance: -1), to: input))
        XCTAssertEqual(dark.r, 0.31498, accuracy: accuracy)
        XCTAssertEqual(dark.g, 0.31498, accuracy: accuracy)
        XCTAssertEqual(dark.b, 0.02211, accuracy: accuracy)
    }

    func testSelectiveColorRangeWidensEffect() {
        // An in-between (roughly red-orange) pixel: a narrow Range barely
        // reaches it, a wide Range affects it substantially — MEASURED
        // strictly monotonic, proving Range controls falloff width, not
        // just a cosmetic parameter.
        let input = solidColorImage(r: 0.6, g: 0.15, b: 0.05)
        let orig = linearPixel(of: input)

        func deviation(range: Double) -> Float {
            let output = EditPipeline.apply(EditState(redHue: 1, selectiveColorRange: range), to: input)
            let pixel = linearPixel(of: output)
            return max(abs(pixel.r - orig.r), max(abs(pixel.g - orig.g), abs(pixel.b - orig.b)))
        }

        let narrow = deviation(range: 0)
        let mid = deviation(range: 0.5)
        let wide = deviation(range: 1)

        XCTAssertEqual(narrow, 0.0005, accuracy: 0.001)
        XCTAssertEqual(mid, 0.09400, accuracy: accuracy)
        XCTAssertEqual(wide, 0.12447, accuracy: accuracy)
        XCTAssertLessThan(narrow, mid)
        XCTAssertLessThan(mid, wide)
    }

    func testSelectiveColorWraparound() {
        // A pixel near 350° and one near 10° are both close to the Red
        // band's 0° center via CIRCULAR distance — both should be
        // meaningfully affected, proving the falloff correctly wraps
        // around rather than treating 350° as maximally far from 0°.
        let near350 = solidColorImage(r: 0.55, g: 0.02, b: 0.09167)
        let near10 = solidColorImage(r: 0.55, g: 0.09167, b: 0.02)

        let out350 = linearPixel(of: EditPipeline.apply(EditState(redHue: 1), to: near350))
        let out10 = linearPixel(of: EditPipeline.apply(EditState(redHue: 1), to: near10))

        // The two test colors' "x" (partially-lit) channel differs by
        // construction (near350's is b, near10's is g) — check each color's
        // own moving channel.
        XCTAssertEqual(out350.b, 0.02916, accuracy: accuracy)
        XCTAssertEqual(out10.g, 0.19840, accuracy: accuracy)
        XCTAssertNotEqual(out350.b, Float(0.09167), accuracy: 0.001, "H=350 should be measurably affected, not treated as far from the Red center")
        XCTAssertNotEqual(out10.g, Float(0.09167), accuracy: 0.001, "H=10 should be measurably affected")
    }

    func testSelectiveColorPreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.3, b: 0.05, a: 0.5)
        let output = EditPipeline.apply(EditState(orangeHue: 1), to: input)

        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: accuracy)
    }

    func testSelectiveColorPreservesHeadroomOutsideActiveBand() {
        // A bright NEUTRAL pixel has no real hue (achromatic) and must not
        // register as belonging to any band regardless of the kernel's
        // arbitrary hue=0 fallback for undefined-hue pixels — MEASURED: a
        // real bug caught by the pre-implementation probe (an earlier
        // kernel draft silently clamped this to 1.0 before band weight was
        // scaled by the pixel's own saturation; see the kernel's own doc
        // comment on `bandWeights`/saturation-weighting for detail).
        let input = solidColorImage(1.4)
        let output = EditPipeline.apply(EditState(redHue: 1), to: input)

        XCTAssertEqual(linearPixel(of: output).r, 1.4, accuracy: accuracy)
    }

    func testSelectiveColorPreservesHeadroomInsideActiveBand() {
        // A colored pixel genuinely inside an active band's influence keeps
        // its own headroom exactly (unlike an earlier design, caught on
        // review: the standard HSL saturation formula's denominator goes
        // negative once perceptual lightness exceeds 1.0, which silently
        // made the kernel treat EVERY colored headroom pixel as "outside
        // every band" — a real, systematic bug, not a narrow corner case;
        // an ordinary bright saturated highlight was completely unaffected
        // by any Selective Color slider). Fixed by normalizing by the
        // pixel's own max channel before the HSL round-trip and rescaling
        // after — the kernel's own doc comment has the full derivation.
        // Still correctly color-processed: the luminance boost visibly
        // lifts/desaturates the low channels, it just no longer destroys
        // the pixel's own brightness to do it.
        let input = solidColorImage(r: 1.4, g: 0.02, b: 0.02)
        let output = EditPipeline.apply(EditState(redLuminance: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 1.4, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.49355, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.49355, accuracy: accuracy)
    }

    func testSelectiveColorAffectsColoredHighlights() {
        // Regression guard for the exact bug above, using the reviewer's
        // own repro: a colored, moderately bright pixel (perceptual
        // lightness > 1.0 after encoding) must still be affected by Hue/
        // Saturation/Luminance sliders — before the fix, all three were
        // silently complete no-ops on this input.
        let input = solidColorImage(r: 1.6, g: 1.3, b: 1.3)
        let orig = linearPixel(of: input)

        let hueOut = linearPixel(of: EditPipeline.apply(EditState(redHue: 1), to: input))
        let satOut = linearPixel(of: EditPipeline.apply(EditState(redSaturation: -1), to: input))
        let lumOut = linearPixel(of: EditPipeline.apply(EditState(redLuminance: 1), to: input))

        XCTAssertNotEqual(hueOut.g, orig.g, accuracy: 0.01, "redHue should visibly shift this colored highlight")
        XCTAssertNotEqual(satOut.g, orig.g, accuracy: 0.01, "redSaturation should visibly desaturate this colored highlight")
        XCTAssertNotEqual(lumOut.g, orig.g, accuracy: 0.01, "redLuminance should visibly affect this colored highlight")
    }

    func testSelectiveColorRunsAfterGlobalHue() {
        // Proves pipeline ORDERING (global Hue, then Selective Color), not
        // just each stage in isolation — MEASURED non-commuting: the
        // reversed order (Selective Color, then global Hue) gives
        // (0.32724, 0.17081, 0.72195) for the same inputs, a real,
        // substantial gap (up to 0.122 on the b channel) well above this
        // file's 0.002 tolerance.
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(hslHue: -90, redSaturation: 1), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.33953, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.22242, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.6, accuracy: accuracy)
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

    // MARK: - Black & White
    //
    // Black & White reuses the EXACT same saturation-zero mechanism
    // hslSaturation's own -1 extreme already uses (proven grayscale by
    // testSaturationMinusOneIsGrayscale above) — these tests focus on the
    // NEW behavior (the override itself), not re-deriving Core Image
    // numbers. Where the exact composed output value isn't already a
    // known/reused measurement (e.g. after Hue/Vibrance also ran), tests
    // assert the STRUCTURAL property (r==g==b) rather than a fabricated
    // magic number.

    func testBlackAndWhiteFalseIsIdentity() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(blackAndWhite: false), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.6, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.2, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.2, accuracy: accuracy)
    }

    func testBlackAndWhiteProducesGrayscale() {
        // Same input/mechanism as testSaturationMinusOneIsGrayscale, so
        // the exact same measured value applies here.
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, 0.26441, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.26441, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.26441, accuracy: accuracy)
    }

    func testBlackAndWhiteOverridesSaturationVibranceHue() {
        // Strongly non-default Saturation, Vibrance, AND Hue all set
        // simultaneously — output must STILL be grayscale, proving the
        // override takes precedence over all three, not just that B&W
        // works in isolation.
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let output = EditPipeline.apply(
            EditState(hslHue: 45, hslSaturation: 0.8, vibrance: 0.8, blackAndWhite: true),
            to: input
        )
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, pixel.g, accuracy: accuracy)
        XCTAssertEqual(pixel.g, pixel.b, accuracy: accuracy)
    }

    func testBlackAndWhitePreservesContrast() {
        // Contrast must still visibly apply to a B&W image, not be
        // silently dropped once color is removed.
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2)
        let plain = linearPixel(of: EditPipeline.apply(EditState(blackAndWhite: true), to: input))
        let contrasted = linearPixel(
            of: EditPipeline.apply(EditState(contrast: 0.5, blackAndWhite: true), to: input)
        )

        XCTAssertEqual(contrasted.r, contrasted.g, accuracy: accuracy, "still grayscale with contrast active")
        XCTAssertEqual(contrasted.g, contrasted.b, accuracy: accuracy)
        XCTAssertGreaterThan(abs(contrasted.r - plain.r), 0.01, "contrast should visibly change the B&W output")
    }

    func testBlackAndWhitePreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2, a: 0.5)
        let output = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let pixel = linearPixel(of: output)

        XCTAssertEqual(pixel.r, pixel.g, accuracy: accuracy)
        XCTAssertEqual(pixel.g, pixel.b, accuracy: accuracy)
        XCTAssertEqual(pixel.a, 0.5, accuracy: accuracy)
    }

    // MARK: - Straighten geometry
    //
    // Straighten is pure geometry (rotation around the extent's own center),
    // not color, so — like flip/crop below — these values are hand-derived
    // rather than measured from a Core Image diagnostic. The direction proof
    // uses an exact 90° rotation (avoids resampling ambiguity that an
    // arbitrary small angle would introduce) against quadrantImage's known
    // layout (top-left red, top-right green, bottom-left blue, bottom-right
    // yellow).

    func testStraightenZeroIsIdentity() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(straightenAngle: 0), to: input)

        XCTAssertEqual(output.extent, input.extent)
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "red")
    }

    func testStraightenIncreasesExtent() {
        // The pure rotated-bounding-box math (W|cosθ| + H|sinθ|) predicts
        // ≈136.60 for a 100x100 square at 30° — but the ACTUAL, MEASURED
        // CIImage extent is 138.0, a few pixels larger. Core Image pads a
        // transformed image's extent for its resampling/interpolation
        // kernel, a real implementation detail the pure geometry doesn't
        // predict — pinned here to the measured value, not the idealized
        // one, matching this project's measure-don't-assume discipline. The
        // test still proves the core claim (extent grows well beyond the
        // untransformed 100, roughly matching the rotated-bounding-box
        // scale) without over-trusting a derivation Core Image doesn't
        // exactly follow.
        let input = quadrantImage(width: 100, height: 100)
        let output = EditPipeline.apply(EditState(straightenAngle: 30), to: input)

        XCTAssertEqual(output.extent.width, 138.0, accuracy: 0.5)
        XCTAssertEqual(output.extent.height, 138.0, accuracy: 0.5)
        XCTAssertGreaterThan(output.extent.width, 136.60, "should be at least the pure-geometry bounding-box size")
    }

    func testStraightenPreservesCenterOfExtent() {
        // Rotating a rectangle around its own center always yields a
        // bounding box centered at that SAME point (provable by symmetry) —
        // this is what lets applyFlip (which runs next) still mirror around
        // the correct center after straighten grows the extent.
        let input = quadrantImage(width: 100, height: 100)
        let output = EditPipeline.apply(EditState(straightenAngle: 30), to: input)

        XCTAssertEqual(output.extent.midX, input.extent.midX, accuracy: 0.01)
        XCTAssertEqual(output.extent.midY, input.extent.midY, accuracy: 0.01)
    }

    func testStraightenRotatesCounterclockwise() {
        // Derived: at θ=90°, (x,y) ↦ (100-y, x) for a 100x100 image rotated
        // around its center (50,50). So content at output (25,75) is
        // original(75,75) = green (top-right sweeps to top-left under a CCW
        // turn); output (75,75) is original(75,25) = yellow (bottom-right
        // sweeps to top-right).
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(straightenAngle: 90), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "green")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 75)), "yellow")
    }

    func testStraightenAppliedBeforeFlip() {
        // Proves pipeline ORDERING (straighten, then flip), not just each
        // stage in isolation. At θ=90° on a 100x100 square, both stages'
        // extents stay exactly 100x100 (a lucky, exact property of a square
        // rotated by precisely 90°), making the composed math exact:
        // straighten-then-flip gives (x,y) ↦ (y,x), so output(75,75) reads
        // original(75,75) = green. The reversed (wrong) order would give
        // (x,y) ↦ (100-y,100-x), reading original(25,25) = blue at the same
        // point — a real discriminator, same pattern as
        // testFlipAppliedBeforeCrop.
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(straightenAngle: 90, flipHorizontal: true), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 75)), "green")
    }

    func testStraightenPreservesColorMath() {
        // Straighten composed with exposure: the rotated region's color
        // still reflects the exposure adjustment, proving straighten
        // doesn't interfere with the rest of the pipeline.
        let input = solidColorImage(0.2, size: 100)
        let output = EditPipeline.apply(EditState(exposureEV: 1, straightenAngle: 30), to: input)

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 50, y: 50, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        XCTAssertEqual(buffer[0], 0.4, accuracy: accuracy)
    }

    // MARK: - Perspective geometry
    //
    // Perspective (keystone) correction is pure geometry, via
    // CIPerspectiveTransform, so — like straighten/flip/crop — these values
    // are pinned to the real filter's measured behavior (a Plan agent ran
    // throwaway Core Image diagnostics), not just derived from projective-
    // geometry theory, per this project's discipline. Direction proofs
    // composite the pipeline's OUTPUT over black (overBlack, mirroring
    // ImageRenderer's own background) so the corners a taper reveals read
    // "black" rather than an ambiguous transparent pixel.

    func testPerspectiveZeroIsIdentity() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(output.extent, input.extent)
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "red")
    }

    func testPerspectivePreservesExtent() {
        // Unlike Straighten (which measurably grows the extent by ~1.4px
        // from resampling padding), perspective correction's corners only
        // move INWARD, so the extent is preserved EXACTLY — measured, not
        // assumed.
        let input = quadrantImage(width: 100, height: 100)

        let vOutput = EditPipeline.apply(EditState(verticalPerspective: 1), to: input)
        XCTAssertEqual(vOutput.extent, CGRect(x: 0, y: 0, width: 100, height: 100))

        let hOutput = EditPipeline.apply(EditState(horizontalPerspective: 1), to: input)
        XCTAssertEqual(hOutput.extent, CGRect(x: 0, y: 0, width: 100, height: 100))

        let bothOutput = EditPipeline.apply(EditState(verticalPerspective: 1, horizontalPerspective: 1), to: input)
        XCTAssertEqual(bothOutput.extent, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(pixel(of: bothOutput, at: 50, 50).a, 1, "center should stay covered/convex even at the combined cap")
    }

    func testPerspectiveVerticalDirection() {
        let input = quadrantImage()

        let plusOutput = overBlack(EditPipeline.apply(EditState(verticalPerspective: 1), to: input))
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 10, y: 90)), "black", "top tapers in")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 10, y: 10)), "blue")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 90, y: 90)), "black", "top tapers in")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 90, y: 10)), "yellow")

        let minusOutput = overBlack(EditPipeline.apply(EditState(verticalPerspective: -1), to: input))
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 10, y: 90)), "red")
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 10, y: 10)), "black", "bottom tapers in")
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 90, y: 10)), "black", "bottom tapers in")
    }

    func testPerspectiveHorizontalDirection() {
        let input = quadrantImage()

        let plusOutput = overBlack(EditPipeline.apply(EditState(horizontalPerspective: 1), to: input))
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 90, y: 90)), "black", "right tapers in")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 10, y: 90)), "red")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 90, y: 10)), "black", "right tapers in")
        XCTAssertEqual(describeColor(of: plusOutput, at: CGPoint(x: 10, y: 10)), "blue")

        let minusOutput = overBlack(EditPipeline.apply(EditState(horizontalPerspective: -1), to: input))
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 10, y: 90)), "black", "left tapers in")
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 90, y: 90)), "green")
        XCTAssertEqual(describeColor(of: minusOutput, at: CGPoint(x: 10, y: 10)), "black", "left tapers in")
    }

    func testPerspectiveCombinedIsSingleQuad() {
        // Documents that both axes compose in ONE filter call without
        // blanking the center, even at the combined cap.
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(verticalPerspective: 1, horizontalPerspective: 1), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 50, y: 50)), "blue")
        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testPerspectiveIsGeometryOnly() {
        let input = solidColorImage(0.5, size: 100)
        let output = EditPipeline.apply(EditState(verticalPerspective: 1), to: input)

        XCTAssertEqual(pixel(of: output, at: 50, 50).r, 0.5, accuracy: accuracy)
    }

    func testPerspectivePreservesHighlightHeadroom() {
        let input = solidColorImage(r: 1.4, g: 0.5, b: 0.2, a: 1, size: 100)
        let output = EditPipeline.apply(EditState(verticalPerspective: 1), to: input)
        let center = pixel(of: output, at: 50, 50)

        XCTAssertEqual(center.r, 1.4, accuracy: accuracy)
        XCTAssertGreaterThan(center.r, 1.0, "should not be clamped, unlike curves")
    }

    func testPerspectivePreservesAlpha() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 0.5, size: 100)
        let output = EditPipeline.apply(EditState(verticalPerspective: 1), to: input)
        let center = pixel(of: output, at: 50, 50)

        XCTAssertEqual(center.r, 0.15, accuracy: accuracy)
        XCTAssertEqual(center.a, 0.5, accuracy: accuracy)
    }

    func testPerspectiveMaxIsSafe() {
        // Proves the chosen kMaxPerspectiveShift (0.25) keeps even the
        // worst-case combined setting (both axes at the cap, sharing a
        // corner) convex — no NaN, no blanked center.
        let input = solidColorImage(0.5, size: 100)
        let output = EditPipeline.apply(EditState(verticalPerspective: 1, horizontalPerspective: 1), to: input)
        let center = pixel(of: output, at: 50, 50)

        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(center.r.isNaN)
        XCTAssertEqual(center.a, 1, "center should stay covered, not blanked")
    }

    func testPerspectiveAppliedBeforeFlip() {
        // Proves pipeline ORDERING (perspective, then flip), not just each
        // stage in isolation — same pattern as
        // testStraightenAppliedBeforeFlip/testFlipAppliedBeforeCrop. The
        // reversed (wrong) order would read green/black instead of
        // black/red at these same points (measured).
        let input = quadrantImage()
        let output = overBlack(
            EditPipeline.apply(EditState(horizontalPerspective: 1, flipHorizontal: true), to: input)
        )

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 10, y: 90)), "black")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 90, y: 90)), "red")
    }

    func testPerspectivePreservesColorMath() {
        // Perspective composed with exposure: a covered interior pixel
        // still reflects the exposure adjustment, proving perspective
        // doesn't interfere with the rest of the pipeline.
        let input = solidColorImage(0.2, size: 100)
        let output = EditPipeline.apply(EditState(exposureEV: 1, verticalPerspective: 1), to: input)

        XCTAssertEqual(pixel(of: output, at: 50, 20).r, 0.4, accuracy: accuracy)
    }

    // MARK: - Flip geometry
    //
    // Flip is pure geometry (mirrors around the extent's own center), not
    // color, so — like crop below — these values are hand-computable rather
    // than measured from a Core Image diagnostic. Direction proofs use the
    // same empirically-verified quadrantImage ground truth crop's own tests
    // use (top-left red, top-right green, bottom-left blue, bottom-right
    // yellow).

    func testFlipFalseIsIdentity() {
        let input = solidColorImage(0.35)
        let output = EditPipeline.apply(EditState(flipHorizontal: false, flipVertical: false), to: input)
        XCTAssertEqual(linearPixel(of: output).r, linearPixel(of: input).r, accuracy: accuracy)
    }

    func testFlipHorizontalMirrorsLeftRight() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(flipHorizontal: true), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "green", "was top-left, now shows top-right's original color")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 75)), "red", "was top-right, now shows top-left's original color")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 25)), "yellow", "was bottom-left, now shows bottom-right's original color")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 25)), "blue", "was bottom-right, now shows bottom-left's original color")
    }

    func testFlipVerticalMirrorsTopBottom() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(flipVertical: true), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "blue", "was top-left, now shows bottom-left's original color")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 25)), "red", "was bottom-left, now shows top-left's original color")
    }

    func testFlipBothAxesMirrorsDiagonally() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(flipHorizontal: true, flipVertical: true), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 25, y: 75)), "yellow", "top-left now shows the diagonally-opposite bottom-right color")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 75, y: 25)), "red", "bottom-right now shows the diagonally-opposite top-left color")
    }

    func testFlipPreservesExtent() {
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(flipHorizontal: true, flipVertical: true), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testFlipAppliedBeforeCrop() {
        // Proves pipeline ORDERING (flip, then crop), not just each stage in
        // isolation: crop-then-flip (the wrong order) would read green/
        // yellow at these exact points instead — see the plan's derivation.
        let input = quadrantImage()
        let output = EditPipeline.apply(EditState(flipHorizontal: true, cropInsetLeft: 0.5), to: input)

        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 60, y: 75)), "red")
        XCTAssertEqual(describeColor(of: output, at: CGPoint(x: 60, y: 25)), "blue")
    }

    func testFlipPreservesColorMath() {
        // Flip composed with exposure: the mirrored region's color still
        // reflects the exposure adjustment, proving flip doesn't interfere
        // with the rest of the pipeline.
        let input = solidColorImage(0.2, size: 100)
        let output = EditPipeline.apply(EditState(exposureEV: 1, flipHorizontal: true), to: input)

        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 10, y: 10, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        XCTAssertEqual(buffer[0], 0.4, accuracy: accuracy)
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

    func testGeometryStagesScaleProportionallyOnADownscaledSource() {
        // The entire premise IMPROVEMENTS.md P2's interactive-drag preview
        // proxy (ProxyScale/ProxyBuilder) rests on: every extent-dependent
        // stage derives its geometry as a FRACTION of the current extent,
        // so running the pipeline on a proportionally-downscaled source
        // produces a proportionally-scaled OUTPUT EXTENT — the same
        // argument ThumbnailGenerator's edited-thumbnail overload already
        // documents and ships. This test pins exactly that: the extent, for
        // the three stages that mutate it together (straighten grows it,
        // perspective preserves it, crop shrinks it). It does NOT cover the
        // resolution-DEPENDENT divergence `ProxyScale`'s own doc comment
        // already enumerates (vignette/red-eye/Clarity/Texture/Sharpen radii,
        // none of which change extent; Noise Reduction, measured
        // resolution-independent) — those are accepted, documented preview
        // tradeoffs, not regressions this test is meant to catch.
        //
        // Tolerance is 1.5px absolute, not a relative percentage: measured
        // directly for this exact state (400/200px, scale 0.5), the real
        // deviation from perfect proportionality is a single pixel of
        // integer rounding (~0.25%) — `testStraightenIncreasesExtent`'s own
        // doc comment records Core Image padding a rotated extent by a few
        // pixels beyond the pure geometric prediction, but that padding
        // measures as EXACTLY proportional at these two sizes, not a
        // fixed-pixel offset. A loose relative tolerance (e.g. 2%) would
        // admit several pixels of real regression; 1.5px absolute is tight
        // enough to fail on that while still covering the genuine rounding.
        let scale = 0.5
        let fullSize = 400
        let full = quadrantImage(width: fullSize, height: fullSize)
        let half = quadrantImage(width: Int(Double(fullSize) * scale), height: Int(Double(fullSize) * scale))

        let state = EditState(
            straightenAngle: 10,
            verticalPerspective: 0.2,
            horizontalPerspective: -0.15,
            cropInsetTop: 0.1,
            cropInsetBottom: 0.05,
            cropInsetLeft: 0.1,
            cropInsetRight: 0.05
        )

        let fullOutput = EditPipeline.apply(state, to: full)
        let halfOutput = EditPipeline.apply(state, to: half)

        let expectedWidth = fullOutput.extent.width * scale
        let expectedHeight = fullOutput.extent.height * scale
        XCTAssertEqual(halfOutput.extent.width, expectedWidth, accuracy: 1.5)
        XCTAssertEqual(halfOutput.extent.height, expectedHeight, accuracy: 1.5)
    }

    // MARK: - Red-Eye Removal math
    //
    // Localized "suppress red + darken" correction (CIRadialGradient mask +
    // CIColorMatrix + CIBlendWithMask) — built-ins only, no custom kernel
    // needed (unlike Selective Color). Expected values are measured against
    // the real filter chain (a real compiled probe was run before this
    // shipped, matching every other feature's discipline), not hand-derived.

    func testRedEyeNoPointsIsExactNoOp() {
        // Guarded off entirely when no points are placed — exact no-op
        // including headroom, the same load-bearing guard pattern every
        // other stage in this file relies on.
        for value in [0.05, 0.214, 0.5, 0.7, 1.2, 1.4] {
            let input = solidColorImage(value)
            let output = EditPipeline.apply(EditState(), to: input)
            XCTAssertEqual(linearPixel(of: output).r, Float(value), accuracy: accuracy, "value \(value)")
        }
    }

    func testRedEyeStrengthZeroIsNoOp() {
        // A point IS placed, but strength=0 — still an exact no-op,
        // including headroom, proving the guard checks strength too, not
        // just point count.
        let input = solidColorImage(r: 1.4, g: 1.4, b: 1.4, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeStrength: 0),
            to: input
        )
        let pixel = pixel(of: output, at: 200, 200)

        XCTAssertEqual(pixel.r, 1.4, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 1.4, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 1.4, accuracy: accuracy)
    }

    func testRedEyeDesaturatesAndDarkensAtTap() {
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 1),
            to: input
        )
        let pixel = pixel(of: output, at: 200, 200)

        XCTAssertEqual(pixel.r, 0.04, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.04, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.04, accuracy: accuracy)
    }

    func testRedEyeLeavesFarPixelUnchanged() {
        // Spatial isolation: a tightly-sized correction leaves a far pixel
        // completely untouched, mirroring how Vignette's own corners stay
        // pristine at its own center.
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 0.3, redEyeStrength: 1),
            to: input
        )
        let pixel = pixel(of: output, at: 10, 10)

        XCTAssertEqual(pixel.r, 0.7, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 0.1, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 0.1, accuracy: accuracy)
    }

    func testRedEyeSoftEdgeFalloff() {
        // MEASURED monotonic, smooth transition from full correction (core)
        // to zero effect (past the radius) — not a hard-edged circle.
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 0.5, redEyeStrength: 1),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.04, accuracy: accuracy, "center")
        XCTAssertEqual(pixel(of: output, at: 209, 200).r, 0.04091, accuracy: accuracy, "still within the core")
        XCTAssertEqual(pixel(of: output, at: 215, 200).r, 0.45740, accuracy: accuracy, "mid-falloff")
        XCTAssertEqual(pixel(of: output, at: 219, 200).r, 0.7, accuracy: accuracy, "at the radius boundary")
        XCTAssertEqual(pixel(of: output, at: 230, 200).r, 0.7, accuracy: accuracy, "beyond the radius")
    }

    func testRedEyeSizeControlsReach() {
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let small = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 0.1, redEyeStrength: 1),
            to: input
        )
        let large = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 1),
            to: input
        )

        XCTAssertEqual(pixel(of: small, at: 215, 200).r, 0.7, accuracy: accuracy, "small size shouldn't reach 15px away")
        XCTAssertEqual(pixel(of: large, at: 215, 200).r, 0.04, accuracy: accuracy, "large size fully reaches 15px away")
    }

    func testRedEyeStrengthScalesCorrection() {
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let half = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 0.5),
            to: input
        )
        let full = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 1),
            to: input
        )
        let halfPixel = pixel(of: half, at: 200, 200)
        let fullPixel = pixel(of: full, at: 200, 200)

        XCTAssertEqual(halfPixel.r, 0.37, accuracy: accuracy)
        XCTAssertEqual(halfPixel.g, 0.07, accuracy: accuracy)
        XCTAssertEqual(fullPixel.r, 0.04, accuracy: accuracy)
        // Monotonic: half-strength sits strictly between no correction and full.
        XCTAssertLessThan(fullPixel.r, halfPixel.r)
        XCTAssertLessThan(halfPixel.r, 0.7)
    }

    func testRedEyeOverlappingPointsCorrectOnce() {
        // The test that actually proves the union-mask design decision:
        // two overlapping points' shared region is corrected exactly ONCE
        // (close to a single point's own effect there), NOT twice —
        // MEASURED: sequential double-application at this same setup gives
        // a much darker, over-corrected 0.061 instead.
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let overlapping = EditPipeline.apply(
            EditState(
                redEyePoints: [RedEyePoint(x: 0.45, y: 0.5), RedEyePoint(x: 0.55, y: 0.5)],
                redEyeSize: 1, redEyeStrength: 1
            ),
            to: input
        )
        let pixel = pixel(of: overlapping, at: 200, 200)

        XCTAssertEqual(pixel.r, 0.18464, accuracy: accuracy)
        XCTAssertGreaterThan(pixel.r, 0.1, "should NOT be over-corrected toward the sequential-compositing 0.061 result")
    }

    func testRedEyePreservesAlpha() {
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 0.5, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 1),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.5, accuracy: accuracy, "corrected pixel")
        XCTAssertEqual(pixel(of: output, at: 10, 10).a, 0.5, accuracy: accuracy, "untouched pixel")
    }

    func testRedEyePreservesHeadroomOutsideMask() {
        // A bright pixel far from every point survives exactly — the SAME
        // headroom-preservation family as Vignette/Sharpen for untouched
        // content. (A bright pixel INSIDE an active mask is, by design,
        // reduced toward a dark corrected value — see
        // testRedEyeDesaturatesAndDarkensAtTap — that reduction IS the
        // feature, not a headroom bug.)
        let input = solidColorImage(r: 1.4, g: 1.4, b: 1.4, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(redEyePoints: [RedEyePoint(x: 0.1, y: 0.1)], redEyeSize: 0.1, redEyeStrength: 1),
            to: input
        )
        let pixel = pixel(of: output, at: 200, 200)

        XCTAssertEqual(pixel.r, 1.4, accuracy: accuracy)
        XCTAssertEqual(pixel.g, 1.4, accuracy: accuracy)
        XCTAssertEqual(pixel.b, 1.4, accuracy: accuracy)
    }

    func testRedEyeCentersOnCroppedExtent() {
        // MEASURED: like Vignette, a stored normalized point maps against
        // the CURRENT (post-crop) extent, not the original frame — and the
        // stage preserves the crop's own extent exactly.
        let input = quadrantImage(width: 100, height: 100)
        let cropOnly = EditPipeline.apply(EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1), to: input)
        let withRedEye = EditPipeline.apply(
            EditState(
                cropInsetTop: 0.25, cropInsetLeft: 0.1,
                redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 0.1, redEyeStrength: 1
            ),
            to: input
        )

        XCTAssertEqual(withRedEye.extent, cropOnly.extent)
    }

    // MARK: - Local Adjustments (Masks) math
    //
    // Radial (ellipse, Phase 7 slice 2) and Linear (graduated, slice 3)
    // local adjustments. Runs after Red-Eye, before Vignette (see
    // `EditPipeline.applyMasks`'s own doc comment). Most assertions here
    // are EQUIVALENCE checks against the
    // corresponding GLOBAL slider (a full-image-covering mask must produce
    // the exact same pixels as the identically-valued global field, since
    // both funnel through the same private filter functions) rather than
    // hand-derived magic numbers — a stronger, self-verifying guarantee
    // than a probed constant, and the direct proof that a mask's value of
    // X really does mean the same thing as the global slider's value of X.
    // The soft-edge falloff, rotation, and y-down-convention tests DO use
    // real measured numbers (via a temporary standalone probe mirroring
    // `applyMasks`' exact filter chain, then discarded), matching this
    // file's own Red-Eye/Vignette precedent for genuinely spatial claims.

    /// A mask whose ellipse is far larger than any test image (radius 2.0,
    /// i.e. 2x the full extent on each axis) so every sampled point away
    /// from the extreme corners sits deep in the mask's fully-opaque core —
    /// the direct analog of a "global" adjustment for equivalence testing,
    /// without needing a second combining/full-coverage code path.
    private func fullyCoveringMask(
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        Mask(
            centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, rotationDegrees: 0, feather: 0.5,
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    // MARK: Guards / no-op

    func testIdentityParamMaskIsExactNoOp() {
        // A mask IS placed (real, non-default geometry) but every
        // adjustment param is at its identity (0) -- must render
        // byte-identical to no mask at all, the guarantee the mask-level
        // `isIdentity` skip exists to provide.
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let withMask = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.4, centerY: 0.6, radiusX: 0.3, radiusY: 0.15, rotationDegrees: 20, feather: 0.2)]),
            to: input
        )
        let withoutMask = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).g, pixel(of: withoutMask, at: 200, 200).g, accuracy: accuracy)
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).b, pixel(of: withoutMask, at: 200, 200).b, accuracy: accuracy)
    }

    func testMaskWithDegenerateZeroRadiusIsSkippedNotCrashed() {
        // radiusX=0 -> RadialMaskGeometry.resolve returns nil -> applyMasks
        // `continue`s past this mask entirely, rather than crashing or
        // dividing by zero.
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0, radiusY: 0.2, exposureEV: 1)]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.7, accuracy: accuracy)
    }

    // MARK: Geometry

    func testMaskExposureBrightensInsideTheEllipseAndLeavesFarPixelUnchanged() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.15, radiusY: 0.15, feather: 0.3, exposureEV: 1)]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.4, accuracy: accuracy, "center: 0.2 * 2^1")
        XCTAssertEqual(pixel(of: output, at: 10, 10).r, 0.2, accuracy: accuracy, "far corner: untouched")
    }

    func testMaskSoftEdgeFalloffIsMonotonic() {
        // MEASURED (temporary standalone probe mirroring applyMasks' exact
        // filter chain, discarded before commit) -- circle mask, radius
        // 0.2*400=80px, feather 0.5 -> inner (fully-opaque) radius 40px.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5, exposureEV: 1)]),
            to: input
        )

        let center = pixel(of: output, at: 200, 200).r
        let withinCore = pixel(of: output, at: 235, 200).r
        let midFalloff1 = pixel(of: output, at: 245, 200).r
        let midFalloff2 = pixel(of: output, at: 260, 200).r
        let atBoundary = pixel(of: output, at: 280, 200).r
        let beyond = pixel(of: output, at: 300, 200).r

        XCTAssertEqual(center, 0.4, accuracy: accuracy, "center")
        XCTAssertEqual(withinCore, 0.4, accuracy: accuracy, "still within the opaque core (35px < 40px inner)")
        XCTAssertEqual(midFalloff1, 0.37249, accuracy: accuracy, "mid-falloff")
        XCTAssertEqual(midFalloff2, 0.29749, accuracy: accuracy, "mid-falloff")
        XCTAssertEqual(atBoundary, 0.2, accuracy: accuracy, "at the radius boundary")
        XCTAssertEqual(beyond, 0.2, accuracy: accuracy, "beyond the radius")

        // The test's own name claim, not just fixed probed values: strictly
        // monotonic decay from the opaque core down to the untouched value.
        XCTAssertGreaterThanOrEqual(center, withinCore)
        XCTAssertGreaterThan(withinCore, midFalloff1)
        XCTAssertGreaterThan(midFalloff1, midFalloff2)
        XCTAssertGreaterThan(midFalloff2, atBoundary)
        XCTAssertEqual(atBoundary, beyond, accuracy: accuracy, "flat once past the radius")
    }

    func testMaskEllipseReachesFartherAlongTheWiderAxis() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.1, feather: 0.3, exposureEV: 2)]),
            to: input
        )

        XCTAssertGreaterThan(pixel(of: output, at: 300, 200).r, 0.2, "100px along the WIDE (radiusX) axis should be measurably affected")
        XCTAssertEqual(pixel(of: output, at: 200, 300).r, 0.2, accuracy: accuracy, "100px along the NARROW (radiusY) axis should be untouched")
    }

    func testMaskRotationSwapsWhichAxisIsAffected() {
        // MEASURED: at rotation 0 the wide axis reaches x=300 but not
        // y=300; at rotation 90 the SAME two points swap roles exactly
        // (0.5247511 either way) -- confirms the whole ellipse rotated,
        // not just a label.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var mask = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.1, feather: 0.3, exposureEV: 2)

        let rot0 = EditPipeline.apply(EditState(masks: [mask]), to: input)
        XCTAssertEqual(pixel(of: rot0, at: 300, 200).r, 0.52475, accuracy: accuracy, "rotation 0, wide axis")
        XCTAssertEqual(pixel(of: rot0, at: 200, 300).r, 0.2, accuracy: accuracy, "rotation 0, narrow axis")

        mask.rotationDegrees = 90
        let rot90 = EditPipeline.apply(EditState(masks: [mask]), to: input)
        XCTAssertEqual(pixel(of: rot90, at: 300, 200).r, 0.2, accuracy: accuracy, "rotation 90: now unaffected")
        XCTAssertEqual(pixel(of: rot90, at: 200, 300).r, 0.52475, accuracy: accuracy, "rotation 90: now affected")
    }

    func testMaskCenterUsesTopLeftYDownConvention() {
        // MEASURED: a pure-red 100x100 image, mask centered at UI (0.25,
        // 0.25) -- if the y-flip were wrong (mapping to CIImage y=25
        // instead of the correct y=75), this would darken the WRONG
        // corner. exposureEV=-3 gives an exact, hand-checkable 1.0*2^-3.
        let redColor = CIColor(red: 1, green: 0, blue: 0, colorSpace: linearSpace)!
        let input = CIImage(color: redColor).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.25, centerY: 0.25, radiusX: 0.15, radiusY: 0.15, feather: 0.3, exposureEV: -3)]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 25, 75).r, 0.125, accuracy: accuracy, "visual top-left (UI y=0.25) must be darkened")
        XCTAssertEqual(pixel(of: output, at: 25, 25).r, 1.0, accuracy: accuracy, "visual bottom-left must be untouched")
    }

    func testMaskCentersOnCroppedExtent() {
        // Like Red-Eye/Vignette, a stored normalized center maps against the
        // CURRENT (post-crop) extent, not the original frame. Reviewer-
        // strengthened (round 2): the ORIGINAL version of this test only
        // checked extent equality, which would not catch `applyMasks` ever
        // moving to run BEFORE crop — mirrors
        // `testVignetteCentersOnCroppedExtent`'s stronger precedent (same
        // exact crop configuration, same established crop-relative center
        // (55, 37) for a 100x100 source) with an actual rendered-value
        // check, not just extent.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 100)
        let cropOnly = EditPipeline.apply(EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1), to: input)
        let withMask = EditPipeline.apply(
            EditState(
                cropInsetTop: 0.25, cropInsetLeft: 0.1,
                masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, exposureEV: 1)]
            ),
            to: input
        )

        XCTAssertEqual(withMask.extent, cropOnly.extent)
        XCTAssertEqual(pixel(of: withMask, at: 55, 37).r, 0.4, accuracy: accuracy, "mask centers on the CROP's own center, not the original frame's")
    }

    func testMaskGeometryIsProportionalUnderDownscale() {
        // The direct guard on ProxyScale.swift's constraint: the SAME
        // EditState applied to two differently-sized sources must produce
        // the same value at the same FRACTIONAL sample point, since P2's
        // interactive preview renders the whole pipeline on a
        // proportionally-downscaled source.
        let state = EditState(masks: [
            Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.3, exposureEV: 1)
        ])
        let small = EditPipeline.apply(state, to: solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 200))
        let large = EditPipeline.apply(state, to: solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400))

        // Sample the same fraction of each image (0.5 + 0.05, 0.5) -- an
        // offset inside the falloff zone on both, where a proportionality
        // bug (absolute-pixel geometry) would show up as a mismatch.
        XCTAssertEqual(
            pixel(of: small, at: 110, 100).r, pixel(of: large, at: 220, 200).r,
            accuracy: accuracy
        )
    }

    // MARK: Global-equivalence (proves each param reuses its global stage's exact filter)

    func testMaskExposureMatchesGlobalExposure() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(exposureEV: 1.2)]), to: input)
        let global = EditPipeline.apply(EditState(exposureEV: 1.2), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskContrastMatchesGlobalContrastInsideTheEllipse() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(contrast: 0.5)]), to: input)
        let global = EditPipeline.apply(EditState(contrast: 0.5), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskContrastSaturationShadowsHighlightsAreClampedToUnitRange() {
        // Reviewer-mandated (round 1): unlike Exposure/Temperature/Tint (all
        // measured to degrade gracefully, matching the global sliders' own
        // unclamped convention), Contrast/Shadows/Highlights/Saturation MUST
        // clamp to -1...1 like `effectiveTone(_:)` already does for the
        // global path -- an unclamped factor can drive `CIColorControls`
        // negative, inverting hue/channels. This slice ships with no UI, so
        // a hand-authored sidecar is the only input path and nothing else
        // bounds these values; pin the clamp itself so a future refactor
        // that drops it fails a test, not just a live-authored sidecar.
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let atLimit = EditPipeline.apply(EditState(masks: [fullyCoveringMask(contrast: 1)]), to: input)
        let wayOverLimit = EditPipeline.apply(EditState(masks: [fullyCoveringMask(contrast: 5)]), to: input)

        XCTAssertEqual(
            pixel(of: atLimit, at: 200, 200).r, pixel(of: wayOverLimit, at: 200, 200).r, accuracy: accuracy,
            "contrast: 5 must render identically to contrast: 1, not push further"
        )
    }

    func testMaskShadowsMatchesGlobalCurvesShadows() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(shadows: 0.6)]), to: input)
        let global = EditPipeline.apply(EditState(curvesShadows: 0.6), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskHighlightsMatchesGlobalCurvesHighlights() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(highlights: -0.6)]), to: input)
        let global = EditPipeline.apply(EditState(curvesHighlights: -0.6), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskSaturationMatchesGlobalHslSaturation() {
        let input = solidColorImage(r: 0.6, g: 0.3, b: 0.2, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(saturation: 0.7)]), to: input)
        let global = EditPipeline.apply(EditState(hslSaturation: 0.7), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskTemperatureShiftMatchesGlobalTemperatureFromNeutral() {
        // mask.temperature is a KELVIN OFFSET from neutral (6500), not an
        // absolute value -- +1500 must match the global field's absolute
        // 8000 exactly, since both feed the identical `whiteBalanced` call.
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(temperature: 1500)]), to: input)
        let global = EditPipeline.apply(EditState(whiteBalanceTemperature: 8000), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).b, pixel(of: global, at: 200, 200).b, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testMaskTintMatchesGlobalTint() {
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(tint: 40)]), to: input)
        let global = EditPipeline.apply(EditState(whiteBalanceTint: 40), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).g, pixel(of: global, at: 200, 200).g, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).g, pixel(of: input, at: 200, 200).g, "sanity: a real effect happened")
    }

    // MARK: Clarity (the one extent-sensitive param -- CLAUDE.md's Phase 7 "Hazard 1")

    func testMaskClarityMatchesGlobalClarityAndScalesWithExtent() {
        // A full-covering mask's Clarity must match global Clarity
        // EXACTLY at several sizes -- this fails immediately if a future
        // change narrows the input to the mask's own bounding box instead
        // of the full extent (which would silently change the radius).
        for size in [400, 800, 1600] {
            let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: size)
            let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(clarity: 1)]), to: input)
            let global = EditPipeline.apply(EditState(clarity: 1), to: input)

            XCTAssertEqual(
                edgePixel(of: masked, x: size / 2 + 30, size: size).r,
                edgePixel(of: global, x: size / 2 + 30, size: size).r,
                accuracy: accuracy, "size \(size)"
            )
        }
    }

    // MARK: Composition (sequential, compounding -- deliberately unlike Red-Eye's union)

    func testMasksApplySequentiallyAndCompoundInOverlappingRegions() {
        // MEASURED: two +1EV masks, centers 120px apart each with radius
        // ~120px. Far from both: untouched (0.2). Inside only the first:
        // exactly 2x (0.4). Inside BOTH (the overlap): exactly 4x (0.8) --
        // the second mask's correction computed on top of the first's
        // already-brightened result, unlike Red-Eye's union-then-correct-
        // once design.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(centerX: 0.35, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1),
                Mask(centerX: 0.65, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
            ]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 0, 200).r, 0.2, accuracy: accuracy, "far from both masks")
        XCTAssertEqual(pixel(of: output, at: 100, 200).r, 0.4, accuracy: accuracy, "only the first mask")
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.8, accuracy: accuracy, "both masks -- compounded 2x * 2x")
    }

    func testTwoMasksInReverseOrderProduceDifferentResults() {
        // Contrast (perceptual domain) and Exposure (scene-linear) don't
        // commute in general -- the same "two mechanisms in different
        // domains" reasoning `applyPerceptualAdjustments` already
        // documents for Brightness-vs-Contrast. MEASURED: 0.69886 vs
        // 0.88281 for these specific values, confirmed genuinely different
        // (not a near-miss of the tolerance).
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let contrastMask = fullyCoveringMask(contrast: 0.5)
        let exposureMask = fullyCoveringMask(exposureEV: 1)

        let contrastThenExposure = EditPipeline.apply(EditState(masks: [contrastMask, exposureMask]), to: input)
        let exposureThenContrast = EditPipeline.apply(EditState(masks: [exposureMask, contrastMask]), to: input)

        XCTAssertEqual(pixel(of: contrastThenExposure, at: 200, 200).r, 0.69886, accuracy: accuracy)
        XCTAssertEqual(pixel(of: exposureThenContrast, at: 200, 200).r, 0.88281, accuracy: accuracy)
    }

    func testMaskPerceptualSandwichFoldingMatchesTwoAdjacentSandwiches() {
        // The claim behind folding Contrast/Saturation/Clarity into ONE
        // shared encode/decode round trip (rather than each opening its
        // own): since `decodeToLinear(encodeToPerceptual(x)) == x` exactly
        // (documented, `applyPerceptualAdjustments`'s own doc comment),
        // ONE combined mask must produce the SAME result as TWO separate,
        // same-geometry masks each carrying one param. Both sides only use
        // the public EditState/EditPipeline API.
        let input = solidColorImage(r: 0.4, g: 0.25, b: 0.2, a: 1, size: 400)
        let combined = fullyCoveringMask(contrast: 0.4, saturation: 0.5)
        let separateContrast = fullyCoveringMask(contrast: 0.4)
        let separateSaturation = fullyCoveringMask(saturation: 0.5)

        let folded = EditPipeline.apply(EditState(masks: [combined]), to: input)
        let adjacent = EditPipeline.apply(EditState(masks: [separateContrast, separateSaturation]), to: input)

        XCTAssertEqual(pixel(of: folded, at: 200, 200).r, pixel(of: adjacent, at: 200, 200).r, accuracy: accuracy)
        XCTAssertEqual(pixel(of: folded, at: 200, 200).g, pixel(of: adjacent, at: 200, 200).g, accuracy: accuracy)
        XCTAssertEqual(pixel(of: folded, at: 200, 200).b, pixel(of: adjacent, at: 200, 200).b, accuracy: accuracy)
    }

    // MARK: Invariants

    func testMaskPreservesExtentExactly() {
        let input = solidColorImage(0.5, size: 400)
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testMaskPreservesAlpha() {
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 0.5, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, exposureEV: 1)]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.5, accuracy: accuracy, "masked pixel")
        XCTAssertEqual(pixel(of: output, at: 10, 10).a, 0.5, accuracy: accuracy, "untouched pixel")
    }

    func testMaskPreservesHeadroomOutsideTheEllipse() {
        let input = solidColorImage(r: 1.4, g: 1.4, b: 1.4, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(centerX: 0.1, centerY: 0.1, radiusX: 0.1, radiusY: 0.1, exposureEV: 1)]),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 1.4, accuracy: accuracy)
    }

    func testMaskShadowsPreservesHeadroomInsideTheEllipse() {
        // Per-mask Shadows/Highlights route through the SAME applyCurves, so
        // the headroom fix reaches them with no per-mask code change. The
        // second assertion is the one that matters and is unchanged: a mask
        // must still read identically to the global slider — that equality
        // held under the clamp and must keep holding under the fix, which is
        // what proves both paths moved together rather than diverging.
        let input = solidColorImage(r: 1.4, g: 1.4, b: 1.4, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringMask(shadows: 0.5)]), to: input)
        let global = EditPipeline.apply(EditState(curvesShadows: 0.5), to: input)

        XCTAssertGreaterThan(pixel(of: masked, at: 200, 200).r, 1.0)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
    }

    func testMaskWhiteBalanceIsNoOpOnABlackAndWhitePhoto() {
        // Reviewer-caught gap: a mask's Temperature/Tint must not repaint
        // color into an already-forced-desaturated B&W render (see
        // `Mask.temperature`'s own doc comment for the full reasoning) --
        // this is the one param pair where a mask deliberately does NOT
        // read the same as it would on a color photo.
        let input = solidColorImage(r: 0.6, g: 0.3, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(blackAndWhite: true, masks: [fullyCoveringMask(temperature: 1500, tint: 40)]),
            to: input
        )
        let blackAndWhiteOnly = EditPipeline.apply(EditState(blackAndWhite: true), to: input)

        let masked = pixel(of: output, at: 200, 200)
        let bwOnly = pixel(of: blackAndWhiteOnly, at: 200, 200)
        XCTAssertEqual(masked.r, masked.g, accuracy: accuracy, "stays achromatic despite the mask's WB fields")
        XCTAssertEqual(masked.g, masked.b, accuracy: accuracy, "stays achromatic despite the mask's WB fields")
        XCTAssertEqual(masked.r, bwOnly.r, accuracy: accuracy, "identical to B&W with no mask at all")
    }

    // MARK: Ordering (measured adjacency, matching this file's own standard)

    func testMasksRunAfterRedEye() {
        // A mask covering a Red-Eye point must act on the ALREADY-corrected
        // pupil, not a still-red one. Proven by comparing the REAL pipeline
        // (both active together) against two manually-composed hypotheses:
        // it must match "Red-Eye then mask" and must NOT match "mask then
        // Red-Eye" -- a genuine order check, not a tautology.
        let input = solidColorImage(r: 0.7, g: 0.1, b: 0.1, a: 1, size: 400)
        let redEyeState = EditState(redEyePoints: [RedEyePoint(x: 0.5, y: 0.5)], redEyeSize: 1, redEyeStrength: 1)
        let maskState = EditState(masks: [fullyCoveringMask(saturation: -1)])

        let actual = EditPipeline.apply(
            EditState(
                redEyePoints: redEyeState.redEyePoints, redEyeSize: redEyeState.redEyeSize, redEyeStrength: redEyeState.redEyeStrength,
                masks: maskState.masks
            ),
            to: input
        )
        let redEyeThenMask = EditPipeline.apply(maskState, to: EditPipeline.apply(redEyeState, to: input))
        let maskThenRedEye = EditPipeline.apply(redEyeState, to: EditPipeline.apply(maskState, to: input))

        XCTAssertEqual(
            pixel(of: actual, at: 200, 200).r, pixel(of: redEyeThenMask, at: 200, 200).r, accuracy: accuracy,
            "the real pipeline must match the Red-Eye-then-mask composition"
        )
        XCTAssertNotEqual(
            pixel(of: actual, at: 200, 200).r, pixel(of: maskThenRedEye, at: 200, 200).r,
            "and must NOT match the reverse composition -- proves the order is load-bearing"
        )
    }

    func testMasksRunBeforeVignette() {
        // MEASURED commutation, using Contrast specifically (not Exposure --
        // a pure scalar multiply commutes trivially with Vignette's own
        // per-pixel multiplicative falloff, the same reason Red-Eye and
        // Sharpen were separately measured to commute with Vignette; that
        // is NOT evidence masks-vs-Vignette commute in general). Contrast
        // is perceptual-domain/nonlinear -- the same domain-crossing
        // reasoning `applyClarity`'s own doc comment gives for why IT
        // doesn't cleanly commute with Vignette either. Sampled near a
        // CORNER (not dead-center, where Vignette is itself near a no-op).
        let input = solidColorImage(r: 0.7, g: 0.7, b: 0.7, a: 1, size: 400)
        let actualOrder = EditPipeline.apply(
            EditState(masks: [fullyCoveringMask(contrast: 0.6)], vignetteStrength: 0.8),
            to: input
        )
        // Positive half (reviewer-caught): prove the REAL pipeline actually
        // equals the shipped masks-then-Vignette composition, not just that
        // it differs from the ONE specific reverse composed here — a
        // NotEqual-only check leaves other placements unfalsified (crop-
        // relative correctness specifically is `testMaskCentersOnCroppedExtent`'s
        // job, not this test's).
        let maskThenVignetteComposed = EditPipeline.apply(
            EditState(vignetteStrength: 0.8),
            to: EditPipeline.apply(EditState(masks: [fullyCoveringMask(contrast: 0.6)]), to: input)
        )
        // Hypothetical reverse: Vignette computed on the ORIGINAL input,
        // then the mask's own contrast applied on top of THAT.
        let vignetteOnly = EditPipeline.apply(EditState(vignetteStrength: 0.8), to: input)
        let reverseOrder = EditPipeline.apply(EditState(masks: [fullyCoveringMask(contrast: 0.6)]), to: vignetteOnly)

        XCTAssertEqual(
            pixel(of: actualOrder, at: 40, 40).r, pixel(of: maskThenVignetteComposed, at: 40, 40).r, accuracy: accuracy,
            "the real pipeline must match the masks-then-Vignette composition"
        )
        XCTAssertNotEqual(
            pixel(of: actualOrder, at: 40, 40).r, pixel(of: reverseOrder, at: 40, 40).r,
            "and must NOT match the reverse composition -- proves the order is load-bearing"
        )
    }

    // MARK: - Local Adjustments (Linear/graduated mask) math — Phase 7 slice 3
    //
    // Same equivalence-testing philosophy as the Radial section above:
    // most assertions compare a full-covering Linear mask against the
    // identically-valued GLOBAL slider (no new magic numbers); the
    // genuinely spatial claims (which side gets the effect at a given
    // angle, the ROI not clipping a diagonal corner, narrow-vs-wide
    // falloff steepness) use real pixel comparisons instead.

    /// A Linear mask whose transition band sits right at the very BOTTOM
    /// edge (`centerY: 1.0`, `width` at the render's own minimum) — the
    /// linear analogue of `fullyCoveringMask`'s oversized ellipse: any
    /// sampled point away from that one edge sits deep in the fully-opaque
    /// ("full effect") region, safe for equivalence testing against a
    /// global slider.
    private func fullyCoveringLinearMask(
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        Mask(
            kind: .linear, centerX: 0.5, centerY: 1.0, rotationDegrees: 0, width: LinearMaskGeometry.minimumWidth,
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    // MARK: Guards / no-op

    func testLinearIdentityParamMaskIsExactNoOp() {
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let withMask = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.4, centerY: 0.6, rotationDegrees: 20, width: 0.3)]),
            to: input
        )
        let withoutMask = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testMaskWithNonFiniteLinearGeometryIsSkippedNotCrashed() {
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: .nan, centerY: 0.5, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.7, accuracy: accuracy)
    }

    // MARK: Geometry / direction

    func testLinearMaskFullEffectAboveCenterNoneBelowAtZeroDegrees() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 200, 350).r, 0.4, accuracy: accuracy, "well past point0 (full effect)")
        XCTAssertEqual(pixel(of: output, at: 200, 50).r, 0.2, accuracy: accuracy, "well past point1 (no effect)")
    }

    func testLinearMaskOneHundredEightyDegreesSwapsWhichSideGetsTheEffect() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 180, width: 0.5, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 200, 350).r, 0.2, accuracy: accuracy, "now past point1 (no effect) -- swapped from the 0-degree case")
        XCTAssertEqual(pixel(of: output, at: 200, 50).r, 0.4, accuracy: accuracy, "now past point0 (full effect) -- swapped")
    }

    func testLinearMaskNinetyDegreesPutsFullEffectOnTheRight() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 90, width: 0.5, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 350, 200).r, 0.4, accuracy: accuracy, "well past point0 on the right (full effect)")
        XCTAssertEqual(pixel(of: output, at: 50, 200).r, 0.2, accuracy: accuracy, "well past point1 on the left (no effect)")
    }

    func testLinearMaskSoftEdgeFalloffIsMonotonic() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, exposureEV: 1)]),
            to: input
        )
        // point1 sits at y=100, point0 at y=300 (width 0.5 -> hp=100 on a
        // 400x400 extent) -- sample a rising sequence from below point1
        // to above point0 and confirm the falloff never reverses
        // direction, without pinning exact intermediate values.
        let values = [50, 120, 160, 200, 240, 280, 350].map { pixel(of: output, at: 200, $0).r }
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[index], values[index - 1] - accuracy, "falloff must be monotonically non-decreasing from bottom to top")
        }
    }

    func testLinearMaskNarrowerWidthTransitionsMoreSteeplyThanWiderWidth() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let narrow = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: LinearMaskGeometry.minimumWidth, exposureEV: 1)]),
            to: input
        )
        let wide = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 1.0, exposureEV: 1)]),
            to: input
        )
        let narrowDelta = abs(pixel(of: narrow, at: 200, 210).r - pixel(of: narrow, at: 200, 190).r)
        let wideDelta = abs(pixel(of: wide, at: 200, 210).r - pixel(of: wide, at: 200, 190).r)
        XCTAssertGreaterThan(narrowDelta, wideDelta, "a near-hard edge (minimum width) must change more over the same span than a wide, gradual band")
    }

    func testLinearMaskBrightensTheFarOpaqueCornerAtFortyFiveDegrees() {
        // The ROI-cropping regression case this whole feature's design
        // section exists to prevent: at a diagonal angle, the opaque
        // side's far corner is not axis-aligned, so a naive axis-aligned
        // band rect (instead of `LinearMaskGeometry`'s real half-plane
        // clip) would silently clip it and leave it unbrightened.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .linear, centerX: 0.5, centerY: 0.5, rotationDegrees: 45, width: 0.5, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 390, 390).r, 0.4, accuracy: accuracy, "the far opaque corner must be brightened, not clipped by the ROI")
    }

    // MARK: Global-equivalence

    func testLinearMaskExposureMatchesGlobalExposure() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(exposureEV: 1.2)]), to: input)
        let global = EditPipeline.apply(EditState(exposureEV: 1.2), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testLinearMaskContrastMatchesGlobalContrast() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(contrast: 0.5)]), to: input)
        let global = EditPipeline.apply(EditState(contrast: 0.5), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testLinearMaskShadowsMatchesGlobalCurvesShadows() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(shadows: 0.6)]), to: input)
        let global = EditPipeline.apply(EditState(curvesShadows: 0.6), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
    }

    func testLinearMaskHighlightsMatchesGlobalCurvesHighlights() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(highlights: -0.6)]), to: input)
        let global = EditPipeline.apply(EditState(curvesHighlights: -0.6), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
    }

    func testLinearMaskSaturationMatchesGlobalHslSaturation() {
        let input = solidColorImage(r: 0.6, g: 0.3, b: 0.2, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(saturation: 0.7)]), to: input)
        let global = EditPipeline.apply(EditState(hslSaturation: 0.7), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
    }

    func testLinearMaskTemperatureShiftMatchesGlobalTemperatureFromNeutral() {
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(temperature: 1500)]), to: input)
        let global = EditPipeline.apply(EditState(whiteBalanceTemperature: 8000), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).b, pixel(of: global, at: 200, 200).b, accuracy: accuracy)
    }

    func testLinearMaskTintMatchesGlobalTint() {
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(tint: 40)]), to: input)
        let global = EditPipeline.apply(EditState(whiteBalanceTint: 40), to: input)

        XCTAssertEqual(pixel(of: masked, at: 200, 200).g, pixel(of: global, at: 200, 200).g, accuracy: accuracy)
    }

    func testLinearMaskClarityMatchesGlobalClarity() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(clarity: 1)]), to: input)
        let global = EditPipeline.apply(EditState(clarity: 1), to: input)

        XCTAssertEqual(edgePixel(of: masked, x: 230, size: 400).r, edgePixel(of: global, x: 230, size: 400).r, accuracy: accuracy)
    }

    func testLinearMaskWhiteBalanceIsNoOpOnABlackAndWhitePhoto() {
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let withoutMask = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let withMask = EditPipeline.apply(
            EditState(blackAndWhite: true, masks: [fullyCoveringLinearMask(temperature: 1500, tint: 40)]),
            to: input
        )
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    // MARK: Structural

    func testLinearMaskPreservesExtentExactly() {
        let input = solidColorImage(r: 0.5, g: 0.5, b: 0.5, a: 1, size: 400)
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testLinearMaskPreservesAlpha() {
        let input = solidColorImage(r: 0.5, g: 0.5, b: 0.5, a: 0.6, size: 400)
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringLinearMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.6, accuracy: accuracy)
    }

    func testRadialAndLinearMasksCompoundSequentiallyInTheSameArray() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let radial = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 1)
        let linear = fullyCoveringLinearMask(exposureEV: 1)
        let output = EditPipeline.apply(EditState(masks: [radial, linear]), to: input)
        // Both fully cover the sampled point and each applies +1EV --
        // 0.2 * 2 * 2 = 0.8, proving the two kinds compound like any two
        // masks do, not just two of the same kind.
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.8, accuracy: accuracy)
    }

    // MARK: - Brush mask (Phase 7 slice 4)
    //
    // Freehand stroke local adjustment. Reuses `applyMasks`'s shared tone/
    // color plumbing verbatim (already covered above for `.radial`/
    // `.linear`) — these tests focus on what's genuinely NEW: the
    // `BrushMaskGeometry`-driven raster/blur path, in particular the
    // `CGBitmapContext`-y-up <-> `CIImage(cgImage:)`-row-mapping agreement
    // `brushStrokeMaskImage`'s own doc comment flags as unverified by
    // construction alone (this codebase's documented history of y-flip
    // sign bugs — Metal, Compare split). Written and checked FIRST, per
    // this slice's own plan, before any other Brush test.

    func testBrushStrokeAtTopOfFrameBrightensTopOfRenderedFrame() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(kind: .brush, feather: 0.3, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.1)], exposureEV: 1)
            ]),
            to: input
        )
        // UI y=0.1 (near the visual TOP of the frame) must flip to a HIGH
        // y sample in CIImage's bottom-left/y-up space -- if the raster's
        // row mapping were backwards, this would brighten the BOTTOM
        // instead.
        XCTAssertEqual(pixel(of: output, at: 200, 360).r, 0.4, accuracy: accuracy, "visual top (UI y=0.1) must be brightened")
        XCTAssertEqual(pixel(of: output, at: 200, 40).r, 0.2, accuracy: accuracy, "visual bottom must be untouched")
    }

    /// A large, fully-covering single-dab brush mask for equivalence tests
    /// against the identically-valued global slider — the Brush analog of
    /// `fullyCoveringMask`/`fullyCoveringLinearMask` above.
    private func fullyCoveringBrushMask(
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        Mask(
            kind: .brush, feather: 0.5, brushSize: BrushMaskGeometry.maximumSize,
            brushPoints: [BrushPoint(x: 0.5, y: 0.5)],
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    func testBrushMaskFarFromStrokeIsByteIdentical() {
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(kind: .brush, feather: 0.2, brushSize: 0.05, brushPoints: [BrushPoint(x: 0.1, y: 0.1)], exposureEV: 2)
            ]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 380, 380).r, 0.7, accuracy: accuracy, "far corner, well outside the dab, must be untouched")
    }

    func testEmptyBrushPointsIsByteIdenticalToNoMask() {
        let input = solidColorImage(r: 0.7, g: 0.3, b: 0.2, a: 1, size: 400)
        let withEmptyStroke = EditPipeline.apply(
            EditState(masks: [Mask(kind: .brush, brushPoints: [], exposureEV: 2)]),
            to: input
        )
        let withoutMask = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(pixel(of: withEmptyStroke, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testBrushMaskEdgeShowsPartialCoverageBetweenInsideAndOutsideValues() {
        // F3's RGB==alpha co-variance check: a genuinely soft edge must
        // read STRICTLY between the fully-inside and fully-outside values,
        // not snap to one or the other.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(kind: .brush, feather: 0.6, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.5)], exposureEV: 1)
            ]),
            to: input
        )
        let inside = pixel(of: output, at: 200, 200).r
        let edge = pixel(of: output, at: 260, 200).r
        let outside = pixel(of: output, at: 380, 200).r
        XCTAssertEqual(inside, 0.4, accuracy: accuracy)
        XCTAssertEqual(outside, 0.2, accuracy: accuracy)
        XCTAssertGreaterThan(edge, outside, "edge must read above the fully-outside value")
        XCTAssertLessThan(edge, inside, "edge must read below the fully-inside value")
    }

    func testBrushMaskFeatherIncreaseSoftensTheTransition() {
        // Sampled EXACTLY at the hard-edge radius (brushSize 0.15 * 400 =
        // 60px from center): a hard edge (feather 0, no blur) cuts off
        // completely right there (reads fully "outside", 0.2). A softer
        // edge (feather 1) BLEEDS the effect outward past that same
        // boundary via the Gaussian blur -- so the softer stroke must read
        // MEASURABLY closer to the fully-inside value at this exact point,
        // not further from it. (An earlier draft of this test asserted
        // the opposite direction and failed -- measured, not assumed.)
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        func edgeValue(feather: Double) -> Float {
            let output = EditPipeline.apply(
                EditState(masks: [
                    Mask(kind: .brush, feather: feather, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.5)], exposureEV: 1)
                ]),
                to: input
            )
            return pixel(of: output, at: 260, 200).r
        }
        let hard = edgeValue(feather: 0)
        let soft = edgeValue(feather: 1)
        XCTAssertEqual(hard, 0.2, accuracy: accuracy, "a hard edge has zero effect right at its own nominal boundary")
        XCTAssertGreaterThan(soft, hard, "a softer feather must bleed measurably past the hard-edge boundary")
    }

    func testBrushMaskFalloffIsMonotonicOutwardFromTheStroke() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(kind: .brush, feather: 0.8, brushSize: 0.2, brushPoints: [BrushPoint(x: 0.5, y: 0.5)], exposureEV: 1)
            ]),
            to: input
        )
        let values = [200, 230, 250, 270, 290, 320, 360].map { pixel(of: output, at: $0, 200).r }
        for index in 1..<values.count {
            XCTAssertLessThanOrEqual(values[index], values[index - 1] + accuracy, "must never brighten further away from the stroke")
        }
    }

    func testSingleClickPaintsASymmetricRoundDab() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(kind: .brush, feather: 0.3, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.5)], exposureEV: 1)
            ]),
            to: input
        )
        // Sample four points equidistant from the center along each axis --
        // a single-point stroke must be radially symmetric.
        let up = pixel(of: output, at: 200, 240).r
        let down = pixel(of: output, at: 200, 160).r
        let left = pixel(of: output, at: 160, 200).r
        let right = pixel(of: output, at: 240, 200).r
        XCTAssertEqual(up, down, accuracy: accuracy)
        XCTAssertEqual(left, right, accuracy: accuracy)
        XCTAssertEqual(up, left, accuracy: accuracy)
    }

    func testBrushMaskGeometryIsProportionalUnderDownscale() {
        // The direct guard on ProxyScale.swift's constraint, mirroring
        // `testMaskGeometryIsProportionalUnderDownscale`/`testLinearMask...`'s
        // own equivalents.
        let fullInput = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let proxyInput = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 40)
        let state = EditState(masks: [
            Mask(kind: .brush, feather: 0.3, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.5)], exposureEV: 1)
        ])
        let full = EditPipeline.apply(state, to: fullInput)
        let proxy = EditPipeline.apply(state, to: proxyInput)
        XCTAssertEqual(pixel(of: full, at: 200, 200).r, pixel(of: proxy, at: 20, 20).r, accuracy: accuracy)
    }

    func testBrushMaskExposureMatchesGlobalExposure() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringBrushMask(exposureEV: 1.2)]), to: input)
        let global = EditPipeline.apply(EditState(exposureEV: 1.2), to: input)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testBrushMaskTemperatureOnlyOnABlackAndWhitePhotoNeverReachesTheRaster() {
        // Behavioral proxy for the `guard corrected !== img else { continue }`
        // perf short-circuit: a temperature/tint-only brush mask on a B&W
        // photo has nothing to apply (the WB branch is gated off), so this
        // must render byte-identical to no mask at all -- if the raster/
        // blend pass ran anyway on a no-op `corrected`, it would still be a
        // no-op pixel-wise, but this test protects the short-circuit itself
        // from silently regressing into always-composite behavior.
        let input = solidColorImage(r: 0.5, g: 0.4, b: 0.3, a: 1, size: 400)
        let withoutMask = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let withMask = EditPipeline.apply(
            EditState(blackAndWhite: true, masks: [fullyCoveringBrushMask(temperature: 1500, tint: 40)]),
            to: input
        )
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    // MARK: - Luminance Range mask (Phase 7 slice 5)
    //
    // The first CONTENT-DERIVED mask kind: selects pixels by their own
    // luminance rather than by drawn geometry. `LuminanceRangeSelection`'s
    // own tests already cover the tone->linear mapping and threshold math
    // in isolation; these tests exercise the actual `EditPipeline`
    // integration — the Core Image filter chain, the shared adjustment
    // plumbing, and the "reads `img`, not `image`" decision.

    /// A solid gray at EXACTLY the linear luminance a target tone of 0.5
    /// maps to — guarantees full-strength (weight 1.0) selection
    /// regardless of `range`/`feather` (the target tone's own linear
    /// luminance always sits inside the plateau, even at `feather == 1`'s
    /// single-point tent apex), the Luminance Range analogue of
    /// `fullyCoveringMask`'s oversized radius. Unlike the other three
    /// kinds, there is no way to cover ALL possible luminances at once —
    /// this kind is tone-SELECTIVE by definition — so each equivalence
    /// test uses a solid image at exactly the targeted tone instead.
    private let middleGrayLinear = LuminanceRangeSelection.linearLuminance(forTone: 0.5)

    private func fullyCoveringLuminanceRangeMask(
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        Mask(
            kind: .luminanceRange, feather: 0.5, luminanceTarget: 0.5, luminanceRange: 0.3,
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    func testLuminanceRangeIdentityParamMaskIsExactNoOp() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let withMask = EditPipeline.apply(
            EditState(masks: [Mask(kind: .luminanceRange, luminanceTarget: 0.7, luminanceRange: 0.2)]),
            to: input
        )
        let withoutMask = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testLuminanceRangeOnlyAffectsMatchingTone() {
        // Two side-by-side patches at DIFFERENT luminances -- only the one
        // at the targeted tone should show the exposure boost; the other
        // must be untouched. This is the defining property of the kind.
        let matchingTone = middleGrayLinear
        let farTone = LuminanceRangeSelection.linearLuminance(forTone: 0.95)
        let left = CIColor(red: matchingTone, green: matchingTone, blue: matchingTone, colorSpace: linearSpace)!
        let right = CIColor(red: farTone, green: farTone, blue: farTone, colorSpace: linearSpace)!
        let leftHalf = CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let rightHalf = CIImage(color: right).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 400))
        let input = leftHalf.composited(over: rightHalf)

        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .luminanceRange, luminanceTarget: 0.5, luminanceRange: 0.2, exposureEV: 1)]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 100, 200).r, Float(matchingTone * 2), accuracy: accuracy, "matching tone must be boosted")
        XCTAssertEqual(pixel(of: output, at: 300, 200).r, Float(farTone), accuracy: accuracy, "far tone must be untouched")
    }

    func testLuminanceRangeResponseIsMonotonicSinglePeaked() {
        // Measures the SELECTION WEIGHT itself (output/input, since a
        // fully-selected pixel reads `original * 2^EV` and an unselected
        // one reads `original` unchanged -- the ratio isolates weight from
        // each tone's own differing raw brightness, which a plain output
        // comparison would otherwise conflate: raw output values rise
        // with tone regardless of weight, since brighter tones start from
        // a higher baseline -- an earlier version of this test measured
        // that confound instead and failed to see the real single peak.
        let target = 0.5
        // Starts at 0.05, not 0.0 -- tone 0 maps to LINEAR luminance 0
        // exactly, and this test's own output/input ratio would divide by
        // zero there.
        let tones: [Double] = [0.05, 0.2, 0.35, 0.42, 0.5, 0.58, 0.65, 0.8, 1.0]
        var values: [Float] = []
        for tone in tones {
            let linear = LuminanceRangeSelection.linearLuminance(forTone: tone)
            let input = solidColorImage(linear, size: 8)
            let output = EditPipeline.apply(
                EditState(masks: [Mask(kind: .luminanceRange, feather: 0.5, luminanceTarget: target, luminanceRange: 0.3, exposureEV: 1)]),
                to: input
            )
            values.append(linearPixel(of: output).r / Float(linear))
        }
        // Rises to a single peak (around the middle, target 0.5) then falls.
        let peakIndex = values.firstIndex(of: values.max()!)!
        for i in 1..<peakIndex {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1], "must rise toward the peak")
        }
        for i in (peakIndex + 1)..<values.count {
            XCTAssertLessThanOrEqual(values[i], values[i - 1], "must fall away from the peak")
        }
    }

    /// Reviewer-flagged: every other test in this section checks SHAPE
    /// (monotonic, endpoints, one `accuracy: 0.01` sample) but none pins
    /// the falloff's actual VALUES — swapping `CIMaskToAlpha` for a color
    /// matrix, or `CIMinimumCompositing` for `CIDarkenBlendMode`, would
    /// pass every existing test while silently changing the curve. This
    /// derives its expected weight from `LuminanceRangeSelection.resolve`
    /// directly (the same pure math the shipped branch is built from,
    /// not a hand-typed magic decimal nobody can independently verify),
    /// so it's a genuine cross-check that the Core Image render chain and
    /// the Swift threshold math agree, not a tautology against itself.
    func testLuminanceRangeExactWeightAtAPartialToneMatchesTheAnalyticFormula() {
        let target = 0.5
        let range = 0.3
        let feather = 0.5
        let partialTone = 0.375 // strictly between the lower-edge's zero and full tones (0.35...0.425)
        let sel = LuminanceRangeSelection.resolve(
            luminanceTarget: target, luminanceRange: range, feather: feather,
            extent: CGRect(x: 0, y: 0, width: 400, height: 400)
        )!
        let inputLinear = LuminanceRangeSelection.linearLuminance(forTone: partialTone)
        XCTAssertLessThan(sel.lowerZero, inputLinear, "test tone must sit inside the rising edge's transition zone")
        XCTAssertLessThan(inputLinear, sel.lowerFull, "test tone must sit inside the rising edge's transition zone")
        let expectedWeight = (inputLinear - sel.lowerZero) / (sel.lowerFull - sel.lowerZero)

        let input = solidColorImage(inputLinear, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [Mask(kind: .luminanceRange, feather: feather, luminanceTarget: target, luminanceRange: range, exposureEV: 1)]),
            to: input
        )
        // +1 EV doubles the fully-selected value; `CIBlendWithMask` linearly
        // interpolates original vs. corrected by weight, so a partial
        // weight `w` reads `input * (1 + w)`, not `input * 2`.
        let expected = inputLinear * (1 + expectedWeight)
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, Float(expected), accuracy: accuracy)
    }

    func testLuminanceRangeExposureMatchesGlobalExposure() {
        let input = solidColorImage(middleGrayLinear, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLuminanceRangeMask(exposureEV: 1.2)]), to: input)
        let global = EditPipeline.apply(EditState(exposureEV: 1.2), to: input)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testLuminanceRangeContrastMatchesGlobalContrast() {
        // Both step-edge tones (0.45/0.55) stay INSIDE the default
        // target-0.5/range-0.3/feather-0.5 mask's fully-opaque plateau
        // ([~0.425, ~0.575] in tone, per that geometry's own worked
        // example) -- unlike an arbitrary raw-linear step, this
        // guarantees BOTH sides read full-strength (weight 1.0), so the
        // equivalence comparison is exact, not approximate.
        let lo = LuminanceRangeSelection.linearLuminance(forTone: 0.45)
        let hi = LuminanceRangeSelection.linearLuminance(forTone: 0.55)
        let input = stepEdgeImage(lo: lo, hi: hi, size: 400)
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringLuminanceRangeMask(contrast: 0.5)]), to: input)
        let global = EditPipeline.apply(EditState(contrast: 0.5), to: input)
        XCTAssertEqual(pixel(of: masked, at: 50, 200).r, pixel(of: global, at: 50, 200).r, accuracy: accuracy)
    }

    func testLuminanceRangeWiderRangeSelectsMoreTones() {
        let farTone = LuminanceRangeSelection.linearLuminance(forTone: 0.75)
        let input = solidColorImage(farTone, size: 8)
        func exposedValue(range: Double) -> Float {
            let output = EditPipeline.apply(
                EditState(masks: [Mask(kind: .luminanceRange, feather: 0.5, luminanceTarget: 0.5, luminanceRange: range, exposureEV: 1)]),
                to: input
            )
            return linearPixel(of: output).r
        }
        let narrow = exposedValue(range: LuminanceRangeSelection.minimumRange)
        let wide = exposedValue(range: LuminanceRangeSelection.maximumRange)
        XCTAssertGreaterThan(wide, narrow, "a wider window must select this far-from-target tone more than a narrow one")
    }

    func testLuminanceRangeFeatherTradesPlateauWidthForGentlerShoulder() {
        // UNLIKE the Brush mask's Gaussian blur (which spreads mass PAST
        // the nominal edge, so a softer feather reads HIGHER at the
        // boundary), this kind's `lowerZero`/`upperZero` are the same
        // tone regardless of feather (only `lowerFull`/`upperFull` -- the
        // plateau's own edge -- move). So feather instead trades plateau
        // WIDTH for a gentler shoulder: at a point partway between the
        // target and the (feather-independent) outer edge, a HARD edge
        // (feather 0, whose plateau extends all the way to that outer
        // edge) reads FULL STRENGTH there, while a SOFT edge (feather 1,
        // whose plateau has shrunk to a single point at the target) is
        // already partway down its own shoulder -- the opposite direction
        // from Brush, for a real, measured, kind-specific reason.
        let target = 0.5
        let range = 0.3
        let outerHalf = range / 2
        let halfwayToneOutward = target + outerHalf * 0.5
        let sampleTone = solidColorImage(LuminanceRangeSelection.linearLuminance(forTone: halfwayToneOutward), size: 8)
        func value(feather: Double) -> Float {
            let output = EditPipeline.apply(
                EditState(masks: [Mask(kind: .luminanceRange, feather: feather, luminanceTarget: target, luminanceRange: range, exposureEV: 1)]),
                to: sampleTone
            )
            return linearPixel(of: output).r
        }
        let hard = value(feather: 0)
        let soft = value(feather: 1)
        let sampleLinear = LuminanceRangeSelection.linearLuminance(forTone: halfwayToneOutward)
        XCTAssertEqual(hard, Float(sampleLinear * 2), accuracy: 0.01, "a hard edge's plateau reaches all the way to the outer edge -- full strength at the halfway point")
        XCTAssertLessThan(soft, hard, "a softer feather's SMALLER plateau leaves this same point partway down its own shoulder")
    }

    func testLuminanceRangeWhiteBalanceIsNoOpOnABlackAndWhitePhoto() {
        let input = solidColorImage(r: middleGrayLinear, g: middleGrayLinear * 0.8, b: middleGrayLinear * 0.6, a: 1, size: 400)
        let withoutMask = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let withMask = EditPipeline.apply(
            EditState(blackAndWhite: true, masks: [fullyCoveringLuminanceRangeMask(temperature: 1500, tint: 40)]),
            to: input
        )
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testLuminanceRangePreservesExtentExactly() {
        let input = solidColorImage(middleGrayLinear, size: 400)
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringLuminanceRangeMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testLuminanceRangePreservesAlpha() {
        let color = CIColor(red: middleGrayLinear, green: middleGrayLinear, blue: middleGrayLinear, alpha: 0.6, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringLuminanceRangeMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.6, accuracy: accuracy)
    }

    /// Reviewer-caught: a SOLID input (the original form of this test) is
    /// tautological for this kind — a solid color's own per-pixel
    /// luminance is size-independent by construction, so the assertion
    /// could not fail regardless of what the branch does with `extent`.
    /// Unlike `.radial`/`.linear`/`.brush`, `.luminanceRange` has no
    /// GEOMETRIC boundary that scaling could get wrong at all — its
    /// selection depends only on each pixel's own VALUE, not its
    /// position — so the one real resolution hazard here is the one
    /// `Mask.luminanceTarget`'s own doc comment already documents:
    /// resampling could blend a sharp TONE boundary into intermediate
    /// values that fall outside the plateau. This test isolates that
    /// case directly with a step-edge image (a tone clearly OUTSIDE the
    /// window on one side, exactly AT the target on the other) and
    /// samples well inside the matching half, away from the edge, at
    /// both sizes — proving the selection is resolution-independent
    /// AWAY from a tonal edge, the actual claim worth making here.
    func testLuminanceRangeSelectionIsResolutionIndependentAwayFromATonalEdge() {
        let outsideTone = LuminanceRangeSelection.linearLuminance(forTone: 0.95)
        let matchingTone = middleGrayLinear
        let fullInput = stepEdgeImage(lo: outsideTone, hi: matchingTone, size: 400)
        let proxyInput = stepEdgeImage(lo: outsideTone, hi: matchingTone, size: 40)
        let state = EditState(masks: [fullyCoveringLuminanceRangeMask(exposureEV: 1)])
        let full = EditPipeline.apply(state, to: fullInput)
        let proxy = EditPipeline.apply(state, to: proxyInput)
        // Sample well inside the matching (right) half at each size's own
        // proportional position, far enough from the center edge that
        // downscale resampling can't blend the two tones together.
        XCTAssertEqual(pixel(of: full, at: 350, 200).r, pixel(of: proxy, at: 35, 20).r, accuracy: accuracy)
        // And confirm it's genuinely the boosted value, not a coincidental
        // match at some OTHER shared value both sizes happen to produce.
        XCTAssertEqual(pixel(of: full, at: 350, 200).r, Float(matchingTone * 2), accuracy: accuracy)
    }

    func testLuminanceRangeCompoundsSequentiallyWithARadialMask() {
        let input = solidColorImage(middleGrayLinear, size: 400)
        let radial = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 1)
        let luminance = fullyCoveringLuminanceRangeMask(exposureEV: 1)
        // LUMINANCE mask FIRST, radial SECOND -- deliberately, not an
        // arbitrary choice: the luminance mask's own selection depends on
        // the CURRENT tone (it reads `img`, not `image` -- see
        // `testLuminanceRangeSelectionFollowsEarlierMasksResult` below),
        // so placing the geometric (tone-independent) radial mask FIRST
        // would shift this patch's tone outside the luminance mask's
        // plateau before it ever got a chance to apply, confounding this
        // test's simple "both fully apply" expectation with the exact
        // order-dependence that other test is designed to isolate.
        // Ordering the tone-INDEPENDENT mask second avoids that confound.
        let output = EditPipeline.apply(EditState(masks: [luminance, radial]), to: input)
        // Both fully cover the sampled point and each applies +1EV --
        // proves the two kinds compound like any two masks do.
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, Float(middleGrayLinear * 4), accuracy: accuracy)
    }

    func testLuminanceRangeSelectionFollowsEarlierMasksResult() {
        // Reads `img` (the RUNNING loop result), not `image` (the
        // loop-invariant input): an earlier mask's own exposure boost
        // moves this solid patch's tone OUT of the Luminance Range mask's
        // narrow target window -- so the SECOND mask must see zero
        // effect, proving it measured the ALREADY-BOOSTED tone, not the
        // original one.
        let darkTone = LuminanceRangeSelection.linearLuminance(forTone: 0.2)
        let input = solidColorImage(darkTone, size: 400)
        // A first mask brightens this dark patch by +3 EV, pushing it well
        // outside the narrow window below targeted around the ORIGINAL tone.
        let brighten = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 3)
        let narrowAtOriginalTone = Mask(
            kind: .luminanceRange, feather: 0.5, luminanceTarget: 0.2, luminanceRange: LuminanceRangeSelection.minimumRange,
            exposureEV: 5
        )
        let output = EditPipeline.apply(EditState(masks: [brighten, narrowAtOriginalTone]), to: input)
        let brightenOnly = EditPipeline.apply(EditState(masks: [brighten]), to: input)
        XCTAssertEqual(
            pixel(of: output, at: 200, 200).r, pixel(of: brightenOnly, at: 200, 200).r, accuracy: accuracy,
            "the luminance mask must see the ALREADY-brightened tone (now outside its narrow window), not the original"
        )
    }

    // MARK: - Color Range mask (Phase 7 slice 5, second half)
    //
    // The second CONTENT-DERIVED mask kind: selects pixels by their own
    // color (hue + saturation + luminance JOINTLY), not drawn geometry or
    // tone alone. `ColorRangeSelection`'s own tests already cover the
    // tolerance-window/tone-mapping math and the Swift twin of
    // `ColorRange.cikernel`'s per-pixel conversion in isolation; these
    // tests exercise the actual `EditPipeline` integration — the custom
    // kernel filter chain and the shared adjustment plumbing.

    private func colorRangeTargetScalars(forLinearRGB rgb: (r: Double, g: Double, b: Double)) -> (hue: Double, sat: Double, lum: Double) {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: rgb.r, rgb.g, rgb.b)
        let lum = ColorRangeSelection.luminance(forLinearRGB: rgb.r, rgb.g, rgb.b)
        return (hue, sat, lum)
    }

    private func colorRangeMask(
        targetHue: Double, targetSaturation: Double, targetLuminance: Double,
        tolerance: Double = 0.3, feather: Double = 0.5, hasTarget: Bool = true,
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        Mask(
            kind: .colorRange, feather: feather,
            colorRangeTargetHue: targetHue, colorRangeTargetSaturation: targetSaturation,
            colorRangeTargetLuminance: targetLuminance, colorRangeTolerance: tolerance, colorRangeHasTarget: hasTarget,
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    /// A fixed saturated purple, the Color Range analogue of
    /// `middleGrayLinear` — every equivalence test below builds its mask's
    /// target directly FROM this triple's own computed hue/sat/luminance,
    /// so a solid image of this exact color always sits at distance 0
    /// (full weight) regardless of tolerance/feather.
    private let colorRangeTargetRGB: (r: Double, g: Double, b: Double) = (0.32, 0.11, 0.46)

    private func fullyCoveringColorRangeMask(
        exposureEV: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        clarity: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0
    ) -> Mask {
        let scalars = colorRangeTargetScalars(forLinearRGB: colorRangeTargetRGB)
        return colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.3, feather: 0.5,
            exposureEV: exposureEV, contrast: contrast, highlights: highlights, shadows: shadows,
            clarity: clarity, saturation: saturation, temperature: temperature, tint: tint
        )
    }

    private func colorRangeTargetImage(size: Int = 400) -> CIImage {
        solidColorImage(r: colorRangeTargetRGB.r, g: colorRangeTargetRGB.g, b: colorRangeTargetRGB.b, a: 1, size: size)
    }

    private func colorStepEdgeImage(
        loRGB: (r: Double, g: Double, b: Double), hiRGB: (r: Double, g: Double, b: Double), size: Int
    ) -> CIImage {
        let left = CIColor(red: loRGB.r, green: loRGB.g, blue: loRGB.b, colorSpace: linearSpace)!
        let right = CIColor(red: hiRGB.r, green: hiRGB.g, blue: hiRGB.b, colorSpace: linearSpace)!
        let leftHalf = CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: size / 2, height: size))
        let rightHalf = CIImage(color: right).cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return leftHalf.composited(over: rightHalf)
    }

    /// The "added but unpicked selects nothing" contract, WITH a non-zero
    /// exposure to prove it — mirrors `.brush`'s own empty-`brushPoints`
    /// no-op test.
    func testColorRangeNoTargetIsExactNoOp() {
        let input = solidColorImage(r: 0.3, g: 0.3, b: 0.3, a: 1, size: 400)
        let withMask = EditPipeline.apply(
            EditState(masks: [colorRangeMask(
                targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.2, hasTarget: false, exposureEV: 2
            )]),
            to: input
        )
        let withoutMask = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(
            pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy,
            "an un-picked mask must select nothing, even with a large exposure adjustment"
        )
    }

    func testColorRangeIdentityParamMaskIsExactNoOp() {
        let input = colorRangeTargetImage()
        let withMask = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask()]), to: input)
        let withoutMask = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testColorRangeHueSelectivityAtEqualLuma() {
        // Two colors with the SAME saturation/lightness in HSL, 150 degrees
        // apart in hue — far outside a moderate tolerance's hue window, so
        // only the exact-hue match should be selected.
        let matchRGB = ColorRangeSelection.rgb(forHue: 40, saturation: 0.8, lightness: 0.4)
        let farRGB = ColorRangeSelection.rgb(forHue: 190, saturation: 0.8, lightness: 0.4)
        let scalars = colorRangeTargetScalars(forLinearRGB: matchRGB)
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.3, feather: 0.5, exposureEV: 1
        )
        let matchOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: matchRGB.r, g: matchRGB.g, b: matchRGB.b, a: 1, size: 8)
        )
        let farOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: farRGB.r, g: farRGB.g, b: farRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: matchOutput).r, Float(matchRGB.r * 2), accuracy: accuracy, "the exact-hue match must be fully selected")
        XCTAssertEqual(linearPixel(of: farOutput).r, Float(farRGB.r), accuracy: accuracy, "a far hue must be untouched")
    }

    /// The defining test for the "3 axes jointly" decision — fails for any
    /// hue-only implementation.
    func testColorRangeDistinguishesSameHueDifferentLuminance() {
        let matchRGB = ColorRangeSelection.rgb(forHue: 100, saturation: 0.6, lightness: 0.5)
        let darkRGB = ColorRangeSelection.rgb(forHue: 100, saturation: 0.6, lightness: 0.1)
        let scalars = colorRangeTargetScalars(forLinearRGB: matchRGB)
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.2, feather: 0.5, exposureEV: 1
        )
        let matchOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: matchRGB.r, g: matchRGB.g, b: matchRGB.b, a: 1, size: 8)
        )
        let darkOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: darkRGB.r, g: darkRGB.g, b: darkRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: matchOutput).r, Float(matchRGB.r * 2), accuracy: accuracy)
        XCTAssertEqual(linearPixel(of: darkOutput).r, Float(darkRGB.r), accuracy: accuracy, "same hue but far luminance must be untouched")
    }

    func testColorRangeDistinguishesSameHueDifferentSaturation() {
        let matchRGB = ColorRangeSelection.rgb(forHue: 260, saturation: 0.9, lightness: 0.45)
        let mutedRGB = ColorRangeSelection.rgb(forHue: 260, saturation: 0.05, lightness: 0.45)
        let scalars = colorRangeTargetScalars(forLinearRGB: matchRGB)
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.2, feather: 0.5, exposureEV: 1
        )
        let matchOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: matchRGB.r, g: matchRGB.g, b: matchRGB.b, a: 1, size: 8)
        )
        let mutedOutput = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: mutedRGB.r, g: mutedRGB.g, b: mutedRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: matchOutput).r, Float(matchRGB.r * 2), accuracy: accuracy)
        XCTAssertEqual(linearPixel(of: mutedOutput).r, Float(mutedRGB.r), accuracy: accuracy, "same hue but far saturation must be untouched")
    }

    func testColorRangeNeutralTargetDoesNotSelectSaturated() {
        let grayLinear = 0.3
        let scalars = colorRangeTargetScalars(forLinearRGB: (grayLinear, grayLinear, grayLinear))
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.2, feather: 0.5, exposureEV: 1
        )
        let saturatedRGB = ColorRangeSelection.rgb(forHue: 30, saturation: 0.9, lightness: 0.4)
        let output = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: saturatedRGB.r, g: saturatedRGB.g, b: saturatedRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: output).r, Float(saturatedRGB.r), accuracy: accuracy, "a neutral target must not select a saturated pixel")
    }

    func testColorRangeSaturatedTargetDoesNotSelectNeutral() {
        let targetRGB = ColorRangeSelection.rgb(forHue: 30, saturation: 0.9, lightness: 0.4)
        let scalars = colorRangeTargetScalars(forLinearRGB: targetRGB)
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.2, feather: 0.5, exposureEV: 1
        )
        let grayLinear = 0.3
        let output = EditPipeline.apply(EditState(masks: [mask]), to: solidColorImage(grayLinear, size: 8))
        XCTAssertEqual(linearPixel(of: output).r, Float(grayLinear), accuracy: accuracy, "a saturated target must not select a neutral pixel")
    }

    /// Derives the expected weight from `ColorRangeSelection.resolve`
    /// directly (the exact formula `ColorRange.cikernel` implements,
    /// re-derived here in Swift) — the reviewer-mandated pattern from
    /// slice 5's first half: a genuine cross-check that the Core Image
    /// render chain and the Swift threshold math agree, not a tautology.
    func testColorRangeExactWeightAtAPartialMatchMatchesTheAnalyticFormula() {
        let targetRGB = ColorRangeSelection.rgb(forHue: 210, saturation: 0.8, lightness: 0.4)
        let target = colorRangeTargetScalars(forLinearRGB: targetRGB)
        let tolerance = 0.4
        let feather = 0.6
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let sel = ColorRangeSelection.resolve(
            hasTarget: true, targetHue: target.hue, targetSaturation: target.sat, targetLuminance: target.lum,
            tolerance: tolerance, feather: feather, extent: extent
        )!

        let testRGB = ColorRangeSelection.rgb(forHue: 225, saturation: 0.55, lightness: 0.3)
        let testScalars = colorRangeTargetScalars(forLinearRGB: testRGB)

        var hueDist = abs(testScalars.hue - target.hue)
        hueDist = min(hueDist, 360 - hueDist)
        let saturationAttenuation = min(testScalars.sat, target.sat)
        let dHue = (hueDist / sel.hueWindowDegrees) * saturationAttenuation
        let dSat = abs(testScalars.sat - target.sat) / sel.saturationWindow
        let dLum: Double
        if testScalars.lum < target.lum {
            dLum = (target.lum - testScalars.lum) / sel.lowerLuminanceSpan
        } else {
            dLum = (testScalars.lum - target.lum) / sel.upperLuminanceSpan
        }
        let d = (dHue * dHue + dSat * dSat + dLum * dLum).squareRoot()
        let expectedWeight = min(max((1 - d) / sel.falloffWidth, 0), 1)

        let mask = colorRangeMask(
            targetHue: target.hue, targetSaturation: target.sat, targetLuminance: target.lum,
            tolerance: tolerance, feather: feather, exposureEV: 1
        )
        let output = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: testRGB.r, g: testRGB.g, b: testRGB.b, a: 1, size: 8)
        )
        // +1 EV doubles the fully-selected value; `CIBlendWithMask`
        // linearly interpolates by weight, so a partial weight `w` reads
        // `input * (1 + w)` — the same reconstruction
        // `testLuminanceRangeExactWeightAtAPartialToneMatchesTheAnalyticFormula` uses.
        let actualWeight = Double(linearPixel(of: output).r) / testRGB.r - 1
        XCTAssertEqual(actualWeight, expectedWeight, accuracy: 0.01)
    }

    func testColorRangeWiderToleranceSelectsMore() {
        let targetRGB = ColorRangeSelection.rgb(forHue: 150, saturation: 0.7, lightness: 0.4)
        let scalars = colorRangeTargetScalars(forLinearRGB: targetRGB)
        let farRGB = ColorRangeSelection.rgb(forHue: 190, saturation: 0.7, lightness: 0.4)
        func exposedValue(tolerance: Double) -> Float {
            let mask = colorRangeMask(
                targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
                tolerance: tolerance, feather: 0.5, exposureEV: 1
            )
            let output = EditPipeline.apply(
                EditState(masks: [mask]), to: solidColorImage(r: farRGB.r, g: farRGB.g, b: farRGB.b, a: 1, size: 8)
            )
            return linearPixel(of: output).r
        }
        let narrow = exposedValue(tolerance: ColorRangeSelection.minimumTolerance)
        let wide = exposedValue(tolerance: ColorRangeSelection.maximumTolerance)
        XCTAssertGreaterThan(wide, narrow, "a wider tolerance must select this off-target hue more than a narrow one")
    }

    /// UNLIKE `.luminanceRange`'s plateau/tent split, `feather` here is
    /// used DIRECTLY as the falloff ramp's width in normalized-distance
    /// units — a distance of exactly 1 always reads zero regardless of
    /// feather; only the SHAPE of the ramp between 0 and 1 changes. A
    /// small feather (steep ramp) reads near-full-strength well past the
    /// halfway point; feather 1 (a linear ramp from center to edge) reads
    /// meaningfully less at the same distance.
    func testColorRangeFeatherTradesSteepRampForGentlerShoulder() {
        let targetRGB = ColorRangeSelection.rgb(forHue: 60, saturation: 0.9, lightness: 0.5)
        let scalars = colorRangeTargetScalars(forLinearRGB: targetRGB)
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let tolerance = 0.5
        let sel = ColorRangeSelection.resolve(
            hasTarget: true, targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: tolerance, feather: 1, extent: extent
        )!
        let halfwayHue = scalars.hue + sel.hueWindowDegrees * 0.5
        let halfwayRGB = ColorRangeSelection.rgb(forHue: halfwayHue, saturation: 0.9, lightness: 0.5)
        func value(feather: Double) -> Float {
            let mask = colorRangeMask(
                targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
                tolerance: tolerance, feather: feather, exposureEV: 1
            )
            let output = EditPipeline.apply(
                EditState(masks: [mask]), to: solidColorImage(r: halfwayRGB.r, g: halfwayRGB.g, b: halfwayRGB.b, a: 1, size: 8)
            )
            return linearPixel(of: output).r
        }
        let hard = value(feather: 0)
        let soft = value(feather: 1)
        XCTAssertGreaterThan(hard, Float(halfwayRGB.r * 1.8), "a steep (near-zero-feather) ramp reads near-full-strength at d≈0.5")
        XCTAssertLessThan(soft, hard, "feather 1's linear ramp reads meaningfully less at the same distance")
    }

    func testColorRangeExposureMatchesGlobalExposure() {
        let input = colorRangeTargetImage()
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask(exposureEV: 1.2)]), to: input)
        let global = EditPipeline.apply(EditState(exposureEV: 1.2), to: input)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
        XCTAssertNotEqual(pixel(of: masked, at: 200, 200).r, pixel(of: input, at: 200, 200).r, "sanity: a real effect happened")
    }

    func testColorRangeContrastMatchesGlobalContrast() {
        let input = colorRangeTargetImage()
        let masked = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask(contrast: 0.5)]), to: input)
        let global = EditPipeline.apply(EditState(contrast: 0.5), to: input)
        XCTAssertEqual(pixel(of: masked, at: 200, 200).r, pixel(of: global, at: 200, 200).r, accuracy: accuracy)
    }

    func testColorRangeWhiteBalanceIsNoOpOnABlackAndWhitePhoto() {
        // Unlike `.luminanceRange`'s own version of this test,
        // `fullyCoveringColorRangeMask` can't be reused directly: its
        // target is built from the ORIGINAL saturated `colorRangeTargetRGB`,
        // but `applyPerceptualAdjustments`'s forced B&W desaturation runs
        // BEFORE `applyMasks` — so the RUNNING image this mask's saturation
        // axis actually sees is already desaturated, breaking "full
        // coverage" for a saturated target. Sampling the already-desaturated
        // render and building the target from THAT keeps this test's own
        // premise (full coverage) valid.
        let input = colorRangeTargetImage()
        let withoutMask = EditPipeline.apply(EditState(blackAndWhite: true), to: input)
        let desaturatedPixel = linearPixel(of: withoutMask)
        let desaturatedScalars = colorRangeTargetScalars(
            forLinearRGB: (Double(desaturatedPixel.r), Double(desaturatedPixel.g), Double(desaturatedPixel.b))
        )
        let mask = colorRangeMask(
            targetHue: desaturatedScalars.hue, targetSaturation: desaturatedScalars.sat, targetLuminance: desaturatedScalars.lum,
            tolerance: ColorRangeSelection.maximumTolerance, feather: 0.5, temperature: 1500, tint: 40
        )
        let withMask = EditPipeline.apply(EditState(blackAndWhite: true, masks: [mask]), to: input)
        XCTAssertEqual(pixel(of: withMask, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    func testColorRangePreservesExtentExactly() {
        let input = colorRangeTargetImage()
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testColorRangePreservesAlpha() {
        let color = CIColor(
            red: colorRangeTargetRGB.r, green: colorRangeTargetRGB.g, blue: colorRangeTargetRGB.b,
            alpha: 0.6, colorSpace: linearSpace
        )!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask(exposureEV: 1)]), to: input)
        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.6, accuracy: accuracy)
    }

    func testColorRangeSelectionIsResolutionIndependentAwayFromAColorEdge() {
        let outsideRGB = ColorRangeSelection.rgb(forHue: 20, saturation: 0.8, lightness: 0.4)
        let fullInput = colorStepEdgeImage(loRGB: outsideRGB, hiRGB: colorRangeTargetRGB, size: 400)
        let proxyInput = colorStepEdgeImage(loRGB: outsideRGB, hiRGB: colorRangeTargetRGB, size: 40)
        let state = EditState(masks: [fullyCoveringColorRangeMask(exposureEV: 1)])
        let full = EditPipeline.apply(state, to: fullInput)
        let proxy = EditPipeline.apply(state, to: proxyInput)
        XCTAssertEqual(pixel(of: full, at: 350, 200).r, pixel(of: proxy, at: 35, 20).r, accuracy: accuracy)
        XCTAssertEqual(pixel(of: full, at: 350, 200).r, Float(colorRangeTargetRGB.r * 2), accuracy: accuracy)
    }

    func testColorRangeCompoundsSequentiallyWithARadialMask() {
        let input = colorRangeTargetImage()
        let radial = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 1)
        let output = EditPipeline.apply(EditState(masks: [fullyCoveringColorRangeMask(exposureEV: 1), radial]), to: input)
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, Float(colorRangeTargetRGB.r * 4), accuracy: accuracy)
    }

    func testColorRangeSelectionFollowsEarlierMasksResult() {
        // A first mask brightens this patch by +4 EV. Reviewer-corrected:
        // this does NOT merely shift luminance while leaving hue/saturation
        // untouched — `ColorRangeSelectionTests
        // .testHueSaturationIsHeadroomScaleInvariant` only demonstrates
        // scale invariance WITHIN a fixed headroom regime (both its sample
        // colors already have `maxChannel >= 1`); `colorRangeTargetRGB`
        // (max channel 0.46) starts BELOW that boundary, so a x16 scale
        // crosses it — `scale = max(maxChannel, 1.0)` flips from a real
        // division to a no-op, so measured hue stays fixed (276°) but
        // SATURATION also shifts (0.614 -> 1.0), on top of the (much
        // larger) luminance shift. Either alone would push this patch
        // outside a narrow window; both are outside it here, but the
        // point being tested is unaffected: the second mask must measure
        // the ALREADY-brightened color, not the original, the same
        // "reads `img`, not `image`" contract `.luminanceRange` already
        // established.
        let input = colorRangeTargetImage()
        let brighten = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 4)
        let scalars = colorRangeTargetScalars(forLinearRGB: colorRangeTargetRGB)
        let narrowAtOriginalColor = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: ColorRangeSelection.minimumTolerance, feather: 0, exposureEV: 5
        )
        let output = EditPipeline.apply(EditState(masks: [brighten, narrowAtOriginalColor]), to: input)
        let brightenOnly = EditPipeline.apply(EditState(masks: [brighten]), to: input)
        XCTAssertEqual(
            pixel(of: output, at: 200, 200).r, pixel(of: brightenOnly, at: 200, 200).r, accuracy: accuracy,
            "the color-range mask must see the ALREADY-brightened color (now outside its narrow luminance window), not the original"
        )
    }

    /// The direct `EditPipeline`-level port of `SelectiveColor.cikernel`'s
    /// real shipped bug — the single most important test in this section:
    /// a colored HEADROOM pixel (max channel > 1) must still be selectable
    /// by its own hue/saturation once headroom-normalized, not silently a
    /// no-op from an unnormalized HSL saturation denominator going negative.
    func testColorRangeColoredHeadroomPixelSelection() {
        let headroomRGB: (r: Double, g: Double, b: Double) = (2.4, 0.3, 0.2)
        let scalars = colorRangeTargetScalars(forLinearRGB: headroomRGB)
        let mask = colorRangeMask(
            targetHue: scalars.hue, targetSaturation: scalars.sat, targetLuminance: scalars.lum,
            tolerance: 0.2, feather: 0.5, exposureEV: 1
        )
        let output = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: headroomRGB.r, g: headroomRGB.g, b: headroomRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: output).r, Float(headroomRGB.r * 2), accuracy: 0.01, "a headroom-colored pixel must self-select at full weight")
    }

    func testColorRangeHeadroomPreservedOutsideSelection() {
        let headroomRGB: (r: Double, g: Double, b: Double) = (2.4, 0.3, 0.2)
        let farScalars = colorRangeTargetScalars(forLinearRGB: (0.1, 0.1, 0.5))
        let mask = colorRangeMask(
            targetHue: farScalars.hue, targetSaturation: farScalars.sat, targetLuminance: farScalars.lum,
            tolerance: 0.1, feather: 0.5, exposureEV: 1
        )
        let output = EditPipeline.apply(
            EditState(masks: [mask]), to: solidColorImage(r: headroomRGB.r, g: headroomRGB.g, b: headroomRGB.b, a: 1, size: 8)
        )
        XCTAssertEqual(linearPixel(of: output).r, Float(headroomRGB.r), accuracy: 0.01, "an unmatched headroom pixel must keep its headroom exactly, unclamped")
    }

    // MARK: - Combining masks (intersect/subtract) — Phase 7 slice 6
    //
    // A mask's own selection can additionally be narrowed (`.intersect`)
    // or have another mask's shape removed from it (`.subtract`), via
    // `Mask.combineWithMaskID` naming that other mask (see
    // `EditPipeline.applyMasks`'s own doc comment for the full semantics).
    // THE PRIMARY REGRESSION GATE FOR THIS SECTION IS NOT A NEW TEST — it
    // is that every existing mask test above (radial/linear/brush/
    // luminanceRange/colorRange/composition, ~90 tests) passes with ZERO
    // edits: they all run at the default `combineMode == .none`, and the
    // `resolveMaskGeometry`/`maskImageAndRegion` extraction plus the
    // `if mask.combineMode != .none` guard around the new combine block
    // are what make that a real proof of byte-identity, not an
    // assumption. If any existing expected value ever needs to change to
    // keep this file green, the REFACTOR is wrong — revert and
    // re-extract, don't edit the test.

    func testCombineModeNoneWithATargetSetIsByteIdenticalToNoCombineAtAll() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .none
        consumer.combineWithMaskID = operand.id // set, but must be IGNORED since mode is .none
        let withTargetSet = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        var bareConsumer = consumer
        bareConsumer.combineWithMaskID = nil
        let withoutTarget = EditPipeline.apply(EditState(masks: [operand, bareConsumer]), to: input)

        XCTAssertEqual(pixel(of: withTargetSet, at: 200, 200).r, pixel(of: withoutTarget, at: 200, 200).r, accuracy: accuracy)
    }

    func testCombineTargetNilWithIntersectModeIsByteIdenticalToNoCombineAtAll() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = nil
        let withNilTarget = EditPipeline.apply(EditState(masks: [consumer]), to: input)

        var noCombine = consumer
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: withNilTarget, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    func testTwoMasksWithNoCombineStillCompoundSequentially() {
        // A direct restatement of
        // `testMasksApplySequentiallyAndCompoundInOverlappingRegions`
        // inside THIS section — slice 2's own independent-compounding
        // behavior must survive slice 6's `applyMasks` refactor unchanged.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let output = EditPipeline.apply(
            EditState(masks: [
                Mask(centerX: 0.35, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1),
                Mask(centerX: 0.65, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
            ]),
            to: input
        )
        XCTAssertEqual(pixel(of: output, at: 0, 200).r, 0.2, accuracy: accuracy, "far from both masks")
        XCTAssertEqual(pixel(of: output, at: 100, 200).r, 0.4, accuracy: accuracy, "only the first mask")
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.8, accuracy: accuracy, "both masks -- compounded 2x * 2x")
    }

    // MARK: Intersect/subtract equivalence (magic-number-free)

    /// Intersecting a FULLY-COVERING mask (weight ~1 everywhere sampled)
    /// against a real operand shape must match that operand's OWN
    /// already-measured falloff exactly (`testMaskSoftEdgeFalloffIsMonotonic`'s
    /// own six values) — `min(1, operandWeight) == operandWeight`. The
    /// operand mask itself carries NO adjustments (`isIdentity == true`,
    /// so `applyMasks` never applies it standalone) — this is the "pure
    /// shape-only operand" capability `Mask.isIdentity`'s own doc comment
    /// describes, exercised directly.
    func testIntersectWithAFullyCoveringMaskMatchesTheOperandsOwnShape() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.4, accuracy: accuracy, "center")
        XCTAssertEqual(pixel(of: output, at: 235, 200).r, 0.4, accuracy: accuracy, "within core")
        XCTAssertEqual(pixel(of: output, at: 245, 200).r, 0.37249, accuracy: accuracy, "mid falloff")
        XCTAssertEqual(pixel(of: output, at: 260, 200).r, 0.29749, accuracy: accuracy, "mid falloff")
        XCTAssertEqual(pixel(of: output, at: 280, 200).r, 0.2, accuracy: accuracy, "at boundary")
        XCTAssertEqual(pixel(of: output, at: 300, 200).r, 0.2, accuracy: accuracy, "beyond")
    }

    /// The exact complement of the test above — `subtract` against the
    /// SAME operand, same fully-covering consumer. `M ∧ ¬operand` means
    /// full effect exactly where the operand test above showed none, and
    /// none exactly where it showed full effect.
    func testSubtractWithAFullyCoveringMaskIsTheExactComplementOfIntersect() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .subtract
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.2, accuracy: accuracy, "center: fully subtracted, untouched")
        XCTAssertEqual(pixel(of: output, at: 235, 200).r, 0.2, accuracy: accuracy, "within core: untouched")
        XCTAssertEqual(pixel(of: output, at: 245, 200).r, 0.22751, accuracy: accuracy, "mid falloff")
        XCTAssertEqual(pixel(of: output, at: 260, 200).r, 0.30251, accuracy: accuracy, "mid falloff")
        XCTAssertEqual(pixel(of: output, at: 280, 200).r, 0.4, accuracy: accuracy, "at boundary: fully applied")
        XCTAssertEqual(pixel(of: output, at: 300, 200).r, 0.4, accuracy: accuracy, "beyond: fully applied")
    }

    /// A rigorous, magic-number-free proof of the min/¬min duality: since
    /// `CIBlendWithMask` is an EXACT lerp and Exposure is a linear-light
    /// multiply, `intersectValue + subtractValue == baseValue +
    /// correctedValue` at EVERY sample, including partial-weight falloff
    /// points — not just the fully-in/fully-out extremes the two tests
    /// above already pin.
    func testIntersectAndSubtractAgainstTheSameOperandSumToBaseValuePlusCorrectedValue() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var intersectConsumer = fullyCoveringMask(exposureEV: 1)
        intersectConsumer.combineMode = .intersect
        intersectConsumer.combineWithMaskID = operand.id
        var subtractConsumer = fullyCoveringMask(exposureEV: 1)
        subtractConsumer.combineMode = .subtract
        subtractConsumer.combineWithMaskID = operand.id

        let intersectOutput = EditPipeline.apply(EditState(masks: [operand, intersectConsumer]), to: input)
        let subtractOutput = EditPipeline.apply(EditState(masks: [operand, subtractConsumer]), to: input)

        let points: [(Int, Int)] = [(200, 200), (235, 200), (245, 200), (260, 200), (280, 200), (300, 200)]
        for (x, y) in points {
            let intersectValue = Double(pixel(of: intersectOutput, at: x, y).r)
            let subtractValue = Double(pixel(of: subtractOutput, at: x, y).r)
            XCTAssertEqual(intersectValue + subtractValue, 0.2 + 0.4, accuracy: Double(accuracy) * 2, "at (\(x),\(y))")
        }
    }

    // MARK: Geometry / boolean behavior

    func testIntersectLimitsTheEffectToTheOverlapOfBothShapes() {
        // Same geometry as `testMasksApplySequentiallyAndCompoundInOverlappingRegions`
        // above (already-proven sample points): consumer centered left
        // (0.35), operand centered right (0.65), each radius 0.3 --
        // overlapping only near the middle.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.65, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02)
        var consumer = Mask(centerX: 0.35, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 0, 200).r, 0.2, accuracy: accuracy, "outside both shapes")
        XCTAssertEqual(pixel(of: output, at: 100, 200).r, 0.2, accuracy: accuracy, "consumer-only region: excluded by intersect")
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.4, accuracy: accuracy, "overlap: full effect")
        XCTAssertEqual(pixel(of: output, at: 300, 200).r, 0.2, accuracy: accuracy, "operand-only region")
    }

    func testSubtractRemovesTheOperandShapeFromTheMask() {
        // The complement of the geometry test above.
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.65, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02)
        var consumer = Mask(centerX: 0.35, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
        consumer.combineMode = .subtract
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 100, 200).r, 0.4, accuracy: accuracy, "consumer-only region: full effect, operand doesn't reach here")
        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.2, accuracy: accuracy, "overlap: removed by subtract")
    }

    func testIntersectWithADisjointOperandIsAnExactNoOp() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.1, centerY: 0.1, radiusX: 0.05, radiusY: 0.05, feather: 0.02)
        var consumer = Mask(centerX: 0.9, centerY: 0.9, radiusX: 0.05, radiusY: 0.05, feather: 0.02, exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)
        let withoutMask = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(
            pixel(of: output, at: 360, 360).r, pixel(of: withoutMask, at: 360, 360).r, accuracy: accuracy,
            "even deep inside the consumer's own shape, a disjoint operand makes this an exact no-op"
        )
    }

    func testCombinePreservesExtentExactly() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)
        XCTAssertEqual(output.extent, input.extent)
    }

    func testCombinePreservesAlpha() {
        let color = CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.6, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let operand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2, feather: 0.5)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)
        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.6, accuracy: accuracy)
    }

    // MARK: Cross-kind operands

    func testCombineWithABrushOperandCutsTheStrokeShapeOut() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let operand = Mask(kind: .brush, feather: 0.3, brushSize: 0.15, brushPoints: [BrushPoint(x: 0.5, y: 0.5)])
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.4, accuracy: accuracy, "at the dab's own center")
        XCTAssertEqual(pixel(of: output, at: 10, 10).r, 0.2, accuracy: accuracy, "far from the stroke")
    }

    /// The headline "brighten only the highlights inside this area" use
    /// case — a `.luminanceRange` operand intersected with a fully-covering
    /// geometric consumer, direct analog of
    /// `testLuminanceRangeOnlyAffectsMatchingTone`.
    func testCombineWithALuminanceRangeOperandSelectsByTone() {
        let matchingTone = LuminanceRangeSelection.linearLuminance(forTone: 0.5)
        let farTone = LuminanceRangeSelection.linearLuminance(forTone: 0.95)
        let left = CIColor(red: matchingTone, green: matchingTone, blue: matchingTone, colorSpace: linearSpace)!
        let right = CIColor(red: farTone, green: farTone, blue: farTone, colorSpace: linearSpace)!
        let leftHalf = CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let rightHalf = CIImage(color: right).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 400))
        let input = leftHalf.composited(over: rightHalf)

        let operand = Mask(kind: .luminanceRange, feather: 0.5, luminanceTarget: 0.5, luminanceRange: 0.2)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = operand.id
        let output = EditPipeline.apply(EditState(masks: [operand, consumer]), to: input)

        XCTAssertEqual(pixel(of: output, at: 100, 200).r, Float(matchingTone * 2), accuracy: accuracy, "matching tone: selected")
        XCTAssertEqual(pixel(of: output, at: 300, 200).r, Float(farTone), accuracy: accuracy, "far tone: excluded")
    }

    /// Pins the rule `EditPipeline.applyMasks`'s own doc comment states:
    /// an operand is evaluated against the RUNNING `img` at the CONSUMING
    /// mask's own loop position — direct analog of
    /// `testLuminanceRangeSelectionFollowsEarlierMasksResult`. An earlier
    /// mask brightens this patch well outside the `.luminanceRange`
    /// operand's narrow window, so the consumer's intersect must select
    /// NOTHING here — proving the operand measured the ALREADY-brightened
    /// tone, not the original.
    func testCombineOperandIsEvaluatedAgainstTheRunningImageAtTheConsumingMasksPosition() {
        let darkTone = LuminanceRangeSelection.linearLuminance(forTone: 0.2)
        let input = solidColorImage(darkTone, size: 400)
        let brighten = Mask(centerX: 0.5, centerY: 0.5, radiusX: 2.0, radiusY: 2.0, exposureEV: 3)
        let luminanceOperand = Mask(
            kind: .luminanceRange, feather: 0.5, luminanceTarget: 0.2, luminanceRange: LuminanceRangeSelection.minimumRange
        )
        var consumer = fullyCoveringMask(exposureEV: 2)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = luminanceOperand.id

        let output = EditPipeline.apply(EditState(masks: [brighten, luminanceOperand, consumer]), to: input)
        let brightenOnly = EditPipeline.apply(EditState(masks: [brighten]), to: input)

        XCTAssertEqual(
            pixel(of: output, at: 200, 200).r, pixel(of: brightenOnly, at: 200, 200).r, accuracy: accuracy,
            "the luminanceRange operand must see the ALREADY-brightened tone (now outside its narrow window), so the consumer's intersect selects nothing"
        )
    }

    // MARK: Robustness (self-reference / dangling / degenerate operand)

    func testSelfReferencingIntersectIsIgnored() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var mask = fullyCoveringMask(exposureEV: 1)
        mask.combineMode = .intersect
        mask.combineWithMaskID = mask.id // unreachable from the UI (the picker excludes self)
        let withSelfRef = EditPipeline.apply(EditState(masks: [mask]), to: input)

        var noCombine = mask
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: withSelfRef, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    func testSelfReferencingSubtractIsIgnored() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var mask = fullyCoveringMask(exposureEV: 1)
        mask.combineMode = .subtract
        mask.combineWithMaskID = mask.id
        let withSelfRef = EditPipeline.apply(EditState(masks: [mask]), to: input)

        var noCombine = mask
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: withSelfRef, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    func testDanglingCombineTargetIntersectIsIgnored() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var mask = fullyCoveringMask(exposureEV: 1)
        mask.combineMode = .intersect
        mask.combineWithMaskID = UUID() // names no mask that exists anywhere in `state.masks`
        let withDanglingRef = EditPipeline.apply(EditState(masks: [mask]), to: input)

        var noCombine = mask
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: withDanglingRef, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    func testDanglingCombineTargetSubtractIsIgnored() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var mask = fullyCoveringMask(exposureEV: 1)
        mask.combineMode = .subtract
        mask.combineWithMaskID = UUID()
        let withDanglingRef = EditPipeline.apply(EditState(masks: [mask]), to: input)

        var noCombine = mask
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: withDanglingRef, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    /// The operand exists but its OWN shape resolves to nothing (a
    /// zero-radius Radial) — a genuinely different case from a dangling
    /// reference (§5's own table): the boolean algebra has a real answer,
    /// `M ∧ 0 = 0`, so the whole consumer mask is skipped.
    func testIntersectWithADegenerateOperandSkipsTheMaskEntirely() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let degenerateOperand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0, radiusY: 0.2)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .intersect
        consumer.combineWithMaskID = degenerateOperand.id
        let output = EditPipeline.apply(EditState(masks: [degenerateOperand, consumer]), to: input)
        let withoutMask = EditPipeline.apply(EditState(), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, pixel(of: withoutMask, at: 200, 200).r, accuracy: accuracy)
    }

    /// The dual of the test above: `M ∧ ¬0 = M` — a degenerate operand
    /// under `.subtract` leaves the mask COMPLETELY unaffected, not skipped.
    func testSubtractWithADegenerateOperandLeavesTheMaskFullyApplied() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let degenerateOperand = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0, radiusY: 0.2)
        var consumer = fullyCoveringMask(exposureEV: 1)
        consumer.combineMode = .subtract
        consumer.combineWithMaskID = degenerateOperand.id
        let output = EditPipeline.apply(EditState(masks: [degenerateOperand, consumer]), to: input)

        var noCombine = consumer
        noCombine.combineMode = .none
        let withoutCombine = EditPipeline.apply(EditState(masks: [noCombine]), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, pixel(of: withoutCombine, at: 200, 200).r, accuracy: accuracy)
    }

    // MARK: Non-transitivity / cycle safety

    /// A must not hang, crash, or recurse when combining with B while B
    /// ALSO combines with A — non-transitive resolution (each resolves
    /// the OTHER's raw shape exactly once) is cycle-safe BY CONSTRUCTION,
    /// with no visited-set or depth cap needed. Direct proof, not just an
    /// absence-of-crash: both masks apply fully in their overlap
    /// (compounding, 2x * 2x), and neither reaches outside its own shape
    /// into the other's exclusive region.
    func testMutuallyCombiningMasksTerminateAndUseEachOthersRawShapes() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        var maskA = Mask(centerX: 0.35, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
        var maskB = Mask(centerX: 0.65, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02, exposureEV: 1)
        maskA.combineMode = .intersect
        maskA.combineWithMaskID = maskB.id
        maskB.combineMode = .intersect
        maskB.combineWithMaskID = maskA.id

        let output = EditPipeline.apply(EditState(masks: [maskA, maskB]), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).r, 0.8, accuracy: accuracy, "overlap: both apply, compounding 2x * 2x")
        XCTAssertEqual(pixel(of: output, at: 100, 200).r, 0.2, accuracy: accuracy, "only A's shape -- excluded by A's own intersect with B")
    }

    /// The non-transitivity proof: C intersects with B, and B ITSELF
    /// intersects with A (a small mask). If C correctly resolves B's RAW,
    /// pre-combine shape (as designed), C reaches the FULL extent of B's
    /// own shape, not narrowed to A's small region too.
    func testCombineUsesTheOperandsRawShapeNotItsOwnCombinedShape() {
        let input = solidColorImage(r: 0.2, g: 0.2, b: 0.2, a: 1, size: 400)
        let maskA = Mask(centerX: 0.2, centerY: 0.5, radiusX: 0.05, radiusY: 0.3, feather: 0.02) // narrow band near x=80
        var maskB = Mask(centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3, feather: 0.02) // wide, spans ~80-320
        maskB.combineMode = .intersect
        maskB.combineWithMaskID = maskA.id
        var maskC = fullyCoveringMask(exposureEV: 1)
        maskC.combineMode = .intersect
        maskC.combineWithMaskID = maskB.id

        let output = EditPipeline.apply(EditState(masks: [maskA, maskB, maskC]), to: input)

        XCTAssertEqual(
            pixel(of: output, at: 200, 200).r, 0.4, accuracy: accuracy,
            "C must use B's RAW shape (reaching outside A's own narrow band), not B's shape already-intersected with A"
        )
    }

    // MARK: - Vignette math
    //
    // Vignette (CIVignetteEffect) is a radial darkening/brightening tied to
    // the FINAL framing — it runs after crop and is centered on the
    // post-crop extent. Expected values are measured from the diagnostic
    // script on a sized solid-color image, since a 1x1 image can't show
    // radial falloff.

    func testVignetteZeroIsIdentity() {
        for value in [0.05, 0.214, 0.5, 0.7, 1.2] {
            let input = solidColorImage(value, size: 100)
            let output = EditPipeline.apply(EditState(vignetteStrength: 0), to: input)
            XCTAssertEqual(pixel(of: output, at: 50, 50).r, Float(value), accuracy: accuracy, "center at L=\(value)")
            XCTAssertEqual(pixel(of: output, at: 2, 2).r, Float(value), accuracy: accuracy, "corner at L=\(value)")
        }

        let output = EditPipeline.apply(EditState(), to: solidColorImage(0.5, size: 100))
        XCTAssertEqual(pixel(of: output, at: 50, 50).r, 0.5, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 2, 2).r, 0.5, accuracy: accuracy)
    }

    func testVignetteDarkensCornersPreservesCenter() {
        let input = solidColorImage(0.5, size: 100)
        let output = EditPipeline.apply(EditState(vignetteStrength: 1), to: input)

        let center = pixel(of: output, at: 50, 50).r
        let quarter = pixel(of: output, at: 25, 25).r
        let edgeMid = pixel(of: output, at: 50, 2).r
        let corner = pixel(of: output, at: 2, 2).r

        XCTAssertEqual(center, 0.49981, accuracy: accuracy)
        XCTAssertEqual(quarter, 0.39546, accuracy: accuracy)
        XCTAssertEqual(edgeMid, 0.29049, accuracy: accuracy)
        XCTAssertEqual(corner, 0.12989, accuracy: accuracy)

        // Monotone radial falloff toward the corner.
        XCTAssertLessThan(corner, edgeMid)
        XCTAssertLessThan(edgeMid, quarter)
        XCTAssertLessThan(quarter, center)
    }

    func testVignetteCentersOnCroppedExtent() {
        // Vignette must derive its center/radius from the CURRENT (post-crop)
        // extent, not the original image — otherwise a crop would leave the
        // vignette looking off-center. Crop to (10,0,90,75) (geometric center
        // (55,37.5)) and confirm all four crop corners darken EQUALLY.
        let input = solidColorImage(0.5, size: 100)
        let output = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1, vignetteStrength: 1),
            to: input
        )

        XCTAssertEqual(pixel(of: output, at: 55, 37).r, 0.49981, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 12, 2).r, 0.13481, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 97, 72).r, 0.13481, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 97, 2).r, 0.13481, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 12, 72).r, 0.13481, accuracy: accuracy)
    }

    func testVignetteNegativeLightensCorners() {
        let input = solidColorImage(0.5, size: 100)
        let output = EditPipeline.apply(EditState(vignetteStrength: -1), to: input)

        let center = pixel(of: output, at: 50, 50).r
        let edgeMid = pixel(of: output, at: 50, 2).r
        let corner = pixel(of: output, at: 2, 2).r

        XCTAssertEqual(center, 0.50000, accuracy: accuracy)
        XCTAssertEqual(edgeMid, 0.92737, accuracy: accuracy)
        XCTAssertEqual(corner, 1.40641, accuracy: accuracy)
        XCTAssertGreaterThan(corner, center, "negative strength brightens, not darkens")
    }

    func testVignetteRadiusControlsReach() {
        let input = solidColorImage(0.5, size: 100)

        let tight = EditPipeline.apply(EditState(vignetteStrength: 1, vignetteRadius: 0), to: input)
        XCTAssertEqual(pixel(of: tight, at: 2, 2).r, 0.01547, accuracy: accuracy)
        XCTAssertEqual(pixel(of: tight, at: 25, 25).r, 0.27299, accuracy: accuracy)
        XCTAssertEqual(pixel(of: tight, at: 50, 50).r, 0.49980, accuracy: accuracy)

        let wide = EditPipeline.apply(EditState(vignetteStrength: 1, vignetteRadius: 1), to: input)
        XCTAssertEqual(pixel(of: wide, at: 2, 2).r, 0.25390, accuracy: accuracy)
        XCTAssertEqual(pixel(of: wide, at: 25, 25).r, 0.44560, accuracy: accuracy)
        XCTAssertEqual(pixel(of: wide, at: 50, 50).r, 0.49981, accuracy: accuracy)

        XCTAssertLessThan(
            pixel(of: tight, at: 2, 2).r, pixel(of: wide, at: 2, 2).r,
            "a smaller radius should darken the corner more (tighter/stronger reach)"
        )
    }

    func testVignettePreservesHighlightHeadroom() {
        // Unlike curves, an active vignette does NOT clamp values above
        // linear 1.0 — CIVignetteEffect is a multiplicative blend with no
        // internal [0,1] LUT.
        let input = solidColorImage(1.4, size: 100)
        let output = EditPipeline.apply(EditState(vignetteStrength: 1), to: input)

        XCTAssertEqual(pixel(of: output, at: 50, 50).r, 1.39946, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 2, 2).r, 0.36369, accuracy: accuracy)
    }

    func testVignettePreservesAlpha() {
        let input = solidColorImage(r: 0.6, g: 0.2, b: 0.2, a: 0.5, size: 100)
        let output = EditPipeline.apply(EditState(vignetteStrength: 1), to: input)

        let center = pixel(of: output, at: 50, 50)
        XCTAssertEqual(center.r, 0.29988, accuracy: accuracy)
        XCTAssertEqual(center.g, 0.09996, accuracy: accuracy)
        XCTAssertEqual(center.b, 0.09996, accuracy: accuracy)
        XCTAssertEqual(center.a, 0.5, accuracy: accuracy)

        let corner = pixel(of: output, at: 2, 2)
        XCTAssertEqual(corner.r, 0.07793, accuracy: accuracy)
        XCTAssertEqual(corner.g, 0.02598, accuracy: accuracy)
        XCTAssertEqual(corner.b, 0.02598, accuracy: accuracy)
        XCTAssertEqual(corner.a, 0.5, accuracy: accuracy)
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

    func testBrilliancePreservesHighlightHeadroom() {
        // Brilliance never touches the curve stage directly — it works by
        // making effective shadows/highlights non-zero, which engages it.
        // So it inherited the clamp, and now inherits the fix: this read
        // exactly 1.0 against the old path.
        let output = EditPipeline.apply(EditState(brilliance: 1), to: solidColorImage(1.3))
        XCTAssertEqual(linearPixel(of: output).r, 1.74659, accuracy: accuracy)
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


    // MARK: - Dehaze (dark channel prior) math
    //
    // Dehaze is a real implementation of He/Sun/Tang's dark channel prior, not
    // a reuse of an existing filter, so every value here is measured against
    // the running pipeline.
    //
    // The fixtures exploit the haze model being AFFINE per pixel: hazing a
    // step edge just moves its two levels, so `I = J*t + A*(1-t)` can be
    // synthesized with `stepEdgeImage` alone. With clear J = 0.2, A = 0.9 and
    // t = 0.5, the hazy dark level is 0.2*0.5 + 0.9*0.5 = 0.55.
    //
    // The fixture deliberately includes the SKY (the bright level IS A = 0.9).
    // That matters: A is ESTIMATED from the image, so a fixture whose bright
    // level is merely "bright content" would have its own maximum mistaken for
    // the atmosphere and could not round-trip. Sky pixels themselves recover to
    // A by construction (I == A makes the recovery term vanish), which is
    // correct behaviour and why assertions target the CONTENT side.

    func testDehazeZeroIsExactAndTheGateIsWhatMakesItSo() {
        // The dark level is 0.2, NOT the 0.55 most of this section uses,
        // and that choice is load-bearing. Sterbenz: `(I - A) + A` is exact
        // WHENEVER A/2 <= I <= 2A — sufficient, not necessary, so exactness
        // outside that window is possible but not guaranteed. With A ~ 0.9 the
        // window contains 0.55 and excludes 0.2, and measurement confirms 0.2
        // genuinely is not exact. So a 0.55 fixture silently cannot detect the
        // gate's removal, and two earlier versions of this test were
        // tautological for exactly that reason.
        //
        // VERIFIED BY FAULT INJECTION, not argument: commenting out
        // `guard dehazeActive(state)` in `applyDehaze` makes this test FAIL
        // with "0.19999999 is not equal to 0.2 +/- 0.0" — so the assertion
        // genuinely covers the gate, which is what keeps amount 0 exact.
        let hazy = stepEdgeImage(lo: 0.2, hi: 0.90, size: 800)
        let output = EditPipeline.apply(EditState(dehaze: 0), to: hazy)

        for x in [100, 200, 300, 401, 500, 700] {
            XCTAssertEqual(edgePixel(of: output, x: x, size: 800).r,
                           edgePixel(of: hazy, x: x, size: 800).r, accuracy: 0)
            XCTAssertEqual(edgePixel(of: output, x: x, size: 800).a,
                           edgePixel(of: hazy, x: x, size: 800).a, accuracy: 0)
        }
    }

    func testDehazeRecoversKnownSyntheticHaze() {
        // The signature test: a KNOWN hazy image must come back toward its
        // known clear original. Everything else in this section is a guard rail.
        let hazy = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800)

        let half = EditPipeline.apply(EditState(dehaze: 0.5), to: hazy)
        let full = EditPipeline.apply(EditState(dehaze: 1.0), to: hazy)

        XCTAssertEqual(edgePixel(of: half, x: 200, size: 800).r, 0.40687, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: full, x: 200, size: 800).r, 0.06557, accuracy: accuracy)
        XCTAssertLessThan(edgePixel(of: full, x: 200, size: 800).r,
                          edgePixel(of: hazy, x: 200, size: 800).r,
                          "dehaze must pull hazy content DOWN toward its clear value")
    }

    func testDehazeFullStrengthOvershootsThePhysicalInverse() {
        // Honest characterisation of the slider: amount 1.0 removes MORE haze
        // than the exact inverse. On this fixture the true inverse lands at
        // amount ~0.86 (measured 0.20103 against the 0.20000 target); 1.0 goes
        // past it to 0.06557. That is intentional — Lightroom's Dehaze at 100
        // is likewise aggressive — but it means the slider is a strength
        // control, not a calibrated physical inversion.
        let hazy = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800)

        XCTAssertEqual(edgePixel(of: EditPipeline.apply(EditState(dehaze: 0.86), to: hazy), x: 200, size: 800).r,
                       0.20103, accuracy: accuracy)
        XCTAssertLessThan(edgePixel(of: EditPipeline.apply(EditState(dehaze: 1.0), to: hazy), x: 200, size: 800).r,
                          0.20000, "amount 1.0 deliberately goes past the exact inverse")
    }

    func testDehazeAmountRampsMonotonically() {
        let hazy = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800)
        let values = [0.0, 0.25, 0.5, 0.75, 1.0].map {
            edgePixel(of: EditPipeline.apply(EditState(dehaze: $0), to: hazy), x: 200, size: 800).r
        }
        for (lower, higher) in zip(values.dropFirst(), values) {
            XCTAssertLessThan(lower, higher, "more dehaze must mean less haze, at every step")
        }
    }

    func testNegativeDehazeAddsHazeTowardAtmosphericLight() {
        // The negative half runs the model FORWARD, blending toward the same
        // estimated A. On a clear 0.2/0.5 edge, A estimates to the image's own
        // maximum (0.5), so -1.0 gives mix(0.2, 0.5, 0.85) = 0.455 — which is
        // the add-haze span, `kDehazeAddHazeSpan`, made visible.
        let clear = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)

        XCTAssertEqual(edgePixel(of: EditPipeline.apply(EditState(dehaze: -0.5), to: clear), x: 200, size: 800).r,
                       0.32750, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: EditPipeline.apply(EditState(dehaze: -1.0), to: clear), x: 200, size: 800).r,
                       0.45500, accuracy: accuracy)
    }

    func testDehazePreservesExtentAndAlpha() {
        // Three separate extent hazards in this one stage: CIGaussianBlur and
        // CIMorphologyMinimum both expand, and CIAreaMaximum collapses to 1x1.
        // Reviewer-corrected: the dependents are DOWNSTREAM — Vignette's
        // center and Clarity/Texture/Sharpen's `min(extent)` radius fractions.
        // NOT applyMasks, which runs one line ABOVE this stage and can never
        // see its extent.
        let hazy = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800)
        XCTAssertEqual(EditPipeline.apply(EditState(dehaze: 1), to: hazy).extent, hazy.extent)

        let alphaInput = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800, alpha: 0.5)
        let alphaOutput = EditPipeline.apply(EditState(dehaze: 1), to: alphaInput)
        XCTAssertEqual(alphaOutput.extent, alphaInput.extent)
        XCTAssertEqual(edgePixel(of: alphaOutput, x: 700, size: 800).a, 0.5, accuracy: accuracy)
    }

    func testDehazePreservesHighlightHeadroom() {
        // Dividing by transmission legitimately pushes values above 1.0, and
        // this pipeline preserves headroom everywhere except Levels.
        let input = stepEdgeImage(lo: 0.8, hi: 1.4, size: 800)
        let output = EditPipeline.apply(EditState(dehaze: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 700, size: 800).r, 1.40527, accuracy: accuracy)
        XCTAssertGreaterThan(edgePixel(of: output, x: 700, size: 800).r, 1.0,
                             "dehaze must not clamp highlight headroom")
    }

    func testDehazeRadiusScalesWithResolution() {
        // CIMorphologyMinimum's radius is in ABSOLUTE PIXELS, so a fixed value
        // would give a 24MP photo and its thumbnail different haze estimates.
        // Proof has two halves: the same FRACTIONAL offset must agree across
        // sizes, and the same PIXEL offset must not.
        //
        // The deltas are small (~0.0007) for a structural reason worth knowing:
        // these samples sit in the sky, where I == A makes recovery land on A
        // almost regardless of transmission. They are nonetheless exactly
        // reproducible, hence the tight accuracy.
        func sample(size: Int, offset: Int) -> Float {
            let hazy = stepEdgeImage(lo: 0.55, hi: 0.90, size: size)
            let output = EditPipeline.apply(EditState(dehaze: 1), to: hazy)
            return edgePixel(of: output, x: size / 2 + offset, size: size).r
        }

        // Same fractional offset (1.25% — exactly the radius): identical.
        for size in [400, 800, 1600] {
            XCTAssertEqual(sample(size: size, offset: Int(0.0125 * Double(size))), 0.900878, accuracy: 0.00005)
        }

        // Same pixel offset: 1600's 20px radius swallows +10px while 400's 5px
        // does not. 800's radius is EXACTLY 10px, so that row sits on the
        // boundary rather than outside it — the measured values still separate
        // 1600 from the other two, which is what the assertion rests on.
        XCTAssertEqual(sample(size: 400, offset: 10), 0.900878, accuracy: 0.00005)
        XCTAssertEqual(sample(size: 800, offset: 10), 0.900878, accuracy: 0.00005)
        XCTAssertEqual(sample(size: 1600, offset: 10), 0.900135, accuracy: 0.00005)
        XCTAssertNotEqual(sample(size: 1600, offset: 10), sample(size: 400, offset: 10),
                          "a pixel-fixed radius would make these identical")
    }

    func testDehazeOrderingIsMeasuredNotArbitrary() {
        // Unlike Texture/Clarity (which nearly commute, 0.00215), Dehaze is
        // strongly non-commutative with both its neighbours, so running it
        // BEFORE Vignette and Clarity is a real requirement.
        //
        // Vignette: it darkens corners, and A is estimated from the frame's
        // brightest region — letting it run first feeds the haze estimate a
        // value the scene never had.
        let base = stepEdgeImage(lo: 0.55, hi: 0.90, size: 800)

        let pipelineOrder = EditPipeline.apply(EditState(vignetteStrength: 0.8, dehaze: 1), to: base)
        let reversed = EditPipeline.apply(EditState(dehaze: 1),
                                          to: EditPipeline.apply(EditState(vignetteStrength: 0.8), to: base))
        XCTAssertGreaterThan(
            abs(edgePixel(of: pipelineOrder, x: 700, size: 800).r - edgePixel(of: reversed, x: 700, size: 800).r),
            0.4, "Dehaze and Vignette do not commute — measured 0.52275 apart")

        let withClarity = EditPipeline.apply(EditState(clarity: 1, dehaze: 1), to: base)
        let clarityFirst = EditPipeline.apply(EditState(dehaze: 1),
                                              to: EditPipeline.apply(EditState(clarity: 1), to: base))
        XCTAssertGreaterThan(
            abs(edgePixel(of: withClarity, x: 700, size: 800).r - edgePixel(of: clarityFirst, x: 700, size: 800).r),
            0.4, "Dehaze and Clarity do not commute — measured 0.42790 apart")
    }

    // MARK: - Clarity + Texture (local contrast) math
    //
    // Clarity is CIUnsharpMask at a much larger radius than Sharpen, so
    // — like Sharpen and Noise Reduction — these values are measured
    // against the real filter, not derived. Uses `stepEdgeImage` and
    // `edgePixel` (defined below, under Sharpen math) exactly like Sharpen's
    // own tests, sampling several offsets from the edge to show the WIDE
    // band that distinguishes local contrast from fine sharpening.

    func testClarityZeroIsIdentity() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(clarity: 0), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.2, accuracy: accuracy)
    }

    func testClarityBoostsLocalContrastOverBroadBand() {
        // The signature test: Clarity's overshoot stays elevated far from
        // the edge (x=430, x=460 — 30px/60px away), where a fine sharpen has
        // already decayed to baseline. That WIDTH, not the peak, is what
        // makes this local contrast rather than fine detail sharpening.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(clarity: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.66061, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 415, size: 800).r, 0.60219, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 430, size: 800).r, 0.55443, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 460, size: 800).r, 0.50955, accuracy: accuracy)
        XCTAssertGreaterThan(edgePixel(of: output, x: 460, size: 800).r, 0.505, "still measurably elevated 60px from the edge")

        // Monotonic decay back toward baseline as we move further away.
        XCTAssertEqual(edgePixel(of: output, x: 500, size: 800).r, 0.5, accuracy: accuracy)
    }

    func testClarityHaloIsWiderThanSharpen() {
        // Discriminator vs the shipped Sharpen tool: at the same offset from
        // the edge, Clarity stays elevated while Sharpen (tiny radius)
        // has already returned to baseline.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let clarityOutput = EditPipeline.apply(EditState(clarity: 1), to: input)
        let sharpenOutput = EditPipeline.apply(EditState(sharpness: 1), to: input)

        let clarityFar = edgePixel(of: clarityOutput, x: 430, size: 800).r
        let sharpenFar = edgePixel(of: sharpenOutput, x: 430, size: 800).r
        XCTAssertGreaterThan(clarityFar, sharpenFar)
        XCTAssertEqual(sharpenFar, 0.5, accuracy: 0.005, "Sharpen's tiny radius should already be flat 30px from the edge")
    }

    func testClarityRadiusScalesWithResolution() {
        // A FIXED pixel radius would give an IDENTICAL profile regardless of
        // image size; measured values strictly increase with resolution at
        // matching offsets, proving the radius scales with the image itself
        // (mirrors testSharpenRadiusScalesWithResolution).
        let sizes = [400, 800, 1600]
        let expected: [Float] = [0.50955, 0.55443, 0.60285]

        var values: [Float] = []
        for size in sizes {
            let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: size)
            let output = EditPipeline.apply(EditState(clarity: 1), to: input)
            values.append(edgePixel(of: output, x: size / 2 + 30, size: size).r)
        }

        for (value, expectedValue) in zip(values, expected) {
            XCTAssertEqual(value, expectedValue, accuracy: accuracy)
        }
        XCTAssertLessThan(values[0], values[1])
        XCTAssertLessThan(values[1], values[2])
    }

    func testClarityPreservesHighlightHeadroom() {
        let input = stepEdgeImage(lo: 0.8, hi: 1.4, size: 800)
        let output = EditPipeline.apply(EditState(clarity: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 1.68714, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 600, size: 800).r, 1.40127, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.62144, accuracy: accuracy)
    }

    func testClarityPreservesAlpha() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800, alpha: 0.5)
        let output = EditPipeline.apply(EditState(clarity: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 200, size: 800).a, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).a, 0.5, accuracy: accuracy)
    }

    func testClarityPreservesExtent() {
        let input = quadrantImage(width: 100, height: 100)
        let withClarity = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1, clarity: 1),
            to: input
        )
        let withoutClarity = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1),
            to: input
        )

        XCTAssertEqual(withClarity.extent, withoutClarity.extent, "clarity must not change the extent crop already established")
    }

    func testClarityFlatImageUnaffected() {
        let input = solidColorImage(0.35, size: 800)
        let output = EditPipeline.apply(EditState(clarity: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 400, size: 800).r, 0.35, accuracy: accuracy)
    }

    // MARK: - Texture math
    //
    // Texture is the SAME `CIUnsharpMask` construction as Clarity at a much
    // smaller radius (`kTextureRadiusFraction` 0.01 vs Clarity's 0.04), so
    // these values are measured against the real filter like Clarity's own.
    // The point of every test here is the WIDTH of the halo — that is the
    // only thing separating Texture from Clarity above it and Sharpen below.

    func testTextureZeroIsIdentity() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(texture: 0), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.2, accuracy: accuracy)
    }

    func testTextureBoostsLocalContrastOverNarrowBand() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(texture: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.64124, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 415, size: 800).r, 0.50955, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 430, size: 800).r, 0.50060, accuracy: accuracy)
    }

    func testTextureHaloSitsBetweenSharpenAndClarity() {
        // The whole reason these are three separate controls: at 15px out
        // from the edge Sharpen is already flat, Texture is measurably
        // elevated, and Clarity is far higher still. Peak height does NOT
        // separate them (all three are ~0.64-0.66) — only width does.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let sharpen = edgePixel(of: EditPipeline.apply(EditState(sharpness: 1), to: input), x: 415, size: 800).r
        let texture = edgePixel(of: EditPipeline.apply(EditState(texture: 1), to: input), x: 415, size: 800).r
        let clarity = edgePixel(of: EditPipeline.apply(EditState(clarity: 1), to: input), x: 415, size: 800).r

        XCTAssertLessThan(sharpen, texture)
        XCTAssertLessThan(texture, clarity)
        XCTAssertEqual(sharpen, 0.5, accuracy: 0.005, "Sharpen's tiny radius is already flat 15px out")
        XCTAssertGreaterThan(texture, 0.505, "Texture must still be measurably elevated 15px out")
    }

    func testTexturePreservesAlphaAndExtent() {
        let alphaInput = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800, alpha: 0.5)
        let output = EditPipeline.apply(EditState(texture: 1), to: alphaInput)
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).a, 0.5, accuracy: accuracy)

        let input = quadrantImage(width: 100, height: 100)
        let withTexture = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1, texture: 1),
            to: input
        )
        let withoutTexture = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1),
            to: input
        )
        XCTAssertEqual(withTexture.extent, withoutTexture.extent, "texture must not change the extent crop already established")
    }

    // MARK: - Negative Clarity/Texture (the formerly-dead half)
    //
    // `definition` shipped one-directional because `CIUnsharpMask` was
    // measured to clamp negative `intensity` to a BIT-IDENTICAL no-op. The
    // split routes the negative half through a blur blend instead, so these
    // tests exist specifically to prove the negative range is live rather
    // than silently inert — the exact regression that would otherwise
    // reintroduce a dead half-slider without failing anything else.

    func testNegativeClarityActuallySoftens() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let baseline = edgePixel(of: EditPipeline.apply(EditState(), to: input), x: 401, size: 800).r
        let output = EditPipeline.apply(EditState(clarity: -1), to: input)

        XCTAssertEqual(baseline, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.36483, accuracy: accuracy)
        XCTAssertLessThan(edgePixel(of: output, x: 401, size: 800).r, baseline - 0.01,
                          "negative Clarity must measurably soften, not no-op like CIUnsharpMask's clamped negative")
    }

    func testNegativeTextureActuallySoftensOverNarrowerBand() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(texture: -1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.37880, accuracy: accuracy)
        XCTAssertLessThan(edgePixel(of: output, x: 401, size: 800).r, 0.49,
                          "negative Texture must measurably soften, not no-op")
        // Narrower reach than negative Clarity: recovered by 15px out, where
        // negative Clarity is still well below baseline.
        XCTAssertEqual(edgePixel(of: output, x: 415, size: 800).r, 0.49056, accuracy: accuracy)
        let negClarityAt415 = edgePixel(of: EditPipeline.apply(EditState(clarity: -1), to: input), x: 415, size: 800).r
        XCTAssertLessThan(negClarityAt415, edgePixel(of: output, x: 415, size: 800).r)
    }

    func testNegativeClarityPreservesExtentAndAlpha() {
        // The blur-blend path is the one construction here that can change
        // extent: CIGaussianBlur expands its output. `localContrast` clamps
        // and re-crops for exactly this reason, and `applyMasks` resolves
        // mask geometry against this extent — so a regression here would
        // misalign masks, not merely look soft.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(clarity: -1), to: input)
        XCTAssertEqual(output.extent, input.extent)

        let alphaInput = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800, alpha: 0.5)
        let alphaOutput = EditPipeline.apply(EditState(clarity: -1), to: alphaInput)
        XCTAssertEqual(alphaOutput.extent, alphaInput.extent)
        XCTAssertEqual(edgePixel(of: alphaOutput, x: 401, size: 800).a, 0.5, accuracy: accuracy)
    }

    func testNegativeClarityPreservesHighlightHeadroom() {
        // Parity with `testClarityPreservesHighlightHeadroom` on the positive
        // half: the blur-blend path must not clip above 1.0 either. A 1.4
        // flat survives at 1.39873 well away from the edge; near the edge the
        // blur legitimately pulls the two sides toward each other, which is
        // the softening working, not clipping.
        let input = stepEdgeImage(lo: 0.8, hi: 1.4, size: 800)
        let output = EditPipeline.apply(EditState(clarity: -1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 600, size: 800).r, 1.39873, accuracy: accuracy)
        XCTAssertGreaterThan(edgePixel(of: output, x: 600, size: 800).r, 1.0,
                             "the negative path must not clamp highlight headroom to 1.0")
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 1.14359, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 1.00538, accuracy: accuracy)
    }

    func testOutOfRangeNegativeClaritySaturatesRatherThanExtrapolating() {
        // Out-of-range values are unreachable from the bounded slider but
        // reachable from a hand-edited sidecar, and `applyMasks` deliberately
        // does NOT clamp Clarity (unlike contrast/shadows/highlights/
        // saturation). MEASURED: `CIFilter.mix` saturates at `amount` 1.0, so
        // anything past clarity -1.25 (= -1.25 * 0.8 span) is the fully
        // blurred image and nothing extrapolates beyond it.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let atSaturation = edgePixel(of: EditPipeline.apply(EditState(clarity: -1.25), to: input), x: 401, size: 800).r

        XCTAssertEqual(atSaturation, 0.33486, accuracy: accuracy)
        for wild in [-2.0, -5.0, -20.0] {
            let output = EditPipeline.apply(EditState(clarity: wild), to: input)
            XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, atSaturation, accuracy: accuracy,
                           "clarity \(wild) must saturate at the fully blurred image, not extrapolate past it")
        }
    }

    func testNegativeClarityLeavesFlatImageUnchanged() {
        // Blurring a solid colour is a no-op, so the blend must be too —
        // guards against the negative path introducing an overall level
        // shift (e.g. a mis-signed mix amount).
        let input = solidColorImage(0.35, size: 800)
        let output = EditPipeline.apply(EditState(clarity: -1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 400, size: 800).r, 0.35, accuracy: accuracy)
    }

    // MARK: - Noise Reduction math
    //
    // Noise Reduction is a genuine new Core Image filter (CINoiseReduction),
    // so — like Sharpen, and unlike Black & White's reused math — these
    // values are measured against the real filter, not derived. A flat
    // noisy patch (not a solid color) is needed to show any effect;
    // `noisyGray` reproduces the exact deterministic seeded-LCG noise the
    // design probe used so the measured numbers below reproduce.

    /// Deterministic per-pixel noisy gray image, matching the design probe's
    /// exact seeded LCG so the measured std values below reproduce. `amp` is
    /// the noise half-range around `base` (true linear values).
    private func noisyGray(base: Double, amp: Double, size: Int, seed: UInt64 = 88, alpha: Double = 1) -> CIImage {
        var state = seed
        func rand() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let value = Float(base + (rand() * 2 - 1) * amp)
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = Float(alpha)
        }
        return CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) },
            bytesPerRow: size * 16,
            size: CGSize(width: size, height: size),
            format: .RGBAf,
            colorSpace: linearSpace
        )
    }

    /// Mean and standard deviation of the red channel over a pixel region —
    /// noise reduction's effect shows up as a std reduction, not a mean
    /// shift, so tests need this rather than a single-pixel sample.
    private func regionStd(_ image: CIImage, x: Int, y: Int, w: Int, h: Int) -> (mean: Float, std: Float) {
        var buffer = [Float](repeating: 0, count: w * h * 4)
        context.render(
            image, toBitmap: &buffer, rowBytes: w * 16,
            bounds: CGRect(x: x, y: y, width: w, height: h),
            format: .RGBAf, colorSpace: linearSpace
        )
        var sum = 0.0
        var sumSq = 0.0
        let n = w * h
        for i in 0..<n {
            let value = Double(buffer[i * 4])
            sum += value
            sumSq += value * value
        }
        let mean = sum / Double(n)
        let variance = max(0, sumSq / Double(n) - mean * mean)
        return (Float(mean), Float(variance.squareRoot()))
    }

    func testNoiseReductionZeroIsIdentity() {
        let input = noisyGray(base: 0.5, amp: 0.10, size: 600)
        let output = EditPipeline.apply(EditState(noiseReduction: 0), to: input)

        let baseline = regionStd(input, x: 0, y: 0, w: 600, h: 600)
        let result = regionStd(output, x: 0, y: 0, w: 600, h: 600)
        XCTAssertEqual(result.std, baseline.std, accuracy: 0.0005)
        XCTAssertEqual(pixel(of: output, at: 300, 300).r, pixel(of: input, at: 300, 300).r, accuracy: accuracy)
    }

    func testNoiseReductionReducesFlatNoise() {
        let input = noisyGray(base: 0.5, amp: 0.10, size: 600)
        let baseline = regionStd(input, x: 0, y: 0, w: 600, h: 600).std

        let half = EditPipeline.apply(EditState(noiseReduction: 0.5), to: input)
        let full = EditPipeline.apply(EditState(noiseReduction: 1), to: input)
        let halfStd = regionStd(half, x: 0, y: 0, w: 600, h: 600).std
        let fullStd = regionStd(full, x: 0, y: 0, w: 600, h: 600).std

        XCTAssertEqual(halfStd, 0.04378, accuracy: 0.004)
        XCTAssertEqual(fullStd, 0.01378, accuracy: 0.004)
        XCTAssertLessThan(fullStd, halfStd)
        XCTAssertLessThan(halfStd, baseline)
    }

    func testNoiseReductionPreservesEdge() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(noiseReduction: 1), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 400).r, 0.20000, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 600, 400).r, 0.50000, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 398, 400).r, 0.22979, accuracy: accuracy)
        XCTAssertEqual(pixel(of: output, at: 401, 400).r, 0.47021, accuracy: accuracy)
    }

    func testNoiseReductionResolutionIndependent() {
        // UNLIKE Sharpen's radius, noiseLevel needs no extent-derived
        // scaling: residual std stays near-constant across resolutions.
        let sizes = [400, 800, 1600]
        let expected: [Float] = [0.01381, 0.01372, 0.01375]

        for (size, expectedStd) in zip(sizes, expected) {
            let input = noisyGray(base: 0.5, amp: 0.10, size: size)
            let output = EditPipeline.apply(EditState(noiseReduction: 1), to: input)
            let std = regionStd(output, x: 0, y: 0, w: size, h: size).std
            XCTAssertEqual(std, expectedStd, accuracy: 0.004)
        }
    }

    func testNoiseReductionPreservesHighlightHeadroom() {
        let input = noisyGray(base: 1.4, amp: 0.05, size: 400)
        let output = EditPipeline.apply(EditState(noiseReduction: 1), to: input)

        let result = regionStd(output, x: 0, y: 0, w: 400, h: 400)
        XCTAssertEqual(result.mean, 1.39988, accuracy: accuracy)
        XCTAssertGreaterThan(result.mean, 1.0)
    }

    func testNoiseReductionPreservesAlpha() {
        let input = noisyGray(base: 0.5, amp: 0.10, size: 400, alpha: 0.5)
        let output = EditPipeline.apply(EditState(noiseReduction: 1), to: input)

        XCTAssertEqual(pixel(of: output, at: 200, 200).a, 0.5, accuracy: accuracy)
    }

    func testNoiseReductionPreservesExtent() {
        let input = quadrantImage(width: 100, height: 100)
        let output = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1, noiseReduction: 1),
            to: input
        )

        XCTAssertEqual(output.extent, EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1),
            to: input
        ).extent, "noise reduction must not change the extent crop already established")
    }

    func testNoiseReductionSharpnessPinnedToZero() {
        // Regression guard for `filter.sharpness = 0` in `applyNoiseReduction`.
        // A flat SOLID image can't discriminate this (verified): with
        // nothing to sharpen (no edges, no residual noise), the output is
        // unperturbed whether sharpness is pinned to 0 or left at the
        // filter's own default (0.4) — a re-sharpen has nothing to act on.
        // A moderately denoised NOISY patch does discriminate: at slider
        // 0.5 enough residual noise remains for an un-pinned default
        // sharpness to measurably amplify it back (measured, reverting the
        // pin: std rises to 0.05930, an 0.015 jump — well past this test's
        // 0.004 tolerance — and even violates monotonicity against the
        // unfiltered baseline of 0.05781).
        let input = noisyGray(base: 0.5, amp: 0.10, size: 600)
        let output = EditPipeline.apply(EditState(noiseReduction: 0.5), to: input)

        let result = regionStd(output, x: 0, y: 0, w: 600, h: 600)
        XCTAssertEqual(result.std, 0.04378, accuracy: 0.004)
    }

    // MARK: - Sharpen math
    //
    // Sharpen is a genuine new Core Image filter (CISharpenLuminance), so
    // — unlike Black & White, which reused already-proven math — these
    // values are measured against the real filter, not derived. Sharpening
    // needs a real edge to show any effect (a flat solid is unaffected),
    // so tests use `stepEdgeImage` and sample specific columns on the
    // center row rather than the single-pixel `linearPixel(of:)` helper.

    private func edgePixel(of image: CIImage, x: Int, size: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        pixel(of: image, at: x, size / 2)
    }

    func testSharpenZeroIsIdentity() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(sharpness: 0), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.2, accuracy: accuracy)
    }

    func testSharpenIncreasesEdgeContrast() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)

        let full = EditPipeline.apply(EditState(sharpness: 1), to: input)
        let bright = edgePixel(of: full, x: 401, size: 800).r
        let dark = edgePixel(of: full, x: 398, size: 800).r
        XCTAssertEqual(bright, 0.63963, accuracy: accuracy)
        XCTAssertEqual(dark, 0.13242, accuracy: accuracy)
        XCTAssertGreaterThan(bright - dark, 0.3, "sharpened edge contrast should exceed the unsharpened 0.3 baseline")

        // Flats away from the edge stay close to their original value.
        XCTAssertEqual(edgePixel(of: full, x: 200, size: 800).r, 0.2, accuracy: 0.005)
        XCTAssertEqual(edgePixel(of: full, x: 600, size: 800).r, 0.5, accuracy: 0.005)

        // Monotonic growth vs a half-strength slider.
        let half = EditPipeline.apply(EditState(sharpness: 0.5), to: input)
        let halfBright = edgePixel(of: half, x: 401, size: 800).r
        XCTAssertEqual(halfBright, 0.56731, accuracy: accuracy)
        XCTAssertLessThan(halfBright, bright)
    }

    func testSharpenRadiusScalesWithResolution() {
        // A FIXED pixel radius would give an IDENTICAL peak regardless of
        // image size; measured peaks strictly increase with resolution,
        // proving the radius scales with the image's own dimensions.
        let sizes = [400, 800, 1600]
        let expected: [Float] = [0.53896, 0.63963, 0.72959]

        var peaks: [Float] = []
        for size in sizes {
            let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: size)
            let output = EditPipeline.apply(EditState(sharpness: 1), to: input)
            peaks.append(edgePixel(of: output, x: size / 2 + 1, size: size).r)
        }

        for (peak, expectedValue) in zip(peaks, expected) {
            XCTAssertEqual(peak, expectedValue, accuracy: accuracy)
        }
        XCTAssertLessThan(peaks[0], peaks[1])
        XCTAssertLessThan(peaks[1], peaks[2])
    }

    func testSharpenPreservesHighlightHeadroom() {
        let input = stepEdgeImage(lo: 0.8, hi: 1.4, size: 800)
        let output = EditPipeline.apply(EditState(sharpness: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 1.65193, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 600, size: 800).r, 1.40238, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.63947, accuracy: accuracy)
    }

    func testSharpenPreservesAlpha() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800, alpha: 0.5)
        let output = EditPipeline.apply(EditState(sharpness: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 200, size: 800).a, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).a, 0.5, accuracy: accuracy)
    }

    func testSharpenFlatImageUnaffected() {
        let input = solidColorImage(0.35, size: 800)
        let output = EditPipeline.apply(EditState(sharpness: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 400, size: 800).r, 0.35, accuracy: accuracy)
    }

    func testSharpenCommutesWithVignette() {
        // Documents the measured order-independence (≤0.00100, below this
        // file's tolerance) that justifies running Sharpen after Vignette
        // without needing a dedicated ordering-discriminator test the way
        // Straighten/Flip needed one (those genuinely don't commute).
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(vignetteStrength: 1, sharpness: 1), to: input)
        let bright = edgePixel(of: output, x: 401, size: 800)

        XCTAssertFalse(bright.r.isNaN)
        XCTAssertEqual(bright.r, 0.63963, accuracy: 0.01)
    }

    // MARK: - EditState

    func testEditStateDefaultIsIdentity() {
        XCTAssertEqual(EditState().exposureEV, 0)
        XCTAssertEqual(EditState().levelsBlackPoint, 0)
        XCTAssertEqual(EditState().levelsWhitePoint, 1)
        XCTAssertEqual(EditState().levelsGamma, 1)
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
        XCTAssertEqual(EditState().redHue, 0)
        XCTAssertEqual(EditState().redSaturation, 0)
        XCTAssertEqual(EditState().redLuminance, 0)
        XCTAssertEqual(EditState().orangeHue, 0)
        XCTAssertEqual(EditState().orangeSaturation, 0)
        XCTAssertEqual(EditState().orangeLuminance, 0)
        XCTAssertEqual(EditState().yellowHue, 0)
        XCTAssertEqual(EditState().yellowSaturation, 0)
        XCTAssertEqual(EditState().yellowLuminance, 0)
        XCTAssertEqual(EditState().greenHue, 0)
        XCTAssertEqual(EditState().greenSaturation, 0)
        XCTAssertEqual(EditState().greenLuminance, 0)
        XCTAssertEqual(EditState().aquaHue, 0)
        XCTAssertEqual(EditState().aquaSaturation, 0)
        XCTAssertEqual(EditState().aquaLuminance, 0)
        XCTAssertEqual(EditState().blueHue, 0)
        XCTAssertEqual(EditState().blueSaturation, 0)
        XCTAssertEqual(EditState().blueLuminance, 0)
        XCTAssertEqual(EditState().purpleHue, 0)
        XCTAssertEqual(EditState().purpleSaturation, 0)
        XCTAssertEqual(EditState().purpleLuminance, 0)
        XCTAssertEqual(EditState().magentaHue, 0)
        XCTAssertEqual(EditState().magentaSaturation, 0)
        XCTAssertEqual(EditState().magentaLuminance, 0)
        XCTAssertEqual(EditState().selectiveColorRange, 0.5)
        XCTAssertEqual(EditState().vibrance, 0)
        XCTAssertEqual(EditState().blackAndWhite, false)
        XCTAssertEqual(EditState().straightenAngle, 0)
        XCTAssertEqual(EditState().verticalPerspective, 0)
        XCTAssertEqual(EditState().horizontalPerspective, 0)
        XCTAssertEqual(EditState().flipHorizontal, false)
        XCTAssertEqual(EditState().flipVertical, false)
        XCTAssertEqual(EditState().cropInsetTop, 0)
        XCTAssertEqual(EditState().cropInsetBottom, 0)
        XCTAssertEqual(EditState().cropInsetLeft, 0)
        XCTAssertEqual(EditState().cropInsetRight, 0)
        XCTAssertEqual(EditState().redEyePoints, [])
        XCTAssertEqual(EditState().redEyeSize, 0.5)
        XCTAssertEqual(EditState().redEyeStrength, 0.7)
        XCTAssertEqual(EditState().vignetteStrength, 0)
        XCTAssertEqual(EditState().vignetteRadius, 0.5)
        XCTAssertEqual(EditState().clarity, 0)
        XCTAssertEqual(EditState().texture, 0)
        XCTAssertEqual(EditState().noiseReduction, 0)
        XCTAssertEqual(EditState().sharpness, 0)

        let input = solidColorImage(0.35)
        let output = EditPipeline.apply(EditState(), to: input)
        XCTAssertEqual(linearPixel(of: output).r, linearPixel(of: input).r, accuracy: accuracy)
    }

    func testEditStateCodableRoundTrip() throws {
        let original = EditState(
            whiteBalanceTemperature: 5200,
            whiteBalanceTint: -10,
            exposureEV: 1.37,
            levelsBlackPoint: 0.1,
            levelsWhitePoint: 0.85,
            levelsGamma: 1.3,
            brightness: 0.25,
            contrast: -0.4,
            curvesShadows: 0.6,
            curvesHighlights: -0.2,
            blackPoint: -0.3,
            brilliance: 0.5,
            hslHue: 45,
            hslSaturation: 0.3,
            redHue: 0.1,
            redSaturation: 0.2,
            redLuminance: 0.3,
            orangeHue: -0.1,
            orangeSaturation: -0.2,
            orangeLuminance: -0.3,
            yellowHue: 0.15,
            yellowSaturation: 0.25,
            yellowLuminance: 0.35,
            greenHue: -0.15,
            greenSaturation: -0.25,
            greenLuminance: -0.35,
            aquaHue: 0.05,
            aquaSaturation: 0.1,
            aquaLuminance: 0.15,
            blueHue: -0.05,
            blueSaturation: -0.1,
            blueLuminance: -0.15,
            purpleHue: 0.4,
            purpleSaturation: 0.45,
            purpleLuminance: 0.5,
            magentaHue: -0.4,
            magentaSaturation: -0.45,
            magentaLuminance: -0.5,
            selectiveColorRange: 0.7,
            vibrance: 0.4,
            blackAndWhite: true,
            straightenAngle: 12.5,
            verticalPerspective: 0.3,
            horizontalPerspective: -0.4,
            flipHorizontal: true,
            flipVertical: false,
            cropInsetTop: 0.1,
            cropInsetBottom: 0.05,
            cropInsetLeft: 0.15,
            cropInsetRight: 0.2,
            redEyePoints: [RedEyePoint(x: 0.3, y: 0.4), RedEyePoint(x: 0.6, y: 0.65)],
            redEyeSize: 0.4,
            redEyeStrength: 0.9,
            vignetteStrength: 0.7,
            vignetteRadius: 0.3,
            clarity: 0.55,
            noiseReduction: 0.45,
            sharpness: 0.6,
            boostAmount: 0.35,
            rawExposureEV: 0.75,
            shadowBoostScale: 0.4,
            rawWhiteBalanceNeutralPoints: [RawNeutralPoint(x: 0.3, y: 0.7)],
            rawLuminanceNoiseReductionAdjust: 0.2,
            rawColorNoiseReductionScale: 0.8,
            rawSharpnessScale: 0.15,
            rawContrastAdjust: 0.45,
            rawDetailAdjust: 1.75,
            rawMoireReductionAdjust: 0.6,
            rawDecoderVersionPin: "7"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    /// Pins the architecture Phase 6 slices 2-7 depend on: the RAW-native
    /// fields (`boostAmount`, `rawExposureEV`, `shadowBoostScale`,
    /// `rawWhiteBalanceNeutralPoints`, `rawLuminanceNoiseReductionAdjust`,
    /// `rawColorNoiseReductionScale`, `rawSharpnessScale`,
    /// `rawContrastAdjust`, `rawDetailAdjust`, `rawMoireReductionAdjust`,
    /// `rawDecoderVersionPin`) configure `CIRAWFilter` itself, upstream
    /// of `EditPipeline` — none is one of this function's stages and all
    /// must have zero effect on its output. Fails loudly if a future
    /// session tries to "wire the missing fields into the pipeline" by
    /// mistake (there's nothing there to wire them into; they only take
    /// effect via `RawDecoder`/`ImageDocumentModel.redecodeForRawNativeChange`).
    func testRawNativeFieldsHaveNoEffectOnTheEditPipeline() {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        // Reviewer-caught (slice 2): comparing two otherwise-IDENTITY
        // states only proves these fields don't matter when nothing else
        // is active — strictly stronger to also confirm they don't
        // interact with OTHER active fields (exposure, contrast, B&W,
        // vignette all touch pixel values in ways a stray RAW-native
        // field read could plausibly compound with).
        var low = EditState()
        low.exposureEV = 0.8
        low.contrast = 0.3
        low.blackAndWhite = true
        low.vignetteStrength = 0.4
        low.boostAmount = 0
        low.rawExposureEV = -2
        low.shadowBoostScale = 0
        low.rawLuminanceNoiseReductionAdjust = 0
        low.rawColorNoiseReductionScale = 0
        low.rawSharpnessScale = 0
        low.rawContrastAdjust = -1
        low.rawDetailAdjust = -3
        low.rawMoireReductionAdjust = -1
        low.rawDecoderVersionPin = ""
        var high = low
        high.boostAmount = 1
        high.rawExposureEV = 2
        high.shadowBoostScale = 1
        high.rawWhiteBalanceNeutralPoints = [RawNeutralPoint(x: 0.25, y: 0.75)]
        high.rawLuminanceNoiseReductionAdjust = 1
        high.rawColorNoiseReductionScale = 1
        high.rawSharpnessScale = 1
        high.rawContrastAdjust = 1
        high.rawDetailAdjust = 3
        high.rawMoireReductionAdjust = 1
        high.rawDecoderVersionPin = "7"

        let lowOutput = EditPipeline.apply(low, to: image)
        let highOutput = EditPipeline.apply(high, to: image)

        let context = CIContext()
        var lowPixel = [UInt8](repeating: 0, count: 4)
        var highPixel = [UInt8](repeating: 0, count: 4)
        let bounds = CGRect(x: 8, y: 8, width: 1, height: 1)
        context.render(lowOutput, toBitmap: &lowPixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        context.render(highOutput, toBitmap: &highPixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        XCTAssertEqual(lowPixel, highPixel)
    }

    // MARK: - Grain math

    func testGrainZeroIsIdentity() {
        let flat = solidColorImage(0.5)
        let noisy = noisyGray(base: 0.5, amp: 0.2, size: 32)
        XCTAssertEqual(pixel(of: EditPipeline.apply(EditState(), to: flat), at: 0, 0).r, 0.5, accuracy: 0)
        let untouched = pixel(of: noisy, at: 4, 4)
        let output = pixel(of: EditPipeline.apply(EditState(), to: noisy), at: 4, 4)
        XCTAssertEqual(output.r, untouched.r, accuracy: 0, "grain 0 must be an exact identity no-op")
    }

    func testGrainAddsMeasurableNoise() {
        var state = EditState()
        state.grain = 1.0
        let input = solidColorImage(0.5, size: 64)
        let output = EditPipeline.apply(state, to: input)
        let inputStd = regionStd(input, x: 0, y: 0, w: 64, h: 64).std
        let outputStd = regionStd(output, x: 0, y: 0, w: 64, h: 64).std
        XCTAssertEqual(Double(inputStd), 0, accuracy: 1e-6, "fixture must actually be flat, or this proves nothing")
        XCTAssertEqual(Double(outputStd), 0.19939, accuracy: 0.01)
    }

    func testGrainAmountIsMonotone() {
        let input = solidColorImage(0.5, size: 64)
        var low = EditState(); low.grain = 0.5
        var high = EditState(); high.grain = 1.0
        let noGrainStd = regionStd(EditPipeline.apply(EditState(), to: input), x: 0, y: 0, w: 64, h: 64).std
        let lowStd = regionStd(EditPipeline.apply(low, to: input), x: 0, y: 0, w: 64, h: 64).std
        let highStd = regionStd(EditPipeline.apply(high, to: input), x: 0, y: 0, w: 64, h: 64).std
        XCTAssertLessThan(Double(noGrainStd), Double(lowStd))
        XCTAssertLessThan(Double(lowStd), Double(highStd))
    }

    /// The most valuable test in this block: pins that grain is genuinely
    /// zero-mean (via `kGrainZeroPoint`), not a disguised exposure shift.
    /// Deliberately runs at 800px, NOT a small fixture — a REAL, reviewer-
    /// caught bug in an earlier version of this stage (see
    /// `EditPipeline.kGrainZeroPoint`'s own doc comment) only showed up
    /// once the noise's affine scale exceeded 1px (`min(extent)` > 500px);
    /// a 64px fixture floors `cell` to exactly 1px and would have stayed
    /// green through that entire bug's lifetime. The tolerance is wide
    /// enough to accommodate the MEASURED, expected Jensen's-inequality-
    /// style drift from adding symmetric noise before a nonlinear encode/
    /// decode round trip (up to +0.031 at linear 0.214, measured at this
    /// same 800px size — see `EditPipeline.applyGrain`'s own doc comment)
    /// — this test would still catch a genuinely broken zero-point (e.g.
    /// one off by 0.1+), which is the actual regression it guards against.
    func testGrainPreservesMeanBrightness() {
        for base in [0.05, 0.214, 0.5, 0.8, 0.95] {
            var state = EditState(); state.grain = 1.0
            let output = EditPipeline.apply(state, to: solidColorImage(base, size: 800))
            let mean = regionStd(output, x: 300, y: 300, w: 200, h: 200).mean
            XCTAssertEqual(Double(mean), base, accuracy: 0.05, "at linear \(base)")
        }
    }

    /// The measured shape of the kernel's tonal weight `w = 4*L*(1-L)`
    /// across the tone range, at 800px (see `testGrainPreservesMeanBrightness`
    /// for why this must not be a small fixture) — cited by name in
    /// `EditPipeline.kGrainAmountSpan`'s own doc comment.
    func testGrainToneWeightAcrossRange() {
        let expected: [Double: Double] = [0.05: 0.05474, 0.214: 0.16417, 0.5: 0.20193, 0.8: 0.11419, 0.95: 0.03236]
        for (base, expectedStd) in expected {
            var state = EditState(); state.grain = 1.0
            let output = EditPipeline.apply(state, to: solidColorImage(base, size: 800))
            let std = regionStd(output, x: 300, y: 300, w: 200, h: 200).std
            XCTAssertEqual(Double(std), expectedStd, accuracy: 0.02, "at linear \(base)")
        }
    }

    func testGrainIsMonochromatic() {
        var state = EditState(); state.grain = 1.0
        let color = CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let output = EditPipeline.apply(state, to: input)
        for (x, y) in [(2, 3), (10, 17), (25, 8), (30, 30)] {
            let p = pixel(of: output, at: x, y)
            XCTAssertEqual(Double(p.r), Double(p.g), accuracy: 1e-5, "at (\(x),\(y))")
            XCTAssertEqual(Double(p.g), Double(p.b), accuracy: 1e-5, "at (\(x),\(y))")
        }
    }

    func testGrainVanishesAtBlackAndWhite() {
        var state = EditState(); state.grain = 1.0
        let blackStd = regionStd(EditPipeline.apply(state, to: solidColorImage(0, size: 32)), x: 0, y: 0, w: 32, h: 32).std
        let whiteStd = regionStd(EditPipeline.apply(state, to: solidColorImage(1, size: 32)), x: 0, y: 0, w: 32, h: 32).std
        XCTAssertEqual(Double(blackStd), 0, accuracy: 1e-4)
        XCTAssertEqual(Double(whiteStd), 0, accuracy: 1e-4)
    }

    func testGrainDoesNotProduceNegativeValues() {
        var state = EditState(); state.grain = 1.0
        let output = EditPipeline.apply(state, to: solidColorImage(0.02, size: 64))
        var buffer = [Float](repeating: 0, count: 64 * 64 * 4)
        context.render(output, toBitmap: &buffer, rowBytes: 64 * 16,
                        bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: linearSpace)
        var minValue: Float = .infinity
        for i in 0..<(64 * 64) {
            minValue = min(minValue, buffer[i * 4], buffer[i * 4 + 1], buffer[i * 4 + 2])
        }
        XCTAssertGreaterThanOrEqual(minValue, 0)
    }

    func testGrainPreservesHighlightHeadroom() {
        var state = EditState(); state.grain = 1.0
        let output = EditPipeline.apply(state, to: solidColorImage(1.4, size: 32))
        let mean = regionStd(output, x: 0, y: 0, w: 32, h: 32).mean
        XCTAssertEqual(Double(mean), 1.4, accuracy: 0.002)
        XCTAssertGreaterThan(Double(mean), 1.0)
    }

    func testGrainPreservesAlpha() {
        var state = EditState(); state.grain = 1.0
        let noisy = noisyGray(base: 0.5, amp: 0.1, size: 16, alpha: 0.5)
        let output = EditPipeline.apply(state, to: noisy)
        XCTAssertEqual(pixel(of: output, at: 8, 8).a, 0.5, accuracy: 0.002)
    }

    func testGrainPreservesExtent() {
        var state = EditState()
        state.grain = 1.0
        state.cropInsetTop = 0.25
        state.cropInsetLeft = 0.1
        let input = solidColorImage(0.5, size: 64)
        let cropOnly = EditPipeline.apply(EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1), to: input)
        let withGrain = EditPipeline.apply(state, to: input)
        XCTAssertEqual(withGrain.extent, cropOnly.extent)
    }

    func testGrainIsDeterministic() {
        var state = EditState(); state.grain = 0.6
        let input = solidColorImage(0.5, size: 64)
        let first = EditPipeline.apply(state, to: input)
        let second = EditPipeline.apply(state, to: input)
        var bufferA = [Float](repeating: 0, count: 64 * 64 * 4)
        var bufferB = [Float](repeating: 0, count: 64 * 64 * 4)
        let freshContext = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])
        context.render(first, toBitmap: &bufferA, rowBytes: 64 * 16,
                        bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: linearSpace)
        freshContext.render(second, toBitmap: &bufferB, rowBytes: 64 * 16,
                             bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: linearSpace)
        XCTAssertEqual(bufferA, bufferB, "grain must render bit-identically across separate CIContexts/render passes for this app's determinism invariant")
    }

    /// MEASURED, not assumed (800px flat patch, region std over a 256px
    /// sample) — see `EditPipeline.applyGrain`'s own doc comment for the
    /// full reasoning. Pins the shipped order as a regression: reversing it
    /// would push this well outside tolerance (the reversed order measures
    /// 0.23888, ~2.4x higher).
    func testGrainSharpenOrderIsFixed() {
        var state = EditState()
        state.grain = 0.5
        state.sharpness = 1.0
        let output = EditPipeline.apply(state, to: solidColorImage(0.5, size: 800))
        let std = regionStd(output, x: 0, y: 0, w: 256, h: 256).std
        XCTAssertEqual(Double(std), 0.09936, accuracy: 0.01)
    }

    /// MEASURED, not assumed — see `EditPipeline.applyGrain`'s own doc
    /// comment. Pins the shipped order (grain after Noise Reduction) as a
    /// regression: the reversed order measures 0.06439, ~35% lower (NR
    /// eating the grain).
    func testGrainNoiseReductionOrderIsFixed() {
        var state = EditState()
        state.grain = 0.5
        state.noiseReduction = 1.0
        let output = EditPipeline.apply(state, to: solidColorImage(0.5, size: 800))
        let std = regionStd(output, x: 0, y: 0, w: 256, h: 256).std
        XCTAssertEqual(Double(std), 0.09936, accuracy: 0.01)
    }

    /// MEASURED after the `kGrainZeroPoint`/`.samplingNearest()` fix (see
    /// `EditPipeline.kGrainCellFraction`'s own doc comment) — genuinely
    /// stable across a 4x resolution range now, unlike the pre-fix
    /// construction this test's own history caught drifting.
    func testGrainAmplitudeIsResolutionConsistent() {
        let expected: [Int: Double] = [400: 0.19946, 800: 0.20453, 1600: 0.21236]
        for (size, expectedStd) in expected {
            var state = EditState(); state.grain = 1.0
            let output = EditPipeline.apply(state, to: solidColorImage(0.5, size: size))
            let origin = size / 2 - 32
            let std = regionStd(output, x: origin, y: origin, w: 64, h: 64).std
            XCTAssertEqual(Double(std), expectedStd, accuracy: 0.03, "at \(size)px")
        }
    }

    func testGrainDefaultIsZero() {
        XCTAssertEqual(EditState().grain, 0)
    }
}
