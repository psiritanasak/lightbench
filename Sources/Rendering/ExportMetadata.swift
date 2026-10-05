import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an exported file keeps of its source's metadata (camera EXIF, GPS location, IPTC captions…).
/// Before this existed, export silently kept ALL of it — including GPS — and also left the source's Orientation tag
/// on pixels the renderer had already rotated upright (measured 2026-10-02: a source tagged Orientation 6 exported
/// with rotated pixels AND Orientation 6, so a viewer honouring the tag would rotate it a second time).
enum ExportMetadataPolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Keep everything the source had, GPS location included (what export did before the policy existed, minus the stale
    /// Orientation). No longer the default.
    case all
    /// Keep everything except location (GPS and the IPTC place fields).
    case withoutLocation
    /// Keep no descriptive metadata at all (the colour profile is not metadata and is always kept).
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All metadata"
        case .withoutLocation: return "All except location"
        case .none: return "None"
        }
    }
}

enum ExportMetadata {
    /// Top-level keys that describe the pixel data itself, not the photo — kept under every policy.
    private static let structuralKeys: Set<String> = [
        kCGImagePropertyColorModel as String, kCGImagePropertyDepth as String, kCGImagePropertyDPIWidth as String,
        kCGImagePropertyDPIHeight as String, kCGImagePropertyPixelWidth as String,
        kCGImagePropertyPixelHeight as String, kCGImagePropertyProfileName as String,
        kCGImagePropertyHasAlpha as String, kCGImagePropertyIsFloat as String, kCGImagePropertyIsIndexed as String,
    ]
    // Deliberately NOT structural: `{PNG}` (carries text chunks — Author, Copyright, Description, Title, Comment —
    // which ImageIO also mirrors into IPTC/TIFF; measured leaking under a draft of `.none`) and `{JFIF}`. The writer
    // creates its own structural chunks for the file it writes.

    /// PNG colour chunks describing the SOURCE's encoding. The output's profile comes from `ExportColorSpace`, so a
    /// copied sRGB gAMA/cHRM would contradict a Display P3 / Adobe RGB `iCCP`. Dropped under every policy.
    private static let pngColourKeys: [String] = [
        kCGImagePropertyPNGGamma as String, kCGImagePropertyPNGChromaticities as String,
        kCGImagePropertyPNGsRGBIntent as String, kCGImagePropertyPNGInterlaceType as String,
    ]

    /// IPTC fields that name a place (the GPS dictionary is dropped separately).
    private static let iptcLocationKeys: [String] = [
        kCGImagePropertyIPTCSubLocation as String, kCGImagePropertyIPTCCity as String, kCGImagePropertyIPTCProvinceState as String,
        kCGImagePropertyIPTCCountryPrimaryLocationCode as String, kCGImagePropertyIPTCCountryPrimaryLocationName as String,
        kCGImagePropertyIPTCContentLocationCode as String, kCGImagePropertyIPTCContentLocationName as String,
        kCGImagePropertyIPTCExtLocationCreated as String, kCGImagePropertyIPTCExtLocationShown as String,
    ]

    /// The image properties to write for `original` (the source image's own properties) under `policy`.
    ///
    /// Orientation is ALWAYS reset to 1: the renderer bakes EXIF orientation into the pixels, so a surviving tag
    /// makes viewers rotate an already-upright image a second time. `.none` is an ALLOWLIST (only the structural
    /// keys survive), so an unfamiliar metadata dictionary — a maker note, a RAW dictionary — can never leak
    /// through by being missing from a blocklist. `.withoutLocation` is a blocklist and therefore only as complete
    /// as `iptcLocationKeys`.
    ///
    /// `original` is the decoded image's own `properties`. For a RAW source that comes from `CIRAWFilter`'s output;
    /// whether it carries the file's EXIF is UNVERIFIED (no RAW fixture in this suite), so a RAW export may carry
    /// less than "All metadata" implies — never more than the policy allows.
    static func properties(from original: [String: Any], policy: ExportMetadataPolicy) -> [String: Any] {
        var result: [String: Any]
        switch policy {
        case .all:
            result = original
        case .withoutLocation:
            result = original
            result[kCGImagePropertyGPSDictionary as String] = nil
            if var iptc = result[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
                for key in iptcLocationKeys { iptc[key] = nil }
                result[kCGImagePropertyIPTCDictionary as String] = iptc
            }
        case .none:
            result = original.filter { structuralKeys.contains($0.key) }
        }
        if var png = result[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            for key in pngColourKeys { png[key] = nil }
            result[kCGImagePropertyPNGDictionary as String] = png
        }
        result[kCGImagePropertyOrientation as String] = 1
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return result
    }
}
