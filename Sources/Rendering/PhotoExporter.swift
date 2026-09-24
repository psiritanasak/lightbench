import CoreImage
import Foundation
import Metal

/// The output format for an exported photo.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, tiff

    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
}

/// Whether an exported photo keeps its original pixel dimensions or is
/// scaled down to fit a maximum long-edge size.
enum ExportResize: Equatable, Sendable {
    case original
    case maxLongEdge(CGFloat)
}

struct ExportSettings: Sendable {
    var format: ExportFormat = .jpeg
    var quality: CGFloat = 0.9 // JPEG only, 0...1
    var resize: ExportResize = .original
}

enum PhotoExportError: LocalizedError {
    case unreadableSource(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let path):
            return "Couldn't read \"\(path)\" — the app may not currently have permission to access it."
        }
    }
}

/// Renders a catalogued `Photo` with its saved edits applied and writes
/// it to disk — no UI import, safe to call off-main.
///
/// Never manually renders into a raw `MTLTexture`/drawable the way
/// `ImageRenderer` does for live on-screen display — that type's own doc
/// comment flags its "no y-flip" behavior as verified ONLY for that
/// specific live-drawable path, and explicitly warns an offscreen
/// texture (the same shape that misled an earlier, incorrect version of
/// that fix) must be independently re-verified, not assumed. This type
/// sidesteps that specific risk: it calls
/// `CIContext.write*Representation(of:to:...)` directly on the edited
/// `CIImage`, which handles orientation via `CIImage`'s own semantics
/// (matching JPEG/TIFF conventions), never a manual drawable-presentation
/// read-back — independently, visually verified live (see PROGRESS.md).
///
/// The `CIContext` itself IS Metal-backed (`CIContext(mtlDevice:options:)`,
/// falling back to a plain `CIContext` only if no Metal device is
/// available) — live-tested and confirmed necessary: a plain, non-Metal
/// `CIContext` reliably failed (`CINonLocalizedDescriptionKey error 3`)
/// rendering real, full-size photos through `.workingFormat: .RGBAh`,
/// despite working fine in this file's own tests (which only ever use
/// small synthetic images). This is unrelated to the y-flip landmine
/// above — using Metal as the `CIContext`'s internal GPU backend doesn't
/// reintroduce manual texture/drawable handling.
enum PhotoExporter {
    /// Same working/output color-space definition as `ImageRenderer.swift`
    /// (`CLAUDE.md`: "linear light in a defined working color space...
    /// convert to display/sRGB only at output"), keeping export's color
    /// pipeline visually consistent with the live preview.
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// The Metal device backing `context`, when one is available — a
    /// single shared instance rather than each caller making its own
    /// `MTLCreateSystemDefaultDevice()` call, so `SuperResolutionUpscaler`
    /// (`PhotoEnhancer`'s own upscale step) always builds its MetalFX
    /// textures against the SAME device `context` itself renders with.
    /// Not `private`: `PhotoEnhancer` needs it directly (a mismatched
    /// device between the two would be a real, silent bug on a
    /// multi-GPU Mac — see `SuperResolutionUpscaler`'s own doc comment
    /// on that precondition).
    static let renderDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Built once (not per photo) — Metal-backed when a device is
    /// available (always, on any real Mac), falling back to a plain
    /// `CIContext` otherwise so export still degrades gracefully rather
    /// than crashing. Not `private`: `PhotoEnhancer` reuses this exact
    /// context for its own MetalFX/Lanczos upscale render, rather than
    /// building a second one — same testability-driven visibility
    /// widening as `resized`/`uniqueDestinationURL` below.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: workingColorSpace, .workingFormat: CIFormat.RGBAh]
        if let device = renderDevice {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Loads `photo`'s saved edits from its sidecar file, or `.identity`
    /// if none exists or it can't be read. Relies on `CatalogModel`
    /// already holding this photo's containing folder's security scope
    /// open for the app's session (`CatalogModel.activateKnownFolders`,
    /// held for the whole process lifetime, no matching `stop`) — a
    /// design bet confirmed live (see PROGRESS.md), not assumed.
    static func loadEditState(for photo: Photo) -> EditState {
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: URL(fileURLWithPath: photo.path)) else {
            return .identity
        }
        return state
    }

    /// Renders `photo` (decoded, EXIF-oriented, edited, optionally
    /// resized) and writes it into `destinationFolder`, returning the
    /// exact file URL written. Never overwrites an existing file — see
    /// `uniqueDestinationURL`.
    static func export(
        _ photo: Photo,
        editState: EditState,
        to destinationFolder: URL,
        settings: ExportSettings
    ) async throws -> URL {
        let sourceURL = URL(fileURLWithPath: photo.path)
        guard let oriented = await RawDecoder.decode(contentsOf: sourceURL, editState: editState) else {
            throw PhotoExportError.unreadableSource(photo.path)
        }
        let edited = EditPipeline.apply(editState, to: oriented)
        let resized = Self.resized(edited, option: settings.resize)
        let outputURL = Self.uniqueDestinationURL(for: photo, in: destinationFolder, format: settings.format)

        // Writes to an app-writable temp file via CIContext first, then
        // moves those bytes into the real destination via plain
        // Foundation `Data.write(to:options:)` — the same write mechanism
        // `ImageDocumentModel.saveSidecarNow` already uses successfully —
        // rather than having `CIContext.write*Representation` write
        // directly to `outputURL`. Both approaches were tested during
        // this feature's development against a since-fixed sandbox
        // entitlement bug (see `ExportModel.runExport`'s own comment);
        // kept as the proven-working combination rather than re-verified
        // in isolation now that the entitlement is fixed.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(settings.format.fileExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // RAW sources route this write through `RawDecoder.RenderGate` —
        // the same serializing gate `RawDecoder.materialize`/
        // `ThumbnailGenerator` use — so a RAW batch export can't contend
        // with (and, live-caught elsewhere, deadlock against) RAW decode
        // work happening concurrently in the Editor or Library grid; see
        // `RenderGate`'s own doc comment. Non-RAW is untouched/synchronous
        // — it never touches Apple's RawCamera framework, so gating it too
        // would only cost batch-export throughput for no benefit.
        if RawDecoder.isRaw(sourceURL) {
            try await RawDecoder.RenderGate.shared.run {
                try Self.write(resized, format: settings.format, quality: settings.quality, to: tempURL)
            }
        } else {
            try Self.write(resized, format: settings.format, quality: settings.quality, to: tempURL)
        }

        let data = try Data(contentsOf: tempURL)
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    /// Not `private`: `PhotoEnhancer` reuses this exact writer for its own
    /// output (always JPEG in v1, but this stays format-general rather
    /// than duplicating the three `write*Representation` calls).
    static func write(_ image: CIImage, format: ExportFormat, quality: CGFloat, to url: URL) throws {
        switch format {
        case .jpeg:
            try context.writeJPEGRepresentation(
                of: image,
                to: url,
                colorSpace: outputColorSpace,
                options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            )
        case .png:
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: outputColorSpace)
        case .tiff:
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: outputColorSpace)
        }
    }

    /// Scales `image` down to fit `option`'s max long-edge, preserving
    /// aspect ratio. Never upscales beyond the source's own size — same
    /// "don't upscale" precedent as `ThumbnailGenerator`. `.original`
    /// returns `image` unchanged. A non-positive `maxLongEdge` (e.g. an
    /// empty/invalid text field parsed upstream) is also treated as a
    /// no-op rather than producing a degenerate zero-extent or
    /// negative-scale (silently mirrored) image. Internal (not
    /// `private`), matching this project's precedent for pure math
    /// helpers, so `PhotoExporterTests.swift` can unit-test it directly.
    static func resized(_ image: CIImage, option: ExportResize) -> CIImage {
        guard case .maxLongEdge(let maxLongEdge) = option, maxLongEdge > 0 else { return image }
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        guard longSide > maxLongEdge, longSide > 0 else { return image }
        let scale = maxLongEdge / longSide
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// `photo.filename` with `format`'s extension, in `folder` — appending
    /// `" (2)"`, `" (3)"`, etc. on a collision, so re-exporting into the
    /// same folder never silently overwrites a previous export. Internal
    /// (not `private`) for the same testability reason as `resized` above.
    /// Delegates to `uniqueFileURL`, shared with `PhotoEnhancer`.
    static func uniqueDestinationURL(for photo: Photo, in folder: URL, format: ExportFormat) -> URL {
        let baseName = (photo.filename as NSString).deletingPathExtension
        return uniqueFileURL(baseName: baseName, fileExtension: format.fileExtension, in: folder)
    }

    /// `baseName.fileExtension` in `folder`, appending `" (2)"`, `" (3)"`,
    /// etc. on a collision — shared by `uniqueDestinationURL` (above) and
    /// `PhotoEnhancer.destinationURL`, so both features' naming stays
    /// consistent and any future fix to this logic only needs to happen
    /// once. Internal (not `private`) for the same testability reason as
    /// `resized`/`uniqueDestinationURL`.
    ///
    /// A candidate is also rejected if `SidecarStore.sidecarURL(for:)`
    /// already exists on disk for it, even when the candidate FILE itself
    /// doesn't — a fix made alongside this extraction: an orphaned
    /// sidecar left behind by an earlier, since-deleted export/enhance at
    /// that same name would otherwise get silently ADOPTED the next time
    /// that name is reused, applying its stale edits a second time onto a
    /// brand-new file that was never associated with them.
    static func uniqueFileURL(baseName: String, fileExtension: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(atPath: SidecarStore.sidecarURL(for: candidate).path) {
            candidate = folder
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
