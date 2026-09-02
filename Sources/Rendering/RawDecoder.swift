import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The app's first shared file-decode chokepoint. Before this file, three
/// call sites (`ImageDocumentModel.load(from:)`, `PhotoExporter.export`,
/// `ThumbnailGenerator.thumbnail(for:maxPixelSize:)`) each decoded a file
/// URL independently. RAW support needed a fourth decode path
/// (`CIRAWFilter`) in all three places, so rather than repeating a
/// RAW-vs-not branch three times, this type is the one place that branch
/// lives — including the EXIF-orientation lookup all three used to read
/// via `ImageDocumentModel`, moved here (Rendering) so `PhotoImporter`
/// (Catalog) calling into this type doesn't transitively reach into UI,
/// matching CLAUDE.md's "Keep modules separated" principle.
///
/// Phase 6 slice 1 scope: decode only. `CIRAWFilter`'s own RAW-native
/// controls (`baselineExposure`, `boostAmount`, `neutralTemperature`/
/// `neutralLocation`, `lensCorrectionEnabled`, its NR/sharpness/detail/moiré
/// sliders) are a genuine `EditState`-level feature deferred to a later
/// session — see CLAUDE.md/PROGRESS.md.
enum RawDecoder {
    /// True if `url` names a camera RAW file, classified via
    /// UniformTypeIdentifiers rather than a hardcoded extension list — the
    /// UTI graph (`public.camera-raw-image`, `.rawImage`) tracks whatever
    /// RAW formats the running OS actually knows how to decode, instead of
    /// this app's own list silently going stale as new cameras ship.
    /// Case-insensitive on the extension, matching every other extension
    /// check in this codebase (`PhotoImporter.supportedExtensions` et al.).
    static func isRaw(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    /// EXIF/TIFF orientation for `url`, or `.up` if it can't be read —
    /// moved here from `ImageDocumentModel` (its only remaining caller is
    /// this file's own `decode(contentsOf:)`, for the non-RAW path).
    static func exifOrientation(of url: URL) -> CGImagePropertyOrientation {
        readExifOrientation(of: url) ?? .up
    }

    /// Same lookup, but `nil` — not `.up` — when nothing could be read.
    /// Used only by the RAW paths below, where silently substituting `.up`
    /// on a read failure would be actively harmful rather than merely
    /// imprecise: `CIRAWFilter.orientation` already defaults to the file's
    /// own correct EXIF value on its own (measured live against a real
    /// non-identity-orientation NEF — its default `orientation` already
    /// matched ImageIO's independently-read value, and `outputImage` was
    /// already rotated accordingly), so this is only ever assigned when a
    /// value was actually read — never used to overwrite an already-correct
    /// default with a wrong guess for a RAW container ImageIO parses
    /// differently than Core Image's RAW decoder does.
    private static func readExifOrientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return nil
        }
        return orientation
    }

    /// Decodes any file this app can open to a `CIImage`, EXIF orientation
    /// applied. Non-RAW files keep the exact prior behavior
    /// (`CIImage(contentsOf:).oriented(...)`) byte-for-byte. RAW files go
    /// through `CIRAWFilter`, which does NOT need `.oriented(_:)` chained
    /// afterward — see `readExifOrientation`'s doc comment above.
    static func decode(contentsOf url: URL) -> CIImage? {
        guard isRaw(url) else {
            return CIImage(contentsOf: url)?.oriented(exifOrientation(of: url))
        }
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if let orientation = readExifOrientation(of: url) {
            filter.orientation = orientation
        }
        return filter.outputImage
    }

    /// A fast, lower-quality RAW decode for thumbnails, via `CIRAWFilter`'s
    /// own `isDraftModeEnabled`/`scaleFactor` — exactly what Apple provides
    /// draft mode for, rather than decoding every RAW file at full
    /// resolution just to downsize it afterward. Only meaningful for RAW
    /// files; callers are expected to have already checked `isRaw(url)`
    /// (mirrors `ThumbnailGenerator`'s own non-RAW path, which never calls
    /// this).
    static func decodeDraft(contentsOf url: URL, maxPixelSize: Int) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if let orientation = readExifOrientation(of: url) {
            filter.orientation = orientation
        }
        filter.isDraftModeEnabled = true
        let longestSide = max(filter.nativeSize.width, filter.nativeSize.height)
        if maxPixelSize > 0, longestSide > 0 {
            // Clamped to 1 — `scaleFactor` only ever downsizes (Apple's own
            // header documents its valid range as 0...1); a thumbnail
            // request larger than the native image should return the
            // native size, not upscale.
            filter.scaleFactor = min(1, Float(CGFloat(maxPixelSize) / longestSide))
        }
        return filter.outputImage
    }
}
