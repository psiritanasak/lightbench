import XCTest
@testable import PhotoApp

/// Verifies `LinearMaskGeometry`'s pure geometry — the two-point
/// (`CILinearGradient`) math `EditPipeline.applyMasks`'s `.linear` branch
/// depends on. All values are hand-derived (closed-form trig, not a
/// black-box filter), matching the rigor already applied to
/// `RadialMaskGeometryTests`.
///
/// The y-flip/rotation-sign section below is the most important part of
/// this file. `RadialMaskGeometry` negates the WHOLE stored angle before
/// building a rotation MATRIX; `LinearMaskGeometry.resolve` instead flips
/// each of its two computed guide POINTS individually (the same `1 - y`
/// formula the center already uses). These are NOT in tension — both are
/// independently re-derived and confirmed to produce byte-identical
/// points for this same quantity (an earlier draft of this comment
/// incorrectly claimed the angle-negation approach was mathematically
/// wrong for a direction vector; reviewer-corrected — it is not, the two
/// are equivalent). The per-point form is used here only so this file
/// has a single flip idiom rather than mixing it with an angle-negation
/// idiom for the same purpose. The tests below still hand-verify the
/// resulting signs by compass-check, independent of the implementation,
/// so a genuinely WRONG sign (e.g. `testAngleIsNotNegatedUnlikeTheRadialTransform`'s
/// own regression case — substituting `-θ` into THIS file's
/// already-flipped formula, which IS wrong, unlike the equivalent
/// angle-negation-of-the-correctly-flipped-base-vector approach) fails
/// loudly.
final class LinearMaskGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    /// Deliberately non-square (400x200), unlike `RadialMaskGeometryTests`'
    /// square extent — `width`'s `min(extent.width, extent.height)`
    /// denominator only differs from an axis-specific fraction on a
    /// non-square extent, so a square extent would hide a wrong-axis bug.
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 200)

    // MARK: - Points / y-flip (the compass checks)

    func testZeroAnglePutsFullEffectAboveCenterInYUpSpace() {
        // width 0.5 -> hp = 0.25 * min(400,200) = 50. At angle 0, the
        // gradient direction (local +Y) is straight down on screen, so
        // point0 (full effect) sits ABOVE center once flipped into
        // CIImage's y-up space (larger y = up) -- the classic
        // graduated-ND-filter default (sky at top gets the effect).
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: extent
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.point0.x, 200, accuracy: accuracy)
        XCTAssertEqual(result!.point0.y, 150, accuracy: accuracy)
        XCTAssertEqual(result!.point1.x, 200, accuracy: accuracy)
        XCTAssertEqual(result!.point1.y, 50, accuracy: accuracy)
    }

    func testNinetyDegreesPutsFullEffectToTheRight() {
        // Rotating 90 degrees CLOCKWISE on screen turns the line vertical;
        // the gradient direction now points LEFT on screen, so point0
        // (full effect) sits to the RIGHT of center.
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 90, width: 0.5, extent: extent
        )!
        XCTAssertEqual(result.point0.x, 250, accuracy: accuracy)
        XCTAssertEqual(result.point0.y, 100, accuracy: accuracy)
        XCTAssertEqual(result.point1.x, 150, accuracy: accuracy)
        XCTAssertEqual(result.point1.y, 100, accuracy: accuracy)
    }

    func testFortyFiveDegreesIsSelfConsistentWithTheCompassChecks() {
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 45, width: 0.5, extent: extent
        )!
        let half = CGFloat(50) * CGFloat(2).squareRoot() / 2 // 50 * sin(45)/cos(45) == 35.3553...
        XCTAssertEqual(result.point0.x, 200 + half, accuracy: accuracy)
        XCTAssertEqual(result.point0.y, 100 + half, accuracy: accuracy)
        XCTAssertEqual(result.point1.x, 200 - half, accuracy: accuracy)
        XCTAssertEqual(result.point1.y, 100 - half, accuracy: accuracy)
    }

    func testOneHundredEightyDegreesSwapsWhichSideGetsTheEffect() {
        // The exact swap of the 0-degree case -- proves -180...180 is
        // REAL travel, unlike RadialMaskGeometry's deliberately-halved
        // -90...90 (an ellipse has 180-degree symmetry; a line does not,
        // since flipping it 180 degrees swaps which half of the frame
        // gets the effect).
        let zero = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: extent
        )!
        let oneEighty = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 180, width: 0.5, extent: extent
        )!
        XCTAssertEqual(oneEighty.point0.x, zero.point1.x, accuracy: accuracy)
        XCTAssertEqual(oneEighty.point0.y, zero.point1.y, accuracy: accuracy)
        XCTAssertEqual(oneEighty.point1.x, zero.point0.x, accuracy: accuracy)
        XCTAssertEqual(oneEighty.point1.y, zero.point0.y, accuracy: accuracy)
    }

    func testCenterRespectsANonZeroOriginExtent() {
        let offsetExtent = CGRect(x: 20, y: 30, width: 400, height: 200)
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: offsetExtent
        )!
        XCTAssertEqual(result.point0.x, 220, accuracy: accuracy)
        XCTAssertEqual(result.point0.y, 180, accuracy: accuracy)
        XCTAssertEqual(result.point1.x, 220, accuracy: accuracy)
        XCTAssertEqual(result.point1.y, 80, accuracy: accuracy)
    }

    func testAngleIsNotNegatedUnlikeTheRadialTransform() {
        // The exact regression this whole section exists to prevent:
        // substituting -theta into the SAME formula (the naive "just
        // negate the angle like RadialMaskGeometry does" mistake) gives a
        // DIFFERENT, MIRRORED point at a non-axis-aligned angle. Computed
        // independently here (not by calling `resolve` with a negated
        // angle -- that would only prove the function is consistent with
        // itself, not that it picked the RIGHT sign).
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 45, width: 0.5, extent: extent
        )!
        let wrongRadians = -45.0 * .pi / 180
        let hp: CGFloat = 50
        let wrongPoint0 = CGPoint(
            x: 200 + CGFloat(sin(wrongRadians)) * hp,
            y: 100 + CGFloat(cos(wrongRadians)) * hp
        )
        XCTAssertGreaterThan(abs(result.point0.x - wrongPoint0.x), 10, "negating the angle must NOT reproduce the correct point")
    }

    // MARK: - Width

    func testWidthInPixelsUsesTheSmallerExtentDimension() {
        // 0.5 * min(400, 200) == 100 (the FULL guide-to-guide distance,
        // not a half-width).
        XCTAssertEqual(LinearMaskGeometry.widthInPixels(width: 0.5, extent: extent), 100, accuracy: accuracy)
    }

    func testGuideToGuideDistanceIsRotationInvariant() {
        for angle in [0.0, 45.0, 90.0, 135.0] {
            let result = LinearMaskGeometry.resolve(
                centerX: 0.5, centerY: 0.5, rotationDegrees: angle, width: 0.5, extent: extent
            )!
            let dx = result.point0.x - result.point1.x
            let dy = result.point0.y - result.point1.y
            let distance = (dx * dx + dy * dy).squareRoot()
            XCTAssertEqual(distance, 100, accuracy: accuracy, "guide-to-guide distance must not depend on angle \(angle)")
        }
    }

    func testMinimumWidthClampsZeroAndNegativeWidthRatherThanSkippingTheMask() {
        // Deliberate divergence from RadialMaskGeometry: a zero-width
        // linear mask is a legitimate hard-edged half-plane, not "no
        // mask" -- it must still resolve (non-nil) using the clamped
        // minimum, not the requested (too-small) width.
        let zero = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0, extent: extent
        )
        let negative = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: -1, extent: extent
        )
        XCTAssertNotNil(zero)
        XCTAssertNotNil(negative)
        let expectedHalf = CGFloat(LinearMaskGeometry.minimumWidth) * 200 / 2
        XCTAssertEqual(zero!.point0.y - 100, expectedHalf, accuracy: accuracy)
        XCTAssertEqual(negative!.point0.y - 100, expectedHalf, accuracy: accuracy)
    }

    func testMinimumWidthClampsOnASmallExtentInsteadOfReturningNil() {
        // Reviewer-caught regression: on a small extent (e.g. a Library
        // thumbnail, capped well under 240px), `minimumWidth`'s own pixel
        // half-width (0.01 * min(W,H) / 2) can fall BELOW the 0.5px
        // sub-pixel floor -- an earlier draft's `guard halfWidthPixels >=
        // 0.5 else { return nil }` silently dropped the WHOLE mask in
        // exactly this case, contradicting this type's own documented
        // "clamps, never skips" contract for a too-small width. A 90x60
        // extent (min 60) with `width == minimumWidth` gives an
        // UNCLAMPED half-width of 0.01*60/2 = 0.3px, well under 0.5 --
        // this must still resolve, using the 0.5px floor instead.
        let smallExtent = CGRect(x: 0, y: 0, width: 90, height: 60)
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0,
            width: LinearMaskGeometry.minimumWidth, extent: smallExtent
        )
        XCTAssertNotNil(result, "a too-small width on a small extent must clamp, not skip the mask")
        XCTAssertEqual(result!.point0.y - 30, 0.5, accuracy: accuracy)
    }

    func testWidthInPixelsNaNFallsBackToMinimumWidth() {
        // Same shape as `RadialMaskGeometry.innerRadiusFraction`'s own
        // NaN-only fallback: this function is a documented shared source
        // of truth a future standalone UI caller (Session B's overlay)
        // will also call directly, not just through `resolve` (which
        // already guards its own inputs via `.isFinite` before ever
        // reaching this function).
        XCTAssertEqual(
            LinearMaskGeometry.widthInPixels(width: .nan, extent: extent),
            CGFloat(LinearMaskGeometry.minimumWidth) * 200,
            accuracy: accuracy
        )
    }

    func testGeometryScalesProportionallyWithExtent() {
        // The P2 interactive-proxy guard, mirroring
        // RadialMaskGeometryTests' own version of this test.
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let smallResult = LinearMaskGeometry.resolve(
            centerX: 0.3, centerY: 0.7, rotationDegrees: 20, width: 0.25, extent: small
        )!
        let largeResult = LinearMaskGeometry.resolve(
            centerX: 0.3, centerY: 0.7, rotationDegrees: 20, width: 0.25, extent: large
        )!
        XCTAssertEqual(largeResult.point0.x, smallResult.point0.x * 4, accuracy: accuracy)
        XCTAssertEqual(largeResult.point0.y, smallResult.point0.y * 4, accuracy: accuracy)
        XCTAssertEqual(largeResult.point1.x, smallResult.point1.x * 4, accuracy: accuracy)
        XCTAssertEqual(largeResult.point1.y, smallResult.point1.y * 4, accuracy: accuracy)
    }

    // MARK: - Region of interest

    func testRegionOfInterestIsTheWholeExtentForAHugeWidth() {
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 100, extent: extent
        )!
        XCTAssertEqual(result.regionOfInterest, extent)
    }

    func testRegionOfInterestExcludesTheFarHalfPlaneAtZeroDegrees() {
        // point1 (no effect) sits at y=50; everything below y=50 is fully
        // transparent and contributes nothing to the blend, so the ROI's
        // minY must sit at (or above) that boundary, not extent.minY (0).
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: extent
        )!
        XCTAssertGreaterThanOrEqual(result.regionOfInterest.minY, 50 - accuracy)
        XCTAssertLessThanOrEqual(result.regionOfInterest.maxY, extent.maxY)
    }

    func testRegionOfInterestExcludesTheFarHalfPlaneAtNinetyDegrees() {
        // point1 sits at x=150; everything to the left is excluded.
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 90, width: 0.5, extent: extent
        )!
        XCTAssertGreaterThanOrEqual(result.regionOfInterest.minX, 150 - accuracy)
    }

    func testRegionOfInterestAtFortyFiveDegreesContainsTheFarOpaqueCorner() {
        // The exact case a naive AXIS-ALIGNED band rect would clip: at a
        // diagonal angle, the opaque side's far corner is not aligned
        // with either axis, so the ROI must be computed as a real
        // half-plane clip of the extent, not a hand-rolled rectangle.
        // Checked via maxX/maxY directly, not `CGRect.contains(_:)` --
        // that method deliberately excludes a rect's own right/bottom
        // edge (documented CoreGraphics behavior), which would make this
        // assertion fail at the exact corner point even for a CORRECT
        // ROI that legitimately extends all the way to the extent's edge.
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 45, width: 0.5, extent: extent
        )!
        XCTAssertEqual(result.regionOfInterest.maxX, extent.maxX, accuracy: accuracy, "the ROI must not clip the far corner's X on the opaque side")
        XCTAssertEqual(result.regionOfInterest.maxY, extent.maxY, accuracy: accuracy, "the ROI must not clip the far corner's Y on the opaque side")
    }

    func testRegionOfInterestStaysWithinExtent() {
        let result = LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 30, width: 0.3, extent: extent
        )!
        XCTAssertTrue(extent.contains(result.regionOfInterest.insetBy(dx: accuracy, dy: accuracy)))
    }

    // MARK: - Degenerate inputs -> nil

    func testNonFiniteCenterReturnsNil() {
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: .nan, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: extent
        ))
    }

    func testNonFiniteRotationReturnsNil() {
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: .infinity, width: 0.5, extent: extent
        ))
    }

    func testNonFiniteWidthReturnsNil() {
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: .nan, extent: extent
        ))
    }

    func testEmptyExtentReturnsNil() {
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: .zero
        ))
    }

    func testInfiniteExtentReturnsNil() {
        // CGRect.infinite's width/height are CGFloat.greatestFiniteMagnitude
        // -- finite by IEEE semantics -- the same `.isFinite`-alone trap
        // this codebase has been bitten by before (RadialMaskGeometry,
        // ProxyBuilder.build, RawDecoder.materialize).
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: .infinite
        ))
    }

    func testNullExtentReturnsNil() {
        XCTAssertNil(LinearMaskGeometry.resolve(
            centerX: 0.5, centerY: 0.5, rotationDegrees: 0, width: 0.5, extent: .null
        ))
    }
}
