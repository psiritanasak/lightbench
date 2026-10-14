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

    private static func bag(_ metadata: CGImageMetadata, _ path: String) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return nil }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }
}
