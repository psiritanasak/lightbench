import CoreImage
import Foundation
import Metal

/// The output format for an exported photo.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
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

/// The color profile an exported file is converted to and tagged with. The image math stays in the extended-linear
/// working space; this only chooses the output encoding at the very end (CLAUDE.md: convert at output only).
enum ExportColorSpace: String, CaseIterable, Identifiable, Sendable, Codable {
    case sRGB, displayP3, adobeRGB

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        }
    }

    /// Falls back to device RGB only if the system lacks the named space (never observed on macOS 14).
    var cgColorSpace: CGColorSpace {
        let name: CFString
        switch self {
        case .sRGB: name = CGColorSpace.sRGB
        case .displayP3: name = CGColorSpace.displayP3
        case .adobeRGB: name = CGColorSpace.adobeRGB1998
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }
}

/// Whether an exported photo keeps its original pixel dimensions or is
/// scaled down to fit a maximum long-edge size.
enum ExportResize: Equatable, Sendable, Codable {
    case original
    case maxLongEdge(CGFloat)

    /// Largest long edge the UI accepts or a stored value may carry. No real export exceeds it, and bounding it
    /// keeps every stored value displayable (a finite-but-huge one once crashed `Int(edge)` in the options sheet).
    static let maximumLongEdge: CGFloat = 65_536

    /// `self` with a long edge bounded above by `maximumLongEdge`; a non-finite or non-positive one becomes
    /// `.original` (`resized(_:option:)` already treats it as a no-op, so this matches what it would render).
    var sanitized: ExportResize {
        guard case .maxLongEdge(let edge) = self else { return self }
        guard edge.isFinite, edge > 0 else { return .original }
        return .maxLongEdge(min(edge, Self.maximumLongEdge))
    }
}

struct ExportSettings: Sendable, Equatable {
    var format: ExportFormat = .jpeg
    var quality: CGFloat = 0.9 // JPEG only, 0...1
    var resize: ExportResize = .original
    /// File-name template for the exported files (`NamingTemplate` syntax).
    /// The default `{name}` reproduces the source's own base name exactly,
    /// i.e. today's behavior, byte-identical. `{seq}` numbers photos by their
    /// POSITION in the batch: a photo that fails (or is refused) leaves a gap
    /// (001, 003…) rather than renumbering, so a re-export of only the failures
    /// can't collide with an earlier number.
    var namingTemplate: String = NamingTemplate.defaultTemplate
    /// Output profile. Default sRGB = today's behaviour.
    var colorSpace: ExportColorSpace = .sRGB
    /// What to keep of the source's metadata. Default `.withoutLocation`: an export made without touching the options must
    /// not reveal where the photo was taken (`.all` — everything the source had, GPS included — is one click away).
    var metadata: ExportMetadataPolicy = .withoutLocation
    /// Output sharpening applied after the resize. Default `.none` = no change to today's pixels.
    var sharpening: ExportSharpening = .none
    /// Optional text mark composited after sharpening (so the mark itself is never sharpened). Default off.
    var watermark = ExportWatermark()
    /// Embed the photo's catalog keywords (IPTC + XMP `dc:subject`) in the exported file. Ignored under
    /// `ExportMetadataPolicy.none`. Default on: unlike location, keywords are descriptive text the user wrote
    /// to be shared; the toggle is in the options sheet.
    var includeKeywords = true
}

/// Schema-tolerant persistence (the pattern `EditState` uses): a missing key decodes to that field's default, so
/// adding a field in a later release never invalidates settings an older build stored. In an extension, not the
/// struct body, so the memberwise initializer (used by tests and call sites) is kept.
extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey { case format, quality, resize, namingTemplate, colorSpace, metadata, sharpening, watermark, includeKeywords }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportSettings()
        // Per-field `try?`: `decodeIfPresent` only covers a MISSING key, while an unknown enum value (a newer build's
        // format after a downgrade) or a malformed field throws — which must reset that field only, not every setting.
        format = (try? container.decodeIfPresent(ExportFormat.self, forKey: .format)) ?? defaults.format
        let storedQuality = (try? container.decodeIfPresent(CGFloat.self, forKey: .quality)) ?? defaults.quality
        quality = storedQuality.isFinite ? min(max(storedQuality, 0.1), 1) : defaults.quality
        resize = ((try? container.decodeIfPresent(ExportResize.self, forKey: .resize)) ?? defaults.resize).sanitized
        namingTemplate = (try? container.decodeIfPresent(String.self, forKey: .namingTemplate)) ?? defaults.namingTemplate
        colorSpace = (try? container.decodeIfPresent(ExportColorSpace.self, forKey: .colorSpace)) ?? defaults.colorSpace
        metadata = (try? container.decodeIfPresent(ExportMetadataPolicy.self, forKey: .metadata)) ?? defaults.metadata
        sharpening = (try? container.decodeIfPresent(ExportSharpening.self, forKey: .sharpening)) ?? defaults.sharpening
        watermark = (try? container.decodeIfPresent(ExportWatermark.self, forKey: .watermark)) ?? defaults.watermark
        includeKeywords = (try? container.decodeIfPresent(Bool.self, forKey: .includeKeywords)) ?? defaults.includeKeywords
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(quality, forKey: .quality)
        // JSONEncoder throws on a non-finite number, which would silently stop ALL saving; `resized(_:option:)` already
        // treats a non-finite/non-positive long edge as "original", so persist exactly that.
        try container.encode(resize.sanitized, forKey: .resize)
        try container.encode(namingTemplate, forKey: .namingTemplate)
        try container.encode(colorSpace, forKey: .colorSpace)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(watermark, forKey: .watermark)
        try container.encode(includeKeywords, forKey: .includeKeywords)
    }
}

/// Remembers the last-used `ExportSettings` across launches in `UserDefaults` (JSON under one key). The
/// destination folder is deliberately not part of the settings. Tests must pass an isolated suite: the test host is
/// the real app, so `.standard` there is the real app's preferences.
struct ExportSettingsStore {
    static let key = "exportSettings.v2"
    /// The first release's key. Every save under it wrote `"metadata":"all"` (then the default, which keeps the GPS
    /// location), so a v1 value cannot be told apart from an unexamined default.
    static let legacyKey = "exportSettings.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored settings, or the defaults when nothing is stored or the data is unreadable. When only a v1 value
    /// exists it is migrated ONCE: every field is kept EXCEPT the metadata policy, which takes the new (privacy-
    /// preserving) default, because a stored `all` is just the old default; whoever really wants all metadata chooses
    /// it again (the sheet shows the policy and warns that `All metadata` includes the location). v1 is left untouched.
    func load() -> ExportSettings {
        if let data = defaults.data(forKey: Self.key) {
            return (try? JSONDecoder().decode(ExportSettings.self, from: data)) ?? ExportSettings()
        }
        guard let legacy = defaults.data(forKey: Self.legacyKey),
              var migrated = try? JSONDecoder().decode(ExportSettings.self, from: legacy) else { return ExportSettings() }
        migrated.metadata = ExportSettings().metadata
        save(migrated)
        return migrated
    }

    func save(_ settings: ExportSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum PhotoExportError: LocalizedError {
    case unreadableSource(String)
    case incompleteSource(String)
    case invalidNaming(NamingError)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let path):
            return "Couldn't read \"\(path)\" — the app may not currently have permission to access it."
        case .invalidNaming(let error):
            return error.errorDescription ?? "The file name template is invalid."
        case .incompleteSource(let path):
            return "\"\(path)\" looks cut off (an incomplete or damaged file), so exporting it would write a partial image. Nothing was written. (The photo can still be opened and viewed.)"
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
    /// Same WORKING color space as `ImageRenderer.swift` (`CLAUDE.md`:
    /// "linear light in a defined working color space... convert only at
    /// output"). The OUTPUT profile is the user's `ExportColorSpace` choice
    /// (default sRGB, matching the preview); the editor preview itself is
    /// still sRGB, so a wide-gamut export can look more saturated than it.
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpace(name: CGColorSpace.linearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()

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
        settings: ExportSettings,
        sequenceIndex: Int = 0,
        keywords: [String] = []
    ) async throws -> URL {
        let sourceURL = URL(fileURLWithPath: photo.path)
        // D37: refuse a truncated source rather than silently exporting a partial image.
        if SourceIntegrity.verdict(forFileAt: sourceURL) == .truncated {
            throw PhotoExportError.incompleteSource(photo.path)
        }
        // Naming is resolved BEFORE the expensive decode/render so a bad
        // template fails fast. The capture-date read (file I/O) only happens
        // for templates that actually use {date}/{datetime}.
        let baseName = try Self.destinationBaseName(
            for: photo, sourceURL: sourceURL, format: settings.format,
            template: settings.namingTemplate, sequenceIndex: sequenceIndex
        )
        guard let oriented = await RawDecoder.decode(contentsOf: sourceURL, editState: editState) else {
            throw PhotoExportError.unreadableSource(photo.path)
        }
        // Grain is the pipeline's last stage because sharpening grain amplifies it (measured: +14%/+35% noise std with
        // output sharpening). Output sharpening runs after the pipeline, so when both are on, hold the grain back and
        // add it after the sharpen, at the output size — the same order the Editor uses. Every other export is unchanged.
        // `effectiveGrain`, not `editState.grain`: the Style's Grain toggle is grain too and must be held back the same way.
        let deferGrain = settings.sharpening != .none && EditPipeline.effectiveGrain(editState) != 0
        var pipelineState = editState
        if deferGrain { pipelineState.grain = 0; pipelineState.styleGrain = false }
        let edited = EditPipeline.apply(pipelineState, to: oriented)
        // Sharpen the image AT OUTPUT SIZE (after the resize). A CONVENTION, not a measured requirement: the radius is
        // a fraction of the extent, so before/after landed within 0.0043 of each other on a step edge (see
        // OutputSharpenTests); after-resize is simply the exact-pixel, unambiguous definition.
        var sharpened = OutputSharpen.apply(settings.sharpening, to: Self.resized(edited, option: settings.resize))
        if deferGrain { sharpened = EditPipeline.applyFinalGrain(editState, to: sharpened) }
        let resizedPixels = WatermarkRenderer.apply(settings.watermark, to: sharpened)
        // The writer emits the image's own `properties`, so setting them IS applying the metadata policy.
        let resized = resizedPixels.settingProperties(
            KeywordEmbedding.properties(
                ExportMetadata.properties(from: oriented.properties, policy: settings.metadata),
                addingKeywords: keywords, policy: settings.metadata, include: settings.includeKeywords
            )
        )
        let outputURL = Self.uniqueFileURL(
            baseName: baseName, fileExtension: settings.format.fileExtension, in: destinationFolder
        )

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
                try Self.write(resized, format: settings.format, quality: settings.quality, colorSpace: settings.colorSpace, to: tempURL)
            }
        } else {
            try Self.write(resized, format: settings.format, quality: settings.quality, colorSpace: settings.colorSpace, to: tempURL)
        }

        let data = try Data(contentsOf: tempURL)
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    /// Not `private`: `PhotoEnhancer` reuses this exact writer for its own
    /// output (always JPEG in v1, but this stays format-general rather
    /// than duplicating the three `write*Representation` calls).
    static func write(
        _ image: CIImage, format: ExportFormat, quality: CGFloat, colorSpace: ExportColorSpace = .sRGB, to url: URL
    ) throws {
        let outputColorSpace = colorSpace.cgColorSpace
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

    /// The exported file's base name (no extension) for `photo` under
    /// `template`: `{seq}` counts from 1 at `sequenceIndex` 0, `{date}` reads
    /// the source's capture date (only when the template needs it). Throws
    /// `PhotoExportError.invalidNaming` for a bad template or an unusable
    /// result. Internal for testability.
    static func destinationBaseName(
        for photo: Photo, sourceURL: URL, format: ExportFormat, template: String, sequenceIndex: Int
    ) throws -> String {
        let compiled: CompiledNamingTemplate
        switch NamingTemplate.compile(template) {
        case .success(let value): compiled = value
        case .failure(let error): throw PhotoExportError.invalidNaming(error)
        }
        let captureDate = compiled.usesCaptureDate
            ? CaptureDate.read(from: sourceURL, fallback: photo.importedAt)
            : photo.importedAt
        return try destinationBaseName(for: photo, format: format, compiled: compiled, sequenceIndex: sequenceIndex, captureDate: captureDate)
    }

    /// Pure core (no I/O) of `destinationBaseName` — what the tests and the
    /// Export sheet's live preview call with an already-known capture date.
    static func destinationBaseName(
        for photo: Photo, format: ExportFormat, compiled: CompiledNamingTemplate, sequenceIndex: Int, captureDate: Date
    ) throws -> String {
        let context = NamingContext(
            baseName: (photo.filename as NSString).deletingPathExtension,
            fileExtension: format.fileExtension,
            sequenceIndex: sequenceIndex,
            captureDate: captureDate,
            rating: photo.rating,
            colorLabel: photo.colorLabel,
            flagStatus: photo.flagStatus
        )
        switch compiled.renderBaseName(context: context) {
        case .success(let base): return base
        case .failure(let error): throw PhotoExportError.invalidNaming(error)
        }
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
        // An ORPHAN `<base>.xmp` (no photo shares that base name) is also refused: the new file would silently inherit someone else's metadata.
        func orphanXMPExists(at url: URL) -> Bool {
            FileManager.default.fileExists(atPath: XMPSidecarStore.sidecarURL(for: url).path)
                && RenameEngine.siblingPhotos(sharingBaseNameWith: url).isEmpty
        }
        while FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(atPath: SidecarStore.sidecarURL(for: candidate).path)
            || orphanXMPExists(at: candidate) {
            candidate = folder
                .appendingPathComponent(baseNameFitting(baseName, suffix: " (\(suffix))", fileExtension: fileExtension))
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    /// `baseName + suffix`, with whole CHARACTERS trimmed off the end of
    /// `baseName` until the full file name (`base + suffix + "." + ext`) fits
    /// in 255 UTF-8 bytes (`NAME_MAX`). IMPROVEMENTS.md D39: a base that passed
    /// the length check WITHOUT its " (2)" suffix could exceed it once the
    /// suffix was added, and `fileExists` reports a too-long path as absent,
    /// so the collision loop returned an unwritable name. Never splits a
    /// character or scalar; the suffix itself is always kept whole.
    static func baseNameFitting(_ baseName: String, suffix: String, fileExtension: String) -> String {
        let reserved = suffix.utf8.count + 1 + fileExtension.utf8.count // suffix + "." + ext
        var trimmed = baseName
        while trimmed.utf8.count + reserved > 255, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        return trimmed + suffix
    }
}
