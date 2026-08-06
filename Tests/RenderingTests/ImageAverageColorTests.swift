import XCTest
import CoreImage
@testable import PhotoApp

/// Mirrors `HistogramComputerTests`'/`PixelSamplerTests`' style — see
/// `ImageAverageColor` for what this is used for (the sampling half of Cast
/// color-cast neutralization).
final class ImageAverageColorTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double = 1, size: Int = 64) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    func testSolidImageAveragesToItsOwnColor() {
        let image = solidColorImage(r: 0.6, g: 0.3, b: 0.4)
        let average = ImageAverageColor.compute(of: image)

        XCTAssertEqual(average?.r ?? -1, 0.6, accuracy: 0.005)
        XCTAssertEqual(average?.g ?? -1, 0.3, accuracy: 0.005)
        XCTAssertEqual(average?.b ?? -1, 0.4, accuracy: 0.005)
    }

    func testTwoRegionImageAveragesToTheWeightedMean() {
        // Left half and right half, equal area, both within the mid-luma
        // range so both contribute — expected result is the simple mean.
        let left = solidColorImage(r: 0.6, g: 0.2, b: 0.4, size: 64).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let right = solidColorImage(r: 0.2, g: 0.6, b: 0.8, size: 64).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = left.composited(over: right)

        let average = ImageAverageColor.compute(of: image)

        XCTAssertEqual(average?.r ?? -1, 0.4, accuracy: 0.01)
        XCTAssertEqual(average?.g ?? -1, 0.4, accuracy: 0.01)
        XCTAssertEqual(average?.b ?? -1, 0.6, accuracy: 0.01)
    }

    func testAlphaExcludedPixelsDoNotDiluteTheAverage() {
        // Mirrors PixelSamplerTests's own transparent-region case: a
        // partially transparent image should read as just its opaque
        // portion's color, not a value diluted toward zero.
        let opaqueColor = CIColor(red: 0.6, green: 0.2, blue: 0.4, alpha: 1, colorSpace: linearSpace)!
        let transparentColor = CIColor(red: 0.6, green: 0.2, blue: 0.4, alpha: 0, colorSpace: linearSpace)!
        let opaqueHalf = CIImage(color: opaqueColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let transparentHalf = CIImage(color: transparentColor).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = opaqueHalf.composited(over: transparentHalf)

        let average = ImageAverageColor.compute(of: image)

        XCTAssertEqual(average?.r ?? -1, 0.6, accuracy: 0.01)
        XCTAssertEqual(average?.g ?? -1, 0.2, accuracy: 0.01)
        XCTAssertEqual(average?.b ?? -1, 0.4, accuracy: 0.01)
    }

    func testBlownOutOutlierRegionDoesNotSkewTheAverage() {
        // A base tone plus a small near-white outlier patch: the outlier
        // should be excluded (luma clipping), so the average should still
        // read close to the base tone rather than being pulled toward white.
        let base = solidColorImage(r: 0.5, g: 0.48, b: 0.45, size: 64).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64))
        let blownOut = solidColorImage(r: 0.99, g: 0.99, b: 0.99, size: 64).cropped(to: CGRect(x: 48, y: 0, width: 16, height: 64))
        let image = base.composited(over: blownOut)

        let average = ImageAverageColor.compute(of: image)

        XCTAssertEqual(average?.r ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(average?.g ?? -1, 0.48, accuracy: 0.01)
        XCTAssertEqual(average?.b ?? -1, 0.45, accuracy: 0.01)
    }

    func testZeroExtentImageReturnsNil() {
        let average = ImageAverageColor.compute(of: CIImage.empty())
        XCTAssertNil(average)
    }

    func testOffsetExtentDoesNotCrash() {
        // Mirrors HistogramComputerTests's/PixelSamplerTests's own
        // offset-extent case — must handle an image whose extent doesn't
        // start at the origin (e.g. after a crop).
        let cropped = solidColorImage(r: 0.4, g: 0.4, b: 0.4, size: 100).cropped(to: CGRect(x: 10, y: 5, width: 40, height: 30))
        let average = ImageAverageColor.compute(of: cropped)

        XCTAssertEqual(average?.r ?? -1, 0.4, accuracy: 0.01)
    }
}
