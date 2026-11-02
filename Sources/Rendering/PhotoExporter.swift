import CoreImage
import Foundation
import Metal

/// The output format for an exported photo.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case jpeg, png, tiff, heic

    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    /// Whether the format takes a lossy quality setting (the Export sheet shows the quality slider for these).
    var isLossy: Bool { self == .jpeg || self == .heic }
    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
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
    var quality: CGFloat = 0.9 // JPEG and HEIC only, 0...1
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
    /// Embed the photo's Library title, caption, creator and copyright (IPTC + TIFF + XMP `dc:`) in the exported file.
    /// Ignored under `ExportMetadataPolicy.none`. Default OFF: a caption can be private, so nothing is written
    /// unless the user switches it on in the options sheet (the choice is remembered).
    var includeInfo = false
    /// Rendered (default) or a byte-identical copy of the original file. When `.original`, EVERY other setting except
    /// the file-name template is ignored: nothing is rendered, converted, stripped or embedded. NEVER remembered
    /// (neither saved nor read back): a byte copy keeps the GPS, so each sheet opens as Rendered, like Copy Photos' Move choice.
    var kind: ExportKind = .rendered
    /// Maximum file size in KB for a JPEG/HEIC export (`minimumFileSizeKB...maximumFileSizeKB`); nil = no limit (default).
    /// Ignored for PNG/TIFF and for `.original`; see `sizeLimitBytes`.
    var maxFileSizeKB: Int?

    static let minimumFileSizeKB = 50
    static let maximumFileSizeKB = 1_000_000

    /// A stored or typed limit as a usable one: values of 0 or less mean "no limit", small values are raised to the floor
    /// (a smaller file than ~50 KB is not something a photo export can reach), huge ones capped.
    static func sanitizedFileSizeKB(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return min(max(value, minimumFileSizeKB), maximumFileSizeKB)
    }

    /// The byte limit that actually applies to the file this export writes, nil when none does.
    var sizeLimitBytes: Int? {
        guard kind == .rendered, format.isLossy, let kb = Self.sanitizedFileSizeKB(maxFileSizeKB) else { return nil }
        return kb * 1024
    }
}

/// Schema-tolerant persistence (the pattern `EditState` uses): a missing key decodes to that field's default, so
/// adding a field in a later release never invalidates settings an older build stored. In an extension, not the
/// struct body, so the memberwise initializer (used by tests and call sites) is kept.
extension ExportSettings: Codable {
    private enum CodingKeys: String, CodingKey { case format, quality, resize, namingTemplate, colorSpace, metadata, sharpening, watermark, includeKeywords, includeInfo, kind, maxFileSizeKB }

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
        includeInfo = (try? container.decodeIfPresent(Bool.self, forKey: .includeInfo)) ?? defaults.includeInfo
        kind = defaults.kind // a stored `kind` (an older build's) is deliberately ignored
        // A wrong type (a string) or a value outside Int resets this field only; a number is sanitised.
        maxFileSizeKB = ExportSettings.sanitizedFileSizeKB((try? container.decodeIfPresent(Int.self, forKey: .maxFileSizeKB)) ?? nil)
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
        try container.encode(includeInfo, forKey: .includeInfo)
        try container.encodeIfPresent(Self.sanitizedFileSizeKB(maxFileSizeKB), forKey: .maxFileSizeKB)
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
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let path):
            return "Couldn't read \"\(path)\" — the app may not currently have permission to access it."
        case .invalidNaming(let error):
            return error.errorDescription ?? "The file name template is invalid."
        case .encodingFailed(let path):
            return "Couldn't write \"\(path)\" within the file size limit."
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
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: URL(fileURLWithPath: photo.path), versionKey: photo.versionKey) else {
            return .identity
        }
        return state
    }

    /// Renders `photo` (decoded, EXIF-oriented, edited, optionally
    /// resized) and writes it into `destinationFolder`, returning the
    /// exact file URL written. Never overwrites an existing file — the
    /// name is claimed at the very end by an exclusive commit
    /// (`commitExclusively`), see `commitStaged`. With `settings.kind == .original`
    /// this copies the original file instead (`exportOriginal`).
    static func export(
        _ photo: Photo,
        editState: EditState,
        to destinationFolder: URL,
        settings: ExportSettings,
        sequenceIndex: Int = 0,
        keywords: [String] = [],
        info: PhotoInfo = PhotoInfo(),
        logoStore: WatermarkLogoStore = .shared
    ) async throws -> URL {
        try await exportReporting(
            photo, editState: editState, to: destinationFolder, settings: settings, sequenceIndex: sequenceIndex,
            keywords: keywords, info: info, logoStore: logoStore
        ).url
    }

    /// `export`, also reporting whether a file-size limit could not be met. `firstCandidate` is a test hook: the first
    /// name the commit tries (a name that is taken makes the commit move on, exactly like a collision that appears in
    /// the moment between choosing a name and writing it).
    static func exportReporting(
        _ photo: Photo,
        editState: EditState,
        to destinationFolder: URL,
        settings: ExportSettings,
        sequenceIndex: Int = 0,
        keywords: [String] = [],
        info: PhotoInfo = PhotoInfo(),
        logoStore: WatermarkLogoStore = .shared,
        firstCandidate: URL? = nil
    ) async throws -> ExportOutcome {
        if settings.kind == .original {
            let result = try exportOriginal(photo, to: destinationFolder, settings: settings, sequenceIndex: sequenceIndex, firstCandidate: firstCandidate)
            return ExportOutcome(url: result.url, overLimit: false)
        }
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
        // `effectiveGrain`, not `editState.grain`: the Style's Grain toggle and B&W Grain are grain too and must be held back the same way (`zeroingGrain()` lists every source).
        let deferGrain = settings.sharpening != .none && EditPipeline.effectiveGrain(editState) != 0
        let pipelineState = deferGrain ? editState.zeroingGrain() : editState
        let edited = EditPipeline.apply(pipelineState, to: oriented)
        // Sharpen the image AT OUTPUT SIZE (after the resize). A CONVENTION, not a measured requirement: the radius is
        // a fraction of the extent, so before/after landed within 0.0043 of each other on a step edge (see
        // OutputSharpenTests); after-resize is simply the exact-pixel, unambiguous definition.
        var sharpened = OutputSharpen.apply(settings.sharpening, to: Self.resized(edited, option: settings.resize))
        if deferGrain { sharpened = EditPipeline.applyFinalGrain(editState, to: sharpened) }
        let resizedPixels = WatermarkRenderer.apply(settings.watermark, to: sharpened, logoStore: logoStore)
        // The writer emits the image's own `properties`, so setting them IS applying the metadata policy.
        let resized = resizedPixels.settingProperties(
            InfoEmbedding.properties(
                KeywordEmbedding.properties(
                    ExportMetadata.properties(from: oriented.properties, policy: settings.metadata),
                    addingKeywords: keywords, policy: settings.metadata, include: settings.includeKeywords
                ),
                adding: info, policy: settings.metadata, include: settings.includeInfo
            )
        )

        // The encoded bytes are produced first (in memory for a size-limited export, via a temp file for the existing
        // writer), then committed under a name claimed exclusively — see `commitStaged`.
        // RAW sources route the encode through `RawDecoder.RenderGate` —
        // the same serializing gate `RawDecoder.materialize`/
        // `ThumbnailGenerator` use — so a RAW batch export can't contend
        // with (and, live-caught elsewhere, deadlock against) RAW decode
        // work happening concurrently in the Editor or Library grid; see
        // `RenderGate`'s own doc comment. Non-RAW is untouched/synchronous
        // — it never touches Apple's RawCamera framework, so gating it too
        // would only cost batch-export throughput for no benefit.
        struct Encoded: Sendable { var data: Data; var overLimit: Bool }
        let encode: @Sendable () throws -> Encoded = {
            if let limit = settings.sizeLimitBytes {
                let result = try Self.writeLimited(
                    resized, format: settings.format, maxQuality: settings.quality, colorSpace: settings.colorSpace, limitBytes: limit,
                    pathForError: photo.path
                )
                return Encoded(data: result.data, overLimit: !result.metLimit)
            }
            // Writes to an app-writable temp file via CIContext first (the proven-working combination, see
            // `ExportModel.runExport`'s comment), then reads those bytes back.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(settings.format.fileExtension)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try Self.write(resized, format: settings.format, quality: settings.quality, colorSpace: settings.colorSpace, to: tempURL)
            return Encoded(data: try Data(contentsOf: tempURL), overLimit: false)
        }
        let encoded: Encoded
        if RawDecoder.isRaw(sourceURL) {
            encoded = try await RawDecoder.RenderGate.shared.run { try encode() }
        } else {
            encoded = try encode()
        }
        let url = try commitData(
            encoded.data, baseName: baseName, fileExtension: settings.format.fileExtension, in: destinationFolder, firstCandidate: firstCandidate
        )
        return ExportOutcome(url: url, overLimit: encoded.overLimit)
    }

    // MARK: - Exclusive commit

    /// The hidden temp file a commit stages in: the destination folder itself, so the final hard link never crosses a volume.
    private static func stagingURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".lightbench-export-\(UUID().uuidString).tmp")
    }

    /// Claims a free name for the staged file with `commitExclusively` (a hard link: atomic, fails instead of replacing a
    /// file that appeared after the name was chosen, then the next name is tried). `firstCandidate`, when given, is tried
    /// first (tests simulate the race with it).
    private static func commitStaged(
        _ staged: URL, baseName: String, fileExtension: String, in folder: URL, firstCandidate: URL?
    ) throws -> URL {
        var pending = firstCandidate
        return try PhotoEnhancer.commitExclusively(staged, nextCandidate: {
            if let first = pending { pending = nil; return first }
            return Self.uniqueFileURL(baseName: baseName, fileExtension: fileExtension, in: folder)
        })
    }

    /// Writes `data` into `folder` under `baseName.fileExtension` (or the next free " (2)"… name). Never overwrites.
    static func commitData(_ data: Data, baseName: String, fileExtension: String, in folder: URL, firstCandidate: URL? = nil) throws -> URL {
        let staged = stagingURL(in: folder)
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged)
        return try commitStaged(staged, baseName: baseName, fileExtension: fileExtension, in: folder, firstCandidate: firstCandidate)
    }

    // MARK: - Original-file export

    /// One row per FILE: virtual copies share their master's file, so exporting the originals of a master and its copies
    /// would write the same bytes twice. The first row of each path (standardised) wins; order is kept.
    static func photosForOriginalExport(_ photos: [Photo]) -> [Photo] {
        var seen = Set<String>()
        return photos.filter { seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted }
    }

    /// Copies `photo`'s ORIGINAL file into `destinationFolder`, byte for byte, named by `settings.namingTemplate` with the
    /// SOURCE's own extension. Nothing is rendered, converted, stripped or embedded, so the file keeps its GPS and every
    /// other tag (the sheet says so). Only the photo file is copied, never its edit file or XMP sidecar. A truncated
    /// source is copied as it is and reported. Mechanism (as `ImportCopyEngine.copyOne`): copy to a hidden temp file in the
    /// destination, verify size and SHA-256, then commit exclusively under a free name. The source is only ever read.
    /// On APFS `copyItem` clones the file, so the hash check verifies little there (it matters on other file systems and
    /// for an injected `copy`); `copy` is injectable so a corrupt copy is tested.
    static func exportOriginal(
        _ photo: Photo, to destinationFolder: URL, settings: ExportSettings, sequenceIndex: Int, firstCandidate: URL? = nil,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> OriginalExportResult {
        let sourceURL = URL(fileURLWithPath: photo.path)
        let fileExtension = sourceURL.pathExtension
        let compiled: CompiledNamingTemplate
        switch NamingTemplate.compile(settings.namingTemplate) {
        case .success(let value): compiled = value
        case .failure(let error): throw PhotoExportError.invalidNaming(error)
        }
        let captureDate = compiled.usesCaptureDate
            ? CaptureDate.read(from: sourceURL, fallback: photo.importedAt)
            : photo.importedAt
        let baseName = try destinationBaseName(
            for: photo, fileExtension: fileExtension, compiled: compiled, sequenceIndex: sequenceIndex, captureDate: captureDate
        )
        let fm = FileManager.default
        // Only a REGULAR file is copied (lstat, links not followed): `copyItem` would copy a symlink AS a symlink pointing
        // back at the original, and a folder catalogued as `X.jpg` recursively.
        guard TrashPlan.systemFileKind(sourceURL) == .file, fm.isReadableFile(atPath: sourceURL.path) else {
            throw PhotoExportError.unreadableSource(photo.path)
        }
        let truncated = SourceIntegrity.verdict(forFileAt: sourceURL) == .truncated

        let staged = stagingURL(in: destinationFolder)
        defer { try? fm.removeItem(at: staged) }
        do {
            try copy(sourceURL, staged)
        } catch {
            throw PhotoExportError.unreadableSource(photo.path)
        }
        // The source could have been swapped for a link after the check above: what was staged must be a regular file.
        guard TrashPlan.systemFileKind(staged) == .file else { throw PhotoExportError.unreadableSource(photo.path) }
        let sourceSize = (try? fm.attributesOfItem(atPath: sourceURL.path))?[.size] as? Int64
        let stagedSize = (try? fm.attributesOfItem(atPath: staged.path))?[.size] as? Int64
        guard let sourceSize, sourceSize == stagedSize,
              let sourceHash = FileHasher.sha256Hex(ofFileAt: sourceURL),
              FileHasher.sha256Hex(ofFileAt: staged) == sourceHash else {
            throw PhotoExportError.unreadableSource(photo.path)
        }
        let url = try commitStaged(staged, baseName: baseName, fileExtension: fileExtension, in: destinationFolder, firstCandidate: firstCandidate)
        return OriginalExportResult(url: url, sourceWasTruncated: truncated)
    }

    // MARK: - Size-limited encode

    /// JPEG/HEIC bytes under `limitBytes` (see `FileSizeLimiter`). The image is rendered ONCE to an 8-bit CGImage in the
    /// output colour space — flattened over black exactly like the unlimited writer does — then only the encode repeats,
    /// in memory, at different qualities (metadata, keywords and the ICC tag ride along on the image's own properties, a
    /// fixed cost). `EditPipeline` is never re-run per step. Memory: a full-size RGBA8 CGImage is held while the encodes
    /// run (peak not measured). Throws `encodingFailed` when the image cannot be rendered/encoded.
    static func writeLimited(
        _ image: CIImage, format: ExportFormat, maxQuality: CGFloat, colorSpace: ExportColorSpace, limitBytes: Int, pathForError: String = ""
    ) throws -> FileSizeLimiter.Result {
        let outputColorSpace = colorSpace.cgColorSpace
        let flattened = flattenedOverBlack(image, outputColorSpace: outputColorSpace)
        guard !flattened.extent.isInfinite,
              let cgImage = context.createCGImage(flattened, from: flattened.extent, format: .RGBA8, colorSpace: outputColorSpace)
        else { throw PhotoExportError.encodingFailed(pathForError) }
        let reloaded = CIImage(cgImage: cgImage).settingProperties(image.properties)
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let result = FileSizeLimiter.search(limitBytes: limitBytes, maxQuality: maxQuality) { quality in
            switch format {
            case .jpeg:
                return context.jpegRepresentation(of: reloaded, colorSpace: outputColorSpace, options: [key: quality])
            case .heic:
                return context.heifRepresentation(of: reloaded, format: .RGBA8, colorSpace: outputColorSpace, options: [key: quality])
            case .png, .tiff:
                return nil // never limited (`ExportSettings.sizeLimitBytes`)
            }
        }
        guard let result else { throw PhotoExportError.encodingFailed(pathForError) }
        return result
    }

    /// Transparency flattened over opaque black on the OUTPUT-ENCODED values (what the JPEG writer does and `write`'s HEIC
    /// branch pins; blending in linear light would give a different red). An infinite extent is returned as is.
    private static func flattenedOverBlack(_ image: CIImage, outputColorSpace: CGColorSpace) -> CIImage {
        if image.extent.isInfinite { return image }
        let encoded = image.matchedFromWorkingSpace(to: outputColorSpace) ?? image
        let opaque = encoded.composited(over: CIImage(color: .black).cropped(to: image.extent))
            .settingAlphaOne(in: image.extent)
        return opaque.matchedToWorkingSpace(from: outputColorSpace) ?? opaque
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
        case .heic:
            // HEIC is a delivery format like JPEG, so transparency is FLATTENED the same way JPEG does it: over opaque
            // black (a 50%-alpha red reads back (127, 0, 1) from JPEG; HEIC is pinned to match in
            // `ExportFormatProbeTests`). Left alone, `.RGBA8` would write an alpha auxiliary image that many HEIC
            // readers ignore or show differently. 8-bit (`.RGBA8`) like the other lossy path.
            // The blend is done on the OUTPUT-ENCODED values (as JPEG's writer does; blending in linear light would give
            // 187 instead of 126 for that red), and `settingAlphaOne` makes the result opaque so no alpha plane is written.
            let flattened = flattenedOverBlack(image, outputColorSpace: outputColorSpace)
            try context.writeHEIFRepresentation(
                of: flattened,
                to: url,
                format: .RGBA8,
                colorSpace: outputColorSpace,
                options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            )
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
        try destinationBaseName(for: photo, fileExtension: format.fileExtension, compiled: compiled, sequenceIndex: sequenceIndex, captureDate: captureDate)
    }

    /// The same, for a file that keeps an arbitrary extension (an original-file export keeps the SOURCE's).
    static func destinationBaseName(
        for photo: Photo, fileExtension: String, compiled: CompiledNamingTemplate, sequenceIndex: Int, captureDate: Date
    ) throws -> String {
        let context = NamingContext(
            baseName: (photo.filename as NSString).deletingPathExtension,
            fileExtension: fileExtension,
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
