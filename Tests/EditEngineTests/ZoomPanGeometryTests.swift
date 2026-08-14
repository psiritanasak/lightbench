import XCTest
@testable import PhotoApp

/// Verifies `ZoomPanGeometry`'s pure math — extracted from `ImageRenderer`/
/// `PanOverlay`/`ContentView`'s scroll handler specifically so the trickiest
/// arithmetic in the zoom/pan feature (cursor-centered zoom, pan clamping)
/// gets direct unit test coverage, matching the rigor already applied to
/// `CompareLayoutTests`/`CropAspectMathTests`/`ThinSliderGeometryTests`.
final class ZoomPanGeometryTests: XCTestCase {
    private let accuracy: Double = 0.0001

    // MARK: - steppedZoom

    func testSteppedZoomPositiveDeltaIncreasesZoom() {
        let result = ZoomPanGeometry.steppedZoom(current: 1, scrollDelta: 10)
        XCTAssertGreaterThan(result, 1)
    }

    func testSteppedZoomNegativeDeltaDecreasesZoom() {
        let result = ZoomPanGeometry.steppedZoom(current: 2, scrollDelta: -10)
        XCTAssertLessThan(result, 2)
    }

    func testSteppedZoomZeroDeltaIsANoOp() {
        let result = ZoomPanGeometry.steppedZoom(current: 1.5, scrollDelta: 0)
        XCTAssertEqual(result, 1.5, accuracy: accuracy)
    }

    func testSteppedZoomClampsAtMinZoom() {
        let result = ZoomPanGeometry.steppedZoom(current: 1, scrollDelta: -1000)
        XCTAssertEqual(result, ZoomPanGeometry.minZoom, accuracy: accuracy)
    }

    func testSteppedZoomClampsAtMaxZoom() {
        let result = ZoomPanGeometry.steppedZoom(current: 1, scrollDelta: 1000)
        XCTAssertEqual(result, ZoomPanGeometry.maxZoom, accuracy: accuracy)
    }

    // MARK: - panForZoomAboutCursor

    func testPanForZoomAboutCursorAtCenterStaysCentered() {
        let result = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 4, cursorFraction: CGPoint(x: 0.5, y: 0.5), oldPan: .zero
        )
        XCTAssertEqual(result.width, 0, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy)
    }

    func testPanForZoomAboutCursorAtLeftEdgeKeepsLeftEdgeFixed() {
        // Zooming 1 -> 2 with the cursor at the fit rect's left edge
        // (fraction 0): the content's own left edge must still be under
        // that same fraction after the zoom, which requires panning by
        // exactly +0.5 (half a fit-rect-width) per the derivation.
        let result = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 2, cursorFraction: CGPoint(x: 0, y: 0.5), oldPan: .zero
        )
        XCTAssertEqual(result.width, 0.5, accuracy: accuracy)
    }

    func testPanForZoomAboutCursorAtRightEdgeKeepsRightEdgeFixed() {
        let result = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 2, cursorFraction: CGPoint(x: 1, y: 0.5), oldPan: .zero
        )
        XCTAssertEqual(result.width, -0.5, accuracy: accuracy)
    }

    func testPanForZoomAboutCursorIsSymmetricBetweenXAndY() {
        let x = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 3, cursorFraction: CGPoint(x: 0.2, y: 0.5), oldPan: .zero
        ).width
        let y = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 3, cursorFraction: CGPoint(x: 0.5, y: 0.2), oldPan: .zero
        ).height
        XCTAssertEqual(x, y, accuracy: accuracy)
    }

    func testPanForZoomAboutCursorWithNoZoomChangeLeavesPanUnchanged() {
        let oldPan = CGSize(width: 0.3, height: -0.2)
        let result = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 2, newZoom: 2, cursorFraction: CGPoint(x: 0.1, y: 0.9), oldPan: oldPan
        )
        XCTAssertEqual(result.width, oldPan.width, accuracy: accuracy)
        XCTAssertEqual(result.height, oldPan.height, accuracy: accuracy)
    }

    // MARK: - clampedPan

    func testClampedPanForcesZeroAtFit() {
        let result = ZoomPanGeometry.clampedPan(CGSize(width: 5, height: -5), zoom: 1)
        XCTAssertEqual(result, .zero)
    }

    func testClampedPanBoundsAreHalfOfZoomMinusOne() {
        let maxOffset = (3.0 - 1) / 2 // zoom = 3 -> ±1.0
        let overLimit = ZoomPanGeometry.clampedPan(CGSize(width: 5, height: -5), zoom: 3)
        XCTAssertEqual(overLimit.width, maxOffset, accuracy: accuracy)
        XCTAssertEqual(overLimit.height, -maxOffset, accuracy: accuracy)
    }

    func testClampedPanLeavesInRangeValuesUnchanged() {
        let pan = CGSize(width: 0.1, height: -0.1)
        let result = ZoomPanGeometry.clampedPan(pan, zoom: 3)
        XCTAssertEqual(result.width, pan.width, accuracy: accuracy)
        XCTAssertEqual(result.height, pan.height, accuracy: accuracy)
    }

    func testClampedPanAxesAreIndependent() {
        let result = ZoomPanGeometry.clampedPan(CGSize(width: 5, height: 0), zoom: 3)
        XCTAssertEqual(result.width, 1, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy)
    }

    // MARK: - cursorFractionInFitRect

    func testCursorFractionInFitRectAtCenter() {
        let fitRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let result = ZoomPanGeometry.cursorFractionInFitRect(cursor: CGPoint(x: 110, y: 70), fitRect: fitRect)
        XCTAssertEqual(result.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.5, accuracy: accuracy)
    }

    func testCursorFractionInFitRectAtCorners() {
        let fitRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let topLeft = ZoomPanGeometry.cursorFractionInFitRect(cursor: CGPoint(x: 0, y: 0), fitRect: fitRect)
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 0, accuracy: accuracy)
        let bottomRight = ZoomPanGeometry.cursorFractionInFitRect(cursor: CGPoint(x: 200, y: 100), fitRect: fitRect)
        XCTAssertEqual(bottomRight.x, 1, accuracy: accuracy)
        XCTAssertEqual(bottomRight.y, 1, accuracy: accuracy)
    }

    func testCursorFractionInFitRectOnDegenerateZeroSizeRectReturnsCenterNotNaN() {
        let result = ZoomPanGeometry.cursorFractionInFitRect(cursor: CGPoint(x: 5, y: 5), fitRect: .zero)
        XCTAssertFalse(result.x.isNaN)
        XCTAssertFalse(result.y.isNaN)
        XCTAssertEqual(result.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.5, accuracy: accuracy)
    }

    // MARK: - Round-trip stability

    func testZoomInThenOutByTheInverseFactorReturnsToIdentity() {
        let cursor = CGPoint(x: 0.3, y: 0.7)
        let zoomedIn = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 1, newZoom: 4, cursorFraction: cursor, oldPan: .zero
        )
        let zoomedOut = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: 4, newZoom: 1, cursorFraction: cursor, oldPan: zoomedIn
        )
        let clamped = ZoomPanGeometry.clampedPan(zoomedOut, zoom: 1)
        XCTAssertEqual(clamped, .zero)
    }
}
