import XCTest
import CoreImage
@testable import PhotoApp

final class HistogramComputerTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(_ value: Double, size: Int = 64) -> CIImage {
        solidColorImage(r: value, g: value, b: value, size: size)
    }

    private func solidColorImage(r: Double, g: Double, b: Double, size: Int = 64) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // MARK: - inputDownscale(forDisplayedSize:)

    func testInputDownscaleNeverUpscales() {
        let scale = HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: 100, height: 80))
        XCTAssertEqual(scale, 1)
    }

    func testInputDownscaleAtExactlyTheTarget() {
        let target = CGFloat(HistogramComputer.sampleDimension * 2)
        let scale = HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: target, height: target / 2))
        XCTAssertEqual(scale, 1, accuracy: 0.0001)
    }

    func testInputDownscaleTargetsTheLongSide() {
        // 6000x4000 (a real 24MP source's shape) with a long side well past
        // the target should scale down to exactly 2x sampleDimension on the
        // long side, preserving aspect ratio.
        let scale = HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: 6000, height: 4000))
        let expected = CGFloat(HistogramComputer.sampleDimension * 2) / 6000
        XCTAssertEqual(scale, expected, accuracy: 0.0001)
    }

    func testInputDownscaleHandlesPortraitOrientation() {
        let scale = HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: 4000, height: 6000))
        let expected = CGFloat(HistogramComputer.sampleDimension * 2) / 6000
        XCTAssertEqual(scale, expected, accuracy: 0.0001)
    }

    func testInputDownscaleDegenerateInputsReturnOne() {
        XCTAssertEqual(HistogramComputer.inputDownscale(forDisplayedSize: .zero), 1)
        XCTAssertEqual(HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: -10, height: 100)), 1)
        XCTAssertEqual(
            HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: CGFloat.infinity, height: 100)), 1
        )
        XCTAssertEqual(
            HistogramComputer.inputDownscale(forDisplayedSize: CGSize(width: CGFloat.nan, height: 100)), 1
        )
    }

    func testEmptyExtentReturnsEmptyHistogram() {
        let data = HistogramComputer.histogram(of: CIImage.empty())
        XCTAssertTrue(data.luminance.isEmpty)
        XCTAssertTrue(data.red.isEmpty)
        XCTAssertTrue(data.green.isEmpty)
        XCTAssertTrue(data.blue.isEmpty)
    }

    func testSolidImageProducesASingleTallBin() {
        // A neutral GRAY input (r == g == b) — a good sanity check that
        // channel binning doesn't silently diverge on a neutral color: all
        // four histograms should collapse the same way.
        let data = HistogramComputer.histogram(of: solidColorImage(0.5))

        for bins in [data.luminance, data.red, data.green, data.blue] {
            XCTAssertEqual(bins.count, HistogramComputer.binCount)
            let tallBins = bins.filter { $0 > 0 }
            XCTAssertLessThanOrEqual(tallBins.count, 3, "a flat image should collapse into a small handful of adjacent bins")
            XCTAssertEqual(bins.max(), 1.0, "the tallest bin is always normalized to 1.0")
        }
    }

    func testChannelsTrackTheirOwnColorIndependently() {
        // A solid color with a distinctly different value per channel — if
        // the red/green/blue histograms were accidentally computed from
        // luminance (or from each other) instead of their OWN channel byte,
        // their peak bins would collapse together instead of tracking
        // r > g > b (the same monotonic sRGB encode is applied identically
        // to every channel, so ordering survives the linear->display
        // conversion).
        let data = HistogramComputer.histogram(of: solidColorImage(r: 0.9, g: 0.5, b: 0.1))

        let redPeak = data.red.firstIndex(of: 1.0) ?? -1
        let greenPeak = data.green.firstIndex(of: 1.0) ?? -1
        let bluePeak = data.blue.firstIndex(of: 1.0) ?? -1

        XCTAssertGreaterThanOrEqual(redPeak, 0)
        XCTAssertGreaterThanOrEqual(greenPeak, 0)
        XCTAssertGreaterThanOrEqual(bluePeak, 0)
        XCTAssertGreaterThan(redPeak, greenPeak, "red's own peak should track its own (higher) channel value, not collapse toward green")
        XCTAssertGreaterThan(greenPeak, bluePeak, "green's own peak should track its own channel value, distinct from blue")
    }

    func testDarkerInputProducesALowerBin() {
        let darkData = HistogramComputer.histogram(of: solidColorImage(0.02))
        let brightData = HistogramComputer.histogram(of: solidColorImage(0.9))

        let darkPeak = darkData.luminance.firstIndex(of: 1.0) ?? -1
        let brightPeak = brightData.luminance.firstIndex(of: 1.0) ?? -1

        XCTAssertGreaterThanOrEqual(darkPeak, 0)
        XCTAssertGreaterThanOrEqual(brightPeak, 0)
        XCTAssertLessThan(darkPeak, brightPeak)
    }

    func testAllValuesAreFiniteAndNormalized() {
        let data = HistogramComputer.histogram(of: solidColorImage(0.7))
        for bins in [data.luminance, data.red, data.green, data.blue] {
            for value in bins {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testMinorityRegionProportionIsResolutionIndependent() {
        // Pins the property IMPROVEMENTS.md P5's fix depends on: the
        // RELATIVE proportion of pixels across two distinct tonal regions
        // must be preserved whether the histogram is computed from a small
        // or a large version of the same scene — not just that a single
        // constant field trivially matches itself at any resolution (which
        // no resampling/distribution bias could ever break, since a solid
        // color resamples to itself under any interpolation). A 45:19
        // split (deliberately not 50/50) means the MINORITY region's own
        // normalized peak height directly reflects its area fraction
        // (`HistogramData`'s per-channel max-normalization preserves
        // RATIOS between bins even though it discards absolute counts), so
        // a resolution-dependent distribution bias would show up as a
        // shifted ratio here. The large fixture's split (1440:608) is an
        // exact ×32 scale of the small one's (45:19), so both should read
        // the same minority-peak height if resolution is truly independent.
        //
        // Previously unpinned: every existing fixture in this suite was
        // smaller than `HistogramComputer.sampleDimension` (256), so none
        // of them ever exercised a real downscale, only the upscale branch.
        let smallMajor = solidColorImage(0.2, size: 64).cropped(to: CGRect(x: 0, y: 0, width: 45, height: 64))
        let smallMinor = solidColorImage(0.8, size: 64).cropped(to: CGRect(x: 45, y: 0, width: 19, height: 64))
        let small = smallMajor.composited(over: smallMinor)

        let largeMajor = solidColorImage(0.2, size: 2048).cropped(to: CGRect(x: 0, y: 0, width: 1440, height: 2048))
        let largeMinor = solidColorImage(0.8, size: 2048).cropped(to: CGRect(x: 1440, y: 0, width: 608, height: 2048))
        let large = largeMajor.composited(over: largeMinor)

        let smallMinorHeight = secondTallestBin(HistogramComputer.histogram(of: small).luminance)
        let largeMinorHeight = secondTallestBin(HistogramComputer.histogram(of: large).luminance)

        XCTAssertNotNil(smallMinorHeight)
        XCTAssertNotNil(largeMinorHeight)
        XCTAssertEqual(Double(smallMinorHeight ?? -1), Double(largeMinorHeight ?? -2), accuracy: 0.06)
    }

    /// The tallest non-degenerate bin height BELOW the normalized maximum
    /// (1.0) — i.e. the minority region's own peak, in a two-region image.
    private func secondTallestBin(_ bins: [Float]) -> Float? {
        bins.filter { $0 > 0 && $0 < 0.999 }.max()
    }

    func testOffsetExtentDoesNotCrash() {
        // Mirrors EditPipeline's own cropped/offset-extent test pattern —
        // the histogram must handle an image whose extent doesn't start at
        // the origin (e.g. after a crop), not just the (0,0)-origin case.
        let cropped = solidColorImage(0.4, size: 100).cropped(to: CGRect(x: 10, y: 5, width: 40, height: 30))
        let data = HistogramComputer.histogram(of: cropped)

        for bins in [data.luminance, data.red, data.green, data.blue] {
            XCTAssertEqual(bins.count, HistogramComputer.binCount)
            XCTAssertEqual(bins.max(), 1.0)
        }
    }
}
