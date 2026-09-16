import ImageIO
import CoreImage
import Foundation

/// Thumbnail decoding for the Library grid. Non-RAW files go through
/// ImageIO's own thumbnail API — it decodes straight to a downsized
/// `CGImage` without ever materializing the full-resolution image, and
/// applies EXIF orientation for us (`kCGImageSourceCreateThumbnailWithTransform`),
/// unlike `RawDecoder.decode(contentsOf:)`'s `CIImage(contentsOf:).oriented(...)`
/// path which has to do that step itself. RAW files can't use that API for
/// anything but the camera's own embedded JPEG preview (see
/// `rawDecodedThumbnail` below), so they go through `CIContext`/`CIRAWFilter`
/// instead — this type
/// isn't the ImageIO-only helper its original doc comment claimed once that
/// became true.
enum ThumbnailGenerator {
    /// Returns a thumbnail for the image at `url`, no larger than
    /// `maxPixelSize` on its longest side, or `nil` if `url` isn't a
    /// readable image (missing, unreadable, unsupported format). Safe to
    /// call off the main thread — does no UI work.
    static func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard !RawDecoder.isRaw(url) else {
            // `.identity` — this overload IS the unedited thumbnail, so it
            // decodes with every RAW-native field at its own identity
            // value rather than duplicating those literals.
            guard let decoded = await rawDecodedThumbnail(
                for: url, maxPixelSize: maxPixelSize, editState: .identity
            ) else { return nil }
            return await renderToCGImage(decoded, isRaw: true)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// ImageIO's own thumbnail API *can* decode a RAW file, but only from
    /// its embedded camera-JPEG preview — the camera's own rendering, not
    /// Apple's RAW rendering — which would make the Library grid visibly
    /// disagree with the Editor for every RAW photo (the exact mismatch
    /// post-Phase-5 follow-up #4 already fixed once for edited-vs-unedited
    /// thumbnails). So RAW thumbnails instead go through
    /// `RawDecoder.decodeDraft`, Apple's fast/lower-quality RAW decode path,
    /// returning the still-in-flight `CIImage` (extended-range, wide-gamut)
    /// rather than an already-baked-down `CGImage` — the caller decides
    /// when to flatten to 8-bit sRGB, so an edited RAW thumbnail (below)
    /// can run `EditPipeline` BEFORE that lossy step instead of after,
    /// which matters for any edit touching highlight headroom or saturated
    /// color (reviewer-caught: an earlier draft flattened to 8-bit sRGB
    /// here unconditionally, then re-imported that flattened `CGImage` for
    /// `EditPipeline` to run on — silently clipping exactly the extra
    /// range/gamut RAW provides before the edit math ever saw it).
    private static func rawDecodedThumbnail(for url: URL, maxPixelSize: Int, editState: EditState) async -> CIImage? {
        await RawDecoder.decodeDraft(contentsOf: url, maxPixelSize: maxPixelSize, editState: editState)
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

    /// Flattens `image` to the final 8-bit sRGB `CGImage` every thumbnail
    /// path returns. `isRaw` RAW renders route through
    /// `RawDecoder.RenderGate` — the same serializing gate `RawDecoder.materialize`
    /// uses — so a grid full of RAW thumbnails decoding in the background
    /// can never contend with (and, live-caught, deadlock against) the
    /// Editor's own RAW materialize call inside Apple's private RawCamera
    /// framework; see `RenderGate`'s own doc comment. Non-RAW skips the
    /// gate entirely — it never touches RawCamera, so serializing it too
    /// would only cost Library-grid scroll throughput for no benefit.
    private static func renderToCGImage(_ image: CIImage, isRaw: Bool) async -> CGImage? {
        guard isRaw else {
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace)
        }
        return await RawDecoder.RenderGate.shared.run {
            context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace)
        }
    }

    /// Same as `thumbnail(for:maxPixelSize:)`, but runs `editState` through
    /// `EditPipeline` first so the Library grid reflects the photo's actual
    /// saved edits instead of always showing the original. `editState ==
    /// .identity` (the common case for an unedited photo) takes a fast
    /// path — returns the plain thumbnail unchanged, paying zero extra
    /// decode/render cost. For non-RAW, runs the pipeline on the
    /// ALREADY-SMALL, already-EXIF-oriented base thumbnail (not a second
    /// full-res decode) — approximately correct because every pipeline stage
    /// that depends on image size (crop, straighten, vignette/sharpen radius,
    /// etc.) derives its geometry from the image's own current extent, so it
    /// scales proportionally rather than needing a fixed absolute resolution.
    /// **Approximately, not exactly** — an earlier version of this sentence
    /// claimed exactness. `ProxyScale` and `ImageDocumentModel` cite this
    /// comment as precedent for their own (also overstated) versions, so it
    /// propagated; `ImageRenderer` cites `ProxyScale`, not this one.
    /// Measured: all four stages tested diverge under downscale, by amounts
    /// that swap rank with scale. This path runs the most aggressive ratio in
    /// the app — but that is BEYOND the measured range (the matrix stops at
    /// 0.16, and Dehaze is non-monotonic there), so thumbnail behaviour is
    /// extrapolated, not measured. Dehaze is the likeliest to show it, since
    /// its atmospheric light is a whole-frame statistic a thumbnail estimates
    /// from different pixels entirely — which would mean a Library-grid
    /// thumbnail of a dehazed photo visibly differing from the Editor render.
    /// Accepted, same class as the documented RAW-thumbnail divergences.
    /// See IMPROVEMENTS.md D18. For RAW, runs the pipeline directly on
    /// `RawDecoder.decodeDraft`'s `CIImage` — see `rawDecodedThumbnail`'s
    /// doc comment for why that single-render-pass ordering matters.
    static func thumbnail(for url: URL, maxPixelSize: Int, editState: EditState) async -> CGImage? {
        guard editState != .identity else {
            return await thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
        let isRaw = RawDecoder.isRaw(url)
        let decoded: CIImage?
        if isRaw {
            decoded = await rawDecodedThumbnail(for: url, maxPixelSize: maxPixelSize, editState: editState)
        } else {
            decoded = await thumbnail(for: url, maxPixelSize: maxPixelSize).map { CIImage(cgImage: $0) }
        }
        guard let decoded else { return nil }
        let edited = EditPipeline.apply(editState, to: decoded)
        return await renderToCGImage(edited, isRaw: isRaw)
    }
}
