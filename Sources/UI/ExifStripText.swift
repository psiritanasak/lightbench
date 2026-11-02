import Foundation

/// Pure text for the Editor's pinned EXIF strip: "ISO 800 · 50 mm · f/2.8 · 1/250 s" and an optional "camera · lens" line.
/// Missing fields are skipped; a line with nothing to show is nil.
enum ExifStripText {
    static let separator = " · "

    /// Only finite, positive numbers are shown; anything else is skipped like a missing field.
    private static func usable(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func exposureLine(_ fields: PhotoMetadataReader.Fields) -> String? {
        var parts: [String] = []
        if let iso = fields.iso { parts.append("ISO \(iso)") }
        if let focal = usable(fields.focalLength) { parts.append(focalLength(focal)) }
        if let aperture = usable(fields.aperture) { parts.append(Self.aperture(aperture)) }
        if let shutter = usable(fields.shutter) { parts.append(Self.shutter(shutter)) }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    static func cameraLine(_ fields: PhotoMetadataReader.Fields) -> String? {
        let parts = [PhotoMetadata.cameraName(make: fields.cameraMake, model: fields.cameraModel), fields.lens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// Fast speeds as a fraction ("1/250 s"), slow ones (0.4 s and longer) as decimal seconds ("0.5 s", "30 s").
    static func shutter(_ seconds: Double) -> String {
        if seconds.isFinite, seconds > 0, seconds < 0.4 {
            let denominator = (1 / seconds).rounded()
            if denominator < 1e9 { return "1/\(Int(denominator)) s" }
        }
        return "\(trimmed(seconds)) s"
    }

    static func aperture(_ fNumber: Double) -> String { "f/\(trimmed(fNumber))" }

    static func focalLength(_ millimetres: Double) -> String { "\(trimmed(millimetres)) mm" }

    /// One decimal at most, no trailing ".0". Non-finite or huge values fall back to `%g` (never a trapping `Int` conversion).
    private static func trimmed(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return String(format: "%g", value) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
