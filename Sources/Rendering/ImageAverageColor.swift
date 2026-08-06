import CoreImage

/// Computes a downsampled gray-world average color of a `CIImage`, safe to
/// call from a background thread/queue — the sampling half of "Cast" color-
/// cast neutralization (see `ImageDocumentModel.fixColorCast`).
///
/// Structurally mirrors `HistogramComputer` (its own independent, non-Metal
/// `CIContext`, downsample-before-analyze) but computes a MEAN in
/// SCENE-LINEAR light, not a histogram in display space — the domain
/// `WhiteBalanceSolver`/`PixelSampler` already use, since the average feeds
/// directly into `WhiteBalanceSolver.solve(sampleLinearRGB:)`.
enum ImageAverageColor {
    /// Downsample target — MEASURED to give an average IDENTICAL (not just
    /// close) to a full-resolution computation on a real test scene, at a
    /// fraction of the cost. Reuses the same target `HistogramComputer`
    /// already validated this same reasoning for.
    private static let sampleDimension = 256

    /// Luma range a pixel must fall within to count toward the average —
    /// MEASURED necessity, not a nicety: on a test scene with a blown-out
    /// quadrant, an unclipped mean was measurably pulled away from the
    /// scene's true base tone ((0.625,0.610,0.587) vs the correct
    /// (0.5,0.48,0.45)) and solved a meaningfully different (250K off)
    /// correction; excluding near-black/near-white pixels recovered the
    /// true base tone almost exactly. Real photos commonly have blown skies/
    /// light sources or crushed shadows that would otherwise bias a naive
    /// whole-image mean the same way.
    ///
    /// These bounds are LINEAR-light values, not perceptual/gamma percentiles
    /// — 0.05 linear is already a fairly bright shadow (~27% gray in gamma
    /// terms), so the shadow-side cut is more aggressive than the "crushed
    /// shadows" framing above might suggest. Intentional: this matches the
    /// scene-linear domain the rest of this computation (and
    /// `WhiteBalanceSolver`) already works in, not a separate perceptual pass.
    private static let minLuma: Double = 0.05
    private static let maxLuma: Double = 0.95

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    /// Returns the gray-world average color of `image` in linear light, or
    /// `nil` for a zero-extent image or one with no qualifying (opaque,
    /// mid-luma) pixels at all.
    static func compute(of image: CIImage) -> (r: Double, g: Double, b: Double)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        let scale = Double(sampleDimension) / Double(max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let width = max(1, Int(scaledExtent.width.rounded()))
        let height = max(1, Int(scaledExtent.height.rounded()))

        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(
            scaled, toBitmap: &buffer, rowBytes: width * 16,
            bounds: CGRect(x: scaledExtent.minX, y: scaledExtent.minY, width: CGFloat(width), height: CGFloat(height)),
            format: .RGBAf, colorSpace: linearSpace
        )

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let r = Double(buffer[offset])
            let g = Double(buffer[offset + 1])
            let b = Double(buffer[offset + 2])
            let a = Double(buffer[offset + 3])
            // Same reasoning as PixelSampler: a mostly-transparent margin
            // (e.g. revealed by straighten/perspective) shouldn't dilute
            // the average with meaningless transparent content.
            guard a >= 0.5 else { continue }

            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard luma > minLuma, luma < maxLuma else { continue }

            sumR += r
            sumG += g
            sumB += b
            count += 1
        }
        guard count > 0 else { return nil }
        return (sumR / Double(count), sumG / Double(count), sumB / Double(count))
    }
}
