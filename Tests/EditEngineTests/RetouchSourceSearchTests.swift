import XCTest
@testable import PhotoApp

final class RetouchSourceSearchTests: XCTestCase {
    /// A bitmap whose every ROW is a random line repeated horizontally with period `period`: two circles one
    /// period apart see identical surroundings (cost ~0); circles at other offsets do not.
    private func periodicBitmap(width: Int = 512, height: Int = 384, period: Int, seed: UInt64 = 7) -> RetouchSourceSearch.Bitmap {
        var state = seed
        func next() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float((state >> 33) % 1000) / 1000 }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        var rowPattern = [Float](repeating: 0, count: period * 3)
        for y in 0..<height {
            for i in 0..<(period * 3) { rowPattern[i] = next() }
            for x in 0..<width { for c in 0..<3 { rgb[(y * width + x) * 3 + c] = rowPattern[(x % period) * 3 + c] } }
        }
        return RetouchSourceSearch.Bitmap(width: width, height: height, rgb: rgb)!
    }

    func testFindsThePlantedTwinOneRadiusMultipleAway() throws {
        // radius fraction r with r * min(w,h) = 64/3.5 px so a distance of 3.5 radii is exactly one period (64 px).
        let bitmap = periodicBitmap(period: 64)
        let radius = (64.0 / 3.5) / 384.0
        let result = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: radius))
        XCTAssertEqual(abs(result.dx) * 384, 64, accuracy: 1.0, "found a source exactly one period away")
        XCTAssertEqual(result.dy * 384, 0, accuracy: 1.0)
        XCTAssertLessThan(result.cost, 0.01, "an exact twin has ~zero cost")
    }

    func testObstaclesAreAvoided() throws {
        let bitmap = periodicBitmap(period: 64)
        let radius = (64.0 / 3.5) / 384.0
        let free = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: radius))
        // Block exactly where the best candidate sits.
        let blocker = RetouchSourceSearch.Obstacle(x: 0.5 + free.dx * 384 / 512, y: 0.5 + free.dy, radius: radius)
        let blocked = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: radius, avoiding: [blocker]))
        XCTAssertNotEqual(blocked, free)
        XCTAssertFalse(abs(blocked.dx - free.dx) < 0.01 && abs(blocked.dy - free.dy) < 0.01)
    }

    /// Every COLUMN is a random line repeated vertically with period `period` (the transpose of `periodicBitmap`).
    private func verticallyPeriodicBitmap(width: Int = 512, height: Int = 384, period: Int) -> RetouchSourceSearch.Bitmap {
        var state: UInt64 = 11
        func next() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float((state >> 33) % 1000) / 1000 }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for x in 0..<width {
            var column = [Float](repeating: 0, count: period * 3)
            for i in 0..<(period * 3) { column[i] = next() }
            for y in 0..<height { for c in 0..<3 { rgb[(y * width + x) * 3 + c] = column[(y % period) * 3 + c] } }
        }
        return RetouchSourceSearch.Bitmap(width: width, height: height, rgb: rgb)!
    }

    /// The offset is y-UP: a spot near the TOP of the picture (y close to 1) can only borrow from BELOW, i.e. a
    /// NEGATIVE dy; a spot near the bottom only from above (positive dy). A bitmap-row-direction mix-up flips both.
    func testVerticalOffsetSignFollowsYUp() throws {
        let bitmap = verticallyPeriodicBitmap(period: 64)
        let radius = (64.0 / 3.5) / 384.0
        let nearTop = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.80, radius: radius))
        XCTAssertEqual(nearTop.dy * 384, -64, accuracy: 1.0, "the only in-frame twin is 64 px BELOW (y-up: negative)")
        let nearBottom = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.20, radius: radius))
        XCTAssertEqual(nearBottom.dy * 384, 64, accuracy: 1.0, "the only in-frame twin is 64 px ABOVE (y-up: positive)")
    }

    func testHorizontalOffsetNearTheLeftEdgeIsPositive() throws {
        let bitmap = periodicBitmap(period: 64)
        let radius = (64.0 / 3.5) / 384.0
        let left = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.14, y: 0.5, radius: radius))
        XCTAssertGreaterThan(left.dx, 0, "candidates to the left would leave the frame")
    }

    func testOutOfFrameCandidatesAreSkippedAndTooSmallBitmapsReturnNil() throws {
        // 12x12: the destination ring fits around the centre but every candidate (>= 5.2 px away) leaves the frame.
        let bitmap = periodicBitmap(width: 12, height: 12, period: 4)
        XCTAssertNil(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: 0.1), "no candidate fits")
        XCTAssertNil(RetouchSourceSearch.Bitmap(width: 0, height: 5, rgb: []))
        XCTAssertNil(RetouchSourceSearch.Bitmap(width: 2, height: 2, rgb: [0]))
    }

    func testIsDeterministic() throws {
        let bitmap = periodicBitmap(period: 50, seed: 99)
        let a = RetouchSourceSearch.bestSource(in: bitmap, x: 0.4, y: 0.6, radius: 0.04)
        let b = RetouchSourceSearch.bestSource(in: bitmap, x: 0.4, y: 0.6, radius: 0.04)
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a)
    }

    /// The offset must be the one that was SCORED. The search floors its radius at 2 px; a tiny radius used to
    /// report `distance * radius` instead (about 2 px for a 5.2 px candidate), i.e. an unevaluated, possibly
    /// overlapping source.
    func testTinyRadiusReportsTheOffsetThatWasActuallyEvaluated() throws {
        let bitmap = periodicBitmap(period: 64)
        let result = try XCTUnwrap(RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: 0.002))
        // radius 0.002 * 384 = 0.77 px -> floored to 2 px; the nearest candidate ring is 2.6 * 2 = 5.2 px away.
        XCTAssertGreaterThanOrEqual(hypot(result.dx, result.dy) * 384, 5.2 - 0.01)
    }

    func testBadInputsReturnNilInsteadOfTrapping() {
        let bitmap = periodicBitmap(period: 64)
        for (x, y, r) in [(Double.nan, 0.5, 0.02), (0.5, .infinity, 0.02), (0.5, 0.5, .nan), (0.5, 0.5, -.infinity)] {
            XCTAssertNil(RetouchSourceSearch.bestSource(in: bitmap, x: x, y: y, radius: r))
        }
        XCTAssertNil(RetouchSourceSearch.bestSource(
            in: bitmap, x: 0.5, y: 0.5, radius: 0.02, avoiding: [.init(x: .nan, y: 0, radius: 0)]))
        // A huge radius is clamped to the allowed range instead of allocating reach^2 offsets.
        _ = RetouchSourceSearch.bestSource(in: bitmap, x: 0.5, y: 0.5, radius: 1e9)
    }
}
