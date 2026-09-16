import CoreImage

/// The four histograms `HistogramComputer.histogram(of:)` produces in one
/// pass — luminance plus the three color channels it's derived from. All
/// four arrays share `HistogramComputer.binCount` length and are each
/// independently normalized to their OWN tallest bin = 1.0 (matching the
/// luminance histogram's original convention) — so, deliberately, relative
/// magnitudes are NOT comparable across channels (a channel with few
/// qualifying pixels still shows its full shape, not a nearly-flat line).
struct HistogramData {
    let luminance: [Float]
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    /// "No histogram to show" — all four arrays empty. Callers should treat
    /// this as distinct from a full-zero histogram (which can't actually
    /// occur — see `histogram(of:)`'s zero-count guard).
    static let empty = HistogramData(luminance: [], red: [], green: [], blue: [])
}

/// Computes a downsampled luminance + per-channel RGB histogram of a
/// `CIImage`, safe to call from a background thread/queue.
///
/// Deliberately NOT `ImageRenderer`'s `@MainActor`/Metal-drawable-bound
/// `CIContext` — that one exists to draw into a live on-screen `MTKView` and
/// is only ever touched from MetalKit's main-thread delegate callbacks. This
/// is a separate, plain `CIContext` whose only job is an off-screen render
/// for statistics, so it can run off the main thread (`CIContext` is safe
/// for concurrent use across threads — Apple's own documented contract).
enum HistogramComputer {
    /// Number of buckets per channel — the conventional 0...255 8-bit
    /// display range every real photo editor's histogram uses.
    static let binCount = 256

    /// Downsample target for the image's long side before bucketing. A
    /// histogram is a coarse statistical summary, not a per-pixel readout —
    /// rendering at full photo resolution for this would be wasted work
    /// with no visual benefit, and would make the debounced background
    /// recompute (see `ImageDocumentModel`) noticeably slower on large photos.
    /// Not `private`: `HistogramComputerTests` reads this directly (via
    /// `@testable import`) to size its own resolution-independence fixtures
    /// relative to this exact target, rather than duplicating the literal.
    static let sampleDimension = 256

    /// Downscale factor for a caller (`ImageDocumentModel.recomputeHistogram()`,
    /// IMPROVEMENTS.md P5) to apply to its OWN source image BEFORE running
    /// `EditPipeline.apply`, so convolution-backed stages (Sharpen/Noise
    /// Reduction/Clarity/Texture) never execute at full source resolution just to
    /// feed this type's own 256px downsample. Pure and unit-tested, matching
    /// this codebase's established pattern for exactly this shape of
    /// geometry (`ProxyScale`, `AspectFit`, `ZoomPanGeometry`).
    ///
    /// `size` must be the DISPLAYED extent — i.e. `EditPipeline.apply(state,
    /// to: source).extent.size`, taken AFTER geometry stages (crop,
    /// straighten, perspective) have already run, not the source's own raw
    /// extent. Sizing against the pre-pipeline extent would size the
    /// downscale wrong for any cropped photo: a crop can shrink the
    /// displayed extent to as little as ~10% per side
    /// (`EditPipeline`'s own `kMaxCropInset`), so a headroom computed
    /// against the UNCROPPED source could still hand this type's own
    /// downsample a near-1:1 (or even smaller-than-target) input — exactly
    /// the degenerate case the headroom exists to prevent.
    ///
    /// Headroom is `2x sampleDimension`, not exactly `sampleDimension`, so
    /// this type's own downsample-to-256 step (above) stays a real, if
    /// smaller, resize rather than a degenerate no-op. `min(1, ...)` never
    /// upscales an image already smaller than the target — the same
    /// invariant `ProxyScale.requiredScale`/`RawDecoder.decodeDraft`'s own
    /// `scaleFactor = min(1, Float(CGFloat(maxPixelSize) / longestSide))`
    /// both hold elsewhere. Returns `1` (no-op) on any degenerate input.
    static func inputDownscale(forDisplayedSize size: CGSize) -> CGFloat {
        // `.isFinite` alone does NOT catch `CGRect.infinite`'s width/height
        // (`CGFloat.greatestFiniteMagnitude` — finite by IEEE semantics) —
        // the same trap `RawDecoder.materialize`/`ProxyBuilder.build` both
        // guard against with this identical upper bound. Unreachable from
        // `recomputeHistogram`'s real caller today (a loaded photo's extent
        // is never that large), kept for consistency with those two.
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width < CGFloat(Int32.max), size.height < CGFloat(Int32.max)
        else {
            return 1
        }
        let longSide = max(size.width, size.height)
        return min(1, CGFloat(sampleDimension * 2) / longSide)
    }

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

    /// Returns luminance + per-channel R/G/B histograms, each `binCount`
    /// values normalized 0...1 relative to THEIR OWN tallest bin (see
    /// `HistogramData`'s doc comment). Empty input (zero-size extent)
    /// returns `.empty` — callers should treat that as "no histogram to
    /// show," not a full-zero histogram.
    static func histogram(of image: CIImage) -> HistogramData {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return .empty
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

        // One pass over the buffer accumulates all four histograms — the
        // R/G/B bytes are already being read to derive luminance, so binning
        // them too is free. Unlike luminance (a Rec.709-weighted sum needing
        // a bin computation), each channel's raw 8-bit byte value already
        // IS its own bin index (0...255), no extra math needed.
        var luminanceCounts = [Int](repeating: 0, count: binCount)
        var redCounts = [Int](repeating: 0, count: binCount)
        var greenCounts = [Int](repeating: 0, count: binCount)
        var blueCounts = [Int](repeating: 0, count: binCount)
        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let r = buffer[offset]
            let g = buffer[offset + 1]
            let b = buffer[offset + 2]
            let luminance = lumaRed * Float(r) + lumaGreen * Float(g) + lumaBlue * Float(b)
            let luminanceBin = min(binCount - 1, max(0, Int(luminance)))
            luminanceCounts[luminanceBin] += 1
            redCounts[Int(r)] += 1
            greenCounts[Int(g)] += 1
            blueCounts[Int(b)] += 1
        }

        return HistogramData(
            luminance: normalized(luminanceCounts),
            red: normalized(redCounts),
            green: normalized(greenCounts),
            blue: normalized(blueCounts)
        )
    }

    /// Scales `counts` so its own tallest bin becomes 1.0 — see
    /// `HistogramData`'s doc comment on why each channel is normalized
    /// independently rather than sharing one global scale.
    private static func normalized(_ counts: [Int]) -> [Float] {
        guard let maxCount = counts.max(), maxCount > 0 else {
            return [Float](repeating: 0, count: binCount)
        }
        return counts.map { Float($0) / Float(maxCount) }
    }
}
