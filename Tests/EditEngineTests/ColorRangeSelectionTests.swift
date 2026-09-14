import XCTest
@testable import PhotoApp

/// Verifies `ColorRangeSelection`'s pure math — the tolerance-window
/// interpolation, the tone/scene-linear mapping, and the Swift-side twin of
/// `ColorRange.cikernel`'s own per-pixel HSL/luma conversion.
final class ColorRangeSelectionTests: XCTestCase {
    private let accuracy = 0.0001
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 200)

    // MARK: - Degenerate input -> nil

    func testInfiniteExtentReturnsNil() {
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: true, targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: 0.3, feather: 0.5, extent: .infinite
        ))
    }

    func testNullExtentReturnsNil() {
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: true, targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: 0.3, feather: 0.5, extent: .null
        ))
    }

    func testZeroSizedExtentReturnsNil() {
        let zero = CGRect(x: 0, y: 0, width: 0, height: 200)
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: true, targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: 0.3, feather: 0.5, extent: zero
        ))
    }

    func testHasTargetFalseReturnsNil() {
        // The defining contract of this kind: an un-picked mask selects
        // nothing, regardless of how plausible the other scalars look.
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: false, targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: 0.3, feather: 0.5, extent: extent
        ))
    }

    func testNaNHueReturnsNil() {
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: true, targetHue: .nan, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: 0.3, feather: 0.5, extent: extent
        ))
    }

    func testNaNToleranceReturnsNil() {
        XCTAssertNil(ColorRangeSelection.resolve(
            hasTarget: true, targetHue: 30, targetSaturation: 0.5, targetLuminance: 0.3,
            tolerance: .nan, feather: 0.5, extent: extent
        ))
    }

    // MARK: - Clamping (never nil for out-of-range input, once hasTarget is true)

    func testToleranceClampsBelowMinimum() {
        let low = resolve(tolerance: -5)!
        let atMin = resolve(tolerance: ColorRangeSelection.minimumTolerance)!
        XCTAssertEqual(low, atMin)
    }

    func testToleranceClampsAboveMaximum() {
        let high = resolve(tolerance: 5)!
        let atMax = resolve(tolerance: ColorRangeSelection.maximumTolerance)!
        XCTAssertEqual(high, atMax)
    }

    func testHueWrapsIntoZeroTo360() {
        let negative = resolve(hue: -30)!
        let wrapped = resolve(hue: 330)!
        XCTAssertEqual(negative.targetHue, wrapped.targetHue, accuracy: accuracy)

        let over = resolve(hue: 390)!
        let equivalent = resolve(hue: 30)!
        XCTAssertEqual(over.targetHue, equivalent.targetHue, accuracy: accuracy)
    }

    func testSaturationClampsToZeroOne() {
        let negative = resolve(saturation: -1)!
        let atZero = resolve(saturation: 0)!
        XCTAssertEqual(negative.targetSaturation, atZero.targetSaturation, accuracy: accuracy)

        let over = resolve(saturation: 5)!
        let atOne = resolve(saturation: 1)!
        XCTAssertEqual(over.targetSaturation, atOne.targetSaturation, accuracy: accuracy)
    }

    func testNegativeLuminanceNeverCrashesAndStaysUnclamped() {
        // Deliberately NOT clamped -- a measured pixel value can be
        // negative (e.g. an aggressively cooled shadow), same domain
        // flexibility as `LuminanceRangeSelection`'s own tone mapping.
        let r = resolve(luminance: -0.1)!
        XCTAssertEqual(r.targetLuminance, -0.1, accuracy: accuracy)
        XCTAssertGreaterThan(r.lowerLuminanceSpan, 0)
        XCTAssertGreaterThan(r.upperLuminanceSpan, 0)
    }

    // MARK: - hueSaturation(forLinearRGB:_:_:)

    func testHueSaturationPureRed() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 0, 0)
        XCTAssertEqual(hue, 0, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationPureGreen() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 0, 1, 0)
        XCTAssertEqual(hue, 120, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationPureBlue() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 0, 0, 1)
        XCTAssertEqual(hue, 240, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationCyan() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 0, 1, 1)
        XCTAssertEqual(hue, 180, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationMagenta() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 0, 1)
        XCTAssertEqual(hue, 300, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationYellow() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 1, 0)
        XCTAssertEqual(hue, 60, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationNeutralGrayHasZeroSaturation() {
        let (_, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 0.4, 0.4, 0.4)
        XCTAssertEqual(sat, 0, accuracy: 0.0001)
    }

    /// The direct Swift-side analogue of `SelectiveColor.cikernel`'s real
    /// shipped bug: a colored HEADROOM pixel (max channel > 1) must still
    /// resolve to the correct hue/saturation once headroom-normalized,
    /// not silently misbehave from a negative HSL saturation denominator.
    func testHueSaturationHeadroomColoredPixelResolvesCorrectly() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 2, 0, 0)
        XCTAssertEqual(hue, 0, accuracy: 0.01)
        XCTAssertEqual(sat, 1, accuracy: 0.01)
    }

    func testHueSaturationIsHeadroomScaleInvariant() {
        let (hueAt1, satAt1) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 0.5, 0.2)
        let (hueAt3, satAt3) = ColorRangeSelection.hueSaturation(forLinearRGB: 3, 1.5, 0.6)
        XCTAssertEqual(hueAt1, hueAt3, accuracy: 0.01)
        XCTAssertEqual(satAt1, satAt3, accuracy: 0.01)
    }

    func testHueSaturationClampsNegativeChannels() {
        let (hue, sat) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, -0.3, -0.1)
        let (expectedHue, expectedSat) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 0, 0)
        XCTAssertEqual(hue, expectedHue, accuracy: 0.01)
        XCTAssertEqual(sat, expectedSat, accuracy: 0.01)
    }

    /// Catches the floored-vs-symmetric-modulo trap directly: a
    /// magenta-side red (green channel below blue) exercises the ONE
    /// branch (`maxC == nr`) where GLSL's floored `mod` and Swift's
    /// symmetric `truncatingRemainder` disagree.
    func testHueSaturationMagentaSideRedUsesFlooredModulo() {
        // R is max, B > G -- (g - b)/c is negative, so a naive symmetric
        // remainder would produce a negative intermediate before the
        // final *60, landing on the WRONG side of 0/360 if not floored.
        let (hue, _) = ColorRangeSelection.hueSaturation(forLinearRGB: 1, 0.1, 0.3)
        // Hand-computed: chroma = 0.9, (0.1-0.3)/0.9 = -0.2222 -> floored
        // mod 6 = 5.7778 -> *60 = 346.67 degrees (magenta-red, NOT ~13
        // degrees, which a naive unfloored path would produce after the
        // final `if h < 0` add-360 masked the sign difference at a
        // different magnitude).
        XCTAssertEqual(hue, 346.67, accuracy: 0.1)
    }

    // MARK: - tone(forLinearLuminance:) -- exact inverse round-trip

    func testToneIsExactInverseOfLinearLuminanceAcrossALadder() {
        let tones = [-0.2, 0, 0.02, 0.04045, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.3]
        for t in tones {
            let linear = LuminanceRangeSelection.linearLuminance(forTone: t)
            let roundTripped = ColorRangeSelection.tone(forLinearLuminance: linear)
            XCTAssertEqual(roundTripped, t, accuracy: 0.0001, "failed for tone \(t)")
        }
    }

    func testLinearLuminanceIsExactInverseOfToneAcrossALadder() {
        let linears = [-0.05, 0, 0.001, 0.0031308, 0.05, 0.214, 0.5, 1.0, 1.3]
        for y in linears {
            let tone = ColorRangeSelection.tone(forLinearLuminance: y)
            let roundTripped = LuminanceRangeSelection.linearLuminance(forTone: tone)
            XCTAssertEqual(roundTripped, y, accuracy: 0.0001, "failed for linear \(y)")
        }
    }

    // MARK: - Resolved invariants

    func testWindowsArePositiveAtEveryToleranceExtreme() {
        for tolerance in [0.0, 0.5, 1.0] {
            let r = resolve(tolerance: tolerance)!
            XCTAssertGreaterThan(r.hueWindowDegrees, 0)
            XCTAssertGreaterThan(r.saturationWindow, 0)
            XCTAssertGreaterThan(r.lowerLuminanceSpan, 0)
            XCTAssertGreaterThan(r.upperLuminanceSpan, 0)
            XCTAssertGreaterThan(r.falloffWidth, 0)
        }
    }

    func testAsymmetricLuminanceSpansAtMidGrayTarget() {
        // The whole point of the tone -> linear split: a symmetric tone
        // window around mid-gray is NOT symmetric in scene-linear light.
        let r = resolve(luminance: LuminanceRangeSelection.linearLuminance(forTone: 0.5), tolerance: 0.5)!
        XCTAssertNotEqual(r.lowerLuminanceSpan, r.upperLuminanceSpan, accuracy: 0.001)
    }

    func testWindowsGrowMonotonicallyWithTolerance() {
        let low = resolve(tolerance: 0.1)!
        let high = resolve(tolerance: 0.9)!
        XCTAssertGreaterThan(high.hueWindowDegrees, low.hueWindowDegrees)
        XCTAssertGreaterThan(high.saturationWindow, low.saturationWindow)
        XCTAssertGreaterThan(high.lowerLuminanceSpan, low.lowerLuminanceSpan)
        XCTAssertGreaterThan(high.upperLuminanceSpan, low.upperLuminanceSpan)
    }

    func testRegionOfInterestIsTheFullExtent() {
        let r = resolve()!
        XCTAssertEqual(r.regionOfInterest, extent)
    }

    func testWorkedExampleMatchesHandDerivedNumbers() {
        // hue 200, saturation 0.4, luminance = mid-gray linear, tolerance
        // 0.5, feather 0.5 -- interpolated windows at tolerance 0.5 sit
        // exactly halfway between each axis's own min/max constants.
        let r = resolve(hue: 200, saturation: 0.4, luminance: 0.214, tolerance: 0.5, feather: 0.5)!
        XCTAssertEqual(r.hueWindowDegrees, (5 + 90) / 2, accuracy: 0.01)
        XCTAssertEqual(r.saturationWindow, (0.05 + 0.75) / 2, accuracy: 0.001)
        XCTAssertEqual(r.falloffWidth, 0.5, accuracy: 0.0001)
    }

    // MARK: - displaySRGB round-trip

    func testDisplaySRGBIsLumaPreservingForAMidGrayTarget() {
        let swatch = ColorRangeSelection.displaySRGB(hue: 0, saturation: 0, luminance: 0.214)
        let reconstructedLuma = ColorRangeSelection.luminance(forLinearRGB: swatch.r, swatch.g, swatch.b)
        // The swatch itself is sRGB-ENCODED; decode it back to scene-linear
        // via LuminanceRangeSelection's own forward tone mapping before
        // comparing luma, matching how the rest of this pipeline treats
        // "tone" vs "linear" values.
        let decoded = (
            LuminanceRangeSelection.linearLuminance(forTone: swatch.r),
            LuminanceRangeSelection.linearLuminance(forTone: swatch.g),
            LuminanceRangeSelection.linearLuminance(forTone: swatch.b)
        )
        let decodedLuma = ColorRangeSelection.luminance(forLinearRGB: decoded.0, decoded.1, decoded.2)
        XCTAssertEqual(decodedLuma, 0.214, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(reconstructedLuma, 0)
    }

    func testDisplaySRGBPreservesHueForASaturatedTarget() {
        let swatch = ColorRangeSelection.displaySRGB(hue: 210, saturation: 0.6, luminance: 0.3)
        let decoded = (
            LuminanceRangeSelection.linearLuminance(forTone: swatch.r),
            LuminanceRangeSelection.linearLuminance(forTone: swatch.g),
            LuminanceRangeSelection.linearLuminance(forTone: swatch.b)
        )
        let (hue, _) = ColorRangeSelection.hueSaturation(forLinearRGB: decoded.0, decoded.1, decoded.2)
        XCTAssertEqual(hue, 210, accuracy: 2)
    }

    func testDisplaySRGBClampsHeadroomToOne() {
        let atHeadroom = ColorRangeSelection.displaySRGB(hue: 0, saturation: 1, luminance: 3)
        let atOne = ColorRangeSelection.displaySRGB(hue: 0, saturation: 1, luminance: 1)
        XCTAssertEqual(atHeadroom.r, atOne.r, accuracy: 0.01)
        XCTAssertEqual(atHeadroom.g, atOne.g, accuracy: 0.01)
        XCTAssertEqual(atHeadroom.b, atOne.b, accuracy: 0.01)
    }

    /// Reviewer-caught (round 1): a hand-edited/corrupt sidecar's `.nan`
    /// scalar must never propagate into a SwiftUI `Color` — `displaySRGB`
    /// used to have no guard at all, unlike `resolve`'s own `nil` return
    /// for non-finite input.
    func testDisplaySRGBNonFiniteInputsReturnBlackNotNaN() {
        for candidate in [
            ColorRangeSelection.displaySRGB(hue: .nan, saturation: 0.5, luminance: 0.2),
            ColorRangeSelection.displaySRGB(hue: 30, saturation: .nan, luminance: 0.2),
            ColorRangeSelection.displaySRGB(hue: 30, saturation: 0.5, luminance: .nan),
            ColorRangeSelection.displaySRGB(hue: .infinity, saturation: 0.5, luminance: 0.2)
        ] {
            XCTAssertEqual(candidate.r, 0)
            XCTAssertEqual(candidate.g, 0)
            XCTAssertEqual(candidate.b, 0)
        }
    }

    /// Reviewer-caught (round 1): an out-of-0..<360 stored hue (e.g. from a
    /// hand-edited sidecar) must wrap the SAME way `resolve` already wraps
    /// its own `targetHue`, or the swatch reads a different hue than the
    /// kernel actually selects on.
    func testDisplaySRGBWrapsOutOfRangeHue() {
        let negative = ColorRangeSelection.displaySRGB(hue: -400, saturation: 0.8, luminance: 0.3)
        let wrapped = ColorRangeSelection.displaySRGB(hue: -400 + 720, saturation: 0.8, luminance: 0.3)
        XCTAssertEqual(negative.r, wrapped.r, accuracy: 0.001)
        XCTAssertEqual(negative.g, wrapped.g, accuracy: 0.001)
        XCTAssertEqual(negative.b, wrapped.b, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func resolve(
        hue: Double = 30, saturation: Double = 0.5, luminance: Double = 0.3,
        tolerance: Double = 0.3, feather: Double = 0.5
    ) -> ColorRangeSelection.Resolved? {
        ColorRangeSelection.resolve(
            hasTarget: true, targetHue: hue, targetSaturation: saturation, targetLuminance: luminance,
            tolerance: tolerance, feather: feather, extent: extent
        )
    }
}
