import XCTest
@testable import PhotoApp

/// Verifies `CompareLayout`'s pure geometry — extracted from `ImageRenderer`/
/// `CompareDividerOverlay` specifically so this arithmetic gets direct unit
/// test coverage, matching the rigor already applied to `CropAspectMathTests`/
/// `ThinSliderGeometryTests`.
final class CompareLayoutTests: XCTestCase {
    private let accuracy: Double = 0.0001

    // MARK: - sideBySideFitRects

    func testSideBySideFitRectsAreCongruentAndOffsetByHalfTheDrawableWidth() {
        let (left, right) = CompareLayout.sideBySideFitRects(
            imageSize: CGSize(width: 100, height: 100), drawableSize: CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(left.width, right.width, accuracy: accuracy)
        XCTAssertEqual(left.height, right.height, accuracy: accuracy)
        XCTAssertEqual(right.minX - left.minX, 200, accuracy: accuracy)
        XCTAssertEqual(right.minY, left.minY, accuracy: accuracy)
    }

    func testSideBySideFitRectsEachFitWithinTheirOwnHalf() {
        let (left, right) = CompareLayout.sideBySideFitRects(
            imageSize: CGSize(width: 300, height: 100), drawableSize: CGSize(width: 400, height: 200)
        )
        XCTAssertLessThanOrEqual(left.maxX, 200 + accuracy)
        XCTAssertGreaterThanOrEqual(right.minX, 200 - accuracy)
        XCTAssertLessThanOrEqual(right.maxX, 400 + accuracy)
    }

    func testSideBySideFitRectsHandleATallImage() {
        let (left, right) = CompareLayout.sideBySideFitRects(
            imageSize: CGSize(width: 100, height: 300), drawableSize: CGSize(width: 400, height: 200)
        )
        XCTAssertLessThanOrEqual(left.height, 200 + accuracy)
        XCTAssertEqual(left.height, right.height, accuracy: accuracy)
    }

    func testSideBySideFitRectsOfDegenerateZeroSizeAreZero() {
        let (left, right) = CompareLayout.sideBySideFitRects(
            imageSize: .zero, drawableSize: CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(left, .zero)
        XCTAssertEqual(right, .zero)
    }

    // MARK: - splitRects

    func testSplitRectsTileTheOriginalRectExactlyAtEveryPosition() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 150)
        for orientation: SplitOrientation in [.vertical, .horizontal] {
            for position in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let (first, second) = CompareLayout.splitRects(rect, orientation: orientation, position: position)
                let union = first.union(second)
                let message = "orientation \(orientation) position \(position)"
                XCTAssertEqual(union.minX, rect.minX, accuracy: accuracy, message)
                XCTAssertEqual(union.minY, rect.minY, accuracy: accuracy, message)
                XCTAssertEqual(union.width, rect.width, accuracy: accuracy, message)
                XCTAssertEqual(union.height, rect.height, accuracy: accuracy, message)
                // No overlap: the two areas sum to exactly the original area.
                XCTAssertEqual(
                    first.width * first.height + second.width * second.height,
                    rect.width * rect.height, accuracy: 0.01, message
                )
            }
        }
    }

    func testSplitRectsVerticalDividesAlongX() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let (first, second) = CompareLayout.splitRects(rect, orientation: .vertical, position: 0.25)
        XCTAssertEqual(first.width, 50, accuracy: accuracy)
        XCTAssertEqual(second.width, 150, accuracy: accuracy)
        XCTAssertEqual(first.height, rect.height, accuracy: accuracy)
        XCTAssertEqual(second.height, rect.height, accuracy: accuracy)
    }

    func testSplitRectsHorizontalDividesAlongY() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let (first, second) = CompareLayout.splitRects(rect, orientation: .horizontal, position: 0.25)
        XCTAssertEqual(first.height, 25, accuracy: accuracy)
        XCTAssertEqual(second.height, 75, accuracy: accuracy)
        XCTAssertEqual(first.width, rect.width, accuracy: accuracy)
        XCTAssertEqual(second.width, rect.width, accuracy: accuracy)
    }

    func testSplitRectsClampsAnOutOfRangePosition() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let (belowZero, _) = CompareLayout.splitRects(rect, orientation: .vertical, position: -1)
        XCTAssertEqual(belowZero.width, 0, accuracy: accuracy)
        let (aboveOne, _) = CompareLayout.splitRects(rect, orientation: .vertical, position: 2)
        XCTAssertEqual(aboveOne.width, rect.width, accuracy: accuracy)
    }

    // MARK: - dividerFraction

    func testDividerFractionAtMidpointIsOneHalf() {
        let fitRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: 100, y: 50), in: fitRect, orientation: .vertical),
            0.5, accuracy: accuracy
        )
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: 100, y: 50), in: fitRect, orientation: .horizontal),
            0.5, accuracy: accuracy
        )
    }

    func testDividerFractionUsesXForVerticalAndYForHorizontal() {
        let fitRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: 50, y: 90), in: fitRect, orientation: .vertical),
            0.25, accuracy: accuracy
        )
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: 190, y: 25), in: fitRect, orientation: .horizontal),
            0.25, accuracy: accuracy
        )
    }

    func testDividerFractionClampsBeyondEitherEdge() {
        let fitRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: -50, y: 50), in: fitRect, orientation: .vertical),
            0, accuracy: accuracy
        )
        XCTAssertEqual(
            CompareLayout.dividerFraction(at: CGPoint(x: 500, y: 50), in: fitRect, orientation: .vertical),
            1, accuracy: accuracy
        )
    }

    func testDividerFractionOnDegenerateZeroSizeFitRectReturnsCenterNotNaN() {
        let result = CompareLayout.dividerFraction(at: CGPoint(x: 10, y: 10), in: .zero, orientation: .vertical)
        XCTAssertFalse(result.isNaN)
        XCTAssertEqual(result, 0.5, accuracy: accuracy)
    }
}
