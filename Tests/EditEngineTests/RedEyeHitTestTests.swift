import XCTest
import CoreGraphics
@testable import PhotoApp

/// Verifies `RedEyeHitTest`'s pure add/remove decision logic — extracted
/// from `RedEyeOverlayView` specifically so this real arithmetic gets
/// direct unit test coverage despite living in the UI layer, matching the
/// established `CropAspectMath` precedent for this pattern.
final class RedEyeHitTestTests: XCTestCase {
    func testTapNearAnExistingPointReturnsItsIndex() {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)]
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 15, y: 12), in: points, threshold: 16)

        XCTAssertEqual(index, 0)
    }

    func testTapFarFromEveryPointReturnsNil() {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)]
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 55, y: 55), in: points, threshold: 16)

        XCTAssertNil(index)
    }

    func testTapExactlyAtThresholdCounts() {
        let points = [CGPoint(x: 0, y: 0)]
        // Distance is exactly 16 (3-4-5 triangle scaled by 4).
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 9.6, y: 12.8), in: points, threshold: 16)

        XCTAssertEqual(index, 0)
    }

    func testTapJustBeyondThresholdReturnsNil() {
        let points = [CGPoint(x: 0, y: 0)]
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 9.7, y: 12.9), in: points, threshold: 16)

        XCTAssertNil(index)
    }

    func testEmptyPointsAlwaysReturnsNil() {
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 0, y: 0), in: [], threshold: 16)
        XCTAssertNil(index)
    }

    func testReturnsTheNearestOfMultipleCandidatesWithinThreshold() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 20, y: 0)]
        // (5,0) is closer than (0,0), both within threshold; (20,0) is out of range.
        let index = RedEyeHitTest.nearestPointIndex(to: CGPoint(x: 6, y: 0), in: points, threshold: 16)

        XCTAssertEqual(index, 1)
    }
}
