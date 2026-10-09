import XCTest
@testable import PhotoApp

final class HDRGainRefinementTests: XCTestCase {
    /// Reference luminance ramp 0.05...0.40 (well exposed in the reference and, scaled, in a frame up to ~2.2x brighter).
    private func ramp(_ n: Int = 5000) -> [Float] { (0..<n).map { 0.05 + 0.35 * Float($0 % 1000) / 1000 } }
    private func ones(_ n: Int) -> [Float] { [Float](repeating: 1, count: n) }

    /// Grey frames: the largest channel equals the luminance.
    private func refine(_ exif: Float, _ ref: [Float], _ frame: [Float], validity: [Float]? = nil) -> Float {
        HDRGainRefinement.refine(exifGain: exif, referenceLuma: ref, referencePeak: ref, frameLuma: frame, framePeak: frame, validity: validity ?? ones(ref.count))
    }

    func testMeasuresTheTrueGainWhenExifIsOff() {
        let ref = ramp()
        XCTAssertEqual(refine(2.0, ref, ref.map { $0 * 2.24 }), 2.24, accuracy: 0.01)
    }

    func testIsRobustToMovingSubjectsAndNoise() {
        let ref = ramp()
        var frame = ref.map { $0 * 2.0 } // the TRUE gain is 2.0 while EXIF says 1.8, so returning EXIF cannot pass
        for i in stride(from: 0, to: frame.count, by: 4) { frame[i] = ref[i] * 0.3 } // 25% of pixels belong to something that moved
        for i in stride(from: 1, to: frame.count, by: 10) { frame[i] = ref[i] * 2.0 * 1.1 } // mild noise on another 10%
        XCTAssertEqual(refine(1.8, ref, frame), 2.0, accuracy: 0.06)
    }

    func testClippedPixelsDoNotBiasTheMeasurement() {
        let ref = (0..<4000).map { 0.05 + 0.6 * Float($0 % 1000) / 1000 }
        let frame = ref.map { min($0 * 2.2, 1.0) } // the bright frame clips on the upper part of the ramp; true gain 2.2, EXIF 2.0
        XCTAssertEqual(refine(2.0, ref, frame), 2.2, accuracy: 0.03)
    }

    /// A pixel with ONE blown channel (blue sky: B clipped at 1 while luminance is only ~0.3) is clipped data. A luminance-only ceiling lets it in with
    /// a ratio below the true gain; the largest-channel weight must drop it (reviewer-found).
    func testPixelsWithOneClippedChannelAreIgnored() {
        let ref = ramp(10_000) // 2000 unclipped pixels: margin above `minimumSamples` so the fallback cannot stand in for the measurement
        var frame = ref.map { $0 * 2.2 }
        var framePeak = frame
        var refPeak = ref
        for i in 0..<ref.count where i % 5 != 0 { // 80% of the pixels: blue clipped in the frame, so its luminance ratio is only ~1.9 (inside the 25% window, so the guard cannot hide a bad estimate)
            frame[i] = ref[i] * 1.9
            framePeak[i] = 1.0
            refPeak[i] = ref[i] * 1.0
        }
        let g = HDRGainRefinement.refine(exifGain: 2.0, referenceLuma: ref, referencePeak: refPeak, frameLuma: frame, framePeak: framePeak, validity: ones(ref.count))
        XCTAssertEqual(g, 2.2, accuracy: 0.05, "only the 20% unclipped pixels may speak; a luminance-only test would answer about 1.9 and be accepted")
    }

    /// Dark tones of a real RAW are not proportional (ratio/gain 2.6x at the 5th luminance percentile). Even when MOST pixels are dark, the measurement
    /// must follow the midtones where the merge weights hand over.
    func testNonProportionalDarkTonesDoNotDominateEvenWhenTheyAreTheMajority() {
        var ref: [Float] = [], frame: [Float] = []
        for i in 0..<3000 { let a = 0.02 + 0.03 * Float(i % 100) / 100; ref.append(a); frame.append(a * 2.0 * 1.2) } // 60% dark, ratio inflated 1.2x (inside the 25% window)
        for i in 0..<2000 { let a = 0.10 + 0.20 * Float(i % 100) / 100; ref.append(a); frame.append(a * 2.0) } // 40% midtones, true gain
        let g = refine(1.8, ref, frame) // true gain 2.0, EXIF 1.8
        XCTAssertEqual(g, 2.0, accuracy: 0.08)
        // The unweighted median of the ratios would be the inflated 2.4.
        XCTAssertLessThan(g, 2.2)
    }

    func testFallsBackToExifWhenTheMeasurementIsImplausibleOrThinOrInvalid() {
        let ref = ramp()
        XCTAssertEqual(refine(2.0, ref, ref.map { $0 * 3.2 }), 2.0, "60% off the EXIF gain: a different scene or failed alignment")
        let tiny = [Float](repeating: 0.2, count: 400)
        XCTAssertEqual(refine(2.0, tiny, tiny.map { $0 * 2.1 }), 2.0, "too few samples")
        XCTAssertEqual(refine(2.0, ref, ref.map { $0 * 2.1 }, validity: [Float](repeating: 0, count: ref.count)), 2.0, "the warped frame covers nothing")
        XCTAssertEqual(refine(2.0, ref, [0.1]), 2.0, "mismatched lengths are returned untouched")
        XCTAssertEqual(refine(0, ref, ref), 0)
        // 30% off is beyond the 25% window.
        XCTAssertEqual(refine(2.0, ref, ref.map { $0 * 2.6 }), 2.0)
    }

    func testPartiallyCoveredPixelsAreSkipped() {
        let ref = ramp()
        var validity = ones(ref.count)
        var frame = ref.map { $0 * 2.2 }
        for i in 0..<(ref.count / 2) { validity[i] = 0.5; frame[i] = ref[i] * 0.2 }
        XCTAssertEqual(refine(2.0, ref, frame, validity: validity), 2.2, accuracy: 0.03)
    }

    func testDownwardCorrectionForAFrameDarkerThanTheReference() {
        let ref = ramp().map { $0 * 2 }
        XCTAssertEqual(refine(0.5, ref, ref.map { $0 * 0.44 }), 0.44, accuracy: 0.015)
    }
}
