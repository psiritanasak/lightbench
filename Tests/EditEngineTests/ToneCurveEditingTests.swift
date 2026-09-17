import XCTest
import CoreGraphics
@testable import PhotoApp

/// Verifies `ToneCurveEditing`'s pure screen-space math — the UI-side
/// inverse of `MonotoneToneCurve`'s forward render math. A 200x200 plot
/// rect at origin (0,0) is used throughout so screen coordinates and
/// fractions differ by a simple, readable factor of 200.
final class ToneCurveEditingTests: XCTestCase {
    let plotRect = CGRect(x: 0, y: 0, width: 200, height: 200)

    // MARK: - screenPoint / normalizedPoint (the Y flip)

    func testScreenPointFlipsYAndScalesByPlotRect() {
        // Curve (0,0) — bottom-left in value terms — must land at the
        // VISUAL bottom of the plot rect, which is the HIGH-y screen point.
        XCTAssertEqual(ToneCurveEditing.screenPoint(ToneCurvePoint(x: 0, y: 0), in: plotRect), CGPoint(x: 0, y: 200))
        // Curve (1,1) — top-right — lands at the visual top, low-y screen point.
        XCTAssertEqual(ToneCurveEditing.screenPoint(ToneCurvePoint(x: 1, y: 1), in: plotRect), CGPoint(x: 200, y: 0))
        XCTAssertEqual(
            ToneCurveEditing.screenPoint(ToneCurvePoint(x: 0.5, y: 0.25), in: plotRect), CGPoint(x: 100, y: 150)
        )
    }

    func testNormalizedPointIsExactInverseOfScreenPoint() {
        let point = ToneCurvePoint(x: 0.3, y: 0.8)
        let roundTripped = ToneCurveEditing.normalizedPoint(ToneCurveEditing.screenPoint(point, in: plotRect), in: plotRect)
        XCTAssertEqual(roundTripped.x, point.x, accuracy: 1e-12)
        XCTAssertEqual(roundTripped.y, point.y, accuracy: 1e-12)
    }

    func testNormalizedPointClampsOutsideThePlotRect() {
        let below = ToneCurveEditing.normalizedPoint(CGPoint(x: -50, y: 300), in: plotRect)
        XCTAssertEqual(below.x, 0)
        XCTAssertEqual(below.y, 0)

        let above = ToneCurveEditing.normalizedPoint(CGPoint(x: 500, y: -100), in: plotRect)
        XCTAssertEqual(above.x, 1)
        XCTAssertEqual(above.y, 1)
    }

    func testNormalizedPointDegenerateRectReturnsCenter() {
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        let point = ToneCurveEditing.normalizedPoint(CGPoint(x: 10, y: 10), in: degenerate)
        XCTAssertEqual(point.x, 0.5)
        XCTAssertEqual(point.y, 0.5)
    }

    // MARK: - nearestPointIndex

    func testNearestPointIndexFindsAHitWithinThreshold() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        // (1,1) is screen (200, 0); a tap 5pt away should hit it.
        let index = ToneCurveEditing.nearestPointIndex(to: CGPoint(x: 200, y: 5), in: points, plotRect: plotRect)
        XCTAssertEqual(index, 1)
    }

    func testNearestPointIndexReturnsNilWhenFarFromEveryPoint() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        let index = ToneCurveEditing.nearestPointIndex(to: CGPoint(x: 100, y: 100), in: points, plotRect: plotRect)
        XCTAssertNil(index)
    }

    func testNearestPointIndexBreaksTiesByFirstMatch() {
        // Two points equidistant (10pt away) from the tap, on opposite sides.
        let points = [ToneCurvePoint(x: 0.475, y: 0), ToneCurvePoint(x: 0.525, y: 0)]
        let tap = CGPoint(x: 100, y: 200)
        let index = ToneCurveEditing.nearestPointIndex(to: tap, in: points, plotRect: plotRect)
        XCTAssertEqual(index, 0, "a tie must resolve to the FIRST match in array order, not the last")
    }

    func testNearestPointIndexHitsExactlyAtTheThreshold() {
        let points = [ToneCurvePoint(x: 0, y: 0)]
        // Screen point is (0, 200); a tap exactly 16pt straight above it.
        // Purely vertical (dx=0) so the distance is exactly 16.0 in binary
        // floating point with no rounding ambiguity — a diagonal offset
        // (e.g. a 9.6/12.8 3-4-5 triangle) lands a few ULPs off 16.0 once
        // computed via `hypot`, which would make this test flaky rather
        // than a real check of the inclusive boundary.
        let index = ToneCurveEditing.nearestPointIndex(
            to: CGPoint(x: 0, y: 184), in: points, plotRect: plotRect, threshold: 16
        )
        XCTAssertEqual(index, 0, "the threshold boundary is inclusive")
    }

    // MARK: - adding

    func testAddingToAnEmptyCurveSeedsTheTwoDefaultEndpointsThenInserts() {
        // Click at curve (0.5, 0.5) -> screen (100, 100).
        let result = ToneCurveEditing.adding(CGPoint(x: 100, y: 100), to: [], plotRect: plotRect)
        XCTAssertEqual(result.points, [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.5),
            ToneCurvePoint(x: 1, y: 1),
        ])
        XCTAssertEqual(result.insertedIndex, 1)
    }

    func testAddingInsertsInXSortedOrder() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        // Click near curve x=0.25 -> screen x=50.
        let result = ToneCurveEditing.adding(CGPoint(x: 50, y: 150), to: points, plotRect: plotRect)
        XCTAssertEqual(result.points.count, 3)
        XCTAssertEqual(result.points[1].x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(result.insertedIndex, 1)
    }

    func testAddingClampsTooCloseToLeftNeighbor() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.02, y: 0.02), ToneCurvePoint(x: 1, y: 1)]
        // Click just right of x=0 (0.001), between the two existing points.
        let result = ToneCurveEditing.adding(CGPoint(x: 0.2, y: 199.8), to: points, plotRect: plotRect)
        XCTAssertEqual(result.points.count, 4)
        XCTAssertEqual(result.insertedIndex, 1)
        // Must stay >= minimumXSeparation from the point at x=0.
        XCTAssertGreaterThanOrEqual(result.points[1].x, ToneCurveEditing.minimumXSeparation - 1e-9)
    }

    func testAddingRefusesWhenNoRoomBetweenTwoCrowdedNeighbors() {
        // Two points already at the minimum separation from each other —
        // nothing can be inserted strictly between them.
        let points = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.5),
            ToneCurvePoint(x: 0.5 + ToneCurveEditing.minimumXSeparation, y: 0.6),
            ToneCurvePoint(x: 1, y: 1),
        ]
        let clickX = (0.5 + (0.5 + ToneCurveEditing.minimumXSeparation)) / 2 * 200
        let result = ToneCurveEditing.adding(CGPoint(x: clickX, y: 100), to: points, plotRect: plotRect)
        XCTAssertEqual(result.points, points)
        XCTAssertNil(result.insertedIndex)
    }

    func testAddingAtTheRenderCapIsANoOp() {
        var points: [ToneCurvePoint] = []
        for i in 0..<MonotoneToneCurve.maximumPointCount {
            let x = Double(i) / Double(MonotoneToneCurve.maximumPointCount - 1)
            points.append(ToneCurvePoint(x: x, y: x))
        }
        XCTAssertEqual(points.count, MonotoneToneCurve.maximumPointCount)
        let result = ToneCurveEditing.adding(CGPoint(x: 33, y: 167), to: points, plotRect: plotRect)
        XCTAssertEqual(result.points, points)
        XCTAssertNil(result.insertedIndex)
    }

    // MARK: - addingAtWidestGap

    func testAddingAtWidestGapOnEmptyCurveSeedsThenSplitsTheMiddle() {
        let result = ToneCurveEditing.addingAtWidestGap(of: [])
        XCTAssertEqual(result, [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1),
        ])
    }

    func testAddingAtWidestGapPicksTheWidestOfSeveralGaps() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.1, y: 0.1), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.addingAtWidestGap(of: points)
        // The 0.1...1 gap is widest; the new point splits it at its midpoint.
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[2].x, 0.55, accuracy: 1e-9)
        XCTAssertEqual(result[2].y, 0.55, accuracy: 1e-9)
    }

    func testAddingAtWidestGapRefusesAtTheRenderCap() {
        var points: [ToneCurvePoint] = []
        for i in 0..<MonotoneToneCurve.maximumPointCount {
            let x = Double(i) / Double(MonotoneToneCurve.maximumPointCount - 1)
            points.append(ToneCurvePoint(x: x, y: x))
        }
        XCTAssertEqual(ToneCurveEditing.addingAtWidestGap(of: points), points)
    }

    func testAddingAtWidestGapRefusesWhenEveryGapIsAtMinimumSeparation() {
        let step = ToneCurveEditing.minimumXSeparation
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: step, y: step), ToneCurvePoint(x: 2 * step, y: 2 * step)]
        // Neither gap (0...step, step...2*step) is wide enough to split further.
        XCTAssertEqual(ToneCurveEditing.addingAtWidestGap(of: points), points)
    }

    // MARK: - canAddAtWidestGap

    /// `canAddAtWidestGap` is the "Add Point" button's `.disabled` check —
    /// it must never disagree with whether `addingAtWidestGap` would
    /// actually insert a point, across the exact same fixtures the
    /// refusal/success tests above already build.
    func testCanAddAtWidestGapAgreesWithAddingAtWidestGapAcrossFixtures() {
        let step = ToneCurveEditing.minimumXSeparation
        let fixtures: [[ToneCurvePoint]] = [
            [],
            [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.1, y: 0.1), ToneCurvePoint(x: 1, y: 1)],
            [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: step, y: step), ToneCurvePoint(x: 2 * step, y: 2 * step)],
        ]
        for points in fixtures {
            let actuallyInserts = ToneCurveEditing.addingAtWidestGap(of: points) != points
            XCTAssertEqual(
                ToneCurveEditing.canAddAtWidestGap(to: points), actuallyInserts,
                "disagreement for \(points)"
            )
        }

        var atCap: [ToneCurvePoint] = []
        for i in 0..<MonotoneToneCurve.maximumPointCount {
            let x = Double(i) / Double(MonotoneToneCurve.maximumPointCount - 1)
            atCap.append(ToneCurvePoint(x: x, y: x))
        }
        XCTAssertFalse(ToneCurveEditing.canAddAtWidestGap(to: atCap))
        XCTAssertEqual(ToneCurveEditing.addingAtWidestGap(of: atCap), atCap)
    }

    // MARK: - moving

    func testMovingAnInteriorPointUpdatesBothAxes() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.moving(pointAt: 1, to: CGPoint(x: 140, y: 60), in: points, plotRect: plotRect)
        XCTAssertEqual(result[1].x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(result[1].y, 0.7, accuracy: 1e-9)
    }

    func testMovingAnEndpointPinsXAndOnlyMovesY() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.moving(pointAt: 0, to: CGPoint(x: 999, y: 40), in: points, plotRect: plotRect)
        XCTAssertEqual(result[0].x, 0)
        XCTAssertEqual(result[0].y, 0.8, accuracy: 1e-9)

        let resultLast = ToneCurveEditing.moving(pointAt: 1, to: CGPoint(x: -500, y: 160), in: points, plotRect: plotRect)
        XCTAssertEqual(resultLast[1].x, 1)
        XCTAssertEqual(resultLast[1].y, 0.2, accuracy: 1e-9)
    }

    func testMovingStopsAtMinimumSeparationAndNeverReorders() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.4, y: 0.4), ToneCurvePoint(x: 0.6, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        // Drag the middle-left point far to the right, well past its neighbor.
        let result = ToneCurveEditing.moving(pointAt: 1, to: CGPoint(x: 199, y: 1), in: points, plotRect: plotRect)
        XCTAssertEqual(result[1].x, 0.6 - ToneCurveEditing.minimumXSeparation, accuracy: 1e-9)
        // Order preserved.
        XCTAssertLessThan(result[0].x, result[1].x)
        XCTAssertLessThan(result[1].x, result[2].x)
        XCTAssertLessThan(result[2].x, result[3].x)
    }

    func testMovingOutOfRangeIndexIsANoOp() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.moving(pointAt: 5, to: CGPoint(x: 10, y: 10), in: points, plotRect: plotRect)
        XCTAssertEqual(result, points)
    }

    // MARK: - nudged (shares clamping with moving)

    func testNudgedInteriorPointMovesByDelta() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.nudged(pointAt: 1, dx: 0.05, dy: -0.05, in: points)
        XCTAssertEqual(result[1].x, 0.55, accuracy: 1e-9)
        XCTAssertEqual(result[1].y, 0.45, accuracy: 1e-9)
    }

    func testNudgedEndpointIgnoresDxAndClampsDy() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.nudged(pointAt: 0, dx: -0.5, dy: -0.5, in: points)
        XCTAssertEqual(result[0].x, 0)
        XCTAssertEqual(result[0].y, 0)
    }

    func testNudgedRepeatedlyStopsExactlyAtEndpointPin() {
        // The end-to-end no-cross claim from the plan: nudging an endpoint's
        // NEIGHBOR repeatedly toward it must stop short, never cross.
        var points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        for _ in 0..<40 {
            points = ToneCurveEditing.nudged(pointAt: 1, dx: 0.1, dy: 0, in: points)
        }
        XCTAssertEqual(points[1].x, 1 - ToneCurveEditing.minimumXSeparation, accuracy: 1e-9)
        XCTAssertLessThan(points[1].x, points[2].x)
    }

    func testNudgedRepeatedlyOnAnEndpointStaysExactlyPinned() {
        var points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        for _ in 0..<10 {
            points = ToneCurveEditing.nudged(pointAt: 0, dx: -1, dy: 0, in: points)
        }
        XCTAssertEqual(points[0].x, 0)
    }

    // MARK: - removing

    func testRemovingAnInteriorPointDeletesIt() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.3, y: 0.2), ToneCurvePoint(x: 0.7, y: 0.9), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.removing(pointAt: 1, in: points)
        XCTAssertEqual(result, [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.7, y: 0.9), ToneCurvePoint(x: 1, y: 1)])
    }

    func testRemovingRefusesTheFirstEndpoint() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ToneCurveEditing.removing(pointAt: 0, in: points), points)
    }

    func testRemovingRefusesTheLastEndpoint() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ToneCurveEditing.removing(pointAt: 2, in: points), points)
    }

    func testRemovingLastInteriorPointCollapsesToEmptyWhenEndpointsAreDefault() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ToneCurveEditing.removing(pointAt: 1, in: points), [])
    }

    func testRemovingLastInteriorPointKeepsTwoPointsWhenAnEndpointWasMoved() {
        // The left endpoint was dragged away from its default (0,0) — the
        // remaining 2-point curve is a genuine edit, not identity, and must
        // NOT be silently collapsed away.
        let points = [ToneCurvePoint(x: 0, y: 0.15), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        let result = ToneCurveEditing.removing(pointAt: 1, in: points)
        XCTAssertEqual(result, [ToneCurvePoint(x: 0, y: 0.15), ToneCurvePoint(x: 1, y: 1)])
    }

    func testRemovingOutOfRangeIndexIsANoOp() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ToneCurveEditing.removing(pointAt: 9, in: points), points)
    }

    // MARK: - validated

    func testValidatedKeepsAnInRangeIndex() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertEqual(ToneCurveEditing.validated(1, in: points), 1)
    }

    func testValidatedDropsAnOutOfRangeIndex() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]
        XCTAssertNil(ToneCurveEditing.validated(5, in: points))
    }

    func testValidatedDropsNil() {
        XCTAssertNil(ToneCurveEditing.validated(nil, in: [ToneCurvePoint(x: 0, y: 0)]))
    }

    func testValidatedOnEmptyPointsIsAlwaysNil() {
        XCTAssertNil(ToneCurveEditing.validated(0, in: []))
    }
}
