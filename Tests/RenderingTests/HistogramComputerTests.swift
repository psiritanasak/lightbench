import XCTest
import CoreImage
@testable import PhotoApp

final class HistogramComputerTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(_ value: Double, size: Int = 64) -> CIImage {
        let color = CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    func testEmptyExtentReturnsEmptyHistogram() {
        let bins = HistogramComputer.histogram(of: CIImage.empty())
        XCTAssertTrue(bins.isEmpty)
    }

    func testSolidImageProducesASingleTallBin() {
        // A perfectly flat image should concentrate almost every sample
        // into one bin (small AA/downsample edge effects aside).
        let bins = HistogramComputer.histogram(of: solidColorImage(0.5))

        XCTAssertEqual(bins.count, HistogramComputer.binCount)
        let tallBins = bins.filter { $0 > 0 }
        XCTAssertLessThanOrEqual(tallBins.count, 3, "a flat image should collapse into a small handful of adjacent bins")
        XCTAssertEqual(bins.max(), 1.0, "the tallest bin is always normalized to 1.0")
    }

    func testDarkerInputProducesALowerBin() {
        // Bucket index should track perceived brightness: a near-black
        // image's peak bin should sit well below a near-white image's.
        let darkBins = HistogramComputer.histogram(of: solidColorImage(0.02))
        let brightBins = HistogramComputer.histogram(of: solidColorImage(0.9))

        let darkPeak = darkBins.firstIndex(of: 1.0) ?? -1
        let brightPeak = brightBins.firstIndex(of: 1.0) ?? -1

        XCTAssertGreaterThanOrEqual(darkPeak, 0)
        XCTAssertGreaterThanOrEqual(brightPeak, 0)
        XCTAssertLessThan(darkPeak, brightPeak)
    }

    func testAllValuesAreFiniteAndNormalized() {
        let bins = HistogramComputer.histogram(of: solidColorImage(0.7))
        for value in bins {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    func testOffsetExtentDoesNotCrash() {
        // Mirrors EditPipeline's own cropped/offset-extent test pattern —
        // the histogram must handle an image whose extent doesn't start at
        // the origin (e.g. after a crop), not just the (0,0)-origin case.
        let cropped = solidColorImage(0.4, size: 100).cropped(to: CGRect(x: 10, y: 5, width: 40, height: 30))
        let bins = HistogramComputer.histogram(of: cropped)

        XCTAssertEqual(bins.count, HistogramComputer.binCount)
        XCTAssertEqual(bins.max(), 1.0)
    }
}
