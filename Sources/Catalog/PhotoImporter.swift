import Foundation

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
}
