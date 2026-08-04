import XCTest
@testable import PhotoApp

/// Verifies `CropAspectMath`'s pure geometry — extracted from
/// `CropOverlayView` specifically so this real arithmetic (division,
/// clamping, several edge cases) gets direct unit test coverage despite
/// living in the UI layer. All values are hand-derived (closed-form
/// algebra, not a black-box filter), matching the rigor already applied to
/// Crop v1's own coordinate-direction math.
final class CropAspectMathTests: XCTestCase {
    private let accuracy: Double = 0.0001

    // MARK: - snappedInsets

    func testSnappedInsetsHeightConstrainedPreservesRatioAndCenter() {
        // 200x100 container, current crop (0.1,0.1,0.1,0.1) -> 160x80,
        // ratio 2.0. Target ratio 1 (square) is narrower, so the result is
        // HEIGHT-constrained (height stays 80, width shrinks to 80).
        let result = CropAspectMath.snappedInsets(
            top: 0.1, bottom: 0.1, left: 0.1, right: 0.1,
            targetRatio: 1, containerSize: CGSize(width: 200, height: 100),
            maxInset: 0.45
        )
        XCTAssertEqual(result.top, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.bottom, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.left, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.right, 0.3, accuracy: accuracy)

        // Cross-check: resulting rect's own ratio equals the target, and
        // its center matches the original crop's center.
        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 1, accuracy: accuracy)
    }

    func testSnappedInsetsWidthConstrainedPreservesRatioAndCenter() {
        // 200x100 container, current crop (0,0,0.3,0.3) -> 80x100, ratio
        // 0.8. Target ratio 2 is wider, so the result is WIDTH-constrained
        // (width stays 80, height shrinks to 40).
        let result = CropAspectMath.snappedInsets(
            top: 0, bottom: 0, left: 0.3, right: 0.3,
            targetRatio: 2, containerSize: CGSize(width: 200, height: 100),
            maxInset: 0.45
        )
        XCTAssertEqual(result.top, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.bottom, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.left, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.right, 0.3, accuracy: accuracy)

        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 2, accuracy: accuracy)
    }

    func testSnappedInsetsClampsToMaxInset() {
        // A full-frame 100x100 crop snapped to an extreme 100:1 ratio would
        // need top/bottom insets of ~0.495 to stay centered -- must clamp
        // to maxInset (0.45) rather than exceed it, with left/right
        // clamping cleanly to 0 (no negative/inverted insets).
        let result = CropAspectMath.snappedInsets(
            top: 0, bottom: 0, left: 0, right: 0,
            targetRatio: 100, containerSize: CGSize(width: 100, height: 100),
            maxInset: 0.45
        )
        XCTAssertEqual(result.top, 0.45, accuracy: accuracy)
        XCTAssertEqual(result.bottom, 0.45, accuracy: accuracy)
        XCTAssertEqual(result.left, 0, accuracy: accuracy)
        XCTAssertEqual(result.right, 0, accuracy: accuracy)
    }

    // MARK: - cornerResize

    func testCornerResizeTopLeftPreservesRatioAnchorsOppositeCorner() {
        let start = (top: 0.2, bottom: 0.2, left: 0.2, right: 0.2)
        let result = CropAspectMath.cornerResize(
            .topLeft, start: start, dx: 0.1, ratio: 2,
            containerSize: CGSize(width: 200, height: 100), maxInset: 0.45
        )
        XCTAssertEqual(result.top, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.left, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.bottom, start.bottom, "anchor corner must stay exactly fixed")
        XCTAssertEqual(result.right, start.right, "anchor corner must stay exactly fixed")

        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 2, accuracy: accuracy)
    }

    func testCornerResizeTopRightPreservesRatioAnchorsOppositeCorner() {
        let start = (top: 0.2, bottom: 0.2, left: 0.2, right: 0.2)
        let result = CropAspectMath.cornerResize(
            .topRight, start: start, dx: 0.1, ratio: 2,
            containerSize: CGSize(width: 200, height: 100), maxInset: 0.45
        )
        XCTAssertEqual(result.top, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.right, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.bottom, start.bottom, "anchor corner must stay exactly fixed")
        XCTAssertEqual(result.left, start.left, "anchor corner must stay exactly fixed")

        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 2, accuracy: accuracy)
    }

    func testCornerResizeBottomLeftPreservesRatioAnchorsOppositeCorner() {
        let start = (top: 0.2, bottom: 0.2, left: 0.2, right: 0.2)
        let result = CropAspectMath.cornerResize(
            .bottomLeft, start: start, dx: 0.1, ratio: 2,
            containerSize: CGSize(width: 200, height: 100), maxInset: 0.45
        )
        XCTAssertEqual(result.bottom, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.left, 0.3, accuracy: accuracy)
        XCTAssertEqual(result.top, start.top, "anchor corner must stay exactly fixed")
        XCTAssertEqual(result.right, start.right, "anchor corner must stay exactly fixed")

        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 2, accuracy: accuracy)
    }

    func testCornerResizeBottomRightPreservesRatioAnchorsOppositeCorner() {
        let start = (top: 0.2, bottom: 0.2, left: 0.2, right: 0.2)
        let result = CropAspectMath.cornerResize(
            .bottomRight, start: start, dx: 0.1, ratio: 2,
            containerSize: CGSize(width: 200, height: 100), maxInset: 0.45
        )
        XCTAssertEqual(result.bottom, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.right, 0.1, accuracy: accuracy)
        XCTAssertEqual(result.top, start.top, "anchor corner must stay exactly fixed")
        XCTAssertEqual(result.left, start.left, "anchor corner must stay exactly fixed")

        let width = 200 * (1 - result.left - result.right)
        let height = 100 * (1 - result.top - result.bottom)
        XCTAssertEqual(width / height, 2, accuracy: accuracy)
    }

    func testCornerResizeRespectsMinCropSize() {
        // A large drag that would collapse the rect (rightEdge only 0.08,
        // far inside minCropSize's 0.05 floor) must clamp so the resulting
        // width fraction stops at exactly minCropSize, not zero/negative.
        let start = (top: 0.0, bottom: 0.0, left: 0.0, right: 0.92)
        let result = CropAspectMath.cornerResize(
            .topLeft, start: start, dx: 0.5, ratio: 1,
            containerSize: CGSize(width: 200, height: 100), maxInset: 0.45
        )
        XCTAssertEqual(result.left, 0.03, accuracy: accuracy, "0.08 rightEdge - 0.05 minCropSize")
        let widthFraction = 1 - result.left - start.right
        XCTAssertEqual(widthFraction, CropAspectMath.minCropSize, accuracy: accuracy)
        XCTAssertGreaterThan(widthFraction, 0)
    }
}
