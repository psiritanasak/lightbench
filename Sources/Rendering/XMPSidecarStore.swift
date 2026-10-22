import Foundation
import ImageIO

/// Reads and writes standard `.xmp` sidecars for the Library fields in `XMPLibraryFields`. Pure file I/O, no UI,
/// no security-scope handling (callers hold folder access, like `SidecarStore`). WRITING IS A MERGE: the existing packet
/// is parsed, only our three tags are set or removed, and the other tags (Camera Raw `crs:`, `lr:` ...) are kept
/// SEMANTICALLY (the constructs in `XMPSidecarProbeTests`, plus nested Camera Raw structures in a reviewer's scratch probe);
/// the file is re-serialised by ImageIO, so it is not byte-preserved (the `xpacket` wrapper is dropped, attributes may become
/// elements). Not compare-and-swap: a concurrent write by another app between our read and write is lost. A packet that exists but cannot be read or parsed is never overwritten.
enum XMPSidecarStore {
    enum ReadResult: Equatable {
        case missing
        case decoded(XMPLibraryFields)
        /// A sidecar file exists but could not be read or parsed. Never treat as safe to overwrite.
        case undecodable
    }

    enum WriteError: Error, Equatable {
        case unreadableExisting
        case couldNotSerialise
        /// Nothing to write into a sidecar that does not exist yet (every field removed or absent).
        case nothingToWrite
        /// ImageIO refused to set or remove one of our tags; nothing was written.
        case couldNotApply
        case writeFailed
    }

    /// Adobe's name: `IMG_1.CR2` -> `IMG_1.xmp`.
    static func sidecarURL(for photoURL: URL) -> URL { photoURL.deletingPathExtension().appendingPathExtension("xmp") }

    /// darktable / digiKam style: `IMG_1.CR2` -> `IMG_1.CR2.xmp`. Read as a fallback, written only if it is the one that exists.
    static func alternateSidecarURL(for photoURL: URL) -> URL { photoURL.appendingPathExtension("xmp") }

    /// The file a write goes to: the alternate name only when it exists and the Adobe name does not.
    static func writeTarget(for photoURL: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let primary = sidecarURL(for: photoURL)
        let alternate = alternateSidecarURL(for: photoURL)
        return (!fileExists(primary) && fileExists(alternate)) ? alternate : primary
    }

    // MARK: Read

    static func read(forPhotoAt photoURL: URL) -> ReadResult {
        let fm = FileManager.default
        for url in [sidecarURL(for: photoURL), alternateSidecarURL(for: photoURL)] where fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let fields = fields(fromXMP: data) else { return .undecodable }
            return .decoded(fields)
        }
        return .missing
    }

    /// XMP embedded in the photo itself (a Lightroom-exported JPEG, a DNG). nil when there is none or it holds none of our fields.
    static func readEmbedded(forPhotoAt photoURL: URL) -> XMPLibraryFields? {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        let fields = fields(from: metadata)
        return fields.isEmpty ? nil : fields
    }

    /// nil when `data` is not a parseable XMP packet.
    static func fields(fromXMP data: Data) -> XMPLibraryFields? {
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return fields(from: metadata)
    }

    static func fields(from metadata: CGImageMetadata) -> XMPLibraryFields {
        var out = XMPLibraryFields()
        if let text = string(metadata, "xmp:Rating"), let parsed = XMPLibraryFields.parseRating(text) {
            out.rating = parsed.rating
            out.isRejected = parsed.isRejected
        }
        if let text = string(metadata, "xmp:Label"), let label = XMPLibraryFields.label(fromName: text) { out.label = label }
        if let words = bag(metadata, "dc:subject") { out.keywords = words }
        out.title = langAlt(metadata, "dc:title")
        out.caption = langAlt(metadata, "dc:description")
        out.copyright = langAlt(metadata, "dc:rights")
        // A file with several creators (an ordered array) is shown joined; `merge` leaves such an array alone when the Library value equals it.
        out.creator = bag(metadata, "dc:creator").map { $0.joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 }
        return out
    }

    // MARK: Write (merge)

    /// The merged packet: `existing` (nil = start fresh) with our non-nil fields applied. Throws `.unreadableExisting` if `existing` does not parse.
    /// `fields.label == .some(.none)` removes the label tag; an empty `keywords` array removes the bag.
    static func merge(_ fields: XMPLibraryFields, intoExisting existing: Data?) throws -> Data {
        let mutable: CGMutableImageMetadata
        if let existing {
            guard let parsed = CGImageMetadataCreateFromXMPData(existing as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(parsed) else { throw WriteError.unreadableExisting }
            mutable = copy
        } else {
            mutable = CGImageMetadataCreateMutable()
        }
        if let rating = fields.rating {
            let text = XMPLibraryFields.ratingText(rating: rating, isRejected: fields.isRejected ?? false)
            try setValue(mutable, "xmp:Rating", text)
        } else if fields.isRejected == true {
            try setValue(mutable, "xmp:Rating", "-1")
        } else if fields.isRejected == false, let existing = string(mutable, "xmp:Rating"), XMPLibraryFields.parseRating(existing)?.isRejected == true {
            // Un-rejected in the Library with no stars to write: clear the file's Reject marker without inventing a rating.
            try setValue(mutable, "xmp:Rating", "0")
        }
        if let label = fields.label {
            if let name = XMPLibraryFields.labelName(label) {
                try setValue(mutable, "xmp:Label", name)
            } else if let existing = string(mutable, "xmp:Label"), XMPLibraryFields.label(fromName: existing) != nil {
                // "No label" only removes a label we understand; an unknown one (a localised or custom Bridge label) is foreign and stays.
                try removeTag(mutable, "xmp:Label")
            }
        }
        if let keywords = fields.keywords {
            if keywords.isEmpty {
                try removeTag(mutable, "dc:subject")
            } else {
                guard let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                         "subject" as CFString, .arrayUnordered, keywords as CFArray),
                      CGImageMetadataSetTagWithPath(mutable, nil, "dc:subject" as CFString, tag) else { throw WriteError.couldNotApply }
            }
        }
        try setLangAlt(mutable, "title", fields.title)
        try setLangAlt(mutable, "description", fields.caption)
        try setLangAlt(mutable, "rights", fields.copyright)
        if let creator = fields.creator, !creator.isEmpty,
           // Normalised like the Library value: a Read followed by a Write must not collapse a multi-author array over a spacing difference.
           InfoText.normalize((bag(mutable, "dc:creator") ?? []).joined(separator: ", "), field: .creator) != creator {
            guard let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                     "creator" as CFString, .arrayOrdered, [creator] as CFArray),
                  CGImageMetadataSetTagWithPath(mutable, nil, "dc:creator" as CFString, tag) else { throw WriteError.couldNotApply }
        }
        guard let data = CGImageMetadataCreateXMPData(mutable, nil) else {
            throw existing == nil ? WriteError.nothingToWrite : WriteError.couldNotSerialise
        }
        return data as Data
    }

    /// Merges `fields` into the photo's sidecar and writes it atomically. Returns the file written, or nil when there was
    /// nothing to write (no sidecar exists and the fields only remove or leave tags alone) — no empty file is created.
    @discardableResult
    static func write(_ fields: XMPLibraryFields, forPhotoAt photoURL: URL) throws -> URL? {
        let target = writeTarget(for: photoURL)
        var existing: Data?
        if FileManager.default.fileExists(atPath: target.path) {
            guard let data = try? Data(contentsOf: target) else { throw WriteError.unreadableExisting }
            existing = data
        }
        let merged: Data
        do { merged = try merge(fields, intoExisting: existing) } catch WriteError.nothingToWrite { return nil }
        do { try merged.write(to: target, options: .atomic) } catch { throw WriteError.writeFailed }
        return target
    }

    // MARK: Helpers

    private static func setValue(_ metadata: CGMutableImageMetadata, _ path: String, _ value: String) throws {
        guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString) else { throw WriteError.couldNotApply }
    }

    /// Removing a tag that is not there counts as success.
    private static func removeTag(_ metadata: CGMutableImageMetadata, _ path: String) throws {
        guard CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) != nil else { return }
        guard CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) else { throw WriteError.couldNotApply }
    }

    private static func string(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
        return CGImageMetadataTagCopyValue(tag) as? String
    }

    /// The text of a language alternative: the `x-default` entry, else the first one. Empty text is nil (absent).
    private static func langAlt(_ metadata: CGImageMetadata, _ path: String) -> String? {
        let entries = langAltEntries(metadata, path)
        let text = (entries.first { isDefaultLang($0.lang) } ?? entries.first)?.text
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func langAltEntries(_ metadata: CGImageMetadata, _ path: String) -> [(lang: String?, text: String)] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return values.compactMap { entry in
            guard let text = CGImageMetadataTagCopyValue(entry) as? String else { return nil }
            let qualifiers = CGImageMetadataTagCopyQualifiers(entry) as? [CGImageMetadataTag]
            let lang = qualifiers?.first { CGImageMetadataTagCopyName($0) as String? == "lang" }
                .flatMap { CGImageMetadataTagCopyValue($0) as? String }
            return (lang, text)
        }
    }

    /// Sets the `x-default` entry of `dc:<name>` to `value`, keeping its other-language entries. nil or empty `value` leaves the tag
    /// alone; so does a value equal to the current `x-default`. ImageIO has no working way to set a language alternative by path
    /// (a plain set empties an existing one and a fresh one becomes a simple property: `XMPSidecarProbeTests`), so the alternative
    /// is parsed from a small packet and its tag copied in.
    private static func setLangAlt(_ metadata: CGMutableImageMetadata, _ name: String, _ value: String?) throws {
        guard let value, !value.isEmpty else { return }
        let path = "dc:\(name)"
        let existing = langAltEntries(metadata, path)
        if existing.first(where: { isDefaultLang($0.lang) })?.text == value { return }
        var entries = ["<rdf:li xml:lang=\"x-default\">\(xmlEscaped(value))</rdf:li>"]
        for other in existing where !isDefaultLang(other.lang) {
            // An entry with no language is kept as it was (no attribute), not dropped.
            let attribute = other.lang.map { " xml:lang=\"\(xmlEscaped($0))\"" } ?? ""
            entries.append("<rdf:li\(attribute)>\(xmlEscaped(other.text))</rdf:li>")
        }
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:\(name)><rdf:Alt>"
            + entries.joined() + "</rdf:Alt></dc:\(name)></rdf:Description></rdf:RDF></x:xmpmeta>"
        guard let parsed = CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData),
              let tag = CGImageMetadataCopyTagWithPath(parsed, nil, path as CFString),
              CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag) else { throw WriteError.couldNotApply }
    }

    /// XMP language tags are case-insensitive (`X-Default` is the default entry too).
    private static func isDefaultLang(_ lang: String?) -> Bool { lang?.lowercased() == "x-default" }

    private static func xmlEscaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func bag(_ metadata: CGImageMetadata, _ path: String) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return nil }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }
}
