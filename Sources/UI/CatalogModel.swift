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
    /// Phase 5 slice 2: named, saved edit-state "looks", applicable to any
    /// photo. Loaded in `refresh()` alongside `collections` — same shape,
    /// same reasoning.
    @Published private(set) var presets: [Preset] = []
    /// Which photos `photos` reflects. Setting this re-filters `photos` —
    /// see `didSet` below and `refresh()`. Also clears `selectedPhotoIDs`
    /// — switching what the grid shows always starts from a clean
    /// selection, so an off-screen photo can never be silently still
    /// selected without the user realizing it.
    @Published var selectedFilter: LibraryFilter = .allPhotos {
        didSet {
            guard oldValue != selectedFilter else { return }
            selectedPhotoIDs.removeAll()
            Task { await refresh() }
        }
    }
    /// photoID → the set of collectionIDs it belongs to, rebuilt from
    /// `allMemberships()` on every `refresh()`. Keeping this as one
    /// client-side map (rather than a query per grid cell) is what makes
    /// each cell's collection-membership checkmarks a synchronous
    /// dictionary lookup.
    @Published private(set) var membershipsByPhotoID: [Int64: Set<Int64>] = [:]
    /// Which photos are checked in the Library grid, for batch export —
    /// pure in-memory UI state (unlike every other `@Published` mutation
    /// in this class, this never touches the database, so it needs no
    /// `Task.detached`/`refresh()`). Not persisted across relaunches,
    /// same as `selectedFilter`.
    @Published private(set) var selectedPhotoIDs: Set<Int64> = []

    /// Sort/filter/search refinement, applied entirely in memory on top of
    /// whatever source set `selectedFilter` already produced — see
    /// `displayedPhotos`. Deliberately INDEPENDENT of `selectedFilter`
    /// (not reset on Collection/Folder switch, unlike `selectedPhotoIDs`
    /// above): a persistent search/filter while browsing between
    /// collections is more useful than silently losing it every time the
    /// sidebar selection changes.
    @Published var sortOption: LibrarySortOption = .dateOldest
    /// A THRESHOLD ("N stars and up"), not exact match — `0` = no rating
    /// filter. See `LibraryFilterSort.apply`'s own doc comment.
    @Published var minimumRating: Int = 0
    @Published var flaggedOnly: Bool = false
    @Published var searchText: String = ""

    /// What the Library grid actually renders — `photos` (the
    /// `selectedFilter`-selected source set) refined by the four published
    /// fields above via the pure `LibraryFilterSort.apply`. A cheap,
    /// synchronous in-memory transform (not a DB query), so this can be
    /// recomputed on every keystroke/toggle with no debounce needed —
    /// unlike this file's `Task.detached`-based DB mutators, or
    /// `ImageDocumentModel`'s histogram/sidecar-save debouncing, both of
    /// which debounce specifically because the underlying operation IS
    /// expensive; this one isn't.
    var displayedPhotos: [Photo] {
        LibraryFilterSort.apply(
            to: photos, sort: sortOption, minimumRating: minimumRating,
            flaggedOnly: flaggedOnly, searchText: searchText
        )
    }

    /// Resets all four sort/filter/search fields to their defaults — the
    /// Library grid's "Clear Filters" action, for when they've filtered
    /// the current source set down to nothing.
    func clearLibraryFilters() {
        sortOption = .dateOldest
        minimumRating = 0
        flaggedOnly = false
        searchText = ""
    }

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
    ///
    /// Internal, not `private`: `CatalogModelTests` seeds this directly
    /// with a real temp-file root to exercise `isPhotoConfirmedMissing(_:)`
    /// end-to-end (D5, IMPROVEMENTS.md) — `init(database:)`'s testing seam
    /// deliberately skips `activateKnownFolders()` (real security scopes,
    /// `UserDefaults`), so there's no other way to populate this in a test.
    var activeFolders: Set<String> = []

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

    /// Testing seam: takes an already-open catalog and skips both the
    /// asynchronous open above and `activateKnownFolders()`, which touches
    /// `UserDefaults` and real sandbox security scopes — neither of which
    /// belongs in a unit test. Deliberately does NOT call `refresh()`, so a
    /// test controls exactly when the first load happens instead of racing
    /// an implicit one. Same testability-motivated widening as
    /// `ThumbnailCache` and `PhotoExporter.resized`.
    init(database: CatalogDatabase) {
        self.database = database
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

    /// Re-reads `photoCount`/`photos`/`collections`/`presets`/
    /// `membershipsByPhotoID` from the catalog. Safe to call repeatedly (e.g. after every import
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
            presets = try await database.allPresets()
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
        await thumbnailCache.thumbnail(for: photo)
    }

    /// True only if `photo`'s file is confirmed genuinely missing — used by
    /// the Library grid and Editor filmstrip to distinguish "deleted" from
    /// "still decoding" or "can't currently verify" once a thumbnail
    /// decode fails. Three things all have to hold: `photo.path` sits
    /// under a folder we hold confirmed security-scoped access to
    /// (`PhotoImporter.confirmedActiveFolderRoot`), that ROOT folder
    /// itself is still reachable right now (reviewer-caught: `activeFolders`
    /// is insert-only and never pruned when a volume is later ejected or
    /// the root is deleted/renamed mid-session, so membership alone only
    /// proves access was granted at some point, not that it still holds),
    /// and the photo's own file doesn't exist.
    ///
    /// Note: the stored bookmark path (`activeFolders`/`folderBookmarks`
    /// use the bookmark KEY, not `resolved.path` — see `activateKnownFolders`)
    /// means a moved/renamed root fails this check even though its
    /// CONTENTS may still be reachable at the new location — that's a
    /// false NEGATIVE (a genuine deletion under a moved root goes
    /// undetected), never a false positive, so it's an accepted gap, not
    /// a bug: this function only ever errs toward under-reporting
    /// "Missing," never over-reporting it.
    ///
    /// Both filesystem checks run inside `Task.detached`, off the
    /// `MainActor` this class is isolated to — reviewer-caught: a `stat`
    /// on a spun-down external drive or dead network mount can block for
    /// seconds, and this runs on exactly that slow-filesystem path (the
    /// one case a decode has already failed). `folders`/`path`/`root` are
    /// captured as local values before entering the detached closure so
    /// it never touches `self`, matching this app's established
    /// isolation-capture discipline (see `ThumbnailCache`'s own doc
    /// comment on the same hazard) — a plain `Task {}` would inherit this
    /// `@MainActor` class's isolation regardless of captures and put the
    /// `stat` right back on the main thread, so `Task.detached` is
    /// required here, not just a style choice.
    ///
    /// Checks the photo's own file FIRST, the root second, short-circuited
    /// with `&&` — reviewer-caught: the reverse order has a wider window
    /// for a root that's unmounted/deleted BETWEEN the two stats to read
    /// as "not missing" instead of "can't verify," and this order also
    /// skips the extra root stat entirely in the common case (file
    /// present).
    func isPhotoConfirmedMissing(_ photo: Photo) async -> Bool {
        let folders = activeFolders
        guard let root = PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: photo.path, activeFolders: folders)
        else { return false }
        let path = photo.path
        return await Task.detached {
            !FileManager.default.fileExists(atPath: path) && FileManager.default.fileExists(atPath: root)
        }.value
    }

    /// Drops the cached thumbnail for the photo at `url` — called when
    /// that photo's edits are saved (wired from `ImageDocumentModel.
    /// onSidecarSaved` in `ContentView`), so the NEXT time it's decoded
    /// (naturally triggered by returning to the Library) it reflects the
    /// new edits instead of serving the stale pre-edit thumbnail forever.
    /// Sync wrapper (matching this class's other mutators) — the actual
    /// invalidation hops to the `ThumbnailCache` actor via a fire-and-
    /// forget `Task`.
    func invalidateThumbnail(for url: URL) {
        let path = url.path
        Task { await thumbnailCache.invalidate(path: path) }
    }

    // MARK: - Selection (Phase 5 slice 1 follow-up — export a hand-picked subset)

    /// Toggles whether `photo` is checked. Purely in-memory — no DB
    /// write, no `refresh()`.
    func toggleSelection(of photo: Photo) {
        guard let id = photo.id else { return }
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else {
            selectedPhotoIDs.insert(id)
        }
    }

    func isSelected(_ photo: Photo) -> Bool {
        guard let id = photo.id else { return false }
        return selectedPhotoIDs.contains(id)
    }

    func clearSelection() {
        selectedPhotoIDs.removeAll()
    }

    // MARK: - Ratings and flags (Phase 4 slice 3)

    /// Mutates one already-loaded row of `photos` in place. The three tap
    /// mutators below use this instead of re-running `refresh()`, which
    /// re-read the ENTIRE library — `photoCount`, `allCollections`,
    /// `allMemberships` and `allPhotos` — to learn a single changed field.
    /// MEASURED on an on-disk catalog: those four queries cost 6.5 ms per
    /// tap at 1,000 photos and 30.4 ms at 5,000, scaling linearly, before
    /// the wholesale `photos` republish re-renders the grid on top.
    ///
    /// Being synchronous and `@MainActor`, it also settles the ORDERING
    /// bug that motivated this change: taps now land in tap order. The old
    /// shape let each tap's independent `refresh()` finish whenever, so an
    /// older tap's snapshot could publish after a newer one's and the grid
    /// would flash a stale rating.
    private func updatePhotoInPlace(id: Int64, _ mutate: (inout Photo) -> Void) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&photos[index])
    }

    /// Sets `photo`'s star rating. Updates local state first, then writes —
    /// see `updatePhotoInPlace` for why that order is what fixes the stale
    /// rating, and `CatalogDatabase.setRating` for the authoritative store.
    ///
    /// The 0...5 clamp is MIRRORED from `CatalogDatabase.setRating`, which
    /// still clamps independently. That duplication is deliberate and must
    /// stay in sync: the UI no longer re-reads the stored value, so an
    /// unclamped local update would show a rating the database rejected.
    ///
    /// A failed write is no longer swallowed. It can't be: with the local
    /// update applied first, silence would leave the grid showing a value
    /// the catalog never accepted. Instead the failure path falls back to a
    /// full `refresh()`, resyncing from the database as the authority —
    /// i.e. exactly the old behavior, now reserved for the rare case that
    /// actually needs it.
    func setRating(_ rating: Int, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        let clamped = min(max(rating, 0), 5)
        updatePhotoInPlace(id: id) { $0.rating = clamped }
        Task.detached { [weak self] in
            do { try await database.setRating(clamped, for: id) } catch { await self?.refresh() }
        }
    }

    /// Sets `photo`'s flagged state — same shape/reasoning as `setRating`,
    /// minus the clamp (a `Bool` has no invalid value to guard against).
    func setFlagged(_ isFlagged: Bool, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        updatePhotoInPlace(id: id) { $0.isFlagged = isFlagged }
        Task.detached { [weak self] in
            do { try await database.setFlagged(isFlagged, for: id) } catch { await self?.refresh() }
        }
    }

    /// Removes `photo` from the catalog (D5, IMPROVEMENTS.md) — catalog
    /// row only, the original file on disk is never touched (see
    /// `CatalogDatabase.deletePhoto`'s own doc comment). Local-first, same
    /// shape/failure-resync reasoning as `setRating`/`setFlagged`, but
    /// UNLIKE them this is permanent rather than a re-toggleable field, so
    /// it also prunes the two stale-reference gaps `toggleMembership`
    /// leaves for OTHER mutators (there, the entry is expected to resolve
    /// itself on the next `refresh()`; here the row is simply gone, so an
    /// un-pruned `selectedPhotoIDs`/`membershipsByPhotoID` entry would be
    /// permanently stale, not transiently so):
    /// - `selectedPhotoIDs` (its own tracked gap — otherwise this photo's
    ///   ID would linger forever, ghost-inflating the export-selection
    ///   count)
    /// - `membershipsByPhotoID[id]` (the whole entry, not one collection —
    ///   the photo can't be a member of anything once it doesn't exist)
    /// - the thumbnail cache, via the already-existing
    ///   `invalidateThumbnail(for:)`, so a later re-import of the same
    ///   path can't resurrect a stale cached image.
    func removePhoto(_ photo: Photo) {
        guard let database, let id = photo.id else { return }
        photos.removeAll { $0.id == id }
        selectedPhotoIDs.remove(id)
        membershipsByPhotoID.removeValue(forKey: id)
        invalidateThumbnail(for: URL(fileURLWithPath: photo.path))
        Task.detached { [weak self] in
            do { try await database.deletePhoto(id: id) } catch { await self?.refresh() }
        }
    }

    // MARK: - Presets (Phase 5 slice 2)

    /// Creates (or, under an existing name, overwrites — see
    /// `CatalogDatabase.createPreset`'s own doc comment) a saved preset.
    /// Same shape as `createCollection`: validate up front, fire-and-forget
    /// write, then `refresh()` — unlike `removePhoto`'s local-first
    /// pattern, there's no local list position to guess at ahead of the
    /// write (the list is alphabetical, not insertion-ordered), so a full
    /// refresh is the simpler correct choice here, same as collections.
    func createPreset(name: String, editState: EditState) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached { [weak self] in
            _ = try? await database.createPreset(name: trimmed, editState: editState)
            await self?.refresh()
        }
    }

    /// Local-first prune, same shape as `removePhoto` — a preset deletion
    /// is permanent, not a re-toggleable field, so the local list is
    /// updated synchronously rather than waiting on a full `refresh()`.
    func deletePreset(_ preset: Preset) {
        guard let database, let id = preset.id else { return }
        presets.removeAll { $0.id == id }
        Task.detached { [weak self] in
            do { try await database.deletePreset(id: id) } catch { await self?.refresh() }
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

    /// Renames `collection`. Same shape as `createCollection`: validate up
    /// front, fire-and-forget write, then full `refresh()` — NOT a
    /// local-first splice, for the same reason `createPreset`'s own doc
    /// comment already gives: the sidebar list is alphabetical, not
    /// insertion-ordered, so there's no local position to guess at ahead
    /// of the write.
    ///
    /// `isFolder` guard: rename on a folder-tree collection is out of
    /// scope for this slice (see `deleteCollection`'s own doc comment for
    /// the full reasoning — a folder's `name` diverging from its
    /// `folderPath` interacts oddly with re-import). `CollectionSidebarView`
    /// never offers this action for a folder row, but the guard is
    /// defense-in-depth against a future caller reaching this method
    /// directly, not just documentation.
    func renameCollection(_ collection: PhotoCollection, to name: String) {
        guard let database, let id = collection.id, !collection.isFolder else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task.detached { [weak self] in
            try? await database.renameCollection(id: id, to: trimmed)
            await self?.refresh()
        }
    }

    /// Deletes `collection` — catalog rows only, the photos themselves are
    /// never touched (see `CatalogDatabase.deleteCollection`'s own doc
    /// comment). Local-first for the sidebar list (`collections` is
    /// pruned synchronously, same shape/failure-resync reasoning as
    /// `removePhoto`). Also resets `selectedFilter` to `.allPhotos` when
    /// the collection being deleted is the one currently being viewed —
    /// extending `toggleMembership`'s own `affectsCurrentFilter` check to
    /// this mutator, so deleting the active filter falls back to "All
    /// Photos" instead of leaving `selectedFilter` pointing at a vanished
    /// ID (an empty grid with no sidebar row highlighted).
    ///
    /// Deliberately does NOT prune the deleted collection's ID out of
    /// `membershipsByPhotoID`'s per-photo sets, unlike `removePhoto`'s own
    /// discipline for a deleted PHOTO's id — harmless here rather than
    /// latent: the only reader (`LibraryGridView`'s per-cell membership
    /// menu) iterates `catalog.collections`, which no longer contains the
    /// row, and SQLite's `AUTOINCREMENT` primary key never reuses a
    /// deleted id, so a stale entry can't resurface as a phantom checkmark
    /// on some later, unrelated collection.
    ///
    /// `isFolder` guard: deleting a folder-tree collection recursively
    /// deletes its ENTIRE subtree (`parentId` is itself `ON DELETE CASCADE`,
    /// self-referencing — `Migrations/004_folder_collections.swift`), and
    /// the next "Import Folder Tree…" of the same root silently recreates
    /// it anyway (`findOrCreateFolderCollection` matches by disk path, not
    /// name) — both deliberately out of scope for this slice (see
    /// CLAUDE.md/IMPROVEMENTS.md's D5 write-up). `CollectionSidebarView`
    /// never offers this action for a folder row, but the guard is
    /// defense-in-depth against a future caller reaching this method
    /// directly, not just documentation.
    ///
    /// The filter reset happens ONLY AFTER the delete write completes, not
    /// synchronously up front like `collections`' own local removal — a
    /// real race caught before this shipped: `selectedFilter`'s own
    /// `didSet` kicks off `Task { await refresh() }` whenever it actually
    /// changes, and if that fired before this method's write lands,
    /// `refresh()` would re-fetch the collection from the database (still
    /// there) and silently restore the row `collections.removeAll` just
    /// removed — permanently, since this method never refreshes on its
    /// own success path. Deferring the filter flip until the write is
    /// confirmed removes that race entirely: any refresh a later flip
    /// triggers now correctly finds the row already gone. Regression-
    /// tested by `testDeletingTheCurrentlyViewedCollectionResetsToAllPhotos`,
    /// which asserts the filter has NOT yet flipped immediately after this
    /// call returns (not just that it eventually does).
    func deleteCollection(_ collection: PhotoCollection) {
        guard let database, let id = collection.id, !collection.isFolder else { return }
        collections.removeAll { $0.id == id }
        Task.detached { [weak self] in
            do {
                try await database.deleteCollection(id: id)
                await self?.clearSelectedFilterIfCollectionDeleted(id)
            } catch {
                await self?.refresh()
            }
        }
    }

    /// See `deleteCollection`'s own doc comment for why this is called
    /// only after the delete write completes, never synchronously.
    private func clearSelectedFilterIfCollectionDeleted(_ collectionID: Int64) {
        if selectedFilter == .collection(collectionID) {
            selectedFilter = .allPhotos
        }
    }

    /// Toggles `photo`'s membership in `collection` — same local-first
    /// shape and failure-resync reasoning as `setRating`/`setFlagged`,
    /// plus one case they don't have.
    ///
    /// GHOST-CELL CASE: when the sidebar is currently filtered to the very
    /// collection being toggled, `photos` IS that collection's membership
    /// list, so updating `membershipsByPhotoID` alone would leave the
    /// removed photo still sitting in the grid. It has to leave `photos`
    /// too. Note the add-back direction is unreachable from the UI while
    /// that filter is active — every visible cell is already a member, so
    /// a toggle there can only remove — but it is handled via `refresh()`
    /// anyway rather than left to depend on that reasoning staying true.
    func toggleMembership(of photo: Photo, in collection: PhotoCollection) {
        guard let database, let photoID = photo.id, let collectionID = collection.id else { return }
        let willBeMember = !membershipsByPhotoID[photoID, default: []].contains(collectionID)
        let affectsCurrentFilter = selectedFilter == .collection(collectionID)

        if willBeMember {
            membershipsByPhotoID[photoID, default: []].insert(collectionID)
        } else {
            membershipsByPhotoID[photoID]?.remove(collectionID)
            if affectsCurrentFilter { photos.removeAll { $0.id == photoID } }
        }

        Task.detached { [weak self] in
            do {
                try await database.setMembership(
                    photoID: photoID, collectionID: collectionID, isMember: willBeMember
                )
                // Re-adding while viewing that same collection needs the
                // row back at its correct sort position, which only a
                // re-read knows — rare enough to just pay for.
                if affectsCurrentFilter && willBeMember { await self?.refresh() }
            } catch {
                await self?.refresh()
            }
        }
    }

    /// Adds every currently-selected photo, RESTRICTED to those still in
    /// `photos` (D5 follow-up, requested after rename/delete collections
    /// shipped) to `collection` in one action. Always ADDS, never
    /// toggles — unlike `toggleMembership`, a batch selection can be a
    /// mix of members/non-members, and "add all" is the only semantic
    /// that isn't ambiguous for that case.
    ///
    /// The `photos`-intersection matters, reviewer-caught: unlike
    /// `removePhoto` (which prunes `selectedPhotoIDs`, `:414`),
    /// `toggleMembership` does NOT prune a photo's selection when it
    /// removes that photo from the currently-viewed collection's grid —
    /// so a photo toggled OUT of the collection being viewed can remain
    /// in `selectedPhotoIDs` while no longer visible. Without this
    /// intersection, a later "Add to Collection" would silently re-add
    /// that invisible photo. `ContentView.photosToExport` already
    /// establishes this exact "intersect the raw selection with the
    /// currently-displayed set" pattern for Export; this mirrors it.
    /// Local-first: every intersected ID gets `collection` inserted into
    /// `membershipsByPhotoID` synchronously, same discipline as
    /// `toggleMembership`'s own local update; the write itself is one
    /// batched transaction (`CatalogDatabase.addPhotos`), not N separate
    /// calls.
    func addSelectedPhotos(to collection: PhotoCollection) {
        guard let database, let collectionID = collection.id else { return }
        let visibleSelectedIDs = Set(photos.compactMap(\.id)).intersection(selectedPhotoIDs)
        guard !visibleSelectedIDs.isEmpty else { return }
        let photoIDs = Array(visibleSelectedIDs)

        for photoID in photoIDs {
            membershipsByPhotoID[photoID, default: []].insert(collectionID)
        }

        Task.detached { [weak self] in
            do {
                try await database.addPhotos(photoIDs, toCollection: collectionID)
                await self?.refreshIfViewingCollection(collectionID)
            } catch {
                await self?.refresh()
            }
        }
    }

    /// Refreshes only if `collectionID` is STILL the active filter at
    /// completion — re-checked here, on the `MainActor`, rather than a
    /// flag captured before the (potentially large, batched) write
    /// started. Reviewer-caught: capturing `affectsCurrentFilter` up
    /// front would miss a filter change the user makes while this
    /// write is still in flight — the same race `deleteCollection`'s own
    /// `clearSelectedFilterIfCollectionDeleted` already avoids by
    /// re-reading `selectedFilter` at completion instead of trusting a
    /// captured value.
    ///
    /// With the `photos`-intersection above, every added photo was
    /// already visible under whatever filter was active at call time —
    /// so if that filter is STILL `.collection(collectionID)` here, every
    /// added photo was already a member of it, making this refresh a
    /// genuine no-op in practice. Kept anyway, matching `toggleMembership`'s
    /// own "handled anyway, not left to depend on that reasoning staying
    /// true" precedent — and it stops being a no-op the moment the target
    /// collection differs from what was active at call time but matches
    /// by completion (e.g. the user switches filters mid-write).
    private func refreshIfViewingCollection(_ collectionID: Int64) async {
        if selectedFilter == .collection(collectionID) {
            await refresh()
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
