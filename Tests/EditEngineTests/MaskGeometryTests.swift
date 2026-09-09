import XCTest
@testable import PhotoApp

/// Verifies `MaskGeometry`'s pure geometry — the handle-position and
/// drag-to-radius/center math `MaskOverlayView` depends on. All values are
/// hand-derived (closed-form trig, not a black-box filter), matching the
/// rigor already applied to `CropAspectMathTests`/`RadialMaskGeometryTests`.
final class MaskGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    private let squareFitRect = CGRect(x: 0, y: 0, width: 200, height: 200)

    // MARK: - axes

    func testZeroRotationAxesAreIdentity() {
        let (x, y) = MaskGeometry.axes(rotationDegrees: 0)
        XCTAssertEqual(x.dx, 1, accuracy: accuracy)
        XCTAssertEqual(x.dy, 0, accuracy: accuracy)
        XCTAssertEqual(y.dx, 0, accuracy: accuracy)
        XCTAssertEqual(y.dy, 1, accuracy: accuracy)
    }

    func test90DegreesRotatesXAxisToPointStraightDownOnScreen() {
        // Hand-checked: "East rotated 90 degrees clockwise (as a viewer
        // sees it) is South" -- in y-DOWN screen space, South is +y.
        let (x, _) = MaskGeometry.axes(rotationDegrees: 90)
        XCTAssertEqual(x.dx, 0, accuracy: accuracy)
        XCTAssertEqual(x.dy, 1, accuracy: accuracy)
    }

    func test90DegreesRotatesYAxisToPointWestOnScreen() {
        // "South rotated 90 degrees clockwise is West" -- -x in screen space.
        let (_, y) = MaskGeometry.axes(rotationDegrees: 90)
        XCTAssertEqual(y.dx, -1, accuracy: accuracy)
        XCTAssertEqual(y.dy, 0, accuracy: accuracy)
    }

    func test180DegreesNegatesBothAxes() {
        let (x, y) = MaskGeometry.axes(rotationDegrees: 180)
        XCTAssertEqual(x.dx, -1, accuracy: accuracy)
        XCTAssertEqual(x.dy, 0, accuracy: accuracy)
        XCTAssertEqual(y.dx, 0, accuracy: accuracy)
        XCTAssertEqual(y.dy, -1, accuracy: accuracy)
    }

    // MARK: - handlePoint

    func testHandlePointsAtZeroRotationAreAxisAligned() {
        let plusX = MaskGeometry.handlePoint(
            .plusX, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(plusX.x, 140, accuracy: accuracy, "100 + 0.2*200")
        XCTAssertEqual(plusX.y, 100, accuracy: accuracy)

        let plusY = MaskGeometry.handlePoint(
            .plusY, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(plusY.x, 100, accuracy: accuracy)
        XCTAssertEqual(plusY.y, 120, accuracy: accuracy, "100 + 0.1*200")
    }

    func testHandlePointsRespectANonZeroOriginFitRect() {
        let offsetRect = CGRect(x: 20, y: 30, width: 200, height: 200)
        let center = MaskGeometry.handlePoint(
            .center, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, fitRect: offsetRect
        )
        XCTAssertEqual(center.x, 120, accuracy: accuracy)
        XCTAssertEqual(center.y, 130, accuracy: accuracy)
    }

    func testHandlePointsSwapAxesAt90Degrees() {
        // A wide-X ellipse (radiusX 0.3, radiusY 0.1) rotated 90 degrees:
        // the FORMER +X handle (the wide reach) now sits where +Y used to
        // point -- straight down on screen -- confirming the whole
        // ellipse rotated, not just a label. Direct UI-side echo of
        // RadialMaskGeometryTests.testRotationIsNegatedForCIImageYUpSpace.
        let rotated = MaskGeometry.handlePoint(
            .plusX, centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.1,
            rotationDegrees: 90, fitRect: squareFitRect
        )
        XCTAssertEqual(rotated.x, 100, accuracy: accuracy)
        XCTAssertEqual(rotated.y, 100 + 0.3 * 200, accuracy: accuracy)
    }

    func testMinusXAndMinusYHandlePointsAreOppositePlusXAndPlusY() {
        let plusX = MaskGeometry.handlePoint(
            .plusX, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        let minusX = MaskGeometry.handlePoint(
            .minusX, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(minusX.x, 100 - (plusX.x - 100), accuracy: accuracy)
        XCTAssertEqual(minusX.y, plusX.y, accuracy: accuracy)

        let plusY = MaskGeometry.handlePoint(
            .plusY, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        let minusY = MaskGeometry.handlePoint(
            .minusY, centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
            rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(minusY.y, 100 - (plusY.y - 100), accuracy: accuracy)
        XCTAssertEqual(minusY.x, plusY.x, accuracy: accuracy)
    }

    /// Cross-checks the two INDEPENDENT implementations against each
    /// other -- this file's overlay-side `handlePoint` vs. the already-
    /// shipped render-side `RadialMaskGeometry.resolve` -- so a future
    /// one-sided sign edit to either fails loudly instead of silently
    /// drifting the overlay away from what actually renders. Uses a
    /// same-origin, same-size `extent`/`fitRect` so the y-up-to-y-down
    /// flip is the simple `extent.height - y` form. Deliberately `.plusX`
    /// ONLY -- the y-flip reverses handedness, so the UI's `.plusY` handle
    /// actually sits on the OPPOSITE side of the ellipse from the render
    /// side's own local +Y point (the two ellipses are still the
    /// identical point set under that substitution, so this is not a bug,
    /// just a real asymmetry a `.plusY` cross-check would need to account
    /// for rather than assert directly against this same formula).
    func testHandlePointAgreesWithRenderTransformAcrossYFlip() {
        let extent = CGRect(x: 0, y: 0, width: 300, height: 200)
        let centerX = 0.4, centerY = 0.3, radiusX = 0.25, radiusY = 0.15, rotation = 37.0

        let uiPoint = MaskGeometry.handlePoint(
            .plusX, centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
            rotationDegrees: rotation, fitRect: extent
        )

        let resolved = RadialMaskGeometry.resolve(
            centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY,
            rotationDegrees: rotation, feather: 0.5, extent: extent
        )!
        // The render's local +X point on the base (pre-scale) circle is
        // (gradientRadius, 0); the transform scales/rotates/translates it
        // into CIImage's bottom-left/y-UP extent space.
        let renderPoint = CGPoint(x: resolved.gradientRadius, y: 0).applying(resolved.transform)
        let renderPointFlipped = CGPoint(x: renderPoint.x, y: extent.height - renderPoint.y)

        XCTAssertEqual(uiPoint.x, renderPointFlipped.x, accuracy: accuracy)
        XCTAssertEqual(uiPoint.y, renderPointFlipped.y, accuracy: accuracy)
    }

    // MARK: - resized

    func testResizePlusXHandleGrowsWhenDraggedOutwardAtZeroRotation() {
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: CGSize(width: 20, height: 0), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, 0.3, accuracy: accuracy, "0.2 + 20/200")
        XCTAssertEqual(result.radiusY, 0.2, accuracy: accuracy, "unaffected")
    }

    func testResizeMinusXHandleGrowsWhenDraggedOutwardAtZeroRotation() {
        // Outward for the LEFT handle is a NEGATIVE (leftward) translation.
        let result = MaskGeometry.resized(
            .minusX, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: CGSize(width: -20, height: 0), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, 0.3, accuracy: accuracy)
    }

    func testResizePlusXHandleShrinksWhenDraggedInwardAtZeroRotation() {
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.3, startRadiusY: 0.3,
            translation: CGSize(width: -20, height: 0), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, 0.2, accuracy: accuracy)
    }

    func testResizePlusYHandleGrowsWhenDraggedDownwardAtZeroRotation() {
        let result = MaskGeometry.resized(
            .plusY, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: CGSize(width: 0, height: 20), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusY, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.radiusX, 0.2, accuracy: accuracy, "unaffected")
    }

    func testResizeClampsToMinRadius() {
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.05, startRadiusY: 0.2,
            translation: CGSize(width: -100, height: 0), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, MaskGeometry.minRadius, accuracy: accuracy)
    }

    func testResizeClampsToMaxRadius() {
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.9, startRadiusY: 0.2,
            translation: CGSize(width: 1000, height: 0), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, MaskGeometry.maxRadius, accuracy: accuracy)
    }

    func testResizeAtRotationProjectsOntoTheRotatedAxis() {
        // At 90 degrees, dragging in screen +Y direction now grows radiusX
        // (since the local +X axis now points in screen +Y) rather than
        // radiusY -- confirms the drag is projected onto the ROTATED axis,
        // not the screen axis.
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: CGSize(width: 0, height: 20), rotationDegrees: 90, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusX, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.radiusY, 0.2, accuracy: accuracy)
    }

    func testResizeAt45DegreesOnANonSquareFitRectProjectsCorrectly() {
        // A non-square fitRect means the +X and +Y fractions have
        // DIFFERENT pixel denominators, so a 45-degree drag must split
        // correctly between them -- the case that would catch a denominator
        // mix-up (using fitRect.height where fitRect.width belongs, etc).
        // The translation is HARDCODED (not derived from `axes`, the
        // function under test) so this test can't pass merely because it
        // shares a bug with `axes` itself: cos(45)=sin(45)=0.70710678,
        // scaled by a drag magnitude of 20.
        let wideRect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let translation = CGSize(width: 14.1421356, height: 14.1421356)
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: translation, rotationDegrees: 45, fitRect: wideRect
        )
        XCTAssertEqual(result.radiusX, 0.2 + 20.0 / 400.0, accuracy: accuracy)
        // Structural, not incidental: the .plusX branch always returns
        // `startRadiusY` unchanged (see `resized`'s own implementation) --
        // asserted here as a completeness check on this specific call, not
        // as independent evidence of "no leakage" the way the radiusX
        // assertion above is.
        XCTAssertEqual(result.radiusY, 0.2, accuracy: accuracy)
    }

    func testResizeMinusYHandleGrowsWhenDraggedUpwardAtZeroRotation() {
        // Outward for the TOP handle is a NEGATIVE (upward) translation.
        let result = MaskGeometry.resized(
            .minusY, startRadiusX: 0.2, startRadiusY: 0.2,
            translation: CGSize(width: 0, height: -20), rotationDegrees: 0, fitRect: squareFitRect
        )
        XCTAssertEqual(result.radiusY, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.radiusX, 0.2, accuracy: accuracy, "unaffected")
    }

    func testResizeWithZeroSizedFitRectReturnsInputUnchanged() {
        let result = MaskGeometry.resized(
            .plusX, startRadiusX: 0.2, startRadiusY: 0.3,
            translation: CGSize(width: 50, height: 50), rotationDegrees: 0, fitRect: .zero
        )
        XCTAssertEqual(result.radiusX, 0.2, accuracy: accuracy)
        XCTAssertEqual(result.radiusY, 0.3, accuracy: accuracy)
    }

    // MARK: - movedCenter

    func testMovedCenterTranslatesByFraction() {
        let result = MaskGeometry.movedCenter(
            startX: 0.5, startY: 0.5, translation: CGSize(width: 20, height: -40), fitRect: squareFitRect
        )
        XCTAssertEqual(result.x, 0.6, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.3, accuracy: accuracy)
    }

    func testMovedCenterClampsAtAllFourEdges() {
        let farRight = MaskGeometry.movedCenter(
            startX: 0.9, startY: 0.5, translation: CGSize(width: 1000, height: 0), fitRect: squareFitRect
        )
        XCTAssertEqual(farRight.x, 1, accuracy: accuracy)

        let farLeft = MaskGeometry.movedCenter(
            startX: 0.1, startY: 0.5, translation: CGSize(width: -1000, height: 0), fitRect: squareFitRect
        )
        XCTAssertEqual(farLeft.x, 0, accuracy: accuracy)

        let farDown = MaskGeometry.movedCenter(
            startX: 0.5, startY: 0.9, translation: CGSize(width: 0, height: 1000), fitRect: squareFitRect
        )
        XCTAssertEqual(farDown.y, 1, accuracy: accuracy)

        let farUp = MaskGeometry.movedCenter(
            startX: 0.5, startY: 0.1, translation: CGSize(width: 0, height: -1000), fitRect: squareFitRect
        )
        XCTAssertEqual(farUp.y, 0, accuracy: accuracy)
    }

    func testMovedCenterWithZeroSizedFitRectReturnsInputUnchanged() {
        let result = MaskGeometry.movedCenter(
            startX: 0.4, startY: 0.6, translation: CGSize(width: 50, height: 50), fitRect: .zero
        )
        XCTAssertEqual(result.x, 0.4, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.6, accuracy: accuracy)
    }
}
