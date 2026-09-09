import XCTest
@testable import PhotoApp

/// Verifies `CrosshairGeometry.moved` — the pure step/clamp math the
/// Editor's keyboard-driven WB pick/Red-Eye placement crosshair (D8,
/// IMPROVEMENTS.md) relies on.
final class CrosshairGeometryTests: XCTestCase {
    private let accuracy: Double = 0.0001

    func testMovesRightIncreasesX() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.5), dx: CrosshairGeometry.step, dy: 0)
        XCTAssertEqual(result.x, 0.52, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.5, accuracy: accuracy)
    }

    func testMovesLeftDecreasesX() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.5), dx: -CrosshairGeometry.step, dy: 0)
        XCTAssertEqual(result.x, 0.48, accuracy: accuracy)
    }

    func testMovesDownIncreasesY() {
        // y-DOWN convention, matching `pickWhiteBalance`/`RedEyePoint`.
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.5), dx: 0, dy: CrosshairGeometry.step)
        XCTAssertEqual(result.y, 0.52, accuracy: accuracy)
    }

    func testMovesUpDecreasesY() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.5), dx: 0, dy: -CrosshairGeometry.step)
        XCTAssertEqual(result.y, 0.48, accuracy: accuracy)
    }

    func testClampsAtRightEdge() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.99, y: 0.5), dx: CrosshairGeometry.step, dy: 0)
        XCTAssertEqual(result.x, 1.0, accuracy: accuracy)
    }

    func testClampsAtLeftEdge() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.01, y: 0.5), dx: -CrosshairGeometry.step, dy: 0)
        XCTAssertEqual(result.x, 0.0, accuracy: accuracy)
    }

    func testClampsAtBottomEdge() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.99), dx: 0, dy: CrosshairGeometry.step)
        XCTAssertEqual(result.y, 1.0, accuracy: accuracy)
    }

    func testClampsAtTopEdge() {
        let result = CrosshairGeometry.moved(CGPoint(x: 0.5, y: 0.01), dx: 0, dy: -CrosshairGeometry.step)
        XCTAssertEqual(result.y, 0.0, accuracy: accuracy)
    }

    func testZeroDeltaIsANoOp() {
        let start = CGPoint(x: 0.37, y: 0.63)
        let result = CrosshairGeometry.moved(start, dx: 0, dy: 0)
        XCTAssertEqual(result.x, start.x, accuracy: accuracy)
        XCTAssertEqual(result.y, start.y, accuracy: accuracy)
    }

    func testAlreadyOutOfBoundsPositionIsClampedBack() {
        // Defensive — shouldn't happen in practice, but a corrupted/
        // hand-constructed starting position must not stay out of range.
        let result = CrosshairGeometry.moved(CGPoint(x: 1.5, y: -0.5), dx: 0, dy: 0)
        XCTAssertEqual(result.x, 1.0, accuracy: accuracy)
        XCTAssertEqual(result.y, 0.0, accuracy: accuracy)
    }
}
