import XCTest
@testable import PhotoApp

/// `UprightLineDetector` on lines drawn in code with exact ground truth (centre-based `x cos t + y sin t = rho`, y down).
final class UprightLineDetectorTests: XCTestCase {
    struct Truth {
        var thetaDegrees: Double
        var rho: Double
        /// Optional extent along the line (centre-based pixels), nil = the whole frame.
        var alongRange: ClosedRange<Double>?
    }

    /// A mid-grey frame with each line drawn 3 px wide (soft edges), optionally with deterministic noise.
    static func draw(_ lines: [Truth], width: Int = 640, height: Int = 480, noise: Float = 0) -> FeatureMatcher.GrayImage {
        var pixels = [Float](repeating: 0.3, count: width * height)
        var seed: UInt32 = 987_654_321
        func random() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        let cx = Double(width) / 2 - 0.5, cy = Double(height) / 2 - 0.5
        for y in 0..<height {
            for x in 0..<width {
                var value: Float = 0.3
                for line in lines {
                    let t = line.thetaDegrees * .pi / 180
                    let px = Double(x) - cx, py = Double(y) - cy
                    let distance = abs(px * cos(t) + py * sin(t) - line.rho)
                    let along = -px * sin(t) + py * cos(t)
                    if let range = line.alongRange, !range.contains(along) { continue }
                    value = max(value, 0.3 + 0.6 * Float(min(1, max(0, 2.0 - distance))))
                }
                pixels[y * width + x] = value + noise * random()
            }
        }
        return FeatureMatcher.GrayImage(width: width, height: height, pixels: pixels)! // test-only force unwrap
    }

    private func assertFinds(_ truth: Truth, in lines: [UprightLineDetector.Line], angleAccuracy: Double = 0.05, rhoAccuracy: Double = 0.3,
                             file: StaticString = #filePath, line: UInt = #line) {
        let match = lines.min { abs($0.theta - truth.thetaDegrees * .pi / 180) < abs($1.theta - truth.thetaDegrees * .pi / 180) }
        guard let found = match else { return XCTFail("no lines found", file: file, line: line) }
        XCTAssertEqual(found.theta * 180 / .pi, truth.thetaDegrees, accuracy: angleAccuracy, file: file, line: line)
        XCTAssertEqual(found.rho, truth.rho, accuracy: rhoAccuracy, file: file, line: line)
    }

    func testFindsExactVerticalLinesWithTheirAnglesAndPositions() {
        let truth = [Truth(thetaDegrees: 3, rho: -150), Truth(thetaDegrees: 3.5, rho: 10), Truth(thetaDegrees: -4, rho: 160)]
        let found = UprightLineDetector.detect(in: Self.draw(truth))
        XCTAssertEqual(found.vertical.count, 3)
        for t in truth {
            let near = found.vertical.filter { abs($0.rho - t.rho) < 20 }
            assertFinds(t, in: near)
        }
        XCTAssertTrue(found.horizontal.isEmpty)
    }

    func testFindsExactHorizontalLines() {
        let truth = [Truth(thetaDegrees: 90 + 2, rho: -100), Truth(thetaDegrees: 90 - 3, rho: 120)]
        let found = UprightLineDetector.detect(in: Self.draw(truth))
        XCTAssertEqual(found.horizontal.count, 2)
        for t in truth { assertFinds(t, in: found.horizontal.filter { abs($0.rho - t.rho) < 20 }) }
        XCTAssertTrue(found.vertical.isEmpty)
    }

    func testFindsLinesInMildNoise() {
        let truth = [Truth(thetaDegrees: -2, rho: -120), Truth(thetaDegrees: -2.5, rho: 130)]
        let found = UprightLineDetector.detect(in: Self.draw(truth, noise: 0.05))
        XCTAssertEqual(found.vertical.count, 2)
        for t in truth { assertFinds(t, in: found.vertical.filter { abs($0.rho - t.rho) < 20 }, angleAccuracy: 0.3, rhoAccuracy: 1.5) }
    }

    func testIgnoresLinesOutsideTheAngleWindows() {
        let found = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 45, rho: 0)]))
        XCTAssertTrue(found.vertical.isEmpty)
        XCTAssertTrue(found.horizontal.isEmpty)
    }

    func testIgnoresSegmentsShorterThanTheMinimumLength() {
        // 40 px of a 480 px frame (8%) is under the 12% minimum.
        let found = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 0, rho: 0, alongRange: -20...20)]))
        XCTAssertTrue(found.vertical.isEmpty)
        let long = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 0, rho: 0, alongRange: -150...150)]))
        XCTAssertEqual(long.vertical.count, 1)
    }

    func testFlatImageHasNoLinesAndIsDeterministic() {
        let flat = FeatureMatcher.GrayImage(width: 200, height: 100, pixels: [Float](repeating: 0.5, count: 20_000))!
        let found = UprightLineDetector.detect(in: flat)
        XCTAssertTrue(found.vertical.isEmpty && found.horizontal.isEmpty)
        let image = Self.draw([Truth(thetaDegrees: 1, rho: 40), Truth(thetaDegrees: 91, rho: -60)])
        XCTAssertEqual(UprightLineDetector.detect(in: image), UprightLineDetector.detect(in: image))
    }

    func testTiltSignConvention() {
        // theta > 0 on a vertical line: x = (rho - y sin t)/cos t, so the TOP (y < 0) is further right (clockwise lean).
        let found = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 5, rho: 0)]))
        XCTAssertEqual(found.vertical.first?.ccwTiltDegrees ?? 0, -5, accuracy: 0.3)
        let horizontal = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 95, rho: 0)]))
        XCTAssertEqual(horizontal.horizontal.first?.ccwTiltDegrees ?? 0, -5, accuracy: 0.3)
    }

    // MARK: Clutter and weak support

    private struct Rng {
        var seed: UInt32
        mutating func next() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) }
    }

    private func image(width: Int = 640, height: Int = 480, _ paint: (Int, Int) -> Float) -> FeatureMatcher.GrayImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = paint(x, y) } }
        return FeatureMatcher.GrayImage(width: width, height: height, pixels: pixels)! // test-only force unwrap
    }

    func testRandomSpeckleHasNoLines() {
        var rng = Rng(seed: 1)
        let found = UprightLineDetector.detect(in: image { _, _ in rng.next() })
        XCTAssertTrue(found.vertical.isEmpty, "vertical: \(found.vertical.count)")
        XCTAssertTrue(found.horizontal.isEmpty, "horizontal: \(found.horizontal.count)")
    }

    func testOrientedTextureOfShortStrokesHasNoLines() {
        // Many short (12 px) vertical strokes at random places: every stroke is oriented, none is a line.
        var rng = Rng(seed: 7)
        var pixels = [Float](repeating: 0.3, count: 640 * 480)
        for _ in 0..<1200 {
            let x = Int(rng.next() * 636) + 2, y = Int(rng.next() * 460) + 4
            for dy in 0..<12 { pixels[(y + dy) * 640 + x] = 0.9; pixels[(y + dy) * 640 + x + 1] = 0.9 }
        }
        let found = UprightLineDetector.detect(in: FeatureMatcher.GrayImage(width: 640, height: 480, pixels: pixels)!)
        XCTAssertTrue(found.vertical.isEmpty, "vertical: \(found.vertical.count)")
    }

    func testABlurredThickStepEdgeIsOneLine() {
        // Left dark, right bright, 8 px soft ramp: one edge, however thick its gradient band is.
        let found = UprightLineDetector.detect(in: image { x, _ in
            Float(min(max((Double(x) - 316) / 8, 0), 1)) * 0.6 + 0.2
        })
        XCTAssertEqual(found.vertical.count, 1)
        // A wide gradient band is wider than the fit's 3.4 px band, which limits the angle to about half a degree.
        XCTAssertEqual(found.vertical.first?.theta ?? 9, 0, accuracy: 0.01)
    }

    func testADashedLineWithABigGapIsRejected() {
        // Two 20 px dashes 300 px apart: 40 px of real support, though the end-to-end span is 320 px.
        let dashed = UprightLineDetector.detect(in: Self.draw([
            Truth(thetaDegrees: 0, rho: 0, alongRange: -170...(-150)), Truth(thetaDegrees: 0, rho: 0, alongRange: 130...150)]))
        XCTAssertTrue(dashed.vertical.isEmpty)
        // The same two dashes joined by a continuous line are found.
        let joined = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 0, rho: 0, alongRange: -170...150)]))
        XCTAssertEqual(joined.vertical.count, 1)
    }

    func testAShortDashedPairIsRejectedEvenWhenItsEndsAreFarEnoughApart() {
        // Two 20 px dashes with a 22 px gap: the end-to-end distance (62 px) passes the 12% length test and the
        // fill test (64%), but only 40 px are really covered (under the 57 px minimum).
        let pair = UprightLineDetector.detect(in: Self.draw([
            Truth(thetaDegrees: 0, rho: 0, alongRange: -31...(-11)), Truth(thetaDegrees: 0, rho: 0, alongRange: 11...31)]))
        XCTAssertTrue(pair.vertical.isEmpty)
    }

    func testScatteredCollinearDotsAreRejected() {
        // 20 isolated dots along a vertical line 24 px apart: collinear, but nothing continuous.
        let dots = image { x, y in (abs(x - 320) <= 1 && abs(y % 24 - 12) <= 1) ? 1 : 0.2 }
        let found = UprightLineDetector.detect(in: dots)
        XCTAssertTrue(found.vertical.isEmpty, "found \(found.vertical.count)")
    }

    func testAContinuousLineStillPassesTheSupportChecks() {
        let found = UprightLineDetector.detect(in: Self.draw([Truth(thetaDegrees: 1, rho: 30)]))
        XCTAssertEqual(found.vertical.count, 1)
        XCTAssertGreaterThan(found.vertical.first?.span ?? 0, 450)
    }
}
