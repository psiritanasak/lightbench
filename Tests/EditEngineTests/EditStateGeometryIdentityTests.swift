import XCTest
@testable import PhotoApp

/// Verifies `EditState.isGeometryAtIdentity` — the gate
/// `ImageDocumentModel.pickWhiteBalance` uses to decide whether a screen
/// tap maps 1:1 onto `CIRAWFilter`'s native pixel grid with no
/// inverse-geometry transform needed. A missed `&&` clause here would
/// silently widen eligibility into a case that actually needs inversion,
/// so each of the 9 geometry fields gets its own independent false-case —
/// not just one combined "any geometry set" test — so a single dropped
/// clause can't hide behind another.
final class EditStateGeometryIdentityTests: XCTestCase {
    func testTrueAtIdentity() {
        XCTAssertTrue(EditState.identity.isGeometryAtIdentity)
    }

    func testFalseWhenRotationQuarterTurnsIsNonZero() {
        var s = EditState.identity
        s.rotationQuarterTurns = 1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenStraightenAngleIsNonZero() {
        var s = EditState.identity
        s.straightenAngle = 5
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenVerticalPerspectiveIsNonZero() {
        var s = EditState.identity
        s.verticalPerspective = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenHorizontalPerspectiveIsNonZero() {
        var s = EditState.identity
        s.horizontalPerspective = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenTransformScaleIsNonOne() {
        var s = EditState.identity
        s.transformScale = 1.2
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenTransformAspectIsNonZero() {
        var s = EditState.identity
        s.transformAspect = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenFlipHorizontalIsTrue() {
        var s = EditState.identity
        s.flipHorizontal = true
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenFlipVerticalIsTrue() {
        var s = EditState.identity
        s.flipVertical = true
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenCropInsetTopIsNonZero() {
        var s = EditState.identity
        s.cropInsetTop = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenCropInsetBottomIsNonZero() {
        var s = EditState.identity
        s.cropInsetBottom = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenCropInsetLeftIsNonZero() {
        var s = EditState.identity
        s.cropInsetLeft = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testFalseWhenCropInsetRightIsNonZero() {
        var s = EditState.identity
        s.cropInsetRight = 0.1
        XCTAssertFalse(s.isGeometryAtIdentity)
    }

    func testTrueWhenOnlyANonGeometryFieldDiffers() {
        var s = EditState.identity
        s.exposureEV = 1.5
        s.contrast = 0.3
        s.boostAmount = 0.5
        XCTAssertTrue(s.isGeometryAtIdentity)
    }

    // MARK: - geometryOnlySamplingState

    /// Reviewer-caught (Auto Tone planning session): without a test tying
    /// `geometryOnlySamplingState()` to `isGeometryAtIdentity`, a future
    /// geometry field added to one but not the other would go unnoticed —
    /// the exact failure class that produced several stale field-list
    /// enumerations during Transform Scale/Aspect. This test sets every
    /// field `isGeometryAtIdentity` checks (the same values the false-case
    /// tests above use) PLUS a non-geometry sentinel, and asserts the
    /// result equals a state with ONLY those same 11 fields set — proving
    /// `geometryOnlySamplingState()` copies exactly that field set, no more
    /// and no less.
    func testGeometryOnlySamplingStateCopiesExactlyTheGeometryFields() {
        var full = EditState.identity
        full.rotationQuarterTurns = 3
        full.straightenAngle = 5
        full.verticalPerspective = 0.1
        full.horizontalPerspective = 0.1
        full.transformScale = 1.2
        full.transformAspect = 0.1
        full.flipHorizontal = true
        full.flipVertical = true
        full.cropInsetTop = 0.1
        full.cropInsetBottom = 0.1
        full.cropInsetLeft = 0.1
        full.cropInsetRight = 0.1
        // Non-geometry sentinels — must NOT survive into the sampled state.
        full.exposureEV = 1.5
        full.contrast = 0.3
        full.whiteBalanceTemperature = 9000
        full.whiteBalanceTint = 50
        full.boostAmount = 0.2

        var expected = EditState.identity
        expected.rotationQuarterTurns = 3
        expected.straightenAngle = 5
        expected.verticalPerspective = 0.1
        expected.horizontalPerspective = 0.1
        expected.transformScale = 1.2
        expected.transformAspect = 0.1
        expected.flipHorizontal = true
        expected.flipVertical = true
        expected.cropInsetTop = 0.1
        expected.cropInsetBottom = 0.1
        expected.cropInsetLeft = 0.1
        expected.cropInsetRight = 0.1

        XCTAssertEqual(full.geometryOnlySamplingState(), expected)
    }

    func testGeometryOnlySamplingStateOfIdentityIsAtGeometryIdentity() {
        XCTAssertTrue(EditState.identity.geometryOnlySamplingState().isGeometryAtIdentity)
    }
}
