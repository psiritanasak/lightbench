import XCTest
@testable import PhotoApp

final class StraightenSolverTests: XCTestCase {
    private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Vision reported -X for an image rotated by +X (measured), so its angle passes through unchanged in sign.
    func testSignIsVisionsAngleInDegrees() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(4)), .angle(4))
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(-4)), .angle(-4))
    }

    func testRoundsToTenthsOfADegree() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(2.34)), .angle(2.3))
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(-2.36)), .angle(-2.4))
    }

    func testClampsToFortyFiveDegrees() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(60)), .angle(45))
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(-89)), .angle(-45))
    }

    func testThresholdBoundary() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(0.149)), .alreadyLevel)
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(-0.149)), .alreadyLevel)
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: 0), .alreadyLevel)
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(0.151)), .angle(0.2))
    }

    func testNoHorizonForNilAndNonFinite() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: nil), .noHorizon)
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: .nan), .noHorizon)
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: .infinity), .noHorizon)
    }

    func testJustAboveTheThresholdRoundsUpAndKeepsItsSign() {
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(0.16)), .angle(0.2))
        XCTAssertEqual(StraightenSolver.solve(visionHorizonAngle: rad(-0.16)), .angle(-0.2))
    }
}
