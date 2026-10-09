import simd
import XCTest
@testable import PhotoApp

final class HDRMergeMathTests: XCTestCase {
    private func close(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, _ accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testWeightPeaksAtMidGreyAndVanishesAtBlackAndClippedWhite() {
        let mid = HDRMergeMath.weight(linear: SIMD3(repeating: 0.2140)) // sRGB 0.5
        XCTAssertEqual(mid, 1, accuracy: 0.01)
        XCTAssertEqual(HDRMergeMath.weight(linear: .zero), HDRMergeMath.weightFloor, accuracy: 1e-9)
        XCTAssertEqual(HDRMergeMath.weight(linear: SIMD3(repeating: 1)), HDRMergeMath.weightFloor, accuracy: 1e-9)
        XCTAssertEqual(HDRMergeMath.weight(linear: SIMD3(repeating: 3.5)), HDRMergeMath.weightFloor, accuracy: 1e-9, "values above 1 are clipped data")
        XCTAssertGreaterThan(HDRMergeMath.weight(linear: SIMD3(repeating: 0.05)), HDRMergeMath.weight(linear: SIMD3(repeating: 0.005)))
    }

    func testWeightUsesTheLargestChannelSoOneBlownChannelDownWeightsThePixel() {
        let balanced = HDRMergeMath.weight(linear: SIMD3(0.2, 0.2, 0.2))
        let blown = HDRMergeMath.weight(linear: SIMD3(0.2, 0.2, 1.0))
        XCTAssertGreaterThan(balanced, 0.5)
        XCTAssertEqual(blown, HDRMergeMath.weightFloor, accuracy: 1e-9)
    }

    func testValidityScalesTheWeightAndZeroValidityDropsTheFrame() {
        let w = HDRMergeMath.weight(linear: SIMD3(repeating: 0.2))
        XCTAssertEqual(HDRMergeMath.weight(linear: SIMD3(repeating: 0.2), validity: 0.5), w * 0.5, accuracy: 1e-7)
        XCTAssertEqual(HDRMergeMath.weight(linear: SIMD3(repeating: 0.2), validity: 0), 0)
    }

    /// Exact bracket: three frames of the same radiance at -2/0/+2 EV, each clipped at 1. Wherever at least one frame is unclipped the
    /// merge returns the radiance (here a highlight of 3.0, held only by the -2 EV frame).
    func testMergeRecoversARadianceAboveOneFromTheUnderexposedFrame() {
        let radiance = SIMD3<Float>(3.0, 2.4, 1.8)
        let gains: [Float] = [0.25, 1, 4]
        let samples = gains.map { g in HDRMergeMath.Sample(linear: simd_clamp(radiance * g, .zero, SIMD3(repeating: 1)), gain: g) }
        close(HDRMergeMath.merge(samples), radiance, 1e-4)
    }

    func testMergeOfConsistentUnclippedFramesIsExactAndOrderIndependent() {
        let radiance = SIMD3<Float>(0.08, 0.05, 0.03)
        let gains: [Float] = [0.5, 1, 2]
        let samples = gains.map { HDRMergeMath.Sample(linear: radiance * $0, gain: $0) }
        close(HDRMergeMath.merge(samples), radiance)
        close(HDRMergeMath.merge(samples.reversed()), radiance)
    }

    func testMergeIgnoresAnInvalidFrameAndFallsBackToTheFloorWhenEverythingIsClipped() {
        let valid = HDRMergeMath.Sample(linear: SIMD3(0.1, 0.1, 0.1), gain: 1)
        let garbage = HDRMergeMath.Sample(linear: SIMD3(0.9, 0.9, 0.9), gain: 1, validity: 0)
        close(HDRMergeMath.merge([valid, garbage]), SIMD3(0.1, 0.1, 0.1))
        XCTAssertNil(HDRMergeMath.merge([garbage]))
        XCTAssertNil(HDRMergeMath.merge([]))
        // Both frames clipped: weights are the equal floor, so the result is the plain average of x / g.
        let clippedA = HDRMergeMath.Sample(linear: SIMD3(repeating: 1), gain: 1), clippedB = HDRMergeMath.Sample(linear: SIMD3(repeating: 1), gain: 2)
        close(HDRMergeMath.merge([clippedA, clippedB]), SIMD3(repeating: 0.75))
    }

    func testMergeSkipsNonPositiveGainRatherThanDividingByIt() {
        let bad = HDRMergeMath.Sample(linear: SIMD3(repeating: 0.2), gain: 0)
        let good = HDRMergeMath.Sample(linear: SIMD3(repeating: 0.2), gain: 1)
        close(HDRMergeMath.merge([bad, good]), SIMD3(repeating: 0.2))
    }
}
