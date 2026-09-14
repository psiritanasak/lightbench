import XCTest
@testable import PhotoApp

/// Verifies `BrushMaskGeometry`'s pure geometry — the point/size/raster-rect
/// math `EditPipeline.applyMasks`'s `.brush` branch depends on to rasterize
/// and blur a stroke. Deliberately non-square extent (like
/// `LinearMaskGeometryTests`'), since `radiusInPixels`'s
/// `min(extent.width, extent.height)` denominator only differs from an
/// axis-specific fraction on a non-square extent.
final class BrushMaskGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 200)

    // MARK: - Degenerate input -> nil

    func testEmptyPointsReturnsNil() {
        XCTAssertNil(BrushMaskGeometry.resolve(points: [], brushSize: 0.05, feather: 0.5, extent: extent))
    }

    func testNonFinitePointReturnsNil() {
        let points = [BrushPoint(x: .nan, y: 0.5)]
        XCTAssertNil(BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent))
    }

    func testInfiniteExtentReturnsNil() {
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        XCTAssertNil(BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: .infinite))
    }

    func testNullExtentReturnsNil() {
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        XCTAssertNil(BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: .null))
    }

    func testZeroSizedExtentReturnsNil() {
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        let zero = CGRect(x: 0, y: 0, width: 0, height: 200)
        XCTAssertNil(BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: zero))
    }

    func testWholeStrokeOffFrameReturnsNil() {
        // Every point far outside the extent, and even the padded stroke
        // bounds don't reach back to the visible image.
        let points = [BrushPoint(x: 50, y: 50)]
        XCTAssertNil(BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent))
    }

    // MARK: - Y-flip

    func testPointNearTopOfFrameFlipsToHighYInCIImageSpace() {
        // SwiftUI y-DOWN 0.1 (near the top of the frame) must flip to a
        // HIGH y value in CIImage's bottom-left/y-UP space.
        let points = [BrushPoint(x: 0.5, y: 0.1)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.points[0].x, 200, accuracy: accuracy)
        XCTAssertEqual(result!.points[0].y, 180, accuracy: accuracy)
    }

    func testPointNearBottomOfFrameFlipsToLowYInCIImageSpace() {
        let points = [BrushPoint(x: 0.5, y: 0.9)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.points[0].y, 20, accuracy: accuracy)
    }

    func testNonZeroExtentOriginOffsetsPoints() {
        let offsetExtent = CGRect(x: 1000, y: 2000, width: 400, height: 200)
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: offsetExtent)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.points[0].x, 1200, accuracy: accuracy)
        XCTAssertEqual(result!.points[0].y, 2100, accuracy: accuracy)
    }

    // MARK: - radiusInPixels (F1: clamp, never nil)

    func testTinyBrushSizeClampsRatherThanSkippingOnASmallExtent() {
        // A Library-thumbnail-sized extent (240px) with a brush size below
        // `minimumSize` must still resolve -- the F1 regression guard,
        // named after `LinearMaskGeometryTests`'s own equivalent. Small
        // enough (min dimension 60) that even `minimumSize` (0.005 * 60 =
        // 0.3px) falls under `minimumRadiusPixels` (0.5) and the ABSOLUTE
        // pixel floor must engage, not just the fractional clamp.
        let smallExtent = CGRect(x: 0, y: 0, width: 80, height: 60)
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.0001, feather: 0, extent: smallExtent)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.radiusPixels, BrushMaskGeometry.minimumRadiusPixels, accuracy: accuracy)
    }

    func testOversizedBrushSizeClampsToMaximum() {
        let radius = BrushMaskGeometry.radiusInPixels(brushSize: 999, extent: extent)
        let expected = CGFloat(BrushMaskGeometry.maximumSize) * min(extent.width, extent.height)
        XCTAssertEqual(radius, expected, accuracy: accuracy)
    }

    func testNaNBrushSizeFallsBackToMinimum() {
        let radius = BrushMaskGeometry.radiusInPixels(brushSize: .nan, extent: extent)
        let expected = CGFloat(BrushMaskGeometry.minimumSize) * min(extent.width, extent.height)
        XCTAssertEqual(radius, expected, accuracy: accuracy)
    }

    func testRadiusUsesTheSmallerExtentDimension() {
        // extent is 400x200 -- radius must scale off 200, not 400.
        let radius = BrushMaskGeometry.radiusInPixels(brushSize: 0.1, extent: extent)
        XCTAssertEqual(radius, 20, accuracy: accuracy)
    }

    // MARK: - blurRadiusInPixels

    func testZeroFeatherProducesNoBlur() {
        let radius = BrushMaskGeometry.blurRadiusInPixels(feather: 0, radiusPixels: 40)
        XCTAssertEqual(radius, 0)
    }

    func testFeatherScalesBlurRadiusWithDabRadius() {
        let small = BrushMaskGeometry.blurRadiusInPixels(feather: 1, radiusPixels: 20)
        let large = BrushMaskGeometry.blurRadiusInPixels(feather: 1, radiusPixels: 40)
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(large, small * 2, accuracy: accuracy)
    }

    func testNaNFeatherFallsBackToHardEdgeNotSoftest() {
        // Conservative direction -- the opposite fallback from
        // `radiusInPixels`'s own NaN handling, deliberately.
        let radius = BrushMaskGeometry.blurRadiusInPixels(feather: .nan, radiusPixels: 40)
        XCTAssertEqual(radius, 0)
    }

    // MARK: - Raster rect / region of interest

    func testRasterRectContainsEveryPointOutsetByRadiusAndPadding() {
        let points = [BrushPoint(x: 0.3, y: 0.5), BrushPoint(x: 0.7, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)!
        // `padding(radiusPixels:blurRadiusPixels:)` already bakes in the
        // dab radius itself (`radiusPixels + blurPaddingMultiple *
        // blurRadiusPixels + 1`) -- shrinking `rasterRect` back by exactly
        // that amount must still contain every raw stroke point (allow a
        // small slack for `.integral`'s rounding).
        let pad = BrushMaskGeometry.padding(radiusPixels: result.radiusPixels, blurRadiusPixels: result.blurRadiusPixels)
        let inset = result.rasterRect.insetBy(dx: pad, dy: pad)
        for point in result.points {
            XCTAssertLessThanOrEqual(inset.minX - 1, point.x)
            XCTAssertGreaterThanOrEqual(inset.maxX + 1, point.x)
            XCTAssertLessThanOrEqual(inset.minY - 1, point.y)
            XCTAssertGreaterThanOrEqual(inset.maxY + 1, point.y)
        }
    }

    func testRasterRectIsNotClippedToTheBareExtentNearAnEdge() {
        // A stroke right at the left edge should keep its left padding
        // even though that padding extends past x=0.
        let points = [BrushPoint(x: 0.0, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)!
        XCTAssertLessThan(result.rasterRect.minX, 0)
    }

    func testRegionOfInterestIsClippedToTheExtent() {
        let points = [BrushPoint(x: 0.0, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)!
        XCTAssertGreaterThanOrEqual(result.regionOfInterest.minX, extent.minX)
        XCTAssertTrue(extent.contains(result.regionOfInterest) || result.regionOfInterest == extent.intersection(result.regionOfInterest))
    }

    func testHugeStrokeTriggersRasterScaleBelowOneWithBoundedBitmapArea() {
        let hugeExtent = CGRect(x: 0, y: 0, width: 20_000, height: 20_000)
        let points = [BrushPoint(x: 0.05, y: 0.5), BrushPoint(x: 0.95, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.4, feather: 1, extent: hugeExtent)!
        XCTAssertLessThan(result.rasterScale, 1)
        XCTAssertLessThanOrEqual(
            result.bitmapSize.width * result.bitmapSize.height,
            BrushMaskGeometry.maximumRasterPixels * 1.05 // small slack for the ceil-to-whole-pixel rounding
        )
    }

    func testSmallStrokeDoesNotEngageRasterScale() {
        let points = [BrushPoint(x: 0.5, y: 0.5)]
        let result = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: extent)!
        XCTAssertEqual(result.rasterScale, 1)
    }

    // MARK: - Proxy-scale correctness

    func testGeometryScalesProportionallyUnderADownscaledExtent() {
        let points = [BrushPoint(x: 0.3, y: 0.4), BrushPoint(x: 0.6, y: 0.7)]
        let fullExtent = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let proxyExtent = CGRect(x: 0, y: 0, width: 400, height: 200)

        let full = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: fullExtent)!
        let proxy = BrushMaskGeometry.resolve(points: points, brushSize: 0.05, feather: 0.5, extent: proxyExtent)!

        XCTAssertEqual(full.radiusPixels / 10, proxy.radiusPixels, accuracy: 0.01)
        XCTAssertEqual(full.points[0].x / 10, proxy.points[0].x, accuracy: 0.01)
        XCTAssertEqual(full.points[0].y / 10, proxy.points[0].y, accuracy: 0.01)
    }
}
