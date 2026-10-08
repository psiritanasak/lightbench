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

// MARK: - Displayed rect (where the zoomed picture is)

final class ZoomPanDisplayedRectTests: XCTestCase {
    private let fit = CGRect(x: 40, y: 25, width: 600, height: 400)

    func testAtFitSizeTheDisplayedRectIsTheFitRect() {
        XCTAssertEqual(ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 1, pan: .zero), fit)
    }

    func testZoomingAboutTheCentreScalesTheRectAroundItsCentre() {
        let r = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)
        XCTAssertEqual(r.width, 1200); XCTAssertEqual(r.height, 800)
        XCTAssertEqual(r.midX, fit.midX, accuracy: 1e-9); XCTAssertEqual(r.midY, fit.midY, accuracy: 1e-9)
    }

    /// Pan is y-DOWN and fit-normalised: a positive pan moves the picture right and DOWN on screen.
    func testPositivePanMovesThePictureRightAndDown() {
        let base = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)
        let moved = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: CGSize(width: 0.25, height: 0.1))
        XCTAssertEqual(moved.minX - base.minX, 0.25 * fit.width, accuracy: 1e-9)
        XCTAssertEqual(moved.minY - base.minY, 0.1 * fit.height, accuracy: 1e-9, "y down: positive pan = lower on screen")
        XCTAssertEqual(moved.size, base.size)
    }

    /// `clampedPan`'s bound is exactly "the displayed picture still covers the fit rect": at pan = ±(z-1)/2 an edge sits on the fit edge.
    func testAtTheClampBoundsAnEdgeOfThePictureSitsOnTheFitRectEdge() {
        let z: CGFloat = 3, m = (z - 1) / 2
        let right = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: CGSize(width: m, height: 0))
        XCTAssertEqual(right.minX, fit.minX, accuracy: 1e-9, "panned fully right: the picture's left edge is at the fit rect's left edge")
        let left = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: CGSize(width: -m, height: 0))
        XCTAssertEqual(left.maxX, fit.maxX, accuracy: 1e-9)
        let down = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: CGSize(width: 0, height: m))
        XCTAssertEqual(down.minY, fit.minY, accuracy: 1e-9, "panned fully down: the picture's TOP edge is at the fit rect's top edge")
        let up = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: CGSize(width: 0, height: -m))
        XCTAssertEqual(up.maxY, fit.maxY, accuracy: 1e-9)
    }

    /// The y-DOWN rect and the renderer's y-UP origin are the same placement: mirroring the rect about the fit rect's centre gives
    /// the renderer's bottom-left origin, which is exactly what `ImageRenderer.fitted` uses (it calls `zoomedOriginYUp`).
    func testTheDisplayedRectAgreesWithTheRenderersYUpOrigin() {
        for (z, p) in [(1.0, CGSize.zero), (2.0, CGSize(width: 0.3, height: -0.2)), (5.0, CGSize(width: -1.5, height: 1.9))] as [(CGFloat, CGSize)] {
            let up = ZoomPanGeometry.zoomedOriginYUp(fitRect: fit, zoom: z, panNorm: p)
            let down = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: p)
            XCTAssertEqual(down.minX, up.x, accuracy: 1e-9)
            XCTAssertEqual(2 * fit.midY - down.maxY, up.y, accuracy: 1e-9, "y-up bottom edge = mirror of the y-down bottom edge")
        }
    }

    /// The cursor-anchored zoom keeps the point under the cursor fixed — expressed through the displayed rect: the image point under
    /// the cursor before and after the zoom is the same.
    func testZoomAboutTheCursorKeepsTheImagePointUnderIt() {
        let cursor = CGPoint(x: 500, y: 150)
        let f = ZoomPanGeometry.cursorFractionInFitRect(cursor: cursor, fitRect: fit)
        let z0: CGFloat = 2, pan0 = CGSize(width: 0.2, height: -0.1)
        let z1: CGFloat = 4
        let pan1 = ZoomPanGeometry.clampedPan(ZoomPanGeometry.panForZoomAboutCursor(oldZoom: z0, newZoom: z1, cursorFraction: f, oldPan: pan0), zoom: z1)
        func imagePoint(_ z: CGFloat, _ p: CGSize) -> CGPoint {
            let r = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: z, pan: p)
            return CGPoint(x: (cursor.x - r.minX) / r.width, y: (cursor.y - r.minY) / r.height)
        }
        let a = imagePoint(z0, pan0), b = imagePoint(z1, pan1)
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
    }

    func testNonFiniteInputFallsBackToTheFitRect() {
        XCTAssertEqual(ZoomPanGeometry.displayedRect(fitRect: fit, zoom: .nan, pan: .zero), fit)
        XCTAssertEqual(ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: CGSize(width: CGFloat.infinity, height: 0)), fit)
        XCTAssertEqual(ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 0, pan: .zero), fit)
    }

    func testVisiblePictureRectIsTheIntersectionWithThePane() {
        let pane = CGRect(x: 0, y: 0, width: 700, height: 450)
        let displayed = ZoomPanGeometry.displayedRect(fitRect: fit, zoom: 2, pan: .zero)   // spills well past the pane
        XCTAssertEqual(ZoomPanGeometry.visiblePictureRect(displayedRect: displayed, paneBounds: pane), pane,
                       "a zoomed picture covers the whole pane (it fills the letterbox too)")
        XCTAssertEqual(ZoomPanGeometry.visiblePictureRect(displayedRect: fit, paneBounds: pane), fit, "at fit size: the fit rect")
        XCTAssertTrue(ZoomPanGeometry.visiblePictureRect(displayedRect: CGRect(x: 900, y: 0, width: 10, height: 10), paneBounds: pane).isNull)
    }
}
