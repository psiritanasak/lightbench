import AppKit
import Foundation

/// Which photos the Library grid shows. A non-optional enum rather than
/// `Int64?` (`nil` = All Photos) — SwiftUI's `List(selection:)` on macOS
/// was measured LIVE to be unreliable when a row is tagged with the `nil`
/// case of an `Optional` selection binding: after selecting a real
/// collection, tapping back to the `nil`-tagged "All Photos" row silently
/// failed to register. A plain, always-non-nil enum sidesteps that
/// specific selection-binding quirk entirely (every row's tag is a
/// concrete, non-optional value).
enum LibraryFilter: Hashable, Sendable {
    case allPhotos
    case collection(Int64)
}

/// The UI-facing wrapper around `CatalogDatabase` — deliberately kept in
/// `Sources/UI`, not `Sources/Catalog`, so the Catalog module itself stays
/// free of SwiftUI/AppKit (`CLAUDE.md`: "Keep modules separated... No UI
/// imports in EditEngine" — the same principle applies to Catalog).
///
/// Phase 4 slice 1 added the DB + basic import; slice 2 (this) adds the
/// browsing surface: a published `photos` list for a grid, thumbnail
/// decoding, and persisted read access to imported folders so both keep
/// working after a relaunch.
@MainActor
final class CatalogModel: ObservableObject {
    @Published private(set) var photoCount: Int = 0
    @Published var importStatusMessage: String?
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var collections: [PhotoCollection] = []
    /// Which photos `photos` reflects. Setting this re-filters `photos` —
    /// see `didSet` below and `refresh()`.
    @Published var selectedFilter: LibraryFilter = .allPhotos {
        didSet {
            guard oldValue != selectedFilter else { return }
            Task { await refresh() }
        }
    }
    /// photoID → the set of collectionIDs it belongs to, rebuilt from
    /// `allMemberships()` on every `refresh()`. Keeping this as one
    /// client-side map (rather than a query per grid cell) is what makes
    /// each cell's collection-membership checkmarks a synchronous
    /// dictionary lookup.
    @Published private(set) var membershipsByPhotoID: [Int64: Set<Int64>] = [:]

    /// `nil` until the background open+migrate in `init()` completes (or
    /// forever, if it failed — see `initError`). `CatalogDatabase()`
    /// itself does real, synchronous I/O (creating the Application
    /// Support directory, opening the SQLite file, running migrations),
    /// so it must NOT be called directly from this `@MainActor` init —
    /// that would block app launch, violating `CLAUDE.md`'s "DB access
    /// never blocks the main thread". Instead `init()` kicks off a
    /// detached `Task` that does the open off-main and hops back only to
    /// publish the result.
    private var database: CatalogDatabase?
    /// Set if `CatalogDatabase()` failed to open (e.g. the Application
    /// Support directory couldn't be created), or left `nil` while the
    /// background open is still in flight. Either way `importFolder()`
    /// surfaces a message rather than silently no-op'ing.
    private var initError: Error?

    /// Read-only security-scoped bookmarks for imported folders — kept in
    /// their OWN store (a distinct `UserDefaults` key) rather than reusing
    /// `ImageDocumentModel`'s sidecar-save bookmark store, so this new,
    /// less-tested path can't interfere with that already-shipped one. A
    /// folder ending up with two independently-stored bookmarks (one here
    /// for browsing, one there for sidecar-saving) is an accepted,
    /// harmless redundancy — same underlying `NSOpenPanel` grant, recorded
    /// twice.
    private var folderBookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: Self.folderBookmarksDefaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.folderBookmarksDefaultsKey) }
    }
    private static let folderBookmarksDefaultsKey = "PhotoApp.libraryFolderBookmarks"

    /// Folders (by path) whose security scope is currently active THIS
    /// session — guards `activateFolderAccess`/`activateKnownFolders`
    /// against calling `startAccessingSecurityScopedResource()` again for
    /// a folder that's already open (e.g. re-importing the same folder
    /// twice), since there is no matching `stop` anywhere in this file
    /// (see `activateKnownFolders`'s doc comment) — an unguarded repeat
    /// call would just accumulate unmatched starts for no benefit.
    private var activeFolders: Set<String> = []

    private let thumbnailCache = ThumbnailCache()

    init() {
        Task.detached { [weak self] in
            do {
                let database = try CatalogDatabase()
                await MainActor.run {
                    self?.database = database
                    self?.activateKnownFolders()
                }
                await self?.refresh()
            } catch {
                await MainActor.run { self?.initError = error }
            }
        }
    }

    func importFolder() {
        guard let database else {
            importStatusMessage = initError.map { "Couldn't open the photo catalog: \($0.localizedDescription)" }
                ?? "The photo catalog isn't ready yet — try again in a moment."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of photos to import into the catalog."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        // Capture + activate access right away, synchronously — the user
        // just granted it via this exact panel, so there's no extra prompt
        // involved, matching `ImageDocumentModel.requestFolderAccess`'s
        // existing synchronous-on-@MainActor `bookmarkData(options:...)`
        // call, an already-shipped precedent for this class of call. Any
        // failure is folded into the eventual import summary rather than
        // shown immediately, since an immediate `importStatusMessage`
        // here would just get overwritten the moment the import below
        // finishes.
        let accessWarning = activateFolderAccess(for: folder)

        Task.detached { [weak self] in
            let urls = PhotoImporter.imageFiles(in: folder)
            do {
                let result = try await database.importPhotos(at: urls)
                await self?.refresh()
                await MainActor.run {
                    var message = Self.summary(for: result)
                    if let accessWarning {
                        message += " \(accessWarning)"
                    }
                    self?.importStatusMessage = message
                }
            } catch {
                await MainActor.run {
                    self?.importStatusMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Folder-mirrored nested collections: recursively imports `folder`
    /// and every subfolder, creating (or reusing, on re-import) a
    /// collection per folder and associating each photo with its DIRECT
    /// containing folder's collection. A separate action from
    /// `importFolder()` — that one stays a flat, single-level import,
    /// unchanged.
    func importFolderTree() {
        guard let database else {
            importStatusMessage = initError.map { "Couldn't open the photo catalog: \($0.localizedDescription)" }
                ?? "The photo catalog isn't ready yet — try again in a moment."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to import as a nested collection tree, mirroring its subfolders."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let accessWarning = activateFolderAccess(for: folder)

        Task.detached { [weak self] in
            // The recursive scan is synchronous, blocking filesystem I/O
            // (mirrors `PhotoImporter.imageFiles(in:)`'s existing need to
            // run off-main) — must happen here, inside `Task.detached`,
            // not on `@MainActor`.
            guard let node = PhotoImporter.scanFolderTree(at: folder) else {
                await MainActor.run { self?.importStatusMessage = "No photos found in that folder." }
                return
            }
            do {
                let result = try await database.importFolderTree(node)
                await self?.refresh()
                await MainActor.run {
                    var message = Self.summary(for: result)
                    if let accessWarning {
                        message += " \(accessWarning)"
                    }
                    self?.importStatusMessage = message
                }
            } catch {
                await MainActor.run {
                    self?.importStatusMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Re-reads `photoCount`/`photos`/`collections`/`membershipsByPhotoID`
    /// from the catalog. Safe to call repeatedly (e.g. after every import
    /// or rating/flag/membership change) — `CatalogDatabase`'s own methods
    /// are `async` and do their real work via GRDB's queue, not on this
    /// (`@MainActor`) call site, so this doesn't block the UI despite
    /// being an ordinary method here rather than wrapped in its own
    /// `Task.detached`. `photos` respects `selectedFilter` — `.allPhotos`
    /// (`allPhotos()`), or just one collection's members
    /// (`photos(inCollection:)`). A failed read leaves the previous,
    /// still-valid state in place rather than clearing it.
    func refresh() async {
        guard let database else { return }
        do {
            photoCount = try await database.photoCount()
            collections = try await database.allCollections()
            let memberships = try await database.allMemberships()
            membershipsByPhotoID = Dictionary(grouping: memberships, by: \.photoId)
                .mapValues { Set($0.map(\.collectionId)) }
            switch selectedFilter {
            case .allPhotos:
                photos = try await database.allPhotos()
            case .collection(let collectionID):
                photos = try await database.photos(inCollection: collectionID)
            }
        } catch {
            // Best-effort — a transient read failure shouldn't blank out
            // an otherwise-valid, already-displayed library.
        }
    }

    /// Returns a small thumbnail for `photo`, decoded (and cached) off the
    /// main thread. Requires `photo`'s containing folder to currently have
    /// active security scope — true for a folder imported this session,
    /// and true after a relaunch once `activateKnownFolders()` (run once
    /// at `init`) has resolved its stored bookmark.
    func thumbnail(for photo: Photo) async -> CGImage? {
        await thumbnailCache.thumbnail(for: photo.path)
    }

    // MARK: - Ratings and flags (Phase 4 slice 3)

    /// Sets `photo`'s star rating (clamped to 0...5 by `CatalogDatabase`)
    /// and refreshes `photos` so every grid cell bound to it picks up the
    /// new value. A failed write is swallowed (`try?`) rather than
    /// surfaced via `importStatusMessage` — a rating tap is a frequent,
    /// low-stakes action; the grid simply not updating is a proportionate,
    /// self-evident failure mode, not worth an alert.
    func setRating(_ rating: Int, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        Task.detached { [weak self] in
            try? await database.setRating(rating, for: id)
            await self?.refresh()
        }
    }

    /// Sets `photo`'s flagged state — same shape/reasoning as `setRating`.
    func setFlagged(_ isFlagged: Bool, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        Task.detached { [weak self] in
            try? await database.setFlagged(isFlagged, for: id)
            await self?.refresh()
        }
    }

    // MARK: - Collections (Phase 4 slice 4)

    /// Creates a new collection. An empty (or whitespace-only) name is
    /// rejected before ever reaching the database — mirroring how other
    /// write paths in this class validate up front.
    func createCollection(name: String) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached { [weak self] in
            _ = try? await database.createCollection(name: trimmed)
            await self?.refresh()
        }
    }

    /// Toggles `photo`'s membership in `collection` — same
    /// `Task.detached` + `refresh()` shape and swallowed-failure
    /// reasoning as `setRating`/`setFlagged`.
    func toggleMembership(of photo: Photo, in collection: PhotoCollection) {
        guard let database, let photoID = photo.id, let collectionID = collection.id else { return }
        let isMember = membershipsByPhotoID[photoID, default: []].contains(collectionID)
        Task.detached { [weak self] in
            try? await database.setMembership(photoID: photoID, collectionID: collectionID, isMember: !isMember)
            await self?.refresh()
        }
    }

    // MARK: - Folder access (read-only, persisted across relaunches)

    /// Captures a security-scoped bookmark for `folder` and activates it
    /// for the rest of this process's lifetime. Without this, photos
    /// imported now would stop being readable — thumbnails AND "open"
    /// would both fail — the next time the app launches, since a bare file
    /// path carries no access outside the picker's own transient grant.
    /// Returns a user-facing warning if either step failed — NOT silently
    /// swallowed via `try?`, since a failure here can mean the
    /// just-imported photos aren't viewable even THIS session, not merely
    /// that a future relaunch won't see them.
    @discardableResult
    private func activateFolderAccess(for folder: URL) -> String? {
        guard !activeFolders.contains(folder.path) else { return nil }

        var warning: String?
        if let bookmarkData = try? folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            folderBookmarks[folder.path] = bookmarkData
        } else {
            warning = "Couldn't save access to \"\(folder.lastPathComponent)\" — its photos may not be viewable after the app relaunches."
        }

        if folder.startAccessingSecurityScopedResource() {
            activeFolders.insert(folder.path)
        } else {
            warning = "Couldn't get access to \"\(folder.lastPathComponent)\" — its photos may not be viewable this session."
        }
        return warning
    }

    /// Resolves and activates every previously-granted folder bookmark.
    /// Called once, right after the catalog DB finishes opening. There is
    /// deliberately no matching `stop` call anywhere — the scope is meant
    /// to stay open for the app's entire lifetime (the OS reclaims it on
    /// quit), since `ImageDocumentModel.load(from:)`'s `CIImage(contentsOf:)`
    /// decode is lazy and can re-read the file well after `load` returns
    /// (e.g. on every redraw), so a scope that closed early would produce
    /// intermittent, hard-to-explain read failures. A stale/unresolvable
    /// bookmark is dropped rather than surfaced as an error — self-healing,
    /// since re-importing that folder simply re-grants it.
    private func activateKnownFolders() {
        for (path, data) in folderBookmarks {
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else {
                folderBookmarks.removeValue(forKey: path)
                continue
            }
            if resolved.startAccessingSecurityScopedResource() {
                activeFolders.insert(path)
            }
        }
    }

    private static func summary(for result: ImportResult) -> String {
        let importedPart = "Imported \(result.inserted) photo\(result.inserted == 1 ? "" : "s")"
        guard result.skipped > 0 else { return "\(importedPart)." }
        return "\(importedPart) (\(result.skipped) already in catalog)."
    }
}

/// Small off-main thumbnail cache, keyed by file path. An `actor` gives
/// free in-flight de-duplication: two concurrent requests for the same
/// path (SwiftUI's `.task(id:)` re-firing on scroll/relayout is a
/// realistic way to trigger this) await the SAME decode rather than
/// triggering it twice.
///
/// Backed by `NSCache`, not a plain dictionary — a library grid exists
/// specifically to scale to a large, growing catalog, so every thumbnail
/// ever scrolled into view must NOT stay resident forever. `NSCache`
/// evicts under memory pressure and once `totalCostLimit` is exceeded
/// (cost tracked per-thumbnail as its approximate decoded byte size).
private actor ThumbnailCache {
    private static let maxPixelSize = 240
    /// ~270 thumbnails at 240px RGBA before eviction kicks in — generous
    /// for what's likely on screen/recently scrolled, not sized to hold
    /// an entire large library resident at once.
    private static let totalCostLimit = 64 * 1024 * 1024

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = totalCostLimit
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    func thumbnail(for path: String) async -> CGImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[path] { return await existing.value }

        let task = Task<CGImage?, Never> {
            ThumbnailGenerator.thumbnail(for: URL(fileURLWithPath: path), maxPixelSize: Self.maxPixelSize)
        }
        inFlight[path] = task
        let result = await task.value
        inFlight[path] = nil
        if let result {
            cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        }
        return result
    }
}
