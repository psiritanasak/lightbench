import CoreGraphics
import XCTest
@testable import PhotoApp

final class StylePadGeometryTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 190, height: 190)
    private var half: CGFloat { 95 - StylePadGeometry.puckInset }

    func testCentreIsExactlyIdentityAndTheEdgesAreTheExtremes() {
        let c = StylePadGeometry.screenPoint(tone: 0, color: 0, in: rect)
        XCTAssertEqual(c, CGPoint(x: 95, y: 95))
        let v = StylePadGeometry.values(at: c, in: rect)
        XCTAssertEqual(v.tone, 0); XCTAssertEqual(v.color, 0)
        let topRight = StylePadGeometry.screenPoint(tone: 1, color: 1, in: rect)
        XCTAssertEqual(topRight, CGPoint(x: 95 + half, y: 95 - half), "Tone +1 is the TOP edge, Color +1 the right edge")
        let bottomLeft = StylePadGeometry.screenPoint(tone: -1, color: -1, in: rect)
        XCTAssertEqual(bottomLeft, CGPoint(x: 95 - half, y: 95 + half))
    }

    func testRoundTripAwayFromTheCentre() {
        for (t, c) in [(0.5, -0.25), (-0.75, 0.9), (1.0, -1.0), (0.1, 0.1)] {
            let v = StylePadGeometry.values(at: StylePadGeometry.screenPoint(tone: t, color: c, in: rect), in: rect)
            XCTAssertEqual(v.tone, t, accuracy: 1e-6)
            XCTAssertEqual(v.color, c, accuracy: 1e-6)
        }
    }

    func testDraggingOutsideClampsEachAxisIndependently() {
        let v = StylePadGeometry.values(at: CGPoint(x: 5_000, y: -5_000), in: rect)
        XCTAssertEqual(v.color, 1); XCTAssertEqual(v.tone, 1)
        let w = StylePadGeometry.values(at: CGPoint(x: -5_000, y: 5_000), in: rect)
        XCTAssertEqual(w.color, -1); XCTAssertEqual(w.tone, -1)
        let mixed = StylePadGeometry.values(at: CGPoint(x: 95 + half / 2, y: 9_999), in: rect)
        XCTAssertEqual(mixed.color, 0.5, accuracy: 1e-6, "an out-of-range Y does not disturb X")
        XCTAssertEqual(mixed.tone, -1)
    }

    func testEachAxisSnapsToExactZeroWithinTwoPercentButNotBeyond() {
        let snap = StylePadGeometry.centerSnapFraction
        let inside = CGPoint(x: 95 + half * CGFloat(snap) * 0.9, y: 95 - half * 0.5)
        let a = StylePadGeometry.values(at: inside, in: rect)
        XCTAssertEqual(a.color, 0, "Color snaps to a literal 0")
        XCTAssertEqual(a.tone, 0.5, accuracy: 1e-6, "Tone is unaffected")
        let outside = CGPoint(x: 95 + half * CGFloat(snap) * 1.5, y: 95)
        XCTAssertGreaterThan(StylePadGeometry.values(at: outside, in: rect).color, 0)
    }

    func testDegenerateRectsAndNonFinitePointsGiveZeroNeverNaN() {
        for r in [CGRect.zero, CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 190, height: 4)] {
            let v = StylePadGeometry.values(at: CGPoint(x: 3, y: 3), in: r)
            XCTAssertEqual(v.tone, 0); XCTAssertEqual(v.color, 0)
            let p = StylePadGeometry.screenPoint(tone: 1, color: 1, in: r)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
        }
        let nan = StylePadGeometry.values(at: CGPoint(x: CGFloat.nan, y: 5), in: rect)
        XCTAssertEqual(nan.tone, 0); XCTAssertEqual(nan.color, 0)
        let p = StylePadGeometry.screenPoint(tone: .nan, color: .infinity, in: rect)
        XCTAssertEqual(p, CGPoint(x: 95, y: 95), "non-finite stored values draw at the centre")
    }

    func testSteppedClampsAndReturnsToAnExactZero() {
        XCTAssertEqual(StylePadGeometry.stepped(0, by: 0.1), 0.1)
        XCTAssertEqual(StylePadGeometry.stepped(0.95, by: 0.1), 1)
        XCTAssertEqual(StylePadGeometry.stepped(-0.95, by: -0.1), -1)
        var v = 0.0
        for _ in 0..<7 { v = StylePadGeometry.stepped(v, by: 0.1) }
        for _ in 0..<7 { v = StylePadGeometry.stepped(v, by: -0.1) }
        XCTAssertEqual(v, 0, "seven up and seven down returns to a LITERAL zero, not 1e-16")
        XCTAssertEqual(StylePadGeometry.stepped(.nan, by: 0.1), 0.1)
    }
}
