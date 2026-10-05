import CoreImage

/// Averages a small neighborhood of pixels around a point in a `CIImage`,
/// in the image's own linear working space. Used by the WB eyedropper to
/// get a noise-robust sample rather than trusting a single pixel (real
/// camera images have sensor noise/compression artifacts a single pixel
/// would be vulnerable to).
///
/// Its own small independent `CIContext` — same "non-Metal, safe off the
/// main thread" precedent `HistogramComputer` already established, not
/// `ImageRenderer`'s `@MainActor`/Metal-drawable-bound one.
enum PixelSampler {
    /// Falls back to device RGB if the named space is ever unavailable —
    /// same defensive pattern as `HistogramComputer.displayColorSpace`, not
    /// a force-unwrap.
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    /// The ALPHA at the pixel containing `point` (image coordinates), 0 outside the extent. For mask images, whose
    /// RGB equals alpha, this is the mask's coverage there.
    static func coverage(of image: CIImage, at point: CGPoint) -> Double {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return 0 }
        // `CGRect.contains` excludes maxX/maxY, so a click on the very last row/column (normalized 1.0 / 0.0 after the
        // y-flip) would miss; clamp a point on the extent's far edge onto its last pixel.
        guard point.x >= extent.minX, point.y >= extent.minY, point.x <= extent.maxX, point.y <= extent.maxY else { return 0 }
        let point = CGPoint(x: min(point.x, extent.maxX - 0.5), y: min(point.y, extent.maxY - 0.5))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        return Double(pixel[3])
    }

    /// Averages a `(2*radius+1)`-pixel-per-side box centered at `point` in
    /// `image`'s own coordinate space, clamped to `image.extent`. Only
    /// pixels with alpha at/above `minAlpha` are included, so a sample box
    /// that partly overlaps a transparent margin (e.g. a corner a
    /// straighten/perspective transform revealed) isn't diluted by
    /// meaningless transparent content. Returns `nil` if the box has no
    /// area, or every covered pixel is below the alpha threshold.
    static func averageColor(
        in image: CIImage, at point: CGPoint, radius: Int = 2, minAlpha: Float = 0.5
    ) -> (r: Double, g: Double, b: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let minX = max(extent.minX, point.x - CGFloat(radius))
        let minY = max(extent.minY, point.y - CGFloat(radius))
        let maxX = min(extent.maxX, point.x + CGFloat(radius) + 1)
        let maxY = min(extent.maxY, point.y + CGFloat(radius) + 1)
        let width = Int((maxX - minX).rounded(.down))
        let height = Int((maxY - minY).rounded(.down))
        guard width > 0, height > 0 else { return nil }

        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &buffer, rowBytes: width * 16,
            bounds: CGRect(x: minX, y: minY, width: CGFloat(width), height: CGFloat(height)),
            format: .RGBAf, colorSpace: linearSpace
        )

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let a = Double(buffer[offset + 3])
            // `a > 0` guards the divide below against a future caller
            // passing `minAlpha <= 0` — no current call site does (all 3
            // real callers use the default 0.5), but `minAlpha` is a public
            // parameter, and 0/0 would produce a NaN that could reach
            // `WhiteBalanceSolver` or a persisted Color Range/Point Color
            // target, silently failing every later sidecar write.
            guard a > 0, Float(a) >= minAlpha else { continue }
            // `CIContext.render(_:toBitmap:...)` returns PREMULTIPLIED
            // RGBA — divide by alpha before using color values (D25; same
            // fix as `ImageAverageColor.compute`/`ImageToneStatistics`).
            sumR += Double(buffer[offset]) / a
            sumG += Double(buffer[offset + 1]) / a
            sumB += Double(buffer[offset + 2]) / a
            count += 1
        }
        guard count > 0 else { return nil }
        return (sumR / Double(count), sumG / Double(count), sumB / Double(count))
    }
}
