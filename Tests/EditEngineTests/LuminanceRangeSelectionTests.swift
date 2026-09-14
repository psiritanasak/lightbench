import XCTest
@testable import PhotoApp

/// Verifies `LuminanceRangeSelection`'s pure math — the tone-window
/// clamping and the perceptual-to-scene-linear mapping
/// `EditPipeline.applyMasks`'s `.luminanceRange` branch depends on.
final class LuminanceRangeSelectionTests: XCTestCase {
    private let accuracy = 0.0001
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 200)

    // MARK: - Degenerate input -> nil

    func testInfiniteExtentReturnsNil() {
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: .infinite))
    }

    func testNullExtentReturnsNil() {
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: .null))
    }

    func testZeroSizedExtentReturnsNil() {
        let zero = CGRect(x: 0, y: 0, width: 0, height: 200)
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: zero))
    }

    func testNaNTargetReturnsNil() {
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: .nan, luminanceRange: 0.3, feather: 0.5, extent: extent))
    }

    func testNaNRangeReturnsNil() {
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: .nan, feather: 0.5, extent: extent))
    }

    func testNaNFeatherReturnsNil() {
        XCTAssertNil(LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: .nan, extent: extent))
    }

    // MARK: - Clamping (never nil for narrow/out-of-range input)

    func testTargetClampsBelowMinimum() {
        let low = LuminanceRangeSelection.resolve(luminanceTarget: -5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        let atMin = LuminanceRangeSelection.resolve(luminanceTarget: 0, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertEqual(low, atMin)
    }

    func testTargetClampsAboveMaximum() {
        let high = LuminanceRangeSelection.resolve(luminanceTarget: 5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        let atMax = LuminanceRangeSelection.resolve(luminanceTarget: 1, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertEqual(high, atMax)
    }

    func testRangeClampsBelowMinimum() {
        let low = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0, feather: 0.5, extent: extent)!
        let atMin = LuminanceRangeSelection.resolve(
            luminanceTarget: 0.5, luminanceRange: LuminanceRangeSelection.minimumRange, feather: 0.5, extent: extent
        )!
        XCTAssertEqual(low, atMin)
    }

    func testRangeClampsAboveMaximum() {
        let high = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 10, feather: 0.5, extent: extent)!
        let atMax = LuminanceRangeSelection.resolve(
            luminanceTarget: 0.5, luminanceRange: LuminanceRangeSelection.maximumRange, feather: 0.5, extent: extent
        )!
        XCTAssertEqual(high, atMax)
    }

    // MARK: - linearLuminance(forTone:)

    func testLinearLuminanceAtZeroIsZero() {
        XCTAssertEqual(LuminanceRangeSelection.linearLuminance(forTone: 0), 0, accuracy: accuracy)
    }

    func testLinearLuminanceAtOneIsOne() {
        XCTAssertEqual(LuminanceRangeSelection.linearLuminance(forTone: 1), 1, accuracy: accuracy)
    }

    func testLinearLuminanceAtHalfIsMeasuredMiddleGray() {
        // The exact figure this codebase's own `EditPipeline` doc comments
        // already cite for photographic middle gray in scene-linear light.
        XCTAssertEqual(LuminanceRangeSelection.linearLuminance(forTone: 0.5), 0.214, accuracy: 0.001)
    }

    func testLinearLuminanceIsMonotonicAcrossALadder() {
        let tones = [-0.2, 0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.2]
        let values = tones.map { LuminanceRangeSelection.linearLuminance(forTone: $0) }
        for i in 1..<values.count {
            XCTAssertGreaterThan(values[i], values[i - 1], "must be strictly increasing")
        }
    }

    func testLinearLuminanceLinearBranchBelowThreshold() {
        let tone = 0.02
        XCTAssertEqual(LuminanceRangeSelection.linearLuminance(forTone: tone), tone / 12.92, accuracy: accuracy)
    }

    func testLinearLuminanceExceedsOneAboveToneOne() {
        // Deliberately unclamped -- a target near white must be able to
        // reach real headroom pixels (linear > 1) elsewhere in this pipeline.
        XCTAssertGreaterThan(LuminanceRangeSelection.linearLuminance(forTone: 1.2), 1.0)
    }

    func testLinearLuminanceExtendsBelowZero() {
        XCTAssertLessThan(LuminanceRangeSelection.linearLuminance(forTone: -0.1), 0)
    }

    // MARK: - Resolved ordering / edge floor

    func testOrderingHoldsAtFeatherZero() {
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0, extent: extent)!
        XCTAssertLessThan(r.lowerZero, r.lowerFull)
        XCTAssertLessThanOrEqual(r.lowerFull, r.upperFull)
        XCTAssertLessThan(r.upperFull, r.upperZero)
    }

    func testOrderingHoldsAtFeatherHalf() {
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertLessThan(r.lowerZero, r.lowerFull)
        XCTAssertLessThanOrEqual(r.lowerFull, r.upperFull)
        XCTAssertLessThan(r.upperFull, r.upperZero)
    }

    func testOrderingHoldsAtFeatherOne() {
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 1, extent: extent)!
        XCTAssertLessThan(r.lowerZero, r.lowerFull)
        // feather == 1 collapses the plateau to a single point (a pure tent).
        XCTAssertEqual(r.lowerFull, r.upperFull, accuracy: accuracy)
        XCTAssertLessThan(r.upperFull, r.upperZero)
    }

    func testMinimumEdgeWidthEngagesAtFeatherZero() {
        // At feather 0, the tone-space edge collapses to zero width before
        // the floor widens it back out -- confirm the floor's exact value
        // is what's applied, in LINEAR space.
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0, extent: extent)!
        XCTAssertEqual(r.lowerFull - r.lowerZero, LuminanceRangeSelection.minimumEdgeWidth, accuracy: 1e-9)
        XCTAssertEqual(r.upperZero - r.upperFull, LuminanceRangeSelection.minimumEdgeWidth, accuracy: 1e-9)
    }

    func testToneSymmetricWindowIsLinearlyAsymmetric() {
        // The entire point of doing the tone -> linear mapping: a window
        // that looks even to a tone slider is NOT even in scene-linear light.
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        let lowerEdgeWidth = r.lowerFull - r.lowerZero
        let upperEdgeWidth = r.upperZero - r.upperFull
        XCTAssertNotEqual(lowerEdgeWidth, upperEdgeWidth, accuracy: 0.001)
    }

    func testUpperZeroExceedsOneAtTargetOne() {
        // Headroom reachable: targeting pure white must still have a real
        // falloff extending into linear values above 1.0.
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 1.0, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertGreaterThan(r.upperZero, 1.0)
    }

    func testRegionOfInterestIsTheFullExtent() {
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertEqual(r.regionOfInterest, extent)
    }

    func testWorkedExampleMatchesHandDerivedNumbers() {
        // target 0.5, range 0.3, feather 0.5 -- the exact worked example
        // this type's own doc comments and the implementation plan cite.
        let r = LuminanceRangeSelection.resolve(luminanceTarget: 0.5, luminanceRange: 0.3, feather: 0.5, extent: extent)!
        XCTAssertEqual(r.lowerZero, 0.1005, accuracy: 0.0005)
        XCTAssertEqual(r.lowerFull, 0.1511, accuracy: 0.0005)
        XCTAssertEqual(r.upperFull, 0.2901, accuracy: 0.0005)
        XCTAssertEqual(r.upperZero, 0.3800, accuracy: 0.0005)
    }
}
