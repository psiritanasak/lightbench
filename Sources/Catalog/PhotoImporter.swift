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
    /// The extensions this app can already open, mirrored from
    /// `ImageDocumentModel.openImage()`'s `allowedContentTypes`
    /// (`.jpeg, .png, .tiff, .heic`), plus the common `jpg` alias.
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

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
        return entries.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
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
            } else if supportedExtensions.contains(entry.pathExtension.lowercased()) {
                imageFiles.append(entry)
            }
        }
        return FolderScanNode(url: folder, imageFiles: imageFiles, children: children)
    }
}
