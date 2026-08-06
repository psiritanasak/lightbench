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
