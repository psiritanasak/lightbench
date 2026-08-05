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

    // MARK: - Definition (Clarity) math
    //
    // Definition is CIUnsharpMask at a much larger radius than Sharpen, so
    // — like Sharpen and Noise Reduction — these values are measured
    // against the real filter, not derived. Uses `stepEdgeImage` and
    // `edgePixel` (defined below, under Sharpen math) exactly like Sharpen's
    // own tests, sampling several offsets from the edge to show the WIDE
    // band that distinguishes local contrast from fine sharpening.

    func testDefinitionZeroIsIdentity() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(definition: 0), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.2, accuracy: accuracy)
    }

    func testDefinitionBoostsLocalContrastOverBroadBand() {
        // The signature test: Definition's overshoot stays elevated far from
        // the edge (x=430, x=460 — 30px/60px away), where a fine sharpen has
        // already decayed to baseline. That WIDTH, not the peak, is what
        // makes this local contrast rather than fine detail sharpening.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let output = EditPipeline.apply(EditState(definition: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 0.66061, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 415, size: 800).r, 0.60219, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 430, size: 800).r, 0.55443, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 460, size: 800).r, 0.50955, accuracy: accuracy)
        XCTAssertGreaterThan(edgePixel(of: output, x: 460, size: 800).r, 0.505, "still measurably elevated 60px from the edge")

        // Monotonic decay back toward baseline as we move further away.
        XCTAssertEqual(edgePixel(of: output, x: 500, size: 800).r, 0.5, accuracy: accuracy)
    }

    func testDefinitionHaloIsWiderThanSharpen() {
        // Discriminator vs the shipped Sharpen tool: at the same offset from
        // the edge, Definition stays elevated while Sharpen (tiny radius)
        // has already returned to baseline.
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800)
        let definitionOutput = EditPipeline.apply(EditState(definition: 1), to: input)
        let sharpenOutput = EditPipeline.apply(EditState(sharpness: 1), to: input)

        let definitionFar = edgePixel(of: definitionOutput, x: 430, size: 800).r
        let sharpenFar = edgePixel(of: sharpenOutput, x: 430, size: 800).r
        XCTAssertGreaterThan(definitionFar, sharpenFar)
        XCTAssertEqual(sharpenFar, 0.5, accuracy: 0.005, "Sharpen's tiny radius should already be flat 30px from the edge")
    }

    func testDefinitionRadiusScalesWithResolution() {
        // A FIXED pixel radius would give an IDENTICAL profile regardless of
        // image size; measured values strictly increase with resolution at
        // matching offsets, proving the radius scales with the image itself
        // (mirrors testSharpenRadiusScalesWithResolution).
        let sizes = [400, 800, 1600]
        let expected: [Float] = [0.50955, 0.55443, 0.60285]

        var values: [Float] = []
        for size in sizes {
            let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: size)
            let output = EditPipeline.apply(EditState(definition: 1), to: input)
            values.append(edgePixel(of: output, x: size / 2 + 30, size: size).r)
        }

        for (value, expectedValue) in zip(values, expected) {
            XCTAssertEqual(value, expectedValue, accuracy: accuracy)
        }
        XCTAssertLessThan(values[0], values[1])
        XCTAssertLessThan(values[1], values[2])
    }

    func testDefinitionPreservesHighlightHeadroom() {
        let input = stepEdgeImage(lo: 0.8, hi: 1.4, size: 800)
        let output = EditPipeline.apply(EditState(definition: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).r, 1.68714, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 600, size: 800).r, 1.40127, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 398, size: 800).r, 0.62144, accuracy: accuracy)
    }

    func testDefinitionPreservesAlpha() {
        let input = stepEdgeImage(lo: 0.2, hi: 0.5, size: 800, alpha: 0.5)
        let output = EditPipeline.apply(EditState(definition: 1), to: input)

        XCTAssertEqual(edgePixel(of: output, x: 200, size: 800).a, 0.5, accuracy: accuracy)
        XCTAssertEqual(edgePixel(of: output, x: 401, size: 800).a, 0.5, accuracy: accuracy)
    }

    func testDefinitionPreservesExtent() {
        let input = quadrantImage(width: 100, height: 100)
        let withDefinition = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1, definition: 1),
            to: input
        )
        let withoutDefinition = EditPipeline.apply(
            EditState(cropInsetTop: 0.25, cropInsetLeft: 0.1),
            to: input
        )

        XCTAssertEqual(withDefinition.extent, withoutDefinition.extent, "definition must not change the extent crop already established")
    }

    func testDefinitionFlatImageUnaffected() {
        let input = solidColorImage(0.35, size: 800)
        let output = EditPipeline.apply(EditState(definition: 1), to: input)

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
        XCTAssertEqual(EditState().vignetteStrength, 0)
        XCTAssertEqual(EditState().vignetteRadius, 0.5)
        XCTAssertEqual(EditState().definition, 0)
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
            vignetteStrength: 0.7,
            vignetteRadius: 0.3,
            definition: 0.55,
            noiseReduction: 0.45,
            sharpness: 0.6
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
