import XCTest
@testable import PhotoApp

/// Verifies `PointColorSelection`'s pure math — the Swift-side twin of
/// `PointColor.cikernel`'s own headroom-normalize + `rgb2hsl`, and the
/// display-swatch reconstruction.
final class PointColorSelectionTests: XCTestCase {
    private let accuracy = 0.0001

    // MARK: - hueSaturation(forPerceptualRGB:_:_:)

    func testHueSaturationPureRed() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 0, 0)
        XCTAssertEqual(hue, 0, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationPureGreen() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 0, 1, 0)
        XCTAssertEqual(hue, 120, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationPureBlue() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 0, 0, 1)
        XCTAssertEqual(hue, 240, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationCyan() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 0, 1, 1)
        XCTAssertEqual(hue, 180, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationMagenta() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 0, 1)
        XCTAssertEqual(hue, 300, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationYellow() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 1, 0)
        XCTAssertEqual(hue, 60, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    func testHueSaturationNeutralGrayHasZeroSaturation() {
        let (_, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 0.4, 0.4, 0.4)
        XCTAssertEqual(sat, 0, accuracy: accuracy)
    }

    /// A channel above 1.0 (headroom) is normalized by `scale = max(M, 1.0)`
    /// — the same fix `PointColor.cikernel`'s own header comment documents
    /// as necessary so HSL's saturation denominator never goes negative.
    func testHueSaturationHeadroomColoredPixelResolvesCorrectly() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 2, 0, 0)
        XCTAssertEqual(hue, 0, accuracy: accuracy)
        XCTAssertEqual(sat, 1, accuracy: accuracy)
    }

    /// Scale-invariant only within a fixed headroom regime — mirrors
    /// `ColorRangeSelectionTests.testHueSaturationIsHeadroomScaleInvariant`.
    func testHueSaturationIsHeadroomScaleInvariant() {
        let (hueAt1, satAt1) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 0.5, 0.2)
        let (hueAt3, satAt3) = PointColorSelection.hueSaturation(forPerceptualRGB: 3, 1.5, 0.6)
        XCTAssertEqual(hueAt1, hueAt3, accuracy: accuracy)
        XCTAssertEqual(satAt1, satAt3, accuracy: accuracy)
    }

    /// The one deliberate divergence from `ColorRangeSelection.
    /// hueSaturation(forLinearRGB:)`: `PointColor.cikernel` never clamps
    /// negative channels before `rgb2hsl`, so this must not either — a
    /// negative-channel input produces a DIFFERENT (and here, an
    /// out-of-[0,1]-saturation) result than the same input with negatives
    /// clamped to 0, matching what the real kernel would compute for the
    /// same pixel.
    func testHueSaturationDoesNotClampNegativeChannels() {
        let (hue, sat) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, -0.3, -0.1)
        let (clampedHue, clampedSat) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 0, 0)
        XCTAssertNotEqual(hue, clampedHue, accuracy: accuracy)
        XCTAssertNotEqual(sat, clampedSat, accuracy: accuracy)
        XCTAssertGreaterThan(sat, 1, "an un-clamped negative channel can push saturation above 1, matching the kernel's own rgb2hsl")
    }

    /// Magenta-side red (`g < b`) needs the floored modulo, not a plain
    /// division, to land in [0, 360) rather than wrapping negative —
    /// mirrors `ColorRangeSelectionTests.testHueSaturationMagentaSideRedUsesFlooredModulo`.
    func testHueSaturationMagentaSideRedUsesFlooredModulo() {
        let (hue, _) = PointColorSelection.hueSaturation(forPerceptualRGB: 1, 0.1, 0.3)
        XCTAssertGreaterThan(hue, 300)
        XCTAssertLessThan(hue, 360)
    }

    // MARK: - displaySRGB(hue:saturation:)

    func testDisplaySRGBNonFiniteHueReturnsBlack() {
        let swatch = PointColorSelection.displaySRGB(hue: .nan, saturation: 0.5)
        XCTAssertEqual(swatch.r, 0)
        XCTAssertEqual(swatch.g, 0)
        XCTAssertEqual(swatch.b, 0)
    }

    func testDisplaySRGBNonFiniteSaturationReturnsBlack() {
        let swatch = PointColorSelection.displaySRGB(hue: 30, saturation: .infinity)
        XCTAssertEqual(swatch.r, 0)
        XCTAssertEqual(swatch.g, 0)
        XCTAssertEqual(swatch.b, 0)
    }

    func testDisplaySRGBWrapsHueIntoZeroTo360() {
        let negative = PointColorSelection.displaySRGB(hue: -30, saturation: 0.8)
        let wrapped = PointColorSelection.displaySRGB(hue: 330, saturation: 0.8)
        XCTAssertEqual(negative.r, wrapped.r, accuracy: accuracy)
        XCTAssertEqual(negative.g, wrapped.g, accuracy: accuracy)
        XCTAssertEqual(negative.b, wrapped.b, accuracy: accuracy)
    }

    func testDisplaySRGBClampsSaturationBelowZero() {
        let negative = PointColorSelection.displaySRGB(hue: 200, saturation: -1)
        let atZero = PointColorSelection.displaySRGB(hue: 200, saturation: 0)
        XCTAssertEqual(negative.r, atZero.r, accuracy: accuracy)
        XCTAssertEqual(negative.g, atZero.g, accuracy: accuracy)
        XCTAssertEqual(negative.b, atZero.b, accuracy: accuracy)
    }

    func testDisplaySRGBClampsSaturationAboveOne() {
        let over = PointColorSelection.displaySRGB(hue: 200, saturation: 5)
        let atOne = PointColorSelection.displaySRGB(hue: 200, saturation: 1)
        XCTAssertEqual(over.r, atOne.r, accuracy: accuracy)
        XCTAssertEqual(over.g, atOne.g, accuracy: accuracy)
        XCTAssertEqual(over.b, atOne.b, accuracy: accuracy)
    }

    func testDisplaySRGBZeroSaturationIsMidGray() {
        let swatch = PointColorSelection.displaySRGB(hue: 0, saturation: 0)
        XCTAssertEqual(swatch.r, 0.5, accuracy: accuracy)
        XCTAssertEqual(swatch.g, 0.5, accuracy: accuracy)
        XCTAssertEqual(swatch.b, 0.5, accuracy: accuracy)
    }

    func testDisplaySRGBFullSaturationRedAtMidLightnessIsPureRed() {
        let swatch = PointColorSelection.displaySRGB(hue: 0, saturation: 1)
        XCTAssertEqual(swatch.r, 1, accuracy: accuracy)
        XCTAssertEqual(swatch.g, 0, accuracy: accuracy)
        XCTAssertEqual(swatch.b, 0, accuracy: accuracy)
    }
}
