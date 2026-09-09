import XCTest
@testable import PhotoApp

/// Verifies `RadialMaskGeometry`'s pure geometry — the ellipse-via-affine-
/// transform math `EditPipeline.applyMasks` depends on. All values are
/// hand-derived (closed-form algebra, not a black-box filter), matching the
/// rigor already applied to `CropAspectMathTests`.
final class RadialMaskGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    private let squareExtent = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - Center mapping (y-flip)

    func testCenterMapsToExtentCenterWithYFlip() {
        // centerY 0.5 is the visual middle either way, so the flip is
        // invisible here -- covered separately below.
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        XCTAssertNotNil(result)
        let mapped = CGPoint(x: 0, y: 0).applying(result!.transform)
        XCTAssertEqual(mapped.x, 50, accuracy: accuracy)
        XCTAssertEqual(mapped.y, 50, accuracy: accuracy)
    }

    func testTopLeftUICornerMapsToTopLeftOfCIImageYUpSpace() {
        // centerY near 0 is the TOP of the screen in SwiftUI's y-down space,
        // which must map to the HIGH y (extent.maxY side) of CIImage's
        // y-up space -- the y-flip is the one thing most likely to be
        // silently backwards.
        let result = RadialMaskGeometry.resolve(
            centerX: 0.1, centerY: 0.1, radiusX: 0.05, radiusY: 0.05,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        let mapped = CGPoint(x: 0, y: 0).applying(result!.transform)
        XCTAssertEqual(mapped.x, 10, accuracy: accuracy)
        XCTAssertEqual(mapped.y, 90, accuracy: accuracy, "screen-top must map to CIImage's high y")
    }

    func testCenterRespectsANonZeroOriginExtent() {
        let offsetExtent = CGRect(x: 20, y: 30, width: 100, height: 100)
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: offsetExtent
        )
        let mapped = CGPoint(x: 0, y: 0).applying(result!.transform)
        XCTAssertEqual(mapped.x, 70, accuracy: accuracy)
        XCTAssertEqual(mapped.y, 80, accuracy: accuracy)
    }

    // MARK: - Scale (downscale-only)

    func testCircleCaseHasIdentityScaleOnBothAxes() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        // A point on the unit circle's edge along +X must land exactly
        // gradientRadius away from center when radiusX == radiusY.
        let edge = CGPoint(x: result!.gradientRadius, y: 0).applying(result!.transform)
        XCTAssertEqual(edge.x, 50 + 30, accuracy: accuracy)
        XCTAssertEqual(edge.y, 50, accuracy: accuracy)
    }

    func testGradientRadiusIsTheLargerPixelRadius() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.4, radiusY: 0.1,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        XCTAssertEqual(result!.gradientRadius, 40, accuracy: accuracy)
    }

    func testScaleIsDownscaleOnlyOnTheSmallerAxis() {
        // radiusX (0.4 * 100 = 40px) is the larger axis; radiusY (0.1 * 100
        // = 10px) must be scaled DOWN to 10, never up.
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.4, radiusY: 0.1,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        let plusX = CGPoint(x: result!.gradientRadius, y: 0).applying(result!.transform)
        let plusY = CGPoint(x: 0, y: result!.gradientRadius).applying(result!.transform)
        XCTAssertEqual(plusX.x - 50, 40, accuracy: accuracy)
        XCTAssertEqual(plusY.y - 50, 10, accuracy: accuracy)
    }

    func testEllipseIsWiderThanTallWhenRadiusXExceedsRadiusY() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.4, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        let plusX = CGPoint(x: result!.gradientRadius, y: 0).applying(result!.transform)
        let plusY = CGPoint(x: 0, y: result!.gradientRadius).applying(result!.transform)
        XCTAssertGreaterThan(plusX.x - 50, plusY.y - 50)
    }

    // MARK: - Rotation

    func testZeroRotationProducesNoShear() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.1,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        )
        let plusX = CGPoint(x: result!.gradientRadius, y: 0).applying(result!.transform)
        XCTAssertEqual(plusX.y, 50, accuracy: accuracy, "an unrotated +X axis point must stay on the horizontal through center")
    }

    func testRotationIsNegatedForCIImageYUpSpace() {
        // A wide-X ellipse (radiusX 0.3, radiusY 0.1) rotated +90 degrees
        // CLOCKWISE on screen (the stored, y-down convention) must become
        // TALL in CIImage's y-up space: its former +X axis point must land
        // on the vertical through center, at the SMALL (0.1) radius's
        // distance would be wrong -- it must be the radiusX=0.3 point that
        // now points along Y, confirming the whole ellipse rotated, not
        // just its label.
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.1,
            rotationDegrees: 90, feather: 0.5, extent: squareExtent
        )
        let formerPlusX = CGPoint(x: result!.gradientRadius, y: 0).applying(result!.transform)
        // +90 clockwise on screen = -90 in CIImage's y-up space (per this
        // function's documented negation), which maps local (+R, 0) to
        // world (0, -R) relative to center -- i.e. BELOW center in CIImage
        // space (lower y).
        XCTAssertEqual(formerPlusX.x, 50, accuracy: accuracy)
        XCTAssertEqual(formerPlusX.y, 50 - 30, accuracy: accuracy)
    }

    func testTransformMapsUnitCircleEdgeToTheEllipseEdgeAtAnArbitraryAngle() {
        // Sanity check at a non-axis-aligned angle: the mapped point must
        // still be exactly `gradientRadius` from center pre-scale, i.e. on
        // the scaled ellipse post-scale -- verify via the implicit ellipse
        // equation (x/rx)^2 + (y/ry)^2 == 1 in the ellipse's own rotated
        // frame, which is equivalent to checking the mapped point, rotated
        // back by -radians (CIImage space) and un-translated, satisfies it.
        let radiusX = 0.35, radiusY = 0.15
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: radiusX, radiusY: radiusY,
            rotationDegrees: 37, feather: 0.5, extent: squareExtent
        )!
        let angle = Double.pi / 5
        let local = CGPoint(x: result.gradientRadius * CGFloat(cos(angle)), y: result.gradientRadius * CGFloat(sin(angle)))
        let mapped = local.applying(result.transform)

        // Undo translate + rotate (CIImage space: rotation was -37deg) to
        // recover the pre-rotation, still-elliptical-scaled point.
        let dx = mapped.x - 50, dy = mapped.y - 50
        let ciRadians = -37.0 * .pi / 180
        let unrotatedX = dx * CGFloat(cos(-ciRadians)) - dy * CGFloat(sin(-ciRadians))
        let unrotatedY = dx * CGFloat(sin(-ciRadians)) + dy * CGFloat(cos(-ciRadians))
        let rx = CGFloat(radiusX) * 100, ry = CGFloat(radiusY) * 100
        let normalized = pow(unrotatedX / rx, 2) + pow(unrotatedY / ry, 2)
        XCTAssertEqual(normalized, 1, accuracy: 0.001)
    }

    // MARK: - Feather / inner radius

    func testInnerRadiusRespectsFeather() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3,
            rotationDegrees: 0, feather: 0.4, extent: squareExtent
        )
        XCTAssertEqual(result!.innerRadius, result!.gradientRadius * 0.6, accuracy: accuracy)
    }

    func testFeatherIsClampedToMinimum() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3,
            rotationDegrees: 0, feather: 0, extent: squareExtent
        )
        XCTAssertEqual(
            result!.innerRadius,
            result!.gradientRadius * CGFloat(1 - RadialMaskGeometry.minimumFeather),
            accuracy: accuracy
        )
    }

    func testFeatherAboveOneClampsToOne() {
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3,
            rotationDegrees: 0, feather: 2, extent: squareExtent
        )
        XCTAssertEqual(result!.innerRadius, 0, accuracy: accuracy)
    }

    func testInnerRadiusFractionMatchesResolveForTheSameFeather() {
        let feather = 0.3
        let result = RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.3,
            rotationDegrees: 0, feather: feather, extent: squareExtent
        )!
        let fraction = RadialMaskGeometry.innerRadiusFraction(feather: feather)
        XCTAssertEqual(result.innerRadius, result.gradientRadius * CGFloat(fraction), accuracy: accuracy)
    }

    func testInnerRadiusFractionNaNFeatherReturnsFallback() {
        // Reviewer-caught: this function is a documented shared source of
        // truth a future standalone UI caller will also use directly (not
        // just through `resolve`, which already guards its own inputs) --
        // pin its own independent NaN guard. Only NaN needs the fallback --
        // see the next test for why +/-infinity is deliberately NOT routed
        // through it.
        XCTAssertEqual(RadialMaskGeometry.innerRadiusFraction(feather: .nan), 1 - RadialMaskGeometry.minimumFeather)
    }

    func testInnerRadiusFractionInfiniteFeatherClampsCorrectlyWithoutFallback() {
        // +infinity clamps to feather 1 (fully soft) -> fraction 0; -infinity
        // clamps to minimumFeather -> fraction 1 - minimumFeather. Routing
        // these through the NaN fallback instead (an earlier draft's
        // overcorrection, reviewer-caught) would have given +infinity the
        // HARDEST edge instead of the correct fully-soft one.
        XCTAssertEqual(RadialMaskGeometry.innerRadiusFraction(feather: .infinity), 0)
        XCTAssertEqual(RadialMaskGeometry.innerRadiusFraction(feather: -.infinity), 1 - RadialMaskGeometry.minimumFeather)
    }

    // MARK: - Degenerate inputs -> nil

    func testZeroRadiusXReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        ))
    }

    func testZeroRadiusYReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        ))
    }

    func testNegativeRadiusReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: -0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        ))
    }

    func testSubHalfPixelRadiusReturnsNil() {
        // 0.001 * 100px extent == 0.1px, well under the 0.5px floor.
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.001, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        ))
    }

    func testNonFiniteCenterReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: .nan, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: squareExtent
        ))
    }

    func testNonFiniteRotationReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: .infinity, feather: 0.5, extent: squareExtent
        ))
    }

    func testEmptyExtentReturnsNil() {
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: .zero
        ))
    }

    func testInfiniteExtentReturnsNil() {
        // CGRect.infinite's width/height are CGFloat.greatestFiniteMagnitude
        // -- finite by IEEE semantics -- so this specifically guards against
        // the `.isFinite`-alone trap this codebase has been bitten by before
        // (ProxyBuilder.build, RawDecoder.materialize).
        XCTAssertNil(RadialMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.2,
            rotationDegrees: 0, feather: 0.5, extent: .infinite
        ))
    }

    // MARK: - Proportionality under extent scaling (the P2 proxy guard)

    func testGeometryScalesProportionallyWithExtent() {
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let smallResult = RadialMaskGeometry.resolve(
            centerX: 0.3, centerY: 0.7, radiusX: 0.25, radiusY: 0.15,
            rotationDegrees: 20, feather: 0.5, extent: small
        )!
        let largeResult = RadialMaskGeometry.resolve(
            centerX: 0.3, centerY: 0.7, radiusX: 0.25, radiusY: 0.15,
            rotationDegrees: 20, feather: 0.5, extent: large
        )!
        XCTAssertEqual(largeResult.gradientRadius, smallResult.gradientRadius * 4, accuracy: accuracy)
        XCTAssertEqual(largeResult.innerRadius, smallResult.innerRadius * 4, accuracy: accuracy)

        let smallEdge = CGPoint(x: smallResult.gradientRadius, y: 0).applying(smallResult.transform)
        let largeEdge = CGPoint(x: largeResult.gradientRadius, y: 0).applying(largeResult.transform)
        XCTAssertEqual(largeEdge.x, smallEdge.x * 4, accuracy: accuracy)
        XCTAssertEqual(largeEdge.y, smallEdge.y * 4, accuracy: accuracy)
    }
}
