import XCTest
import CoreImage
@testable import PhotoApp

final class PixelSamplerTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double = 1, size: Int = 64) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    func testSolidImageAveragesToItsOwnColor() {
        let image = solidColorImage(r: 0.6, g: 0.3, b: 0.1)
        let sample = PixelSampler.averageColor(in: image, at: CGPoint(x: 32, y: 32))

        XCTAssertEqual(sample?.r ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(sample?.g ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(sample?.b ?? -1, 0.1, accuracy: 0.001)
    }

    func testSampleNearTheExtentEdgeClampsRatherThanCrashing() {
        let image = solidColorImage(r: 0.5, g: 0.5, b: 0.5, size: 10)
        let sample = PixelSampler.averageColor(in: image, at: CGPoint(x: 0, y: 0))

        XCTAssertEqual(sample?.r ?? -1, 0.5, accuracy: 0.001)
    }

    func testFullyTransparentRegionReturnsNil() {
        let image = solidColorImage(r: 0.5, g: 0.5, b: 0.5, a: 0)
        let sample = PixelSampler.averageColor(in: image, at: CGPoint(x: 32, y: 32))

        XCTAssertNil(sample)
    }

    func testZeroExtentImageReturnsNil() {
        let sample = PixelSampler.averageColor(in: CIImage.empty(), at: CGPoint(x: 0, y: 0))
        XCTAssertNil(sample)
    }

    func testPartiallyTransparentRegionExcludesTransparentPixels() {
        // Left half opaque red, right half fully transparent. Sampling
        // centered well inside the opaque half should read pure red, not a
        // value diluted toward zero by the transparent side.
        let opaqueColor = CIColor(red: 1, green: 0, blue: 0, alpha: 1, colorSpace: linearSpace)!
        let transparentColor = CIColor(red: 1, green: 0, blue: 0, alpha: 0, colorSpace: linearSpace)!
        let opaqueHalf = CIImage(color: opaqueColor).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let transparentHalf = CIImage(color: transparentColor).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = opaqueHalf.composited(over: transparentHalf)

        let sample = PixelSampler.averageColor(in: image, at: CGPoint(x: 5, y: 32))

        XCTAssertEqual(sample?.r ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample?.g ?? -1, 0.0, accuracy: 0.001)
    }

    func testOffsetExtentDoesNotCrash() {
        // Mirrors HistogramComputerTests's own offset-extent case — must
        // handle an image whose extent doesn't start at the origin.
        let cropped = solidColorImage(r: 0.4, g: 0.4, b: 0.4, size: 100).cropped(to: CGRect(x: 10, y: 5, width: 40, height: 30))
        let sample = PixelSampler.averageColor(in: cropped, at: CGPoint(x: 25, y: 20))

        XCTAssertEqual(sample?.r ?? -1, 0.4, accuracy: 0.001)
    }
}
