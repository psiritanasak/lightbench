import Foundation

/// One folder discovered during a recursive scan: the image files
/// directly inside it (not in any subfolder) and its child folders,
/// recursively — the shape `CatalogDatabase.importFolderTree` walks to
/// build a matching collection tree. File-scope (not nested in
/// `PhotoImporter`) so `CatalogDatabase.swift` can reference it directly.
struct FolderScanNode: Sendable {
    let url: URL
    let imageFiles: [URL]
    let children: [FolderScanNode]
}

/// Pure, testable folder scanning — no UI, no DB. Kept separate from
/// `CatalogDatabase` so the "which files count as photos" logic can be
/// unit-tested without touching SQLite (`Tests/CatalogTests/PhotoImporterTests.swift`).
enum PhotoImporter {
    /// The non-RAW extensions this app can already open, mirrored from
    /// `ImageDocumentModel.openImage()`'s `allowedContentTypes`
    /// (`.jpeg, .png, .tiff, .heic`), plus the common `jpg` alias. RAW files
    /// are a second, separate rule — see `isSupportedImage(_:)` — classified
    /// via `RawDecoder.isRaw`'s UTType check rather than added to this
    /// literal set, so RAW coverage tracks whatever formats the OS knows
    /// about instead of needing this list hand-maintained per camera brand.
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

    /// True if `url` is an image file this app can import: either one of
    /// `supportedExtensions`, or a camera RAW file per `RawDecoder.isRaw`.
    static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || RawDecoder.isRaw(url)
    }

    /// Shallow scan of `folder` for image files, matched case-insensitively
    /// on extension. Excludes this app's own sidecar files
    /// (`*.photoapp.json`) and anything else that isn't a supported image
    /// type — a folder containing edit sidecars alongside photos (the
    /// normal state once sidecar persistence has run) must not catalogue
    /// the sidecars themselves.
    static func imageFiles(in folder: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { isSupportedImage($0) }
    }

    // MARK: - Folder-mirrored nested collections

    /// Recursively scans `root`. A subfolder with no images anywhere in
    /// its OWN subtree is excluded from `children` entirely — keeps the
    /// resulting tree free of empty dead-end branches (e.g. a folder of
    /// only `.txt` files, or an entirely empty year folder). Returns
    /// `nil` if `root` itself has no images anywhere in its subtree
    /// (nothing to import), matching `imageFiles(in:)`'s "return empty,
    /// don't throw" behavior for an unreadable/empty folder.
    static func scanFolderTree(at root: URL) -> FolderScanNode? {
        let node = scanNode(at: root)
        return node.imageFiles.isEmpty && node.children.isEmpty ? nil : node
    }

    private static func scanNode(at folder: URL) -> FolderScanNode {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FolderScanNode(url: folder, imageFiles: [], children: [])
        }

        var imageFiles: [URL] = []
        var children: [FolderScanNode] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let child = scanNode(at: entry)
                if !child.imageFiles.isEmpty || !child.children.isEmpty {
                    children.append(child)
                }
            } else if isSupportedImage(entry) {
                imageFiles.append(entry)
            }
        }
        return FolderScanNode(url: folder, imageFiles: imageFiles, children: children)
    }
}
