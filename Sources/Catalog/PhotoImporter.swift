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

    /// A symlinked directory is never recursed into here, but not because
    /// of any special-case guard: `URL.resourceValues(forKeys:
    /// [.isDirectoryKey])` reports the LINK's own type (lstat semantics),
    /// not the resolved target's — a symlink to a directory reports
    /// `isDirectory == false`, same as a symlink to a file, verified
    /// directly (a small standalone script against real on-disk symlinks,
    /// not assumed from documentation) rather than trusted from a
    /// plausible-sounding first-draft comment that turned out to describe
    /// the OPPOSITE of Foundation's real behavior. So `scanNode` was never
    /// actually vulnerable to unbounded recursion through a symlink cycle
    /// — a symlinked entry falls to the `else` branch below and is
    /// silently excluded (no image extension), never appended to
    /// `children`. `Tests/CatalogTests/PhotoImporterTests.swift`'s
    /// symlink-cycle tests exist as regression PINS for this real,
    /// already-correct, easy-to-accidentally-regress behavior (e.g. if a
    /// future change swapped in `resolvingSymlinksInPath()` or a
    /// `FileManager` option that follows links) — not as evidence of a
    /// bug this function once had.
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

    // MARK: - Missing-file detection (D5, IMPROVEMENTS.md)

    /// Returns the root in `activeFolders` that `path` sits under, if any —
    /// `nil` if none matches. `activeFolders` is the set of root folder
    /// paths `CatalogModel` currently holds confirmed security-scoped
    /// access to (see `CatalogModel.activateKnownFolders`). A photo whose
    /// file isn't under any confirmed-active folder can't be reliably
    /// checked for on-disk existence: a bookmark that failed to activate
    /// (or went stale) looks identical to "file deleted" from this
    /// process's point of view — macOS sandboxing deliberately doesn't
    /// leak the difference.
    ///
    /// Returning the matched ROOT (not just a `Bool`) matters,
    /// reviewer-caught: `activeFolders` is insert-only — nothing ever
    /// removes an entry once `startAccessingSecurityScopedResource()`
    /// succeeds, even if the volume is later ejected or the root itself
    /// is deleted/renamed out from under the app mid-session. So "this
    /// root is in `activeFolders`" only proves access was granted at SOME
    /// point this session, not that it's reachable right now. The caller
    /// (`CatalogModel.isPhotoConfirmedMissing(_:)`) additionally checks
    /// that the returned root itself still exists before trusting a
    /// negative existence check on the photo — "root present, this one
    /// file gone" is a genuine delete; "root itself gone/unmounted" is
    /// unverifiable and must not be reported as a missing photo.
    ///
    /// Extracted as a `static` function taking `activeFolders` explicitly,
    /// not just a `CatalogModel` instance method, so it's directly
    /// unit-testable with plain `Set<String>` literals —
    /// `CatalogModel.init(database:)` deliberately skips
    /// `activateKnownFolders()` in tests (it touches `UserDefaults`/real
    /// security scopes), so there'd be no way to exercise this gating
    /// logic through the model alone.
    ///
    /// The `+ "/"` suffix matters: without it, an active folder
    /// `/Users/x/Trip` would wrongly match a sibling
    /// `/Users/x/Trip2/photo.jpg`. Folder-tree imports only bookmark the
    /// ROOT (`CatalogModel.importFolderTree`), so a photo several levels
    /// deep under that root must still match — a plain prefix check
    /// (not exact-parent-only) is what makes that work.
    ///
    /// When MULTIPLE active roots match (e.g. a flat import of
    /// `/Trip/Day1` followed later by a tree import of `/Trip` itself —
    /// both end up in `activeFolders`), picks the LONGEST matching prefix
    /// rather than an arbitrary one — reviewer-caught: `Set` has no
    /// defined iteration order, so `.first` would make the result (and
    /// therefore whether a deleted `Day1` photo reads as missing) depend
    /// on hash-seed-driven iteration order rather than which root is
    /// actually the nearest, most specific match.
    static func confirmedActiveFolderRoot(forPhotoAt path: String, activeFolders: Set<String>) -> String? {
        activeFolders
            .filter { path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    // MARK: - Relocating missing photos (D5 follow-up, IMPROVEMENTS.md)

    /// Matches each of `photos` to a same-named file in `folder` — a
    /// SHALLOW scan via `imageFiles(in:)` (not `scanFolderTree`), so this
    /// folder itself can't contain two files sharing an EXACT-case name —
    /// the ambiguity a recursive scan would introduce doesn't apply here.
    /// Matched case-INSENSITIVELY via a lowercased dictionary key, mainly
    /// for APFS's own default case-insensitive-but-preserving behavior —
    /// but reviewer-caught: on a case-SENSITIVE volume (case-sensitive
    /// APFS, most SMB/NFS shares), `Photo.JPG` and `photo.jpg` coexisting
    /// in one folder WOULD collide on this lowercased key, and whichever
    /// `imageFiles(in:)` happens to enumerate last silently wins — an
    /// accepted, narrow gap for this slice, not solved (a full fix would
    /// need to know the destination volume's case-sensitivity, which
    /// nothing else in this codebase currently checks).
    ///
    /// Matches by NAME only, not content — a same-named-but-different
    /// file in the chosen folder would be wrongly adopted. Accepted for
    /// this slice, flagged not solved: content-hash matching would
    /// correctly reject that case but is a much bigger feature, and
    /// filename is already what every other identity check in this
    /// codebase relies on (`Photo.filename`, `insertPhotoIfNeeded`'s own
    /// `path`-based re-import idempotency).
    ///
    /// Returns the matched `(photoID, newPath)` pairs plus a count of
    /// photos with no match found (including any with a `nil` `id`,
    /// which can never be matched at all — reviewer-caught: the original
    /// draft silently dropped those from the count instead), so the
    /// caller can report a partial-success summary.
    static func matchByFilename(
        _ photos: [Photo], in folder: URL
    ) -> (moves: [(photoID: Int64, newPath: String)], unmatchedCount: Int) {
        var byLowercasedName: [String: URL] = [:]
        for url in imageFiles(in: folder) {
            byLowercasedName[url.lastPathComponent.lowercased()] = url
        }
        var moves: [(photoID: Int64, newPath: String)] = []
        var unmatchedCount = 0
        for photo in photos {
            guard let id = photo.id, let match = byLowercasedName[photo.filename.lowercased()] else {
                unmatchedCount += 1
                continue
            }
            moves.append((id, match.path))
        }
        return (moves, unmatchedCount)
    }
}
