import XCTest
@testable import PhotoApp

/// Covers the Fritsch-Carlson solve behind `PointToneCurve.cikernel` —
/// Curves v2's user-placed point curve — without needing a `CIContext`.
/// Sibling of `ToneCurveSplineTests`, which covers the parametric layer's
/// natural-cubic evaluator.
final class MonotoneToneCurveTests: XCTestCase {

    private func points(_ pairs: [(Double, Double)]) -> [ToneCurvePoint] {
        pairs.map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }

    // MARK: - The collinearity identity

    func testCollinearPointsReproduceTheIdentityLineExactly() {
        // The property the kernel's pad-to-8 scheme rests on, and the reason
        // an identity-shaped curve is a true no-op rather than merely close
        // to one. Asserted at 1e-12, not the suite's 0.002 — "exact" is the
        // claim, so a loose tolerance would not test it.
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.25, 0.25), (0.6, 0.6), (1, 1)]))!
        for u in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertEqual(curve.curveValue(atEncoded: u), u, accuracy: 1e-12, "at u=\(u)")
        }
    }

    func testCollinearNonIdentityLineIsAlsoExact() {
        // Proves the property is COLLINEARITY, not a coincidence at slope 1.
        // Without this, the test above passes for a spline that happens to
        // fix the diagonal and bends everywhere else.
        let line = { (x: Double) in 0.3 + 0.5 * x }
        let curve = MonotoneToneCurve(points: points(
            [(0, line(0)), (0.2, line(0.2)), (0.7, line(0.7)), (1, line(1))]
        ))!
        for u in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertEqual(curve.curveValue(atEncoded: u), line(u), accuracy: 1e-12, "at u=\(u)")
        }
    }

    func testPassesThroughItsOwnControlPoints() {
        let p = points([(0, 0.1), (0.3, 0.2), (0.55, 0.8), (1, 0.95)])
        let curve = MonotoneToneCurve(points: p)!
        for point in p {
            XCTAssertEqual(curve.curveValue(atEncoded: point.x), point.y, accuracy: 1e-12, "at \(point)")
        }
    }

    // MARK: - Monotonicity: the entire reason this evaluator exists

    func testIsMonotoneWhereTheDataIsMonotoneAndNaturalCubicIsNot() {
        // A near-step: the classic case that makes a natural cubic
        // overshoot. The second half of this test is the important half —
        // asserting ToneCurveSpline DOES overshoot on the same points, so
        // the first half cannot pass vacuously and actually demonstrates
        // that the choice of evaluator matters.
        let p = points([(0, 0), (0.45, 0.05), (0.55, 0.95), (1, 1)])

        let monotone = MonotoneToneCurve(points: p)!
        var previous = -Double.infinity
        var monotoneMax = -Double.infinity
        for u in stride(from: 0.0, through: 1.0, by: 0.001) {
            let y = monotone.curveValue(atEncoded: u)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-12, "monotone curve reversed at u=\(u)")
            previous = y
            monotoneMax = max(monotoneMax, y)
        }
        XCTAssertLessThanOrEqual(monotoneMax, 1.0 + 1e-9, "monotone curve must not overshoot its top point")

        let natural = ToneCurveSpline(points: p.map { CGPoint(x: $0.x, y: $0.y) })!
        var naturalMax = -Double.infinity
        var naturalReversed = false
        var previousNatural = -Double.infinity
        for u in stride(from: 0.0, through: 1.0, by: 0.001) {
            let y = natural.splineValue(atEncoded: u)
            if y < previousNatural - 1e-9 { naturalReversed = true }
            previousNatural = y
            naturalMax = max(naturalMax, y)
        }
        XCTAssertTrue(
            naturalMax > 1.0 + 1e-6 || naturalReversed,
            "natural cubic must misbehave on these points, or this test proves nothing"
        )
    }

    func testFlatIntervalStaysFlat() {
        // d == 0 forces both of that interval's tangents to zero; without
        // it the segment bulges above or below both of its own endpoints.
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.3, 0.5), (0.7, 0.5), (1, 1)]))!
        for u in stride(from: 0.3, through: 0.7, by: 0.01) {
            XCTAssertEqual(curve.curveValue(atEncoded: u), 0.5, accuracy: 1e-12, "at u=\(u)")
        }
    }

    // MARK: - Out-of-domain, deliberately asymmetric

    func testClampsBelowTheFirstControlPoint() {
        let curve = MonotoneToneCurve(points: points([(0.2, 0.1), (0.6, 0.6), (1, 1)]))!
        XCTAssertEqual(curve.curveValue(atEncoded: 0.0), 0.1, accuracy: 1e-12)
        XCTAssertEqual(curve.curveValue(atEncoded: -0.5), 0.1, accuracy: 1e-12)
        XCTAssertEqual(curve.curveValue(atEncoded: 0.2), 0.1, accuracy: 1e-12)
    }

    func testExtrapolatesLinearlyAboveTheLastControlPoint() {
        // Equal steps must give equal increments — the constant first
        // difference is what distinguishes linear extrapolation both from
        // continuing the cubic (which curves away) and from a clamp (which
        // flatlines). Same check slice 1 uses.
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.5, 0.4), (1, 1)]))!
        let outputs = [1.0, 1.1, 1.2, 1.3].map { curve.curveValue(atEncoded: $0) }
        let step = outputs[1] - outputs[0]
        XCTAssertGreaterThan(step, 0, "must keep climbing, not flatline")
        XCTAssertEqual(outputs[2] - outputs[1], step, accuracy: 1e-12)
        XCTAssertEqual(outputs[3] - outputs[2], step, accuracy: 1e-12)
    }

    func testExtrapolationIsC1WithTheFinalSegment() {
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.5, 0.4), (1, 1)]))!
        let below = curve.curveValue(atEncoded: 0.9999)
        let at = curve.curveValue(atEncoded: 1.0)
        let above = curve.curveValue(atEncoded: 1.0001)
        XCTAssertEqual(at, 1.0, accuracy: 1e-12)
        XCTAssertEqual(above - at, at - below, accuracy: 1e-6, "a kink here would band the brightest tones")
    }

    func testFlatTopFlattensHeadroomByDesign() {
        // Asserted deliberately so a future reader sees this was a decision,
        // not an oversight. Fritsch-Carlson zeroes the end tangent when the
        // user draws a level top, so the extrapolation is flat and headroom
        // is compressed. That is the curve doing what it was told — unlike
        // v1, which clamped unconditionally whether or not the user asked.
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.5, 0.5), (0.8, 0.9), (1, 0.9)]))!
        XCTAssertEqual(curve.endSlope, 0, accuracy: 1e-12)
        XCTAssertEqual(curve.curveValue(atEncoded: 1.5), 0.9, accuracy: 1e-12)
    }

    // MARK: - Guards

    func testAcceptsExactlyTwoPoints() {
        // The floor is 2 here, not ToneCurveSpline's 3 — monotone Hermite
        // needs no interior point. Not a copy-paste slip.
        let curve = MonotoneToneCurve(points: points([(0, 0.2), (1, 0.8)]))
        XCTAssertNotNil(curve)
        XCTAssertEqual(curve!.curveValue(atEncoded: 0.5), 0.5, accuracy: 1e-12)
    }

    func testRejectsDegenerateInput() {
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0)])), "fewer than 2 points")
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (0, 1)])), "duplicate x")
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (0.7, 0.5), (0.3, 1)])), "non-increasing x")
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (1, 1e300)])), "absurd magnitude")
    }

    func testRejectsPointsTooCloseInXToHaveASaneSlope() {
        // Reviewer-found, measured on the real kernel: a 1e-6 x-gap passes
        // an ordering-only guard and renders linear 0.6 as 2.29e12. The
        // magnitude bound does not catch it, because it bounds where points
        // SIT, not how steep the curve between them is.
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (0.5, 0.5), (0.5 + 1e-6, 1.0)])))
        // Just inside the floor is still accepted, so the guard is a floor
        // and not an accidental ban on close-together points.
        XCTAssertNotNil(MonotoneToneCurve(points: points([(0, 0), (0.5, 0.5), (0.5 + 1e-3, 1.0)])))
    }

    func testRejectsNonFiniteValues() {
        // The guard ToneCurveSpline lacks: an ordering check written as
        // `x <= previous` is FALSE for NaN, so a NaN x passes an
        // ordering-only guard and paints NaN pixels.
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (.nan, 0.5), (1, 1)])), "NaN x")
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (0.5, .nan), (1, 1)])), "NaN y")
        XCTAssertNil(MonotoneToneCurve(points: points([(0, 0), (0.5, .infinity), (1, 1)])), "infinite y")
    }

    func testRejectsMoreThanTheKernelCanCarry() {
        let overCap = (0...MonotoneToneCurve.maximumPointCount).map {
            ToneCurvePoint(x: Double($0) / Double(MonotoneToneCurve.maximumPointCount), y: 0.5)
        }
        XCTAssertEqual(overCap.count, MonotoneToneCurve.maximumPointCount + 1)
        XCTAssertNil(MonotoneToneCurve(points: overCap), "must reject rather than silently truncate")
    }

    // MARK: - Kernel packing

    func testPaddingPreservesTheCurveAndFillsToTheKernelArity() {
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.4, 0.6), (1, 1)]))!
        let padded = curve.paddedForKernel()

        XCTAssertEqual(padded.points.count, MonotoneToneCurve.maximumPointCount)
        XCTAssertEqual(padded.tangents.count, MonotoneToneCurve.maximumPointCount)
        for i in 1..<padded.points.count {
            XCTAssertGreaterThan(padded.points[i].x, padded.points[i - 1].x, "padded x must stay increasing")
        }
        // The padded curve must evaluate identically to the real one,
        // in-domain AND out into the extrapolation region — this is the
        // collinearity argument, checked rather than asserted in a comment.
        let paddedCurve = MonotoneToneCurve(points: padded.points)!
        for u in stride(from: -0.2, through: 2.0, by: 0.01) {
            XCTAssertEqual(
                paddedCurve.curveValue(atEncoded: u), curve.curveValue(atEncoded: u),
                accuracy: 1e-9, "at u=\(u)"
            )
        }
    }

    func testPaddingAnAlreadyFullCurveIsANoOp() {
        let full = (0..<MonotoneToneCurve.maximumPointCount).map {
            ToneCurvePoint(x: Double($0) / Double(MonotoneToneCurve.maximumPointCount - 1),
                           y: Double($0) / Double(MonotoneToneCurve.maximumPointCount - 1))
        }
        let curve = MonotoneToneCurve(points: full)!
        XCTAssertEqual(curve.paddedForKernel().points, full)
    }

    // MARK: - The full transfer function

    func testValueAppliesTheEncodeDecodeSandwich() {
        let curve = MonotoneToneCurve(points: points([(0, 0), (0.5, 0.5), (1, 1)]))!
        // An identity curve must be a true identity through the sandwich,
        // headroom included.
        for v in [0.0, 0.05, 0.214, 0.5, 1.0, 1.4] {
            XCTAssertEqual(curve.value(at: v), v, accuracy: 1e-9, "at v=\(v)")
        }
    }
}
