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
}
