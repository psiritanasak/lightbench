import XCTest
@testable import PhotoApp

final class DepthRangeSelectionTests: XCTestCase {
    // MARK: Window

    func testDefaultsSelectTheNearerHalfWithHardEdges() {
        let w = DepthRangeSelection.window(farLimit: 0.5, nearLimit: 1, feather: 0)
        XCTAssertEqual(w, DepthRangeSelection.Window(low: 0.5, high: 1, edge: 0))
    }

    func testWindowIsSanitised() {
        // Reversed limits are swapped; values clamp to 0...1; non-finite parameters fall back.
        XCTAssertEqual(DepthRangeSelection.window(farLimit: 0.8, nearLimit: 0.2, feather: 0), .init(low: 0.2, high: 0.8, edge: 0))
        XCTAssertEqual(DepthRangeSelection.window(farLimit: -3, nearLimit: 7, feather: 2), .init(low: 0, high: 1, edge: DepthRangeSelection.maxFeatherSpan))
        let bad = DepthRangeSelection.window(farLimit: .nan, nearLimit: .infinity, feather: .nan)
        XCTAssertEqual(bad, .init(low: 0.5, high: 1, edge: 0))
    }

    func testAHairlineWindowIsWidenedAroundItsCentreInsideTheRange() {
        let w = DepthRangeSelection.window(farLimit: 0.4, nearLimit: 0.4, feather: 0)
        XCTAssertEqual(w.high - w.low, DepthRangeSelection.minimumWidth, accuracy: 1e-6)
        XCTAssertEqual((w.low + w.high) / 2, 0.4, accuracy: 1e-6)
        let top = DepthRangeSelection.window(farLimit: 1, nearLimit: 1, feather: 0)
        XCTAssertLessThanOrEqual(top.high, 1)
        XCTAssertEqual(top.high - top.low, DepthRangeSelection.minimumWidth, accuracy: 1e-6)
        let bottom = DepthRangeSelection.window(farLimit: 0, nearLimit: 0, feather: 0)
        XCTAssertGreaterThanOrEqual(bottom.low, 0)
    }

    // MARK: Weights

    func testWeightIsOneInsideZeroOutsideAndASmoothRampAcrossTheEdge() {
        let hard = DepthRangeSelection.Window(low: 0.4, high: 0.7, edge: 0)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.4, window: hard), 1)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.55, window: hard), 1)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.7, window: hard), 1)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.399, window: hard), 0)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.701, window: hard), 0)

        let soft = DepthRangeSelection.Window(low: 0.4, high: 0.7, edge: 0.2)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.4, window: soft), 1)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.3, window: soft), 0.5, accuracy: 1e-6, "halfway down the lower edge: smoothstep(0.5) = 0.5")
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.2, window: soft), 0, accuracy: 1e-6, "the full edge width below the window")
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.8, window: soft), 0.5, accuracy: 1e-6, "halfway down the upper edge")
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.95, window: soft), 0)
        // Smoothstep shape: a quarter of the way down is 0.84375 (3t^2 - 2t^3 at t = 0.75) on the lower side.
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.35, window: soft), 0.84375, accuracy: 1e-6)
    }

    func testWeightIsMonotoneAwayFromTheWindowAndSymmetricInTheEdges() {
        let w = DepthRangeSelection.Window(low: 0.4, high: 0.7, edge: 0.25)
        var previous: Float = 1
        for step in 0...25 {
            let weight = DepthRangeSelection.weight(nearness: 0.4 - Float(step) * 0.01, window: w)
            XCTAssertLessThanOrEqual(weight, previous + 1e-6)
            previous = weight
        }
        for d in stride(from: Float(0), through: 0.25, by: 0.025) {
            XCTAssertEqual(DepthRangeSelection.weight(nearness: 0.4 - d, window: w), DepthRangeSelection.weight(nearness: 0.7 + d, window: w), accuracy: 1e-6)
        }
    }

    func testNonFiniteAndOutOfRangeNearnessAreHandled() {
        let w = DepthRangeSelection.Window(low: 0, high: 1, edge: 0.1)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: .nan, window: w), 0)
        XCTAssertEqual(DepthRangeSelection.weight(nearness: 5, window: w), 1, "clamped to the nearest end, which is inside")
        XCTAssertEqual(DepthRangeSelection.weight(nearness: -5, window: w), 1)
    }

    func testTableMatchesTheFunctionAtEveryByte() {
        let w = DepthRangeSelection.window(farLimit: 0.3, nearLimit: 0.6, feather: 0.4)
        let table = DepthRangeSelection.table(for: w)
        XCTAssertEqual(table.count, 256)
        for byte in 0...255 { XCTAssertEqual(table[byte], DepthRangeSelection.weight(nearness: Float(byte) / 255, window: w), accuracy: 1e-7) }
    }

    // MARK: Normalizer

    func testNormalizerMapsThePercentileRangeToZeroThrough255AndClipsStrayValues() throws {
        // 1000 values 0...999 plus two stray outliers: the 2nd/98th percentile range must ignore the outliers.
        var values = (0..<1000).map { Float($0) }
        values.append(1_000_000); values.append(-1_000_000)
        let r = try XCTUnwrap(DepthNormalizer.normalize(values))
        XCTAssertEqual(r.low, 20, accuracy: 3)
        XCTAssertEqual(r.high, 980, accuracy: 3)
        XCTAssertEqual(r.bytes[0], 0, "a value below the 2nd percentile clamps to 0")
        XCTAssertEqual(r.bytes[500], 127, accuracy: 4, "the middle of the range maps to the middle")
        XCTAssertEqual(r.bytes[999], 255)
        XCTAssertEqual(r.bytes[1000], 255, "the huge outlier clamps to nearest")
        XCTAssertEqual(r.bytes[1001], 0)
        // Monotone: a larger input never maps to a smaller byte.
        for i in 1..<1000 { XCTAssertGreaterThanOrEqual(r.bytes[i], r.bytes[i - 1]) }
    }

    func testNormalizerIsScaleAndOffsetInvariant() throws {
        let base = (0..<500).map { Float($0 % 97) * 0.37 }
        let a = try XCTUnwrap(DepthNormalizer.normalize(base)), b = try XCTUnwrap(DepthNormalizer.normalize(base.map { $0 * 40 + 3 }))
        XCTAssertEqual(a.bytes, b.bytes, "iPhone disparity and model output differ in scale and offset; only the ordering matters")
    }

    func testNormalizerRefusesFlatEmptyAndAllNonFiniteMaps() {
        XCTAssertNil(DepthNormalizer.normalize([]))
        XCTAssertNil(DepthNormalizer.normalize([Float](repeating: 2.5, count: 200)), "a constant map has no depth")
        XCTAssertNil(DepthNormalizer.normalize([Float](repeating: .nan, count: 50)))
        // Nearly flat (a 0.1% wobble around 1.0): stretching it would turn noise into depth.
        let wobble = (0..<400).map { 1 + Float($0 % 5) * 0.0002 }
        XCTAssertNil(DepthNormalizer.normalize(wobble))
    }

    /// Holes are 'far', so they are never FOREGROUND; a window reaching nearness 0 (or Invert) does select them — documented, an 8-bit raster has no spare value.
    func testNormalizerTreatsHolesAsFarNotNear() throws {
        var values = (0..<200).map { Float($0) }
        values[10] = .nan
        values[11] = .infinity
        let r = try XCTUnwrap(DepthNormalizer.normalize(values))
        XCTAssertEqual(r.bytes[10], 0)
        XCTAssertEqual(r.bytes[11], 0, "an infinite hole must not light up as foreground")
    }

    func testNormalizerKeepsRealIPhoneStyleRangesUsable() throws {
        // Observed iPhone disparity ranges (docs): 0.0067...2.37 and 0.49...0.57 (narrow but real structure).
        let wide = (0..<2000).map { 0.0067 + Float($0) / 2000 * 2.36 }
        let narrow = (0..<2000).map { 0.49 + Float($0) / 2000 * 0.077 }
        XCTAssertNotNil(DepthNormalizer.normalize(wide))
        XCTAssertNotNil(DepthNormalizer.normalize(narrow), "a narrow but graded map (15% of its magnitude) is real structure")
    }

    // MARK: Source tags

    func testSourceTags() {
        XCTAssertTrue(DepthSourceTag.isEmbedded(DepthSourceTag.embedded))
        let tag = DepthSourceTag.model(id: "depth-anything-v2-small-f16", revision: "cfef6f6f2a70")
        XCTAssertEqual(tag, "model:depth-anything-v2-small-f16:cfef6f6f2a70")
        XCTAssertTrue(DepthSourceTag.isModel(tag)); XCTAssertFalse(DepthSourceTag.isEmbedded(tag))
        XCTAssertEqual(DepthSourceTag.displayName(DepthSourceTag.embedded), "iPhone depth")
        XCTAssertEqual(DepthSourceTag.displayName(tag), "Depth model")
        XCTAssertEqual(DepthSourceTag.displayName(""), "None")
        XCTAssertEqual(DepthSourceTag.displayName("something-else"), "something-else")
    }
}
