import XCTest
@testable import PhotoApp

/// Verifies `ColorWheelGeometry`'s pure polar math — the screen-point<->
/// (hue, saturation) conversion Color Grading Slice B's wheel control uses.
final class ColorWheelGeometryTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    private let accuracy = 1e-9

    // MARK: - screenPoint / polarValue round trip

    func testRoundTripForRepresentativeHueSaturationPairs() {
        // Deliberately excludes saturation at/below centerSnapSaturationThreshold
        // (0.02) — within that band, Hue is irrelevant/snapped by design
        // (see testCenterSnapsHueToZero below), so it does NOT round-trip
        // for its own good reason.
        let pairs: [(hue: Double, saturation: Double)] = [
            (30, 0.5), (-90, 0.8), (179, 1.0), (-179, 0.3), (0, 1.0), (90, 0.05)
        ]
        for pair in pairs {
            let point = ColorWheelGeometry.screenPoint(hue: pair.hue, saturation: pair.saturation, in: rect)
            let roundTripped = ColorWheelGeometry.polarValue(at: point, in: rect)
            XCTAssertEqual(roundTripped.hue, pair.hue, accuracy: 1e-6, "hue for \(pair)")
            XCTAssertEqual(roundTripped.saturation, pair.saturation, accuracy: 1e-6, "saturation for \(pair)")
        }
    }

    // MARK: - Angle convention

    func testRightEdgeIsHueZero() {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        let point = CGPoint(x: rect.midX + radius, y: rect.midY)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        XCTAssertEqual(result.hue, 0, accuracy: accuracy)
        XCTAssertEqual(result.saturation, 1, accuracy: accuracy)
    }

    func testTopEdgeIsHue90CounterclockwiseConvention() {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        let point = CGPoint(x: rect.midX, y: rect.midY - radius)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        XCTAssertEqual(result.hue, 90, accuracy: accuracy)
    }

    func testLeftEdgeIsHue180() {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        let point = CGPoint(x: rect.midX - radius, y: rect.midY)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        // atan2's own range is -180...180 (not a separate -180/180 case),
        // and exactly-left is the one location where floating point could
        // land on either boundary, so this accepts either sign.
        XCTAssertEqual(abs(result.hue), 180, accuracy: 1e-6)
    }

    // MARK: - Radial clamp is genuinely POLAR, not independent x/y

    func testOutsideCircleClampsRadiusButPreservesAngle() {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        // Distance = radius*sqrt(2), comfortably outside the wheel — an
        // independent x/y clamp (clamping each axis to +/-radius
        // separately) would NOT generally preserve this exact -45 degree
        // angle, so this test distinguishes a true polar clamp from that
        // wrong alternative, not just from "no clamp at all."
        let point = CGPoint(x: rect.midX + radius, y: rect.midY + radius)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        XCTAssertEqual(result.saturation, 1, accuracy: accuracy)
        XCTAssertEqual(result.hue, -45, accuracy: 1e-6)
    }

    func testFarOutsideCircleStillClampsSaturationToExactlyOne() {
        let point = CGPoint(x: rect.maxX + 1000, y: rect.midY)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        XCTAssertEqual(result.saturation, 1, accuracy: accuracy)
    }

    // MARK: - Center / identity-snap edge case

    /// Load-bearing, not cosmetic — see `ColorWheelGeometry.polarValue`'s
    /// own doc comment: without this snap, `AdjustTabView.
    /// isAdjustTabAtIdentity`'s Hue-`== 0` check could fail forever on a
    /// photo that renders as identity. Asserts saturation is EXACTLY 0,
    /// not just hue — a prior version of this guard returned the tiny
    /// non-zero `distance/radius` for saturation even when hue snapped,
    /// which this test would have caught.
    func testCenterSnapsHueToZero() {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let result = ColorWheelGeometry.polarValue(at: center, in: rect)
        XCTAssertEqual(result.hue, 0, accuracy: accuracy)
        XCTAssertEqual(result.saturation, 0, accuracy: accuracy)
    }

    func testVeryNearCenterAlsoSnapsHueToZero() {
        let nearCenter = CGPoint(x: rect.midX + 1e-8, y: rect.midY + 1e-8)
        let result = ColorWheelGeometry.polarValue(at: nearCenter, in: rect)
        XCTAssertEqual(result.hue, 0, accuracy: accuracy)
        XCTAssertEqual(result.saturation, 0, accuracy: accuracy)
    }

    /// The snap threshold is a FRACTION of the radius (2%), not an
    /// absolute point distance — a realistic few-point miss from dead
    /// center on this control's smallest (140pt) frame must still snap.
    func testRealisticNearCenterMissSnapsToIdentityOnSmallestFrame() {
        let smallRect = CGRect(x: 0, y: 0, width: 140, height: 140)
        let radius = ColorWheelGeometry.wheelRadius(smallRect)
        let point = CGPoint(x: smallRect.midX + 1, y: smallRect.midY)
        XCTAssertLessThan(Double(1 / radius), 0.02, "test precondition: this offset must be within the snap threshold")
        let result = ColorWheelGeometry.polarValue(at: point, in: smallRect)
        XCTAssertEqual(result.hue, 0, accuracy: accuracy)
        XCTAssertEqual(result.saturation, 0, accuracy: accuracy)
    }

    /// A point just OUTSIDE the snap threshold must NOT snap — otherwise
    /// the dead zone would eat real low-saturation input near center.
    /// Deliberately close to the 0.02 boundary (not e.g. 0.05, comfortably
    /// past it) so this actually exercises the guard's edge.
    func testJustOutsideSnapThresholdDoesNotSnap() {
        let radius = ColorWheelGeometry.wheelRadius(rect)
        let distance = radius * 0.021
        let point = CGPoint(x: rect.midX + distance, y: rect.midY)
        let result = ColorWheelGeometry.polarValue(at: point, in: rect)
        XCTAssertEqual(result.hue, 0, accuracy: 1e-6)
        XCTAssertEqual(result.saturation, 0.021, accuracy: 1e-6)
    }

    // MARK: - Degenerate rect

    func testZeroSizedRectReturnsSaneDefaultNotNaN() {
        let zero = CGRect(x: 0, y: 0, width: 0, height: 200)
        let result = ColorWheelGeometry.polarValue(at: CGPoint(x: 10, y: 10), in: zero)
        XCTAssertEqual(result.hue, 0, accuracy: accuracy)
        XCTAssertEqual(result.saturation, 0, accuracy: accuracy)
        XCTAssertFalse(result.hue.isNaN)
        XCTAssertFalse(result.saturation.isNaN)
    }

    func testWheelRadiusIsZeroNotNegativeForTinyRect() {
        let tiny = CGRect(x: 0, y: 0, width: 4, height: 4)
        XCTAssertEqual(ColorWheelGeometry.wheelRadius(tiny), 0)
    }

    // MARK: - screenPoint defensively clamps out-of-range saturation

    func testScreenPointClampsSaturationAboveOneToTheWheelEdge() {
        let onEdge = ColorWheelGeometry.screenPoint(hue: 0, saturation: 1, in: rect)
        let overRange = ColorWheelGeometry.screenPoint(hue: 0, saturation: 5, in: rect)
        XCTAssertEqual(onEdge.x, overRange.x, accuracy: accuracy)
        XCTAssertEqual(onEdge.y, overRange.y, accuracy: accuracy)
    }

    func testScreenPointClampsNegativeSaturationToCenter() {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let negative = ColorWheelGeometry.screenPoint(hue: 45, saturation: -1, in: rect)
        XCTAssertEqual(negative.x, center.x, accuracy: accuracy)
        XCTAssertEqual(negative.y, center.y, accuracy: accuracy)
    }

    // MARK: - angularGradientFraction (theta -> AngularGradient stop location)

    /// theta=0 (this type's own right-edge/hue-0 convention) must land at
    /// fraction 0 — `AngularGradient(gradient:center:)`'s own fraction-0
    /// position, per its documented `startAngle: .zero` (screen right edge).
    func testHueZeroIsGradientFractionZero() {
        XCTAssertEqual(ColorWheelGeometry.angularGradientFraction(forHueDegrees: 0), 0, accuracy: accuracy)
    }

    /// `AngularGradient` sweeps CLOCKWISE with increasing fraction, the
    /// OPPOSITE rotational sense from this type's own CCW theta — so
    /// theta=90 (this type's top edge) must land at fraction 0.75 (3/4 of
    /// the way around a clockwise sweep from the right edge back to top),
    /// not 0.25.
    func testHue90LandsAtGradientFractionThreeQuarters() {
        XCTAssertEqual(ColorWheelGeometry.angularGradientFraction(forHueDegrees: 90), 0.75, accuracy: accuracy)
    }

    func testHue180LandsAtGradientFractionOneHalf() {
        XCTAssertEqual(ColorWheelGeometry.angularGradientFraction(forHueDegrees: 180), 0.5, accuracy: accuracy)
    }

    func testHueNegative90LandsAtGradientFractionOneQuarter() {
        XCTAssertEqual(ColorWheelGeometry.angularGradientFraction(forHueDegrees: -90), 0.25, accuracy: accuracy)
    }

    /// Cross-checks `angularGradientFraction` against `screenPoint`'s own
    /// output via a THIRD, independent formula — not against
    /// `angularGradientFraction`'s own arithmetic, which would pass
    /// trivially regardless of whether the convention is actually right.
    /// `atan2(dy, dx)` on a screen point (y-down) measures the angle
    /// CLOCKWISE from the +x/right edge — exactly `AngularGradient`'s own
    /// fraction convention — so normalizing it to 0...1 gives the expected
    /// gradient fraction for the puck's screen position directly from
    /// geometry, with no dependency on this type's `theta`/CCW convention
    /// at all.
    func testAngularGradientFractionAgreesWithScreenPointAtCardinalDirections() {
        for hue in [0.0, 90.0, 180.0, -90.0, 37.0] {
            let point = ColorWheelGeometry.screenPoint(hue: hue, saturation: 1, in: rect)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = Double(point.x - center.x)
            let dy = Double(point.y - center.y)
            let clockwiseAngle = atan2(dy, dx)
            let wrapped = clockwiseAngle < 0 ? clockwiseAngle + 2 * .pi : clockwiseAngle
            let expectedFraction = wrapped / (2 * .pi)
            let actualFraction = ColorWheelGeometry.angularGradientFraction(forHueDegrees: hue)
            XCTAssertEqual(actualFraction, expectedFraction, accuracy: 1e-6, "hue \(hue)")
        }
    }

    // MARK: - Keyboard / VoiceOver stepping (D20)

    func testSteppedHueWrapsAtPlusMinus180() {
        let up = ColorWheelGeometry.stepped(hue: 175, saturation: 0.5, hueDelta: 10)
        XCTAssertEqual(up.hue, -175, accuracy: 1e-9)
        let down = ColorWheelGeometry.stepped(hue: -175, saturation: 0.5, hueDelta: -10)
        XCTAssertEqual(down.hue, 175, accuracy: 1e-9)
        // -180 and +180 are one direction; the range is (-180, 180], so it reads 180.
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: 170, saturation: 0.5, hueDelta: 10).hue, 180, accuracy: 1e-9)
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: -170, saturation: 0.5, hueDelta: -10).hue, 180, accuracy: 1e-9)
        XCTAssertEqual(ColorWheelGeometry.wrappedHue(540), 180, accuracy: 1e-9)
        XCTAssertEqual(ColorWheelGeometry.wrappedHue(-540), 180, accuracy: 1e-9)
    }

    func testSteppedSaturationClampsToZeroAndOne() {
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: 30, saturation: 0.98, saturationDelta: 0.05).saturation, 1)
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: 30, saturation: 0.02, saturationDelta: -0.05).saturation, 0)
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: 30, saturation: 1, saturationDelta: 0.05).hue, 30)
    }

    func testSteppedSaturationReachingZeroForcesHueToExactlyZero() {
        let result = ColorWheelGeometry.stepped(hue: 137, saturation: 0.05, saturationDelta: -0.05)
        XCTAssertEqual(result.saturation, 0)
        XCTAssertEqual(result.hue, 0, "identity rule: Hue must be exactly 0 at Saturation 0")
        // Float residue from repeated steps must not leave a tiny non-zero Saturation (0.15 - 3 * 0.05 != 0 exactly).
        var state: (hue: Double, saturation: Double) = (-90, 0.15)
        for _ in 0..<3 { state = ColorWheelGeometry.stepped(hue: state.hue, saturation: state.saturation, saturationDelta: -0.05) }
        XCTAssertEqual(state.saturation, 0)
        XCTAssertEqual(state.hue, 0)
        // A Hue step on an identity wheel stays identity.
        let idle = ColorWheelGeometry.stepped(hue: 0, saturation: 0, hueDelta: 10)
        XCTAssertEqual(idle.hue, 0)
        XCTAssertEqual(idle.saturation, 0)
    }

    func testSteppedRepeatedHueStepsReturnToTheStartAfterAFullTurn() {
        var state: (hue: Double, saturation: Double) = (40, 0.6)
        for _ in 0..<36 {
            state = ColorWheelGeometry.stepped(
                hue: state.hue, saturation: state.saturation, hueDelta: ColorWheelGeometry.hueStepDegrees
            )
            XCTAssertGreaterThan(state.hue, -180)
            XCTAssertLessThanOrEqual(state.hue, 180)
        }
        XCTAssertEqual(state.hue, 40, accuracy: 1e-9)
        XCTAssertEqual(state.saturation, 0.6, accuracy: 1e-12)
    }

    func testSteppedUpThenDownRoundTrips() {
        let up = ColorWheelGeometry.stepped(hue: 25, saturation: 0.4, hueDelta: 10, saturationDelta: 0.05)
        let back = ColorWheelGeometry.stepped(hue: up.hue, saturation: up.saturation, hueDelta: -10, saturationDelta: -0.05)
        XCTAssertEqual(back.hue, 25, accuracy: 1e-9)
        XCTAssertEqual(back.saturation, 0.4, accuracy: 1e-9)
    }

    func testSteppedNonFiniteInputFallsBackToIdentity() {
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: .nan, saturation: 0.5, hueDelta: 10).hue, 0)
        XCTAssertEqual(ColorWheelGeometry.stepped(hue: 10, saturation: .infinity).saturation, 0)
    }

    func testNoOpStepsReturnNil() {
        XCTAssertNil(ColorWheelGeometry.steppedIfChanged(hue: 0, saturation: 0, hueDelta: 10))
        XCTAssertNil(ColorWheelGeometry.steppedIfChanged(hue: 0, saturation: 0, saturationDelta: -0.05))
        XCTAssertNil(ColorWheelGeometry.steppedIfChanged(hue: 30, saturation: 1, saturationDelta: 0.05))
        let real = ColorWheelGeometry.steppedIfChanged(hue: 30, saturation: 0.5, hueDelta: 10)
        XCTAssertEqual(real?.hue ?? 0, 40, accuracy: 1e-9)
        XCTAssertNotNil(ColorWheelGeometry.steppedIfChanged(hue: 30, saturation: 0.05, saturationDelta: -0.05))
    }

    func testAccessibilityValueText() {
        XCTAssertEqual(ColorWheelGeometry.accessibilityValue(hue: 137, saturation: 0.42), "Hue +137°, Saturation 42%")
        XCTAssertEqual(ColorWheelGeometry.accessibilityValue(hue: -20, saturation: 0), "Hue -20°, Saturation 0%")
    }
}
