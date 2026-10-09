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

    /// Linear luminance, largest channel and coverage of a top-down RGBAf bitmap whose colour is PREMULTIPLIED by alpha (a warped frame): both of the
    /// straight colour where alpha > 0, else 0, plus alpha as the validity. Used to measure a frame's real exposure gain on aligned proxies
    /// (`HDRGainRefinement`: luminance for the ratio, the largest channel for the merge's own well-exposedness weight).
    static func linearLumaAndValidity(rgbaFloat: [Float], width: Int, height: Int) -> (luma: [Float], peak: [Float], validity: [Float])? {
        guard rgbaFloat.count == width * height * 4 else { return nil }
        var luma = [Float](repeating: 0, count: width * height)
        var peak = luma, validity = luma
        for i in 0..<(width * height) {
            let a = rgbaFloat[i * 4 + 3]
            guard a > 0 else { continue }
            validity[i] = min(a, 1)
            let r = rgbaFloat[i * 4] / a, g = rgbaFloat[i * 4 + 1] / a, b = rgbaFloat[i * 4 + 2] / a
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            peak[i] = max(r, max(g, b))
        }
        return (luma, peak, validity)
    }

    /// Where the four corners of a `width x height` image go under `h` (a TOP-LEFT-coordinate homography), returned in Core Image's BOTTOM-LEFT
    /// coordinates: (topLeft, topRight, bottomLeft, bottomRight) of the source image.
    /// `outputHeight` is the height of the image the corners land in (default: the same as the source), needed to flip back to bottom-left.
    static func mappedCorners(_ h: simd_float3x3, width: Double, height: Double, outputHeight: Double? = nil)
        -> (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        let flipHeight = outputHeight ?? height
        func map(_ x: Double, _ yTop: Double) -> CGPoint {
            let q = FeatureMatcher.apply(h, to: SIMD2(Float(x), Float(yTop)))
            return CGPoint(x: CGFloat(q.x), y: CGFloat(flipHeight) - CGFloat(q.y)) // back to bottom-left
        }
        return (map(0, 0), map(width, 0), map(0, height), map(width, height))
    }

    /// `image` warped by the TOP-LEFT homography `h` (target -> reference pixels), expressed on `extent`: transparent wherever the warped frame does
    /// not reach, which is what `HDRMergeFilter` reads as "no data". `image.extent` and `extent` must have their origin at (0, 0); `extent` may be larger than
    /// the image (a panorama canvas), in which case `h` maps into that canvas's top-left coordinates.
    static func warped(_ image: CIImage, by h: simd_float3x3, extent: CGRect) -> CIImage? {
        let corners = mappedCorners(h, width: Double(image.extent.width), height: Double(image.extent.height), outputHeight: Double(extent.height))
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = corners.topLeft
        filter.topRight = corners.topRight
        filter.bottomLeft = corners.bottomLeft
        filter.bottomRight = corners.bottomRight
        return filter.outputImage?.cropped(to: extent)
    }
}
