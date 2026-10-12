import XCTest
@testable import PhotoApp

final class ColorGradingZonesTests: XCTestCase {
    func testZeroIsTheExactOriginalLook() {
        XCTAssertEqual(ColorGradingZones.width(blending: 0), 0.4, "bit-exact: every pinned colour-grading number depends on it")
        XCTAssertEqual(ColorGradingZones.width(blending: 0).bitPattern, 0.4.bitPattern)
        XCTAssertEqual(ColorGradingZones.shift(balance: 0), 0)
        XCTAssertEqual(ColorGradingZones.shift(balance: 0).bitPattern, Double(0).bitPattern)
        XCTAssertEqual(ColorGradingZones.shift(balance: -0.0).bitPattern, Double(0).bitPattern, "negative zero is still the identity")
    }

    func testBlendingWidensToDoubleButNarrowsOnlyToTheMinimum() {
        XCTAssertEqual(ColorGradingZones.width(blending: 1), 0.8, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.width(blending: -1), 0.33, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.width(blending: -1), ColorGradingZones.minWidth, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.width(blending: 0.5), 0.4 * 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.width(blending: -0.5), 0.4 * (0.33 / 0.4).squareRoot(), accuracy: 1e-12)
        // Never narrower than the point where tones between the ranges would go ungraded.
        XCTAssertGreaterThan(ColorGradingZones.width(blending: -1), 0.3)
    }

    func testBlendingIsStrictlyIncreasing() {
        var last = 0.0
        for step in stride(from: -1.0, through: 1.0, by: 0.05) {
            let width = ColorGradingZones.width(blending: step)
            XCTAssertGreaterThan(width, last, "blending \(step)")
            last = width
        }
    }

    func testBalanceIsLinearAndSymmetric() {
        XCTAssertEqual(ColorGradingZones.shift(balance: 1), 0.25)
        XCTAssertEqual(ColorGradingZones.shift(balance: -1), -0.25)
        XCTAssertEqual(ColorGradingZones.shift(balance: 0.4), 0.1, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.shift(balance: -0.4), -0.1, accuracy: 1e-12)
    }

    func testOutOfRangeAndNonFiniteInputIsClampedOrIgnored() {
        XCTAssertEqual(ColorGradingZones.width(blending: 5), 0.8, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.width(blending: -5), 0.33, accuracy: 1e-12)
        XCTAssertEqual(ColorGradingZones.shift(balance: 9), 0.25)
        XCTAssertEqual(ColorGradingZones.shift(balance: -9), -0.25)
        XCTAssertEqual(ColorGradingZones.width(blending: .nan), 0.4, "a hand-edited NaN is the original look")
        XCTAssertEqual(ColorGradingZones.width(blending: .infinity), 0.4)
        XCTAssertEqual(ColorGradingZones.shift(balance: .nan), 0)
    }
}
