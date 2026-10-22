import Foundation
import ImageIO

/// Embeds a photo's Library info (title, caption, creator, copyright) in an EXPORTED file (never in the original).
/// The values go into the image properties' IPTC dictionary (`ObjectName`, `Caption/Abstract`, `By-line`,
/// `CopyrightNotice`); ImageIO's writers then also emit the TIFF `Artist`/`Copyright`/`ImageDescription` tags and an
/// XMP packet with `dc:title`, `dc:description`, `dc:creator` and `dc:rights` — measured for JPEG, PNG, TIFF and HEIC
/// in `InfoEmbeddingTests.testWritersEmitIPTCTIFFAndXMPForEveryFormat`.
enum InfoEmbedding {
    private static let iptcKey = kCGImagePropertyIPTCDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String
    private static let pngKey = kCGImagePropertyPNGDictionary as String

    /// `properties` (already filtered by `ExportMetadata.properties`) with the non-empty Library values written over
    /// whatever the source carried. Returned UNCHANGED when `include` is off, when the policy is `.none` (an allowlist
    /// that promises no descriptive metadata: the option is ignored there, nothing of the info may leak) or when the
    /// info has no value. An EMPTY Library field leaves the source's own value alone.
    ///
    /// ImageIO reconciles IPTC, TIFF and PNG text on write, so a source value left in the TIFF/PNG dictionary could
    /// out-vote the IPTC one. Where the source already carries such a key it is overwritten with the Library value;
    /// no TIFF/PNG key is added where there was none (the IPTC entry is enough, measured).
    static func properties(
        _ properties: [String: Any], adding info: PhotoInfo, policy: ExportMetadataPolicy, include: Bool
    ) -> [String: Any] {
        guard include, policy != .none, !info.isEmpty else { return properties }
        var result = properties
        var iptc = result[iptcKey] as? [String: Any] ?? [:]
        var tiff = result[tiffKey] as? [String: Any]
        var png = result[pngKey] as? [String: Any]

        func replaceExisting(_ dict: inout [String: Any]?, _ key: CFString, _ value: String) {
            guard dict?[key as String] != nil else { return }
            dict?[key as String] = value
        }

        if !info.title.isEmpty {
            iptc[kCGImagePropertyIPTCObjectName as String] = info.title
            replaceExisting(&png, kCGImagePropertyPNGTitle, info.title)
        }
        if !info.caption.isEmpty {
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = info.caption
            replaceExisting(&tiff, kCGImagePropertyTIFFImageDescription, info.caption)
            replaceExisting(&png, kCGImagePropertyPNGDescription, info.caption)
        }
        if !info.creator.isEmpty {
            iptc[kCGImagePropertyIPTCByline as String] = [info.creator]
            replaceExisting(&tiff, kCGImagePropertyTIFFArtist, info.creator)
            replaceExisting(&png, kCGImagePropertyPNGAuthor, info.creator)
        }
        if !info.copyright.isEmpty {
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = info.copyright
            replaceExisting(&tiff, kCGImagePropertyTIFFCopyright, info.copyright)
            replaceExisting(&png, kCGImagePropertyPNGCopyright, info.copyright)
        }
        result[iptcKey] = iptc
        if let tiff { result[tiffKey] = tiff }
        if let png { result[pngKey] = png }
        return result
    }
}
