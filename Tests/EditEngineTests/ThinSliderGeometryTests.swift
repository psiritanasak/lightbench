import XCTest
@testable import PhotoApp

/// Verifies `ThinSliderGeometry`'s pure value↔pixel mapping — extracted
/// from `ThinSlider` specifically so this arithmetic (the one place an
/// off-by-a-thumb-radius bug could hide) gets direct unit test coverage,
/// matching the rigor already applied to `CropAspectMathTests`.
final class ThinSliderGeometryTests: XCTestCase {
    private let accuracy: Double = 0.0001

    // MARK: - fraction(of:in:)

    func testFractionAtLowerBoundIsZero() {
        XCTAssertEqual(ThinSliderGeometry.fraction(of: -5, in: -5...5), 0, accuracy: accuracy)
    }

    func testFractionAtUpperBoundIsOne() {
        XCTAssertEqual(ThinSliderGeometry.fraction(of: 5, in: -5...5), 1, accuracy: accuracy)
    }

    func testFractionAtMidpointIsOneHalf() {
        XCTAssertEqual(ThinSliderGeometry.fraction(of: 0, in: -5...5), 0.5, accuracy: accuracy)
    }

    func testFractionClampsBelowLowerBound() {
        XCTAssertEqual(ThinSliderGeometry.fraction(of: -100, in: 0...1), 0, accuracy: accuracy)
    }

    func testFractionClampsAboveUpperBound() {
        XCTAssertEqual(ThinSliderGeometry.fraction(of: 100, in: 0...1), 1, accuracy: accuracy)
    }

    func testFractionOfDegenerateZeroWidthRangeIsZeroNotNaN() {
        let result = ThinSliderGeometry.fraction(of: 3, in: 3...3)
        XCTAssertFalse(result.isNaN)
        XCTAssertEqual(result, 0, accuracy: accuracy)
    }

    // MARK: - value(atFraction:in:)

    func testValueAtFractionRoundTripsAtEndpointsAndMidpoint() {
        let range = -1.0...1.0
        for f in [0.0, 0.5, 1.0] {
            let value = ThinSliderGeometry.value(atFraction: f, in: range)
            XCTAssertEqual(ThinSliderGeometry.fraction(of: value, in: range), f, accuracy: accuracy)
        }
    }

    func testValueAtFractionClampsOutOfRangeFraction() {
        XCTAssertEqual(ThinSliderGeometry.value(atFraction: -1, in: 0...10), 0, accuracy: accuracy)
        XCTAssertEqual(ThinSliderGeometry.value(atFraction: 2, in: 0...10), 10, accuracy: accuracy)
    }

    // MARK: - thumbCenterX

    func testThumbCenterXAtZeroFractionIsInsetByRadius() {
        // 200pt track, 14pt thumb: at fraction 0 the center sits at the
        // thumb's own radius (7), not at x=0, so it never overhangs the edge.
        XCTAssertEqual(
            ThinSliderGeometry.thumbCenterX(fraction: 0, trackWidth: 200, thumbWidth: 14), 7, accuracy: accuracy
        )
    }

    func testThumbCenterXAtOneFractionIsInsetByRadiusFromTheFarEdge() {
        XCTAssertEqual(
            ThinSliderGeometry.thumbCenterX(fraction: 1, trackWidth: 200, thumbWidth: 14), 193, accuracy: accuracy
        )
    }

    func testThumbCenterXAtHalfFractionIsTrackCenter() {
        XCTAssertEqual(
            ThinSliderGeometry.thumbCenterX(fraction: 0.5, trackWidth: 200, thumbWidth: 14), 100, accuracy: accuracy
        )
    }

    func testThumbCenterXOnDegenerateNarrowTrackDoesNotProduceNaN() {
        // trackWidth < thumbWidth (a not-yet-laid-out GeometryReader can
        // briefly report 0) — usableSpan clamps to 0, center collapses to
        // the thumb radius, never NaN/negative.
        let result = ThinSliderGeometry.thumbCenterX(fraction: 0.5, trackWidth: 5, thumbWidth: 14)
        XCTAssertFalse(result.isNaN)
        XCTAssertEqual(result, 7, accuracy: accuracy)
    }

    // MARK: - fraction(atX:trackWidth:thumbWidth:) — the inverse (drag) direction

    func testFractionAtXIsInverseOfThumbCenterX() {
        let trackWidth = 200.0
        let thumbWidth = 14.0
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let x = ThinSliderGeometry.thumbCenterX(fraction: f, trackWidth: trackWidth, thumbWidth: thumbWidth)
            let roundTripped = ThinSliderGeometry.fraction(atX: x, trackWidth: trackWidth, thumbWidth: thumbWidth)
            XCTAssertEqual(roundTripped, f, accuracy: accuracy)
        }
    }

    func testFractionAtXClampsADragPastTheLeftEdge() {
        XCTAssertEqual(
            ThinSliderGeometry.fraction(atX: -50, trackWidth: 200, thumbWidth: 14), 0, accuracy: accuracy
        )
    }

    func testFractionAtXClampsADragPastTheRightEdge() {
        XCTAssertEqual(
            ThinSliderGeometry.fraction(atX: 500, trackWidth: 200, thumbWidth: 14), 1, accuracy: accuracy
        )
    }

    func testFractionAtXOnDegenerateNarrowTrackDoesNotProduceNaN() {
        let result = ThinSliderGeometry.fraction(atX: 2, trackWidth: 5, thumbWidth: 14)
        XCTAssertFalse(result.isNaN)
        XCTAssertEqual(result, 0, accuracy: accuracy)
    }
}
