import XCTest
@testable import PhotoApp

/// Verifies `MaskGeometry`'s pure geometry — the handle-position and
/// drag-to-radius/center math `MaskOverlayView` depends on. All values are
/// hand-derived (closed-form trig, not a black-box filter), matching the
/// rigor already applied to `CropAspectMathTests`/`RadialMaskGeometryTests`.
final class MaskGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    private let squareFitRect = CGRect(x: 0, y: 0, width: 200, height: 200)
    /// Deliberately non-square, unlike `squareFitRect` above — `width`'s
    /// `min(fitRect.width, fitRect.height)` denominator only diverges from
    /// a per-axis fraction on a non-square rect, mirroring why
    /// `LinearMaskGeometryTests`'s own fixture is deliberately 400x200.
    private let wideFitRect = CGRect(x: 0, y: 0, width: 400, height: 200)

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

    // MARK: - linearGuidePoint

    func testLinearGuidePointFullEffectAboveCenterAtZeroDegrees() {
        // width 0.5 -> widthInPixels = 0.5 * min(400,200) = 100, half = 50.
        // At angle 0, fullEffect sits on the -yAxis side = smaller y =
        // ABOVE center in y-DOWN screen space (the classic graduated-ND
        // default, matching the render's own compass check).
        let fullEffect = MaskGeometry.linearGuidePoint(
            .fullEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, fitRect: wideFitRect
        )
        let noEffect = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, fitRect: wideFitRect
        )
        XCTAssertEqual(fullEffect.x, 200, accuracy: accuracy)
        XCTAssertEqual(fullEffect.y, 50, accuracy: accuracy)
        XCTAssertEqual(noEffect.x, 200, accuracy: accuracy)
        XCTAssertEqual(noEffect.y, 150, accuracy: accuracy)
    }

    func testLinearGuidePointFullEffectToTheRightAtNinetyDegrees() {
        let fullEffect = MaskGeometry.linearGuidePoint(
            .fullEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 90, width: 0.5, fitRect: wideFitRect
        )
        let noEffect = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 90, width: 0.5, fitRect: wideFitRect
        )
        XCTAssertEqual(fullEffect.x, 250, accuracy: accuracy)
        XCTAssertEqual(fullEffect.y, 100, accuracy: accuracy)
        XCTAssertEqual(noEffect.x, 150, accuracy: accuracy)
        XCTAssertEqual(noEffect.y, 100, accuracy: accuracy)
    }

    func testLinearGuidePointsAreExactOppositesAboutCenterAtAnArbitraryAngle() {
        let center = MaskGeometry.linearGuidePoint(
            .center, centerX: 0.4, centerY: 0.6, rotationDegrees: 37, width: 0.4, fitRect: wideFitRect
        )
        let fullEffect = MaskGeometry.linearGuidePoint(
            .fullEffect, centerX: 0.4, centerY: 0.6, rotationDegrees: 37, width: 0.4, fitRect: wideFitRect
        )
        let noEffect = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: 0.4, centerY: 0.6, rotationDegrees: 37, width: 0.4, fitRect: wideFitRect
        )
        XCTAssertEqual((fullEffect.x + noEffect.x) / 2, center.x, accuracy: accuracy)
        XCTAssertEqual((fullEffect.y + noEffect.y) / 2, center.y, accuracy: accuracy)
    }

    func testLinearGuidePointCenterMatchesHandlePointCenter() {
        // Both handle-point functions share the identical center formula
        // -- no new logic for `.center`, just delegated.
        let linear = MaskGeometry.linearGuidePoint(
            .center, centerX: 0.3, centerY: 0.7, rotationDegrees: 20, width: 0.4, fitRect: wideFitRect
        )
        let radial = MaskGeometry.handlePoint(
            .center, centerX: 0.3, centerY: 0.7, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 20, fitRect: wideFitRect
        )
        XCTAssertEqual(linear.x, radial.x, accuracy: accuracy)
        XCTAssertEqual(linear.y, radial.y, accuracy: accuracy)
    }

    /// Cross-checks this file's `linearGuidePoint` against the already-
    /// shipped render-side `LinearMaskGeometry.resolve`, the direct
    /// analogue of `testHandlePointAgreesWithRenderTransformAcrossYFlip`
    /// above -- the single most valuable test in this section, since it
    /// pins the handedness/sign question from BOTH sides simultaneously.
    /// Same-origin, same-size extent/fitRect so the y-flip is the simple
    /// `extent.height - y` form.
    func testLinearGuidePointAgreesWithRenderTransformAcrossYFlip() {
        let extent = CGRect(x: 0, y: 0, width: 300, height: 200)
        let centerX = 0.4, centerY = 0.3, width = 0.4, rotation = 37.0

        let uiFullEffect = MaskGeometry.linearGuidePoint(
            .fullEffect, centerX: centerX, centerY: centerY, rotationDegrees: rotation, width: width, fitRect: extent
        )
        let uiNoEffect = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: centerX, centerY: centerY, rotationDegrees: rotation, width: width, fitRect: extent
        )

        let resolved = LinearMaskGeometry.resolve(
            centerX: centerX, centerY: centerY, rotationDegrees: rotation, width: width, extent: extent
        )!
        let renderPoint0Flipped = CGPoint(x: resolved.point0.x, y: extent.height - resolved.point0.y)
        let renderPoint1Flipped = CGPoint(x: resolved.point1.x, y: extent.height - resolved.point1.y)

        XCTAssertEqual(uiFullEffect.x, renderPoint0Flipped.x, accuracy: accuracy)
        XCTAssertEqual(uiFullEffect.y, renderPoint0Flipped.y, accuracy: accuracy)
        XCTAssertEqual(uiNoEffect.x, renderPoint1Flipped.x, accuracy: accuracy)
        XCTAssertEqual(uiNoEffect.y, renderPoint1Flipped.y, accuracy: accuracy)
    }

    // MARK: - resizedWidth

    func testResizedWidthDoublesTheProjectedDeltaAtZeroRotation() {
        // yAxis at 0 degrees is (0,1); a pure +20 y translation on the
        // .noEffect handle (the +yAxis side) projects to +20, which is a
        // HALF-width delta -- width itself (the FULL distance) must grow
        // by DOUBLE that, divided by min(400,200)=200.
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.3, translation: CGSize(width: 0, height: 20),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, 0.3 + 2.0 * 20.0 / 200.0, accuracy: accuracy, "0.3 + 0.2")
    }

    func testResizedWidthFullEffectHandleGrowsForTheOppositeSignedTranslation() {
        // .fullEffect sits on the -yAxis side, so dragging IT further
        // outward (more negative y at rotation 0) must ALSO grow width,
        // by the identical amount as the .noEffect case above.
        let result = MaskGeometry.resizedWidth(
            .fullEffect, startWidth: 0.3, translation: CGSize(width: 0, height: -20),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, 0.3 + 2.0 * 20.0 / 200.0, accuracy: accuracy)
    }

    func testResizedWidthDraggingInwardShrinksIt() {
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.5, translation: CGSize(width: 0, height: -20),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, 0.5 - 2.0 * 20.0 / 200.0, accuracy: accuracy, "0.5 - 0.2")
    }

    func testResizedWidthAt45DegreesProjectsOntoTheRotatedAxis() {
        // Translation HARDCODED (not derived from `axes`, the function
        // under test) so this can't pass merely by sharing a bug with
        // `axes` itself -- same discipline as
        // `testResizeAt45DegreesOnANonSquareFitRectProjectsCorrectly`.
        // This translation is exactly 20 points along yAxis(45 degrees) =
        // (-sin45, cos45)*20 = (-14.1421356, 14.1421356), so it must
        // produce the IDENTICAL 0.2 growth the zero-rotation case does --
        // confirming rotation-invariant magnitude, not just direction.
        let translation = CGSize(width: -14.1421356, height: 14.1421356)
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.3, translation: translation, rotationDegrees: 45, fitRect: wideFitRect
        )
        XCTAssertEqual(result, 0.3 + 2.0 * 20.0 / 200.0, accuracy: accuracy)
    }

    func testResizedWidthClampsToMinWidth() {
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.1, translation: CGSize(width: 0, height: -1000),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, MaskGeometry.minWidth, accuracy: accuracy)
    }

    func testResizedWidthClampsToMaxWidth() {
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.9, translation: CGSize(width: 0, height: 1000),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, MaskGeometry.maxWidth, accuracy: accuracy)
    }

    func testResizedWidthWithZeroSizedFitRectReturnsInputUnchanged() {
        let result = MaskGeometry.resizedWidth(
            .noEffect, startWidth: 0.4, translation: CGSize(width: 50, height: 50),
            rotationDegrees: 0, fitRect: .zero
        )
        XCTAssertEqual(result, 0.4, accuracy: accuracy)
    }

    func testResizedWidthCenterHandleReturnsInputUnchanged() {
        let result = MaskGeometry.resizedWidth(
            .center, startWidth: 0.4, translation: CGSize(width: 50, height: 50),
            rotationDegrees: 0, fitRect: wideFitRect
        )
        XCTAssertEqual(result, 0.4, accuracy: accuracy)
    }

    /// Reviewer-caught coverage gap: every test above bakes the literal
    /// `2.0` doubling factor into its OWN expected value, so a wrong
    /// multiplier (e.g. 1x instead of 2x) would pass all of them if the
    /// SAME mistake were made in both the test and the implementation.
    /// This test asserts something that does NOT depend on knowing the
    /// multiplier at all: drag the `.noEffect` HANDLE by a translation,
    /// then recompute its on-screen position (via `linearGuidePoint`,
    /// fed the resulting `width`) and confirm the handle moved by EXACTLY
    /// the drag translation -- i.e. the handle tracks the cursor 1:1, the
    /// actual user-facing property this whole feature depends on. A
    /// wrong multiplier would make the handle drift ahead of or lag
    /// behind the cursor, and this test would catch that even if it
    /// shared the same wrong constant the implementation used.
    func testDraggingTheNoEffectHandleMovesItByExactlyTheTranslation() {
        let startWidth = 0.3
        let translation = CGSize(width: 0, height: 20)

        let before = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: startWidth, fitRect: wideFitRect
        )
        let newWidth = MaskGeometry.resizedWidth(
            .noEffect, startWidth: startWidth, translation: translation, rotationDegrees: 0, fitRect: wideFitRect
        )
        let after = MaskGeometry.linearGuidePoint(
            .noEffect, centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: newWidth, fitRect: wideFitRect
        )

        XCTAssertEqual(after.x - before.x, translation.width, accuracy: accuracy)
        XCTAssertEqual(after.y - before.y, translation.height, accuracy: accuracy)
    }

    // MARK: - guideLineLength

    /// The sufficiency bound `guideLineLength`'s own doc comment derives —
    /// factored into ONE helper both tests below call, so the bound has a
    /// single source of truth and weakening it in one place can't silently
    /// desync the positive and negative checks.
    private func requiredHalfLength(for fitRect: CGRect) -> CGFloat {
        hypot(fitRect.width, fitRect.height) + min(fitRect.width, fitRect.height) / 2
    }

    /// Regression test for the exact constant that failed live/rendered
    /// review TWICE (`* 1.5`, too short; `* 3.0`, correct) — asserts the
    /// sufficiency bound above, rather than a specific magic number, so
    /// this test would fail against a reintroduced `* 1.5` (or anything
    /// below the bound) and pass for the shipped `* 3.0` or any other
    /// sufficient multiplier.
    func testGuideLineLengthIsSufficientForAnyAnchorAndOffset() {
        for fitRect in [squareFitRect, wideFitRect, CGRect(x: 10, y: 20, width: 733, height: 219)] {
            let length = MaskGeometry.guideLineLength(fitRect: fitRect)
            XCTAssertGreaterThanOrEqual(length / 2, requiredHalfLength(for: fitRect))
        }
    }

    /// Negative control: confirms the test above actually discriminates —
    /// the old, reviewer-rejected `* 1.5` factor must FAIL this same
    /// sufficiency bound, so a future regression back to it would be
    /// caught by `testGuideLineLengthIsSufficientForAnyAnchorAndOffset`.
    /// Deliberately does NOT call `MaskGeometry.guideLineLength` at all —
    /// the old `* 1.5` factor was never shipped as that function's body,
    /// so there is nothing in the current source to call; this test
    /// instead reconstructs the REJECTED formula directly and checks it
    /// against the same shared `requiredHalfLength` the positive test
    /// uses, so both tests can never silently disagree about the bound.
    func testOldOneAndAHalfMultiplierWasInsufficient() {
        let fitRect = wideFitRect
        let oldLength = hypot(fitRect.width, fitRect.height) * 1.5
        XCTAssertLessThan(oldLength / 2, requiredHalfLength(for: fitRect))
    }

    // MARK: - Brush mask (Phase 7 slice 4)

    func testNormalizedBrushPointConvertsPaneSpaceToFraction() {
        let point = MaskGeometry.normalizedBrushPoint(CGPoint(x: 100, y: 50), fitRect: wideFitRect)
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.25, accuracy: 0.0001)
    }

    func testNormalizedBrushPointClampsPastEveryEdge() {
        let farOutside = CGPoint(x: -500, y: 9000)
        let point = MaskGeometry.normalizedBrushPoint(farOutside, fitRect: wideFitRect)
        XCTAssertEqual(point.x, 0)
        XCTAssertEqual(point.y, 1)
    }

    func testNormalizedBrushPointWithZeroSizedFitRectReturnsCenterFallback() {
        let zero = CGRect(x: 0, y: 0, width: 0, height: 200)
        let point = MaskGeometry.normalizedBrushPoint(CGPoint(x: 10, y: 10), fitRect: zero)
        XCTAssertEqual(point.x, 0.5)
        XCTAssertEqual(point.y, 0.5)
    }

    func testBrushScreenPointIsTheExactInverseOfNormalizedBrushPoint() {
        let original = CGPoint(x: 137, y: 61)
        let normalized = MaskGeometry.normalizedBrushPoint(original, fitRect: wideFitRect)
        let roundTripped = MaskGeometry.brushScreenPoint(normalized, fitRect: wideFitRect)
        XCTAssertEqual(roundTripped.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.y, original.y, accuracy: 0.0001)
    }

    func testBrushScreenPointRespectsANonZeroFitRectOrigin() {
        let offsetRect = CGRect(x: 50, y: 75, width: 400, height: 200)
        let point = BrushPoint(x: 0, y: 0)
        let screen = MaskGeometry.brushScreenPoint(point, fitRect: offsetRect)
        XCTAssertEqual(screen.x, 50, accuracy: 0.0001)
        XCTAssertEqual(screen.y, 75, accuracy: 0.0001)
    }

    func testShouldAppendBrushPointIsFalseUnderTheSpacingThreshold() {
        let last = CGPoint(x: 100, y: 100)
        let tooClose = CGPoint(x: 101, y: 100) // 1pt, under the 3pt default
        XCTAssertFalse(MaskGeometry.shouldAppendBrushPoint(tooClose, after: last))
    }

    func testShouldAppendBrushPointIsTrueAtExactlyTheSpacingThreshold() {
        let last = CGPoint(x: 100, y: 100)
        let atThreshold = CGPoint(x: 103, y: 100) // exactly 3pt
        XCTAssertTrue(MaskGeometry.shouldAppendBrushPoint(atThreshold, after: last))
    }

    func testShouldAppendBrushPointIsTrueOverTheSpacingThreshold() {
        let last = CGPoint(x: 100, y: 100)
        let farEnough = CGPoint(x: 200, y: 100)
        XCTAssertTrue(MaskGeometry.shouldAppendBrushPoint(farEnough, after: last))
    }

    func testShouldAppendBrushPointHonorsACustomMinimumSpacing() {
        let last = CGPoint(x: 100, y: 100)
        let location = CGPoint(x: 105, y: 100) // 5pt
        XCTAssertFalse(MaskGeometry.shouldAppendBrushPoint(location, after: last, minimumSpacing: 10))
        XCTAssertTrue(MaskGeometry.shouldAppendBrushPoint(location, after: last, minimumSpacing: 3))
    }
}
