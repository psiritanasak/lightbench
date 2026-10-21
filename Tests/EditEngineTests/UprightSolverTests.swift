import XCTest
@testable import PhotoApp

/// `UprightSolver` on hand-built line sets. The signs and units are pinned against the real pipeline by
/// `UprightRoundTripTests`; these cases pin the arithmetic (including an independent hypot-based derivation of the
/// off-centre case) and the guards.
final class UprightSolverTests: XCTestCase {
    private let width = 640, height = 480

    /// A near-vertical line through the vanishing point (xv, yv) (centre-based, y UP) crossing the centre row at `a`.
    private func vanishingLine(a: Double, xv: Double, yv: Double, span: Double = 400) -> UprightLineDetector.Line {
        let b = (xv - a) / yv // x = a + b * y_up
        let theta = atan(b)
        return UprightLineDetector.Line(theta: theta, rho: a * cos(theta), span: span, votes: 500)
    }

    private func vertical(_ lines: [UprightLineDetector.Line]) -> UprightLineDetector.Lines {
        UprightLineDetector.Lines(width: width, height: height, vertical: lines, horizontal: [])
    }

    private func converging(xv: Double, yv: Double, offsets: [Double] = [-200, -50, 100, 250]) -> UprightLineDetector.Lines {
        vertical(offsets.map { vanishingLine(a: $0, xv: xv, yv: yv) })
    }

    private func correction(_ outcome: UprightSolver.Outcome, file: StaticString = #filePath, line: UInt = #line) -> UprightSolver.Correction? {
        guard case .solved(let c) = outcome else { XCTFail("expected .solved, got \(outcome)", file: file, line: line); return nil }
        return c
    }

    // MARK: Vertical

    func testLinesConvergingAtTheTopNarrowTheBottom() throws {
        let c = try XCTUnwrap(correction(UprightSolver.solve(converging(xv: 0, yv: 1500), mode: .vertical)))
        let k = (1500.0 - 240) / (1500 + 240)
        XCTAssertEqual(c.verticalPerspective ?? 9, (-2 * (1 - k) * 100).rounded() / 100, accuracy: 0.0101)
        XCTAssertLessThan(c.verticalPerspective ?? 9, 0)
        XCTAssertEqual(c.straightenAngle, 0)
    }

    func testLinesDivergingAtTheTopNarrowTheTop() throws {
        let c = try XCTUnwrap(correction(UprightSolver.solve(converging(xv: 0, yv: -1500), mode: .vertical)))
        let k = (1500.0 + 240) / (1500 - 240)
        XCTAssertEqual(c.verticalPerspective ?? -9, 2 * (1 - 1 / k), accuracy: 0.0101)
        XCTAssertGreaterThan(c.verticalPerspective ?? -9, 0)
    }

    func testStrongConvergenceClampsToTheSliderLimit() throws {
        // d = 500: k = 260/740 = 0.35, below the 0.5 limit.
        XCTAssertEqual(correction(UprightSolver.solve(converging(xv: 0, yv: 500), mode: .vertical))?.verticalPerspective, -1)
        XCTAssertEqual(correction(UprightSolver.solve(converging(xv: 0, yv: -500), mode: .vertical))?.verticalPerspective, 1)
    }

    func testKLimitsAreExactlyTheSliderLimits() throws {
        // k = 0.5 -> d = 3h = 720 gives (720-240)/(720+240) = 0.5 -> v = -1; k = 2 -> d = -720.
        XCTAssertEqual(correction(UprightSolver.solve(converging(xv: 0, yv: 720), mode: .vertical))?.verticalPerspective ?? 0, -1, accuracy: 0.011)
        XCTAssertEqual(correction(UprightSolver.solve(converging(xv: 0, yv: -720), mode: .vertical))?.verticalPerspective ?? 0, 1, accuracy: 0.011)
    }

    func testOffCentreVanishingPointRotatesFirstAndUsesTheEnlargedExtent() throws {
        let xv = 300.0, yv = 1500.0
        let c = try XCTUnwrap(correction(UprightSolver.solve(converging(xv: xv, yv: yv), mode: .vertical)))
        let rotation = atan2(xv, yv) // independent derivation: the VP direction's angle from straight up
        XCTAssertEqual(c.straightenAngle, (rotation * 180 / .pi * 10).rounded() / 10, accuracy: 0.0001)
        let boundsHalf = (Double(width) * abs(sin(rotation)) + Double(height) * abs(cos(rotation))) / 2
        let distance = hypot(xv, yv)
        let k = (distance - boundsHalf) / (distance + boundsHalf)
        XCTAssertEqual(c.verticalPerspective ?? 9, -2 * (1 - k), accuracy: 0.0101)
        // Using the un-rotated frame's half height would give a different (wrong) answer.
        let naive = -2 * (1 - (distance - 240) / (distance + 240))
        XCTAssertGreaterThan(abs((c.verticalPerspective ?? 0) - naive), 0.02)
    }

    func testParallelLinesAreAlreadyUpright() {
        XCTAssertEqual(UprightSolver.solve(converging(xv: 0, yv: 1e12), mode: .vertical), .alreadyUpright)
    }

    func testFewerThanTwoLinesFindNothing() {
        XCTAssertEqual(UprightSolver.solve(vertical([]), mode: .vertical), .noLines)
        XCTAssertEqual(UprightSolver.solve(vertical([vanishingLine(a: 0, xv: 0, yv: 1000)]), mode: .vertical), .noLines)
    }

    func testBunchedLinesCannotMeasureConvergence() {
        XCTAssertEqual(UprightSolver.solve(converging(xv: 0, yv: 1000, offsets: [0, 20, 40]), mode: .vertical), .unmeasurable)
    }

    func testLinesThatCrossInsideTheFrameAreRejected() {
        XCTAssertEqual(UprightSolver.solve(converging(xv: 0, yv: 200), mode: .vertical), .unmeasurable) // d < half height
    }

    // MARK: Level

    private func horizontal(_ tiltsCCW: [Double], spans: [Double]? = nil) -> UprightLineDetector.Lines {
        let lines = tiltsCCW.enumerated().map { index, tilt in
            UprightLineDetector.Line(theta: .pi / 2 - tilt * .pi / 180, rho: Double(index) * 40, span: spans?[index] ?? 500, votes: 500)
        }
        return UprightLineDetector.Lines(width: width, height: height, vertical: [], horizontal: lines)
    }

    func testLevelUndoesTheLinesCounterClockwiseTilt() throws {
        let c = try XCTUnwrap(correction(UprightSolver.solve(horizontal([2.0, 2.2, 1.8]), mode: .level)))
        XCTAssertEqual(c.straightenAngle, -2.0, accuracy: 0.0001)
        XCTAssertNil(c.verticalPerspective)
    }

    func testLevelUsesTheLengthWeightedMedianSoAnOutlierDoesNotWin() throws {
        let c = try XCTUnwrap(correction(UprightSolver.solve(horizontal([3.0, 3.1, 12.0], spans: [400, 400, 100]), mode: .level)))
        XCTAssertEqual(c.straightenAngle, -3.1, accuracy: 0.0001) // the first value whose cumulative weight reaches half (3.1); the 12.0 outlier is ignored
    }

    func testLevelPrefersTheHorizontalFamilyEvenWhenTheVerticalsAreLonger() throws {
        let verticals = [-100.0, 100].map { UprightLineDetector.Line(theta: 0.05, rho: $0, span: 900, votes: 900) }
        let horizontals = [0.0, 50].map { UprightLineDetector.Line(theta: .pi / 2 - 0.02, rho: $0, span: 200, votes: 200) }
        let lines = UprightLineDetector.Lines(width: width, height: height, vertical: verticals, horizontal: horizontals)
        let c = try XCTUnwrap(correction(UprightSolver.solve(lines, mode: .level)))
        XCTAssertEqual(c.straightenAngle, -1.1, accuracy: 0.0001) // the horizontals' 0.02 rad ccw tilt, not the verticals' 2.9 degrees
    }

    func testLevelFallsBackToParallelVerticalsOnly() throws {
        func verticals(_ thetas: [Double]) -> UprightLineDetector.Lines {
            let lines = thetas.enumerated().map { UprightLineDetector.Line(theta: $1, rho: Double($0) * 60, span: 400, votes: 400) }
            return UprightLineDetector.Lines(width: width, height: height, vertical: lines, horizontal: [])
        }
        let parallel = try XCTUnwrap(correction(UprightSolver.solve(verticals([0.05, 0.05, 0.051]), mode: .level)))
        XCTAssertEqual(parallel.straightenAngle, 2.9, accuracy: 0.0001) // top leans right: counter-clockwise fix
        // Converging verticals (a tall building seen from below) must not level the photo.
        XCTAssertEqual(UprightSolver.solve(verticals([-0.12, -0.04, 0.04, 0.12]), mode: .level), .noLines)
    }

    func testLevelRefusesASingleStrongTiltedLine() {
        // A road or hillside: one long line at 25 degrees.
        XCTAssertEqual(UprightSolver.solve(horizontal([25.0], spans: [900]), mode: .level), .noLines)
    }

    func testLevelNeedsAtLeastTwoLinesEvenWhenTheTiltIsSmall() {
        XCTAssertEqual(UprightSolver.solve(horizontal([3.0], spans: [900]), mode: .level), .noLines)
    }

    func testLevelRefusesAConsensusBeyondTheCap() {
        XCTAssertEqual(UprightSolver.solve(horizontal([20.0, 20.1, 19.9]), mode: .level), .noLines)
        XCTAssertNotEqual(UprightSolver.solve(horizontal([11.0, 11.1, 10.9]), mode: .level), .noLines)
    }

    func testLevelNeedsHalfTheLengthToAgree() {
        XCTAssertEqual(UprightSolver.solve(horizontal([1.0, 5.0, 9.0]), mode: .level), .noLines)
    }

    func testLevelBelowTheThresholdIsAlreadyUpright() {
        XCTAssertEqual(UprightSolver.solve(horizontal([0.1, 0.05]), mode: .level), .alreadyUpright)
        XCTAssertEqual(UprightSolver.solve(horizontal([]), mode: .level), .noLines)
    }

    // MARK: Vertical outliers

    func testAnOutlierLineDoesNotMoveTheVerticalFit() throws {
        let clean = converging(xv: 0, yv: 1500)
        let lampPost = UprightLineDetector.Line(theta: 20 * .pi / 180, rho: 300 * cos(20 * .pi / 180), span: 400, votes: 500)
        let dirty = vertical(clean.vertical + [lampPost])
        XCTAssertEqual(UprightSolver.solve(dirty, mode: .vertical), UprightSolver.solve(clean, mode: .vertical))
        let c = try XCTUnwrap(correction(UprightSolver.solve(dirty, mode: .vertical)))
        XCTAssertEqual(c.straightenAngle, 0)
    }

    func testWeightedMedianBasics() {
        XCTAssertEqual(UprightSolver.weightedMedian([(1, 1), (2, 1), (10, 1)]), 2)
        XCTAssertEqual(UprightSolver.weightedMedian([(1, 5), (2, 1), (10, 1)]), 1)
    }

    func testModeLabels() {
        XCTAssertEqual(UprightMode.level.historyLabel, "Upright Level")
        XCTAssertEqual(UprightMode.vertical.historyLabel, "Upright Vertical")
    }
}
