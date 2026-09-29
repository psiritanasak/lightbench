import XCTest
import CoreImage
@testable import PhotoApp

final class PixelSamplerTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func solidColorImage(r: Double, g: Double, b: Double, a: Double = 1, size: Int = 64) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// A REAL bitmap-backed image (not a constant-color generator) — same
    /// discipline `ImageToneStatisticsTests.bitmapGrayImage`'s own doc
    /// comment documents: a constant generator can be folded through
    /// rendering WITHOUT ever rasterizing a real premultiply/unpremultiply
    /// round trip, so it can't exercise D25's bug at all. Takes the
    /// intended STRAIGHT (r, g, b, a) but stores PREMULTIPLIED bytes
    /// (`r*a`, `g*a`, `b*a`, `a`) — empirically verified (a throwaway
    /// probe, not assumed): `CIImage(bitmapData:...)` round-trips its raw
    /// buffer through `CIContext.render(_:toBitmap:...)` UNCHANGED, with no
    /// premultiply/unpremultiply conversion of its own, so feeding it
    /// straight values here would silently test something other than the
    /// premultiplied-source scenario this fixture needs to exercise (a real
    /// premultiplied `CGImageAlphaInfo.premultipliedLast` source, matching
    /// what `render(_:toBitmap:...)` itself always returns, regardless of
    /// the source's own representation).
    private func bitmapColorImage(r: Double, g: Double, b: Double, a: Double, size: Int = 64) -> CIImage {
        var data = [Float](repeating: 0, count: size * size * 4)
        for pixelIndex in 0..<(size * size) {
            let offset = pixelIndex * 4
            data[offset] = Float(r * a)
            data[offset + 1] = Float(g * a)
            data[offset + 2] = Float(b * a)
            data[offset + 3] = Float(a)
        }
        let cfData = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: cfData, bytesPerRow: size * 16,
            size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: linearSpace
        )
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

    /// D25: `CIContext.render(_:toBitmap:...)` returns PREMULTIPLIED RGBA —
    /// `averageColor(in:at:radius:minAlpha:)` read R/G/B directly, with only
    /// an alpha-threshold guard, never dividing by alpha first. A pixel
    /// with fractional alpha still at/above `minAlpha` had its RGB scaled
    /// down by that alpha, biasing the sample. Straight color
    /// (0.6, 0.3, 0.1) at alpha 0.5 premultiplies to (0.3, 0.15, 0.05, 0.5)
    /// — exactly at the default `minAlpha` threshold, so this still
    /// qualifies pre- and post-fix; only the recovered color differs.
    /// Pre-fix, this would have read back the halved (0.3, 0.15, 0.05)
    /// premultiplied triple instead.
    func testPremultipliedAlphaDoesNotBiasTheSample() {
        let image = bitmapColorImage(r: 0.6, g: 0.3, b: 0.1, a: 0.5)
        let sample = PixelSampler.averageColor(in: image, at: CGPoint(x: 32, y: 32))

        XCTAssertEqual(sample?.r ?? -1, 0.6, accuracy: 0.005)
        XCTAssertEqual(sample?.g ?? -1, 0.3, accuracy: 0.005)
        XCTAssertEqual(sample?.b ?? -1, 0.1, accuracy: 0.005)
    }
}
