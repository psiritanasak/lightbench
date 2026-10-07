import XCTest
@testable import PhotoApp

/// The pure math behind the Place Spots tool: view point <-> normalized spot position, drag-to-radius, hit testing, radius handle.
final class RetouchPlacementGeometryTests: XCTestCase {
    typealias G = RetouchOverlayGeometry
    /// A non-zero-origin, non-square fit rect (the picture centred in a pane).
    private let fit = CGRect(x: 40, y: 25, width: 600, height: 400)

    private func spot(x: Double, y: Double, radius: Double = 0.05) -> RetouchSpot {
        var s = RetouchSpot(); s.x = x; s.y = y; s.radius = radius; return s
    }

    // MARK: normalizedPoint

    func testNormalizedPointIsTheInverseOfCenterPoint() throws {
        for (x, y) in [(0.5, 0.5), (0.1, 0.9), (0.9, 0.1), (0.0, 0.0), (1.0, 1.0), (0.25, 0.75)] {
            let p = G.centerPoint(of: spot(x: x, y: y), in: fit)
            let n = try XCTUnwrap(G.normalizedPoint(from: p, in: fit))
            XCTAssertEqual(n.x, x, accuracy: 1e-9); XCTAssertEqual(n.y, y, accuracy: 1e-9)
        }
    }

    func testScreenYRunsDownButSpotYRunsUp() throws {
        let top = try XCTUnwrap(G.normalizedPoint(from: CGPoint(x: fit.midX, y: fit.minY), in: fit))
        let bottom = try XCTUnwrap(G.normalizedPoint(from: CGPoint(x: fit.midX, y: fit.maxY), in: fit))
        XCTAssertEqual(top.y, 1, accuracy: 1e-9, "the top edge of the picture is y = 1")
        XCTAssertEqual(bottom.y, 0, accuracy: 1e-9)
    }

    func testPointsOutsideTheFrameClampAndBadInputIsNil() throws {
        let far = try XCTUnwrap(G.normalizedPoint(from: CGPoint(x: -500, y: 9000), in: fit))
        XCTAssertEqual(far.x, 0); XCTAssertEqual(far.y, 0)
        XCTAssertNil(G.normalizedPoint(from: CGPoint(x: CGFloat.nan, y: 10), in: fit))
        XCTAssertNil(G.normalizedPoint(from: CGPoint(x: 10, y: CGFloat.infinity), in: fit))
        XCTAssertNil(G.normalizedPoint(from: CGPoint(x: 10, y: 10), in: .zero))
        XCTAssertNil(G.normalizedPoint(from: CGPoint(x: 10, y: 10), in: CGRect(x: CGFloat.infinity, y: 0, width: 600, height: 400)))
        XCTAssertNil(G.normalizedPoint(from: CGPoint(x: 10, y: 10), in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400)))
    }

    // MARK: radius from a drag

    func testRadiusIsTheDragDistanceOverTheMinSide() throws {
        let c = CGPoint(x: 300, y: 200)
        let r = try XCTUnwrap(G.radius(fromCenter: c, dragPoint: CGPoint(x: 300 + 12, y: 200 + 16), fitRect: fit)) // 20 pt
        XCTAssertEqual(r, 20.0 / 400.0, accuracy: 1e-9, "min side is the 400 pt height")
    }

    func testRadiusClampsToTheLegalRangeAndRejectsNonFinite() throws {
        let c = CGPoint(x: 300, y: 200)
        XCTAssertEqual(try XCTUnwrap(G.radius(fromCenter: c, dragPoint: c, fitRect: fit)), RetouchSpot.radiusRange.lowerBound)
        XCTAssertEqual(try XCTUnwrap(G.radius(fromCenter: c, dragPoint: CGPoint(x: 5000, y: 200), fitRect: fit)), RetouchSpot.radiusRange.upperBound)
        XCTAssertNil(G.radius(fromCenter: c, dragPoint: CGPoint(x: CGFloat.nan, y: 0), fitRect: fit))
        XCTAssertNil(G.radius(fromCenter: c, dragPoint: c, fitRect: .zero))
    }

    func testAClickUsesTheDefaultRadiusAndADragUsesTheMeasuredOne() throws {
        let c = CGPoint(x: 300, y: 200)
        let click = try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: CGPoint(x: 302, y: 201), fitRect: fit, defaultRadius: 0.03))
        XCTAssertEqual(click, 0.03, "hand jitter under the threshold is a click")
        let drag = try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: CGPoint(x: 300 + 40, y: 200), fitRect: fit, defaultRadius: 0.03))
        XCTAssertEqual(drag, 40.0 / 400.0, accuracy: 1e-9)
        // Exactly at the threshold is a drag.
        let edge = try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: CGPoint(x: 300 + G.minimumSizingDrag, y: 200), fitRect: fit, defaultRadius: 0.03))
        XCTAssertEqual(edge, Double(G.minimumSizingDrag) / 400.0, accuracy: 1e-9)
    }

    func testTheDefaultRadiusIsClampedAndSanitised() throws {
        let c = CGPoint(x: 300, y: 200)
        XCTAssertEqual(try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: c, fitRect: fit, defaultRadius: 5)), RetouchSpot.radiusRange.upperBound)
        XCTAssertEqual(try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: c, fitRect: fit, defaultRadius: -1)), RetouchSpot.radiusRange.lowerBound)
        XCTAssertEqual(try XCTUnwrap(G.newSpotRadius(fromCenter: c, dragPoint: c, fitRect: fit, defaultRadius: .nan)), G.defaultNewRadius)
        XCTAssertNil(G.newSpotRadius(fromCenter: c, dragPoint: CGPoint(x: CGFloat.nan, y: 0), fitRect: fit, defaultRadius: 0.02))
        XCTAssertNil(G.newSpotRadius(fromCenter: c, dragPoint: c, fitRect: .zero, defaultRadius: 0.02))
    }

    // MARK: hit testing

    func testAClickInsideACircleHitsItAndOutsideMissesIt() {
        let a = spot(x: 0.3, y: 0.6, radius: 0.05), b = spot(x: 0.8, y: 0.2, radius: 0.05)
        let ca = G.centerPoint(of: a, in: fit)
        XCTAssertEqual(G.hitTest(point: CGPoint(x: ca.x + 10, y: ca.y), spots: [a, b], fitRect: fit), a.id)
        XCTAssertEqual(G.hitTest(point: G.centerPoint(of: b, in: fit), spots: [a, b], fitRect: fit), b.id)
        XCTAssertNil(G.hitTest(point: CGPoint(x: fit.midX, y: fit.midY), spots: [a, b], fitRect: fit))
    }

    func testTheHitSlopMakesTinySpotsClickableButOnlyJustOutside() {
        let tiny = spot(x: 0.5, y: 0.5, radius: 0.002)   // 0.8 pt on this frame
        let c = G.centerPoint(of: tiny, in: fit)
        XCTAssertEqual(G.hitTest(point: CGPoint(x: c.x + 5, y: c.y), spots: [tiny], fitRect: fit), tiny.id)
        XCTAssertNil(G.hitTest(point: CGPoint(x: c.x + 20, y: c.y), spots: [tiny], fitRect: fit))
    }

    func testANestedSmallSpotStaysSelectableUnderABigOne() {
        let big = spot(x: 0.5, y: 0.5, radius: 0.1)
        var offset = spot(x: 0.52, y: 0.5, radius: 0.01)   // nearest-centre beats array order
        let co = G.centerPoint(of: offset, in: fit)
        XCTAssertEqual(G.hitTest(point: co, spots: [offset, big], fitRect: fit), offset.id, "small first, big drawn on top")
        XCTAssertEqual(G.hitTest(point: co, spots: [big, offset], fitRect: fit), offset.id, "big first")
        offset.x = 0.5   // same centre as the big one: every click inside the small circle is an equal-distance tie
        let c = G.centerPoint(of: offset, in: fit)
        let inside = CGPoint(x: c.x + 1, y: c.y)
        XCTAssertEqual(G.hitTest(point: c, spots: [big, offset], fitRect: fit), offset.id, "equal distance: the SMALLER circle wins")
        XCTAssertEqual(G.hitTest(point: c, spots: [offset, big], fitRect: fit), offset.id, "…in either array order")
        XCTAssertEqual(G.hitTest(point: inside, spots: [offset, big], fitRect: fit), offset.id)
        // Outside the small circle (and its slop) but inside the big one: the big one.
        let outsideSmall = CGPoint(x: c.x + 25, y: c.y)
        XCTAssertEqual(G.hitTest(point: outsideSmall, spots: [offset, big], fitRect: fit), big.id)
    }

    func testTwoIdenticalSpotsTieOnTheLaterOne() {
        let a = spot(x: 0.5, y: 0.5, radius: 0.05), b = spot(x: 0.5, y: 0.5, radius: 0.05)
        let c = G.centerPoint(of: a, in: fit)
        XCTAssertEqual(G.hitTest(point: c, spots: [a, b], fitRect: fit), b.id)
        XCTAssertEqual(G.hitTest(point: c, spots: [b, a], fitRect: fit), a.id)
    }

    /// A hand-edited sidecar can hold any radius; the pipeline renders the clamped disc, so the hit circle and handle match that.
    func testAnOutOfRangeStoredRadiusIsClampedForHitTestingAndTheHandle() {
        let wild = spot(x: 0.5, y: 0.5, radius: 5)
        let c = G.centerPoint(of: wild, in: fit)
        XCTAssertEqual(G.radiusPoints(of: wild, in: fit), CGFloat(RetouchSpot.radiusRange.upperBound) * 400, accuracy: 1e-9)
        XCTAssertNil(G.hitTest(point: CGPoint(x: c.x + 250, y: c.y), spots: [wild], fitRect: fit), "far outside the 0.1 disc")
        XCTAssertEqual(G.radiusHandlePoint(of: wild, in: fit).x - c.x, 40, accuracy: 1e-9)
        let tiny = spot(x: 0.5, y: 0.5, radius: 0)
        XCTAssertEqual(G.radiusPoints(of: tiny, in: fit), CGFloat(RetouchSpot.radiusRange.lowerBound) * 400, accuracy: 1e-9)
    }

    func testHitTestIgnoresNonFiniteSpotsAndPoints() {
        var bad = spot(x: 0.5, y: 0.5); bad.radius = .nan
        XCTAssertNil(G.hitTest(point: G.centerPoint(of: spot(x: 0.5, y: 0.5), in: fit), spots: [bad], fitRect: fit))
        XCTAssertNil(G.hitTest(point: CGPoint(x: CGFloat.nan, y: 0), spots: [spot(x: 0.5, y: 0.5)], fitRect: fit))
        XCTAssertNil(G.hitTest(point: CGPoint(x: 10, y: 10), spots: [], fitRect: fit))
        XCTAssertNil(G.hitTest(point: CGPoint(x: 10, y: 10), spots: [spot(x: 0.5, y: 0.5)], fitRect: .zero))
    }

    // MARK: radius handle

    func testTheRadiusHandleSitsOnTheRightEdgeAndDraggingItResizes() throws {
        let s = spot(x: 0.4, y: 0.6, radius: 0.05)
        let c = G.centerPoint(of: s, in: fit), h = G.radiusHandlePoint(of: s, in: fit)
        XCTAssertEqual(h.x - c.x, G.radiusPoints(of: s, in: fit), accuracy: 1e-9)
        XCTAssertEqual(h.y, c.y)
        // Dragging the handle to twice the distance doubles the radius; the handle follows the new radius.
        let r = try XCTUnwrap(G.radius(afterHandleDragTo: CGPoint(x: c.x + 2 * (h.x - c.x), y: c.y), spot: s, fitRect: fit))
        XCTAssertEqual(r, 0.10, accuracy: 1e-9)
        var resized = s; resized.radius = r
        XCTAssertEqual(G.radiusHandlePoint(of: resized, in: fit).x - c.x, 2 * (h.x - c.x), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(G.radius(afterHandleDragTo: c, spot: s, fitRect: fit)), RetouchSpot.radiusRange.lowerBound)
    }
}
