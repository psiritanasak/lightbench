import CoreImage

/// Computes a downsampled `ToneStatistics` summary of a `CIImage`, safe to
/// call from a background thread/queue — the sampling half of Auto Tone
/// (`AutoToneSolver`, `ImageDocumentModel.autoTone`).
///
/// Structurally mirrors `ImageAverageColor` (its own independent linear
/// RGBAf `CIContext`, downsample-before-analyze, alpha < 0.5 pixels excluded
/// as a transparent margin) but deliberately does NOT apply that type's own
/// min/max-luma exclusion — see `ToneStatistics.percentile0_5`'s own doc
/// comment for why.
enum ImageToneStatistics {
    /// Same target `ImageAverageColor`/`HistogramComputer` already validated
    /// this reasoning for — a coarse statistical summary needs no more.
    private static let sampleDimension = 256

    /// Rec. 709 luma weights, applied to LINEAR-light RGB — same weights,
    /// same domain as `ImageAverageColor`'s own gray-world mean.
    private static let lumaRed = 0.2126
    private static let lumaGreen = 0.7152
    private static let lumaBlue = 0.0722

    /// Reinhard log-average's epsilon, preventing `log(0)` for a
    /// pure-black qualifying pixel — the tone-mapping literature's own
    /// standard small offset, a principled starting constant, not
    /// independently measured against this app's own images.
    private static let kLogAverageEpsilon = 0.0001

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])

    /// Returns `nil` for a zero-extent image or one with no qualifying
    /// (opaque) pixels at all — mirrors `ImageAverageColor.compute`'s own
    /// contract.
    static func compute(of image: CIImage) -> ToneStatistics? {
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

        // One pass accumulates the log-average sum and the chroma sum, and
        // collects every qualifying luma for the percentile sort below —
        // mirrors `HistogramComputer`'s "read the bytes once, derive
        // everything from that one pass" shape.
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        var logLumaSum = 0.0
        var chromaSum = 0.0

        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let a = Double(buffer[offset + 3])
            // Same reasoning as `ImageAverageColor`/`PixelSampler`: a
            // mostly-transparent margin (e.g. revealed by straighten/
            // perspective) shouldn't skew the statistics.
            guard a >= 0.5 else { continue }

            // Reviewer-caught (Auto Tone planning session): `CIContext.
            // render(_:toBitmap:...)` returns PREMULTIPLIED RGBA — a
            // resample's edge row/column commonly lands at a fractional
            // alpha (still >= 0.5, so it passes the guard above), and its
            // RGB has been scaled down by that alpha. MEASURED: on a
            // uniform 0.18-gray bitmap-backed 3000x2000 image, one such
            // edge row alone was enough to pull `percentile0_5` down to
            // 0.134 — an entirely fabricated "lifted black" that would
            // have driven a real, wrong Auto Tone Black Point correction.
            // Dividing by alpha here (safe: `a >= 0.5` above rules out
            // division by zero) fixed it exactly (re-measured: 0.18).
            // `ImageAverageColor`/`PixelSampler` share this same latent
            // bug — out of scope to fix here (their own exclusion filters
            // mostly mask it for their different purposes) but logged in
            // IMPROVEMENTS.md.
            let r = Double(buffer[offset]) / a
            let g = Double(buffer[offset + 1]) / a
            let b = Double(buffer[offset + 2]) / a

            let luma = lumaRed * r + lumaGreen * g + lumaBlue * b
            lumas.append(luma)
            logLumaSum += log(kLogAverageEpsilon + max(0, luma))

            let pr = PerceptualEncoding.srgbEncode(r)
            let pg = PerceptualEncoding.srgbEncode(g)
            let pb = PerceptualEncoding.srgbEncode(b)
            chromaSum += max(pr, pg, pb) - min(pr, pg, pb)
        }

        guard !lumas.isEmpty else { return nil }
        lumas.sort()
        let count = lumas.count

        return ToneStatistics(
            percentile0_5: percentile(0.005, in: lumas),
            percentile5: percentile(0.05, in: lumas),
            percentile50: percentile(0.5, in: lumas),
            percentile95: percentile(0.95, in: lumas),
            percentile99_5: percentile(0.995, in: lumas),
            logAverageLuma: exp(logLumaSum / Double(count)),
            meanChroma: chromaSum / Double(count),
            qualifyingPixelCount: count
        )
    }

    /// Nearest-rank percentile of an already-SORTED array — a coarse
    /// statistical summary has no need for interpolated-rank precision.
    private static func percentile(_ fraction: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }
}
