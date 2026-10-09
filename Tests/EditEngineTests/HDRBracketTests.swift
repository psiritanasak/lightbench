import XCTest
@testable import PhotoApp

final class HDRBracketTests: XCTestCase {
    private func meta(_ t: Double, f: Double = 8, iso: Double = 100) -> HDRBracket.ExposureMetadata {
        .init(exposureTime: t, fNumber: f, iso: iso)
    }
    private let range: ClosedRange<Float> = (1.0 / 16)...16

    private func plan(_ frames: [HDRBracket.ExposureMetadata], max: Int = 9) throws -> HDRBracket.Plan {
        try HDRBracket.plan(frames, maxFrames: max, gainRange: range).get()
    }

    func testBrightnessIsTimeTimesIsoOverFNumberSquared() {
        XCTAssertEqual(meta(1.0 / 100, f: 4, iso: 200).brightness ?? 0, (1.0 / 100) * 200 / 16, accuracy: 1e-12)
        XCTAssertNil(HDRBracket.ExposureMetadata(exposureTime: 0.01, fNumber: nil, iso: 100).brightness)
        XCTAssertNil(HDRBracket.ExposureMetadata(exposureTime: 0, fNumber: 8, iso: 100).brightness)
        XCTAssertNil(HDRBracket.ExposureMetadata(exposureTime: 0.01, fNumber: 8, iso: -5).brightness)
        XCTAssertNil(HDRBracket.ExposureMetadata(exposureTime: .infinity, fNumber: 8, iso: 100).brightness)
    }

    func testThreeStopBracketPicksTheMiddleFrameAsReferenceWithExactGains() throws {
        let p = try plan([meta(1.0 / 400), meta(1.0 / 100), meta(1.0 / 25)]) // -2, 0, +2 EV
        XCTAssertEqual(p.referenceIndex, 1)
        XCTAssertEqual(p.gains, [0.25, 1, 4])
    }

    func testReferenceFollowsTheMedianNotTheInputOrder() throws {
        let p = try plan([meta(1.0 / 25), meta(1.0 / 400), meta(1.0 / 100)])
        XCTAssertEqual(p.referenceIndex, 2)
        XCTAssertEqual(p.gains, [4, 0.25, 1])
    }

    func testEvenCountUsesTheLowerMedianAndApertureAndIsoCountToo() throws {
        // Same shutter, different ISO / aperture: brightness 100*1, 200*1, 400*1 and f/11 halved by 2 stops.
        let p = try plan([meta(0.01, f: 8, iso: 100), meta(0.01, f: 8, iso: 200), meta(0.01, f: 8, iso: 400), meta(0.01, f: 4, iso: 100)])
        // brightness (t*iso/f^2): 100, 200, 400, 400*... f/4: 0.01*100/16 vs f/8: 0.01*100/64 -> ratios 1, 2, 4, 4
        XCTAssertEqual(p.referenceIndex, 1, "lower median of ratios [1, 2, 4, 4] is the ISO-200 frame")
        XCTAssertEqual(p.gains, [0.5, 1, 2, 2])
    }

    func testPlanErrors() {
        XCTAssertEqual(HDRBracket.plan([meta(0.01)], maxFrames: 9, gainRange: range), .failure(.tooFewFrames))
        let ten = (0..<10).map { meta(0.01 * Double($0 + 1)) }
        XCTAssertEqual(HDRBracket.plan(ten, maxFrames: 9, gainRange: range), .failure(.tooManyFrames(limit: 9)))
        XCTAssertEqual(HDRBracket.plan([meta(0.01), .init(exposureTime: 0.02, fNumber: nil, iso: 100)], maxFrames: 9, gainRange: range), .failure(.missingExposureData(frameIndex: 1)))
        XCTAssertEqual(HDRBracket.plan([meta(0.01), meta(0.0105)], maxFrames: 9, gainRange: range), .failure(.noExposureDifference), "7% apart is metadata noise, not a bracket")
        XCTAssertEqual(HDRBracket.plan([meta(0.001), meta(0.01), meta(1)], maxFrames: 9, gainRange: range), .failure(.gainOutOfRange(frameIndex: 2)), "100x = 6.6 stops from the middle frame")
    }

    func testGainOutOfRangeNamesTheOffendingFrame() {
        let result = HDRBracket.plan([meta(1.0 / 8000), meta(1.0 / 100), meta(1.0 / 100)], maxFrames: 9, gainRange: range)
        XCTAssertEqual(result, .failure(.gainOutOfRange(frameIndex: 0)))
    }
}
