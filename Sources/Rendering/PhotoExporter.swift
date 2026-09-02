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

    /// Built once (not per photo) — Metal-backed when a device is
    /// available (always, on any real Mac), falling back to a plain
    /// `CIContext` otherwise so export still degrades gracefully rather
    /// than crashing.
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: workingColorSpace, .workingFormat: CIFormat.RGBAh]
        if let device = MTLCreateSystemDefaultDevice() {
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
        let sidecarURL = ImageDocumentModel.sidecarURL(for: URL(fileURLWithPath: photo.path))
        guard let data = try? Data(contentsOf: sidecarURL) else { return .identity }
        return (try? JSONDecoder().decode(EditState.self, from: data)) ?? .identity
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
    ) throws -> URL {
        let sourceURL = URL(fileURLWithPath: photo.path)
        guard let oriented = RawDecoder.decode(contentsOf: sourceURL) else {
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

        switch settings.format {
        case .jpeg:
            try context.writeJPEGRepresentation(
                of: resized,
                to: tempURL,
                colorSpace: outputColorSpace,
                options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.quality]
            )
        case .png:
            try context.writePNGRepresentation(of: resized, to: tempURL, format: .RGBA8, colorSpace: outputColorSpace)
        case .tiff:
            try context.writeTIFFRepresentation(of: resized, to: tempURL, format: .RGBA16, colorSpace: outputColorSpace)
        }

        let data = try Data(contentsOf: tempURL)
        try data.write(to: outputURL, options: .atomic)
        return outputURL
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
    static func uniqueDestinationURL(for photo: Photo, in folder: URL, format: ExportFormat) -> URL {
        let baseName = (photo.filename as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension(format.fileExtension)
            suffix += 1
        }
        return candidate
    }
}
