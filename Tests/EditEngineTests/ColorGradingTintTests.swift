import XCTest
@testable import PhotoApp

/// Verifies `ColorGradingTint.rgbDelta`'s pure math — the HSL(hue, sat, 0.5)
/// -> RGB -> minus-neutral conversion each Color Grading wheel uses once
/// per render (not per pixel).
final class ColorGradingTintTests: XCTestCase {
    private let accuracy = 0.0001

    func testZeroSaturationIsAlwaysZeroDeltaRegardlessOfHue() {
        for hue: Double in [0, 30, 90, 180, 270, 359, -45, 400] {
            let delta = ColorGradingTint.rgbDelta(hue: hue, saturation: 0)
            XCTAssertEqual(delta.r, 0, accuracy: accuracy, "hue \(hue)")
            XCTAssertEqual(delta.g, 0, accuracy: accuracy, "hue \(hue)")
            XCTAssertEqual(delta.b, 0, accuracy: accuracy, "hue \(hue)")
        }
    }

    func testPureRedHueFullSaturationMatchesHandComputedDelta() {
        // HSL(0, 1, 0.5) is pure red (1, 0, 0) via the standard hexcone
        // formula — verified independently against ColorRangeSelection.rgb
        // itself below, not just self-consistency.
        let delta = ColorGradingTint.rgbDelta(hue: 0, saturation: 1)
        XCTAssertEqual(delta.r, 0.5, accuracy: accuracy)
        XCTAssertEqual(delta.g, -0.5, accuracy: accuracy)
        XCTAssertEqual(delta.b, -0.5, accuracy: accuracy)
    }

    func testMatchesColorRangeSelectionRgbMinusNeutralDirectly() {
        for (hue, saturation) in [(45.0, 0.6), (210.0, 0.3), (300.0, 0.9)] {
            let expected = ColorRangeSelection.rgb(forHue: hue, saturation: saturation, lightness: 0.5)
            let delta = ColorGradingTint.rgbDelta(hue: hue, saturation: saturation)
            XCTAssertEqual(delta.r, expected.r - 0.5, accuracy: accuracy)
            XCTAssertEqual(delta.g, expected.g - 0.5, accuracy: accuracy)
            XCTAssertEqual(delta.b, expected.b - 0.5, accuracy: accuracy)
        }
    }

    func testNegativeHueWrapsTheSameAsItsPositiveEquivalent() {
        let negative = ColorGradingTint.rgbDelta(hue: -30, saturation: 0.7)
        let wrapped = ColorGradingTint.rgbDelta(hue: 330, saturation: 0.7)
        XCTAssertEqual(negative.r, wrapped.r, accuracy: accuracy)
        XCTAssertEqual(negative.g, wrapped.g, accuracy: accuracy)
        XCTAssertEqual(negative.b, wrapped.b, accuracy: accuracy)
    }

    func testHueBeyond360WrapsTheSameAsItsModEquivalent() {
        let over = ColorGradingTint.rgbDelta(hue: 400, saturation: 0.5)
        let wrapped = ColorGradingTint.rgbDelta(hue: 40, saturation: 0.5)
        XCTAssertEqual(over.r, wrapped.r, accuracy: accuracy)
        XCTAssertEqual(over.g, wrapped.g, accuracy: accuracy)
        XCTAssertEqual(over.b, wrapped.b, accuracy: accuracy)
    }

    func testDeltaChannelsAreEachBoundedToPlusMinusOneHalf() {
        // HSL lightness 0.5 chroma is at most 1, so each channel's offset
        // from the 0.5 neutral is at most 0.5 in either direction.
        for hue: Double in stride(from: 0, to: 360, by: 15) {
            let delta = ColorGradingTint.rgbDelta(hue: hue, saturation: 1)
            XCTAssertLessThanOrEqual(delta.r, 0.5 + accuracy)
            XCTAssertGreaterThanOrEqual(delta.r, -0.5 - accuracy)
            XCTAssertLessThanOrEqual(delta.g, 0.5 + accuracy)
            XCTAssertGreaterThanOrEqual(delta.g, -0.5 - accuracy)
            XCTAssertLessThanOrEqual(delta.b, 0.5 + accuracy)
            XCTAssertGreaterThanOrEqual(delta.b, -0.5 - accuracy)
        }
    }
}
