import Foundation
import ImageIO

/// Reads the camera data the Library search understands (see `PhotoMetadata`) from a file's EXIF/TIFF header through
/// ImageIO: one `CGImageSourceCopyPropertiesAtIndex` per file, header only, no pixels decoded. RAW (NEF) goes through the
/// same call as JPEG/HEIC/TIFF. Callers must hold the photo's folder scope (an unreadable file yields nil).
///
/// Every field is optional and sanitised: zero/negative numbers (cameras write 0 for "unknown"), blank strings and
/// impossible dates become nil rather than being stored as values that would match a search.
enum PhotoMetadataReader {
    struct Fields: Equatable, Sendable {
        /// Seconds since 1970 with the camera's wall-clock digits placed in UTC (see `PhotoMetadata.captureDate`).
        var captureDate: Double?
        var iso: Int?
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        var focalLength: Double?
        var aperture: Double?
        var shutter: Double?
        /// As stored in the file, BEFORE any EXIF orientation is applied.
        var pixelWidth: Int?
        var pixelHeight: Int?

        static let empty = Fields()
    }

    /// The fields of `url`, or nil when ImageIO cannot open it as an image at all.
    static func read(from url: URL) -> Fields? {
        // Header only: never decode or cache pixels.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return fields(from: props)
    }

    /// The pure part, so it can be tested without files.
    static func fields(from props: [CFString: Any]) -> Fields {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        var fields = Fields()
        fields.captureDate = CaptureDate.exifDate(inProperties: props)?.timeIntervalSince1970
        fields.iso = iso(from: exif)
        fields.cameraMake = text(tiff?[kCGImagePropertyTIFFMake])
        fields.cameraModel = text(tiff?[kCGImagePropertyTIFFModel])
        // A D610 NEF has no EXIF `LensModel`, but ImageIO's ExifAux dictionary carries it (verified read-only on a real NEF by the reviewer).
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        fields.lens = text(exif?[kCGImagePropertyExifLensModel]) ?? text(aux?[kCGImagePropertyExifAuxLensModel])
        fields.focalLength = positive(exif?[kCGImagePropertyExifFocalLength])
        fields.aperture = positive(exif?[kCGImagePropertyExifFNumber])
        fields.shutter = positive(exif?[kCGImagePropertyExifExposureTime])
        fields.pixelWidth = positiveInt(props[kCGImagePropertyPixelWidth])
        fields.pixelHeight = positiveInt(props[kCGImagePropertyPixelHeight])
        return fields
    }

    private static func iso(from exif: [CFString: Any]?) -> Int? {
        // EXIF caps `ISOSpeedRatings` at 65535: that value means "higher, see ISOSpeed".
        if let ratings = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any] {
            for case let value in ratings {
                if let iso = positiveInt(value), iso < 65535 { return iso }
            }
        }
        // Newer cameras (and some phones) write the standard-output-sensitivity style `ISOSpeed` tag instead.
        if let speed = positiveInt(exif?[kCGImagePropertyExifISOSpeed]) { return speed }
        if let ratings = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any] {
            for case let value in ratings { if let iso = positiveInt(value) { return iso } }
        }
        return nil
    }

    /// Trimmed text, cut at the first NUL (fixed-length EXIF ASCII fields are NUL padded, sometimes with junk after it).
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let head = string.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 1, number < 1e9 else { return nil }
        return Int(number.rounded())
    }
}
