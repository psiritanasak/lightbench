import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// Alignment helpers for Photo Merge: turn a rendered proxy into the grayscale buffer `FeatureMatcher` wants, and warp a full-resolution frame by
/// the homography it found. Pure maths is separated (`lumaProxy`, `mappedCorners`) so it is testable without a GPU.
enum MergeAlignment {
    /// Gamma-encoded luminance (0...1) of a top-down RGBAf bitmap (`width x height`, linear, extended range), after multiplying by `exposureFactor`
    /// and clipping at 1 — "brighten the darker frame to the brighter one's exposure" (docs/ROADMAP_HISTORY.md, Photo Merge spike: registering raw
    /// bracket frames fails at +/-1..3 EV, registering exposure-matched ones recovers the shift). Encoded, not linear, because the matcher's Harris
    /// floor is absolute.
    static func lumaProxy(rgbaFloat: [Float], width: Int, height: Int, exposureFactor: Float) -> FeatureMatcher.GrayImage? {
        guard rgbaFloat.count == width * height * 4 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let luma = 0.2126 * rgbaFloat[i * 4] + 0.7152 * rgbaFloat[i * 4 + 1] + 0.0722 * rgbaFloat[i * 4 + 2]
            let value = luma.isFinite ? min(max(luma * exposureFactor, 0), 1) : 0
            pixels[i] = HDRMergeMath.srgbEncode(value)
        }
        return FeatureMatcher.GrayImage(width: width, height: height, pixels: pixels)
    }

    /// Where the four corners of a `width x height` image go under `h` (a TOP-LEFT-coordinate homography), returned in Core Image's BOTTOM-LEFT
    /// coordinates: (topLeft, topRight, bottomLeft, bottomRight) of the source image.
    static func mappedCorners(_ h: simd_float3x3, width: Double, height: Double)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        func map(_ x: Double, _ yTop: Double) -> CGPoint {
            let q = FeatureMatcher.apply(h, to: SIMD2(Float(x), Float(yTop)))
            return CGPoint(x: CGFloat(q.x), y: CGFloat(height) - CGFloat(q.y)) // back to bottom-left
        }
        return (map(0, 0), map(width, 0), map(0, height), map(width, height))
    }

    /// `image` warped by the TOP-LEFT homography `h` (target -> reference pixels), expressed on `extent`: transparent wherever the warped frame does
    /// not reach, which is what `HDRMergeFilter` reads as "no data". `image.extent` must have its origin at (0, 0).
    static func warped(_ image: CIImage, by h: simd_float3x3, extent: CGRect) -> CIImage? {
        let corners = mappedCorners(h, width: Double(image.extent.width), height: Double(image.extent.height))
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = corners.topLeft
        filter.topRight = corners.topRight
        filter.bottomLeft = corners.bottomLeft
        filter.bottomRight = corners.bottomRight
        return filter.outputImage?.cropped(to: extent)
    }
}
