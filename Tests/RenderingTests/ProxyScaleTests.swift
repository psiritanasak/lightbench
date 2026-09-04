import XCTest
@testable import PhotoApp

final class ProxyScaleTests: XCTestCase {
    // MARK: - requiredScale

    func testDrawableSizedSourceNeverUpscales() {
        // Source already matches the drawable exactly: fitScale == 1, so
        // headroom (1.25) alone would ask for MORE pixels than the source
        // has. The result must still be clamped to 1, never above.
        let scale = ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 3200, height: 2100),
            container: CGSize(width: 3200, height: 2100),
            zoomScale: 1
        )
        XCTAssertEqual(scale ?? -1, 1, accuracy: 0.0001)
    }

    func testRetinaWorkedExample() {
        // The exact worked example from this feature's plan: a 24MP D610
        // source (6000x4000) into a 3200x2100px Retina drawable.
        let scale = ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100),
            zoomScale: 1
        )
        // fitScale = min(3200/6000, 2100/4000) = min(0.5333, 0.525) = 0.525
        // requiredScale = min(1, 1.25 * 0.525) = 0.65625
        XCTAssertEqual(scale ?? -1, 0.65625, accuracy: 0.0001)
    }

    func testZoomDoublesRequiredScale() {
        // Container picked so the SAME axis (height) binds at both zoom
        // levels and the result stays well below the clamp-to-1 ceiling, so
        // the 2x relationship isn't obscured by an axis switch or clamping.
        let extent = CGSize(width: 6000, height: 4000)
        let container = CGSize(width: 2000, height: 666)
        let base = ProxyScale.requiredScale(displayedExtentSize: extent, container: container, zoomScale: 1)
        let zoomed = ProxyScale.requiredScale(displayedExtentSize: extent, container: container, zoomScale: 2)
        XCTAssertEqual(zoomed ?? -1, (base ?? -1) * 2, accuracy: 0.0001)
    }

    func testHighZoomClampsToOne() {
        let scale = ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100),
            zoomScale: 8
        )
        XCTAssertEqual(scale ?? -1, 1, accuracy: 0.0001)
    }

    func testSubOneZoomClampedUpToOne() {
        // ZoomPanGeometry.minZoom is 1, but defend anyway: a hypothetical
        // zoom < 1 must not REDUCE the required scale below what fit alone
        // needs — that would be the unsafe direction.
        let atZoomOne = ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100),
            zoomScale: 1
        )
        let atZoomPointFive = ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100),
            zoomScale: 0.5
        )
        XCTAssertEqual(atZoomPointFive, atZoomOne)
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(ProxyScale.requiredScale(
            displayedExtentSize: .zero, container: CGSize(width: 100, height: 100), zoomScale: 1
        ))
        XCTAssertNil(ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 100, height: 100), container: .zero, zoomScale: 1
        ))
        XCTAssertNil(ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: CGFloat.infinity, height: 100),
            container: CGSize(width: 100, height: 100), zoomScale: 1
        ))
    }

    func testDegenerateZoomScaleReturnsNil() {
        // `max(zoomScale, 1)` alone does NOT catch NaN — Swift's `max(x, y)`
        // returns `x` when `y >= x` is false, and `1 >= .nan` is false, so a
        // NaN zoomScale would otherwise propagate through to a NaN result,
        // contradicting this function's own "nil on any degenerate input"
        // contract. Caught in review; pinned here so it can't regress.
        XCTAssertNil(ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100), zoomScale: .nan
        ))
        XCTAssertNil(ProxyScale.requiredScale(
            displayedExtentSize: CGSize(width: 6000, height: 4000),
            container: CGSize(width: 3200, height: 2100), zoomScale: .infinity
        ))
    }

    // MARK: - effectiveContainer

    func testEffectiveContainerHalvesWidthForSideBySide() {
        let container = ProxyScale.effectiveContainer(
            drawableSize: CGSize(width: 3200, height: 2100), isSideBySide: true
        )
        XCTAssertEqual(container, CGSize(width: 1600, height: 2100))
    }

    func testEffectiveContainerUnchangedOtherwise() {
        let container = ProxyScale.effectiveContainer(
            drawableSize: CGSize(width: 3200, height: 2100), isSideBySide: false
        )
        XCTAssertEqual(container, CGSize(width: 3200, height: 2100))
    }

    func testSideBySideHalvesRequiredScaleVersusUsingTheFullDrawable() {
        // A wide extent so WIDTH is the binding axis at both the full and
        // halved container widths (height is never close to binding),
        // isolating the halving effect from an axis switch. This pins the
        // exact hazard IMPROVEMENTS.md's design review flagged: computing
        // Side by Side's requirement against the FULL drawable instead of
        // its own half-width container would ask for 2x the pixels it needs.
        let drawableSize = CGSize(width: 3200, height: 2100)
        let full = ProxyScale.effectiveContainer(drawableSize: drawableSize, isSideBySide: false)
        let half = ProxyScale.effectiveContainer(drawableSize: drawableSize, isSideBySide: true)
        let extent = CGSize(width: 8000, height: 2000)

        let fullScale = ProxyScale.requiredScale(displayedExtentSize: extent, container: full, zoomScale: 1)
        let halfScale = ProxyScale.requiredScale(displayedExtentSize: extent, container: half, zoomScale: 1)

        XCTAssertEqual(halfScale ?? -1, (fullScale ?? -1) / 2, accuracy: 0.0001)
    }

    // MARK: - isWorthwhile

    func testIsWorthwhileBelowCeilingAndAboveFloor() {
        XCTAssertTrue(ProxyScale.isWorthwhile(requiredScale: 0.5, sourcePixelCount: 24_000_000))
    }

    func testIsWorthwhileFalseAtCeiling() {
        // Documented as `<`, not `<=` — pin the boundary exactly.
        XCTAssertFalse(ProxyScale.isWorthwhile(
            requiredScale: ProxyScale.worthwhileScaleCeiling, sourcePixelCount: 24_000_000
        ))
    }

    func testIsWorthwhileFalseJustBelowCeiling() {
        XCTAssertTrue(ProxyScale.isWorthwhile(
            requiredScale: ProxyScale.worthwhileScaleCeiling - 0.001, sourcePixelCount: 24_000_000
        ))
    }

    func testIsWorthwhileFalseBelowMinimumSourcePixels() {
        XCTAssertFalse(ProxyScale.isWorthwhile(
            requiredScale: 0.3, sourcePixelCount: ProxyScale.minimumSourcePixels - 1
        ))
    }

    func testIsWorthwhileTrueAtMinimumSourcePixels() {
        XCTAssertTrue(ProxyScale.isWorthwhile(
            requiredScale: 0.3, sourcePixelCount: ProxyScale.minimumSourcePixels
        ))
    }

    // MARK: - canReuse (grow-only)

    func testCanReuseFalseWithNoCachedScale() {
        XCTAssertFalse(ProxyScale.canReuse(cachedScale: nil, requiredScale: 0.5))
    }

    func testCanReuseTrueAtExactMatch() {
        XCTAssertTrue(ProxyScale.canReuse(cachedScale: 0.5, requiredScale: 0.5))
    }

    func testCanReuseTrueWhenCachedIsLarger() {
        XCTAssertTrue(ProxyScale.canReuse(cachedScale: 0.8, requiredScale: 0.5))
    }

    func testCanReuseFalseWhenCachedIsSmaller() {
        XCTAssertFalse(ProxyScale.canReuse(cachedScale: 0.4, requiredScale: 0.5))
    }
}
