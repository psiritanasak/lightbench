import XCTest
import CoreImage
@testable import PhotoApp

/// Mirrors `ImageAverageColorTests`'s style — see `ImageToneStatistics` for
/// what this is used for (the sampling half of Auto Tone).
final class ImageToneStatisticsTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double = 1, size: Int = 64) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// A REAL bitmap-backed image (not a constant-color generator) —
    /// reviewer-caught (Auto Tone planning session): `CIImage(color:)
    /// .cropped(to:)` is a constant generator, which Core Image can fold
    /// through `compute(of:)`'s own downscale transform WITHOUT ever
    /// rasterizing/resampling an edge pixel, so it cannot exercise the
    /// premultiplied-alpha edge-bleed bug `compute(of:)` had (now fixed).
    /// Any test that needs to actually exercise resampling at a real pixel
    /// boundary needs a genuine bitmap source instead.
    private func bitmapGrayImage(gray: Double, width: Int, height: Int) -> CIImage {
        var data = [Float](repeating: Float(gray), count: width * height * 4)
        for pixelIndex in 0..<(width * height) {
            data[pixelIndex * 4 + 3] = 1
        }
        let cfData = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: cfData, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace
        )
    }

    /// A bitmap-backed two-region image — `splitAt`'s column and every
    /// column before it are `leftGray`, everything from `splitAt` onward is
    /// `rightGray`. See `bitmapGrayImage`'s own doc comment for why this
    /// needs to be bitmap-backed rather than two composited generators.
    private func bitmapTwoRegionImage(width: Int, height: Int, splitAt: Int, leftGray: Double, rightGray: Double) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(x < splitAt ? leftGray : rightGray)
                let offset = (y * width + x) * 4
                data[offset] = value
                data[offset + 1] = value
                data[offset + 2] = value
                data[offset + 3] = 1
            }
        }
        let cfData = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: cfData, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linearSpace
        )
    }

    /// `columns` distinct luma values (`x / (columns - 1)`), each filling
    /// one full-height column — unlike every two-region fixture above (at
    /// most 2 distinct values), this exercises `percentile(_:in:)`'s
    /// nearest-rank indexing across many real ranks.
    private func bitmapRampImage(columns: Int, height: Int) -> CIImage {
        var data = [Float](repeating: 0, count: columns * height * 4)
        for y in 0..<height {
            for x in 0..<columns {
                let value = Float(x) / Float(columns - 1)
                let offset = (y * columns + x) * 4
                data[offset] = value
                data[offset + 1] = value
                data[offset + 2] = value
                data[offset + 3] = 1
            }
        }
        let cfData = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: cfData, bytesPerRow: columns * 16,
            size: CGSize(width: columns, height: height), format: .RGBAf, colorSpace: linearSpace
        )
    }

    func testSolidGrayImageGivesFlatPercentilesAndZeroChroma() {
        let image = solidColorImage(r: 0.18, g: 0.18, b: 0.18)
        let stats = ImageToneStatistics.compute(of: image)

        XCTAssertEqual(stats?.percentile0_5 ?? -1, 0.18, accuracy: 0.005)
        XCTAssertEqual(stats?.percentile50 ?? -1, 0.18, accuracy: 0.005)
        XCTAssertEqual(stats?.percentile99_5 ?? -1, 0.18, accuracy: 0.005)
        XCTAssertEqual(stats?.logAverageLuma ?? -1, 0.18, accuracy: 0.005)
        XCTAssertEqual(stats?.meanChroma ?? -1, 0, accuracy: 0.001)
    }

    /// Reviewer-caught (Auto Tone planning session): `CIContext.render`'s
    /// output is PREMULTIPLIED, and a bitmap-backed source at a
    /// non-256-sample-target-aligned size gets a resampled edge row/column
    /// whose alpha lands strictly between 0.5 and 1 — still passing the
    /// `a >= 0.5` qualifying guard, but with its RGB scaled down by that
    /// fractional alpha. MEASURED (temporary harness, since deleted): before
    /// the fix, a uniform 0.18-gray 3000x2000 bitmap read `percentile0_5`
    /// as low as 0.134 — an entirely fabricated "lifted black," exactly the
    /// value Auto Tone's own Black Point solver would misread as a real,
    /// present shadow. `solidColorImage`'s constant-generator fixtures
    /// above cannot catch this at all (see `bitmapGrayImage`'s own doc
    /// comment) — this is the one test in this file that would have failed
    /// against the pre-fix code.
    func testUniformBitmapBackedImageAtNonAlignedSizeGivesAccuratePercentiles() {
        let image = bitmapGrayImage(gray: 0.18, width: 3000, height: 2000)
        let stats = ImageToneStatistics.compute(of: image)

        XCTAssertEqual(stats?.percentile0_5 ?? -1, 0.18, accuracy: 0.01)
        XCTAssertEqual(stats?.percentile50 ?? -1, 0.18, accuracy: 0.01)
        XCTAssertEqual(stats?.percentile99_5 ?? -1, 0.18, accuracy: 0.01)
    }

    func testTwoRegionImageGivesDistinctPercentiles() {
        // An UNEQUAL split (25% dark / 75% bright), not a 50/50 one —
        // reviewer-caught: at an exact 50/50 split, nearest-rank's own
        // `round(0.5 * (n-1))` legitimately lands the median INSIDE the
        // bright region (rounds away from zero at the exact tie), not
        // "between" the two regions as a prior version of this test
        // incorrectly asserted; that version only passed because a
        // constant-generator fixture's upscale happened to blend a
        // boundary column. An unequal split makes the median unambiguous.
        let image = bitmapTwoRegionImage(width: 64, height: 64, splitAt: 16, leftGray: 0.02, rightGray: 0.9)
        let stats = ImageToneStatistics.compute(of: image)

        XCTAssertEqual(stats?.percentile5 ?? -1, 0.02, accuracy: 0.01)
        XCTAssertEqual(stats?.percentile50 ?? -1, 0.9, accuracy: 0.01)
        XCTAssertEqual(stats?.percentile95 ?? -1, 0.9, accuracy: 0.01)
    }

    /// Pins `percentile(_:in:)`'s nearest-rank convention
    /// (`round(fraction * (n-1))`) against many distinct ranks — every
    /// other fixture in this file has at most 2 real luma values, so none
    /// of them can tell a correct rank index from an off-by-one. Sized at
    /// exactly `ImageToneStatistics`'s own 256px sample target so
    /// `compute(of:)`'s downscale is the identity transform, ruling out
    /// resampling as an explanation for any mismatch. Expected columns
    /// derived by hand from `n = 256*256 = 65536`: `round(fraction *
    /// 65535)` gives ranks 328/3277/32768/62258/65207, which fall in
    /// columns 1/12/128/243/254 respectively (each column occupies 256
    /// consecutive sorted entries).
    func testPercentilesMatchExpectedRanksOnADistinctValueRamp() {
        let image = bitmapRampImage(columns: 256, height: 256)
        let stats = ImageToneStatistics.compute(of: image)

        // Reviewer-caught: `accuracy: 0.01` was loose enough (~2.5 column
        // steps, each 1/255 ≈ 0.0039) to accept a WRONG rank — measured,
        // `sorted[32767] = 127/255` (one rank off the expected 128/255)
        // still passed at that tolerance, making the test vacuous for its
        // one job (pinning the exact-.5 rounding convention). Values are
        // exact to ~1e-8 on this identity-scale fixture, so a tolerance
        // under half a column step (0.00196) is not flaky.
        XCTAssertEqual(stats?.percentile0_5 ?? -1, 1.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(stats?.percentile5 ?? -1, 12.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(stats?.percentile50 ?? -1, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(stats?.percentile95 ?? -1, 243.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(stats?.percentile99_5 ?? -1, 254.0 / 255.0, accuracy: 0.001)
    }

    func testLogAverageIsBelowTheArithmeticMeanForANonUniformImage() {
        // The Reinhard log-average is a COMPRESSIVE estimator — a few very
        // bright pixels pull a plain arithmetic mean up more than they
        // should for "how dark the scene reads." Pins that this type
        // actually uses the log form, not a mean masquerading as one.
        let dark = solidColorImage(r: 0.02, g: 0.02, b: 0.02, size: 64).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64))
        let bright = solidColorImage(r: 0.9, g: 0.9, b: 0.9, size: 64).cropped(to: CGRect(x: 48, y: 0, width: 16, height: 64))
        let image = dark.composited(over: bright)

        let stats = ImageToneStatistics.compute(of: image)
        let arithmeticMean = 0.02 * 0.75 + 0.9 * 0.25

        XCTAssertLessThan(stats?.logAverageLuma ?? .greatestFiniteMagnitude, arithmeticMean)
    }

    func testColorfulImageGivesPositiveMeanChroma() {
        let image = solidColorImage(r: 0.8, g: 0.1, b: 0.1)
        let stats = ImageToneStatistics.compute(of: image)

        XCTAssertGreaterThan(stats?.meanChroma ?? 0, 0.1)
    }

    func testAlphaExcludedPixelsDoNotSkewStatistics() {
        let opaqueColor = CIColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1, colorSpace: linearSpace)!
        let transparentColor = CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 0, colorSpace: linearSpace)!
        let opaqueHalf = CIImage(color: opaqueColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let transparentHalf = CIImage(color: transparentColor).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = opaqueHalf.composited(over: transparentHalf)
        // A same-extent, fully-opaque reference — NOT a hardcoded pixel
        // count — since `compute(of:)` resamples every input to its own
        // fixed sample target (matching `HistogramComputer`/
        // `ImageAverageColor`'s own established behavior): a 64px source
        // measures far more than 64*64 raw pixels once upscaled to that
        // target, so the only resolution-independent way to assert "half
        // the pixels were excluded" is against what the SAME resample
        // target actually produces for this extent.
        let fullyOpaqueReference = solidColorImage(r: 0.7, g: 0.7, b: 0.7, size: 64)

        guard let stats = ImageToneStatistics.compute(of: image),
              let referenceStats = ImageToneStatistics.compute(of: fullyOpaqueReference)
        else {
            XCTFail("expected non-nil statistics")
            return
        }

        XCTAssertEqual(stats.percentile50, 0.7, accuracy: 0.01)
        XCTAssertEqual(
            Double(stats.qualifyingPixelCount), Double(referenceStats.qualifyingPixelCount) / 2,
            accuracy: Double(referenceStats.qualifyingPixelCount) * 0.02
        )
    }

    func testZeroExtentImageReturnsNil() {
        XCTAssertNil(ImageToneStatistics.compute(of: CIImage.empty()))
    }

    func testStatisticsAreResolutionIndependent() {
        // Bitmap-backed at BOTH sizes, not constant generators — reviewer-
        // caught: a generator-composite version of this test compares two
        // fixtures that can never exercise real edge resampling at either
        // size, so it would pass even if resolution independence were
        // genuinely broken by a resample-dependent bug (like the
        // premultiplied-alpha one this file's own fix addresses).
        let small = bitmapTwoRegionImage(width: 64, height: 64, splitAt: 32, leftGray: 0.02, rightGray: 0.9)
        let large = bitmapTwoRegionImage(width: 2048, height: 2048, splitAt: 1024, leftGray: 0.02, rightGray: 0.9)

        let smallStats = ImageToneStatistics.compute(of: small)
        let largeStats = ImageToneStatistics.compute(of: large)

        XCTAssertEqual(smallStats?.percentile5 ?? -1, largeStats?.percentile5 ?? -2, accuracy: 0.02)
        XCTAssertEqual(smallStats?.percentile95 ?? -1, largeStats?.percentile95 ?? -2, accuracy: 0.02)
        XCTAssertEqual(smallStats?.logAverageLuma ?? -1, largeStats?.logAverageLuma ?? -2, accuracy: 0.02)
    }
}
