import ImageIO
import CoreImage
import Foundation

/// Pure, stateless thumbnail decoding — no UI, no `CIContext`. Unlike the
/// `PixelSampler`/`ImageAverageColor`/`Histogram` family (which build a
/// `CIImage` for numeric analysis), a library grid just needs a small,
/// already-oriented bitmap to display, so ImageIO's own thumbnail API is a
/// better fit: it decodes straight to a downsized `CGImage` without ever
/// materializing the full-resolution image, and applies EXIF orientation
/// for us (`kCGImageSourceCreateThumbnailWithTransform`), unlike
/// `ImageDocumentModel.load(from:)`'s `CIImage(contentsOf:).oriented(...)`
/// path which has to do that step itself.
enum ThumbnailGenerator {
    /// Returns a thumbnail for the image at `url`, no larger than
    /// `maxPixelSize` on its longest side, or `nil` if `url` isn't a
    /// readable image (missing, unreadable, unsupported format). Safe to
    /// call off the main thread — does no UI work.
    static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `EditPipeline`'s filter math (WB, exposure, tone, curves, etc.) is
    /// only correct in the app's own defined scene-linear working space —
    /// this must match `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver`
    /// exactly, not the context's own default. (Reviewer-caught: an
    /// earlier draft of this context used `CIContext()` with no options at
    /// all, reasoning it was "like `HistogramComputer`" — wrong precedent,
    /// since `HistogramComputer` deliberately renders already-computed
    /// DISPLAY-sRGB pixels and never runs `EditPipeline` itself, whereas
    /// this DOES run the full pipeline. `WhiteBalanceSolver` — which also
    /// runs pipeline color math off-main in a small plain `CIContext` — is
    /// the correct precedent, and is what this now matches.)
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: workingColorSpace,
        .workingFormat: CIFormat.RGBAh
    ])
    /// Explicitly tagged, not left to the context's default — applying the
    /// lesson from the Editor-vs-Preview color-space fix (an untagged
    /// render surface can be mis-presented) rather than leaving this
    /// implicit a second time.
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Same as `thumbnail(for:maxPixelSize:)`, but runs `editState` through
    /// `EditPipeline` first so the Library grid reflects the photo's actual
    /// saved edits instead of always showing the original. `editState ==
    /// .identity` (the common case for an unedited photo) takes a fast
    /// path — returns the plain ImageIO thumbnail unchanged, paying zero
    /// extra decode/render cost. Runs the pipeline on the ALREADY-SMALL,
    /// already-EXIF-oriented base thumbnail (not a second full-res decode)
    /// — correct because every pipeline stage that depends on image size
    /// (crop, straighten, vignette/sharpen radius, etc.) already derives
    /// its geometry from the image's own current extent, so it scales
    /// proportionally rather than needing a fixed absolute resolution.
    static func thumbnail(for url: URL, maxPixelSize: Int, editState: EditState) -> CGImage? {
        guard let base = thumbnail(for: url, maxPixelSize: maxPixelSize) else { return nil }
        guard editState != .identity else { return base }
        let edited = EditPipeline.apply(editState, to: CIImage(cgImage: base))
        return context.createCGImage(edited, from: edited.extent, format: .RGBA8, colorSpace: outputColorSpace)
    }
}
