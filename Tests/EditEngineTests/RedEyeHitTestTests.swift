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

    // MARK: - toggling(_:in:fitRect:threshold:) — D8 (IMPROVEMENTS.md): the
    // shared add-or-remove decision reused by both `RedEyeOverlayView`'s
    // mouse tap gesture and `ContentView`'s keyboard Return-to-commit.

    func testTogglingFarFromEveryPointAppendsANewOne() {
        let fitRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = RedEyeHitTest.toggling(
            CGPoint(x: 0.8, y: 0.8), in: [], fitRect: fitRect, threshold: 16
        )
        XCTAssertEqual(result, [RedEyePoint(x: 0.8, y: 0.8)])
    }

    func testTogglingNearAnExistingPointRemovesIt() {
        let fitRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let existing = [RedEyePoint(x: 0.1, y: 0.1), RedEyePoint(x: 0.9, y: 0.9)]
        // (0.1, 0.1) in a 100x100 fitRect is screen point (10, 10); tapping
        // (11, 12) is within the 16pt threshold of it.
        let result = RedEyeHitTest.toggling(
            CGPoint(x: 0.11, y: 0.12), in: existing, fitRect: fitRect, threshold: 16
        )
        XCTAssertEqual(result, [RedEyePoint(x: 0.9, y: 0.9)])
    }

    func testTogglingTwiceAtTheSamePositionIsAddThenRemove() {
        let fitRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let added = RedEyeHitTest.toggling(CGPoint(x: 0.5, y: 0.5), in: [], fitRect: fitRect, threshold: 16)
        XCTAssertEqual(added, [RedEyePoint(x: 0.5, y: 0.5)])

        let removed = RedEyeHitTest.toggling(CGPoint(x: 0.5, y: 0.5), in: added, fitRect: fitRect, threshold: 16)
        XCTAssertEqual(removed, [])
    }
}
