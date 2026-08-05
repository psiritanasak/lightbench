import CoreImage

/// Computes a downsampled luminance histogram of a `CIImage`, safe to call
/// from a background thread/queue.
///
/// Deliberately NOT `ImageRenderer`'s `@MainActor`/Metal-drawable-bound
/// `CIContext` — that one exists to draw into a live on-screen `MTKView` and
/// is only ever touched from MetalKit's main-thread delegate callbacks. This
/// is a separate, plain `CIContext` whose only job is an off-screen render
/// for statistics, so it can run off the main thread (`CIContext` is safe
/// for concurrent use across threads — Apple's own documented contract).
enum HistogramComputer {
    /// Number of luminance buckets — the conventional 0...255 8-bit display
    /// range every real photo editor's histogram uses.
    static let binCount = 256

    /// Downsample target for the image's long side before bucketing. A
    /// histogram is a coarse statistical summary, not a per-pixel readout —
    /// rendering at full photo resolution for this would be wasted work
    /// with no visual benefit, and would make the debounced background
    /// recompute (see `ImageDocumentModel`) noticeably slower on large photos.
    private static let sampleDimension = 256

    /// Rendered in DISPLAY sRGB, NOT this app's scene-linear editing working
    /// space — a histogram conventionally represents the tonal distribution
    /// a VIEWER actually sees, matching every real photo editor and matching
    /// `ImageRenderer`'s own final `outputColorSpace` choice for on-screen
    /// display.
    private static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let context = CIContext(options: [.workingColorSpace: displayColorSpace])

    /// Rec. 709 luma weights, applied to 8-bit DISPLAY-encoded RGB (the
    /// conventional histogram definition — not scene-linear luminance).
    private static let lumaRed: Float = 0.2126
    private static let lumaGreen: Float = 0.7152
    private static let lumaBlue: Float = 0.0722

    /// Returns `binCount` values, normalized 0...1 relative to the tallest
    /// bin, one per luminance bucket. Empty input (zero-size extent) returns
    /// an empty array — callers should treat that as "no histogram to show,"
    /// not a full-zero histogram.
    static func histogram(of image: CIImage) -> [Float] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return []
        }

        let scale = Double(sampleDimension) / Double(max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let width = max(1, Int(scaledExtent.width.rounded()))
        let height = max(1, Int(scaledExtent.height.rounded()))

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled,
            toBitmap: &buffer,
            rowBytes: width * 4,
            bounds: CGRect(x: scaledExtent.minX, y: scaledExtent.minY, width: CGFloat(width), height: CGFloat(height)),
            format: .RGBA8,
            colorSpace: displayColorSpace
        )

        var counts = [Int](repeating: 0, count: binCount)
        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let r = Float(buffer[offset])
            let g = Float(buffer[offset + 1])
            let b = Float(buffer[offset + 2])
            let luminance = lumaRed * r + lumaGreen * g + lumaBlue * b
            let bin = min(binCount - 1, max(0, Int(luminance)))
            counts[bin] += 1
        }

        guard let maxCount = counts.max(), maxCount > 0 else {
            return [Float](repeating: 0, count: binCount)
        }
        return counts.map { Float($0) / Float(maxCount) }
    }
}
