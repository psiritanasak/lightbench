import Foundation

/// Adobe's sidecar name replaces the extension (`IMG_1.xmp`), so `IMG_1.CR2` and `IMG_1.JPG` in one folder
/// would share ONE file. This decides which photo owns it: a RAW file wins (that is what Lightroom/Bridge do),
/// otherwise the first by name. Pure; the caller passes EVERY catalogued photo in the folder, not just the selection,
/// so a JPEG can never write into the xmp of an unselected RAW sibling.
enum XMPSidecarOwnership {
    static func key(for url: URL) -> String {
        url.deletingPathExtension().standardizedFileURL.path.lowercased()
    }

    /// The photo that owns `url`'s `<base>.xmp` among `candidates` (which should include `url` itself).
    static func owner(of url: URL, among candidates: [URL], isRaw: (URL) -> Bool = RawDecoder.isRaw) -> URL {
        let k = key(for: url)
        let group = ([url] + candidates).filter { key(for: $0) == k }
        let unique = Dictionary(group.map { ($0.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
            .values.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return unique.first(where: isRaw) ?? unique.first ?? url
    }

    /// Splits `selected` into the photos that may write (they own their sidecar) and those skipped, with the owner each defers to.
    static func partition(selected: [URL], allPhotos: [URL], isRaw: (URL) -> Bool = RawDecoder.isRaw)
        -> (writers: [URL], skipped: [(photo: URL, owner: URL)]) {
        var writers: [URL] = []
        var skipped: [(photo: URL, owner: URL)] = []
        for url in selected {
            let owner = owner(of: url, among: allPhotos, isRaw: isRaw)
            if owner.standardizedFileURL.path == url.standardizedFileURL.path { writers.append(url) } else { skipped.append((url, owner)) }
        }
        return (writers, skipped)
    }
}
