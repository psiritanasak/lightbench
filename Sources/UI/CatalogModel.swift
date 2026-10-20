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
    /// A saved set of filter criteria (`SmartCollection`), evaluated live over ALL photos.
    case smartCollection(Int64)
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
    /// True once the first `refresh()` has finished (successfully or not), so an empty Library can be told apart from one that has not been
    /// read yet — without it the "no photos" screen would flash at every launch while the catalog opens.
    @Published private(set) var isLoaded = false
    /// Why the catalog could not be opened at launch (a catalog from a newer build, a damaged file), nil otherwise. The Library shows it instead
    /// of a blank grid — `refresh()` returns before `isLoaded` is set when there is no database.
    @Published private(set) var openFailureMessage: String?
    @Published var importStatusMessage: String?
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var collections: [PhotoCollection] = []
    /// Phase 5 slice 2: named, saved edit-state "looks", applicable to any
    /// photo. Loaded in `refresh()` alongside `collections` — same shape,
    /// same reasoning.
    @Published private(set) var presets: [Preset] = []
    /// Saved filter sets shown in the sidebar, sorted by name; loaded in `refresh()`.
    @Published private(set) var smartCollections: [SmartCollection] = []
    private var smartCollectionLoadError: String?
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
    /// Library: a selected FOLDER (folder-mirrored collection) also shows the photos of all its subfolders. Persisted in `AppPreferences`
    /// (off by default). Changing it re-reads the grid when a folder is selected; it never affects albums, All Photos or smart collections.
    @Published var showPhotosInSubfolders = false {
        didSet {
            guard oldValue != showPhotosInSubfolders else { return }
            preferences.showPhotosInSubfolders = showPhotosInSubfolders
            recomputeFolderPhotoCounts()
            if case .collection(let id) = selectedFilter, collections.first(where: { $0.id == id })?.isFolder == true {
                selectedPhotoIDs.removeAll()
                Task { await refresh() }
            }
        }
    }
    /// Folder id → the number the sidebar shows beside it (direct, or the subtree total while `showPhotosInSubfolders` is on). Stored, not
    /// computed in the sidebar's body: it is O(photos x depth) and the sidebar redraws on every grid click. Kept in step with `collections`,
    /// `membershipsByPhotoID` and the flag by `recomputeFolderPhotoCounts()` (assigns only on a real change).
    @Published private(set) var folderPhotoCounts: [Int64: Int] = [:]
    /// photoID → the set of collectionIDs it belongs to, rebuilt from
    /// `allMemberships()` on every `refresh()`. Keeping this as one
    /// client-side map (rather than a query per grid cell) is what makes
    /// each cell's collection-membership checkmarks a synchronous
    /// dictionary lookup.
    @Published private(set) var membershipsByPhotoID: [Int64: Set<Int64>] = [:]
    /// All keywords, sorted case-insensitively by name (refreshed with everything else).
    @Published private(set) var keywords: [Keyword] = []
    /// photoID → the keyword ids on it; same role/discipline as `membershipsByPhotoID`.
    @Published private(set) var keywordIDsByPhotoID: [Int64: Set<Int64>] = [:]
    /// Which photos are checked in the Library grid, for batch export —
    /// pure in-memory UI state (unlike every other `@Published` mutation
    /// in this class, this never touches the database, so it needs no
    /// `Task.detached`/`refresh()`). Not persisted across relaunches,
    /// same as `selectedFilter`.
    @Published private(set) var selectedPhotoIDs: Set<Int64> = []

    /// D4 (IMPROVEMENTS.md): the keyboard-navigable "focused" photo in the
    /// Library grid — Lightroom's own distinction between "focused" (one
    /// cell, arrow-key/rating-key target) and "selected" (`selectedPhotoIDs`
    /// above, an export batch). Deliberately a DIFFERENT shape from that
    /// property, not just a narrower version of it: a single optional
    /// `String` keyed on `Photo.path` (matching `LibraryNavigation`'s and
    /// `EditorFilmstripView`'s own path-based convention), not an
    /// `Int64`-keyed `Set`. Also deliberately NOT cleared in
    /// `selectedFilter`'s `didSet` below, unlike `selectedPhotoIDs` — a
    /// focused path that's no longer in `displayedPhotos` (filtered out, or
    /// a different Collection/Folder) already reads as "nothing focused"
    /// to any lookup against that array, with no extra invalidation code
    /// needed, and it comes back "sticky" for free if the user returns to
    /// where it's still visible.
    @Published var focusedPhotoPath: String?

    /// True while `RenameModel` is applying or undoing a batch rename. Renaming moves files and rewrites
    /// catalog paths, so the catalog's other path-touching actions (import, locate, remove) refuse to run
    /// meanwhile — an import could insert a row at a path the batch is about to claim, which would make
    /// the batch (or its Undo) fail permanently. Set only by `RenameModel`.
    @Published var isRenameInProgress = false

    /// Imports currently running (a folder scan + insert takes time and has no other flag).
    /// `RenameModel` refuses to start while this is non-zero.
    @Published private(set) var importsInFlight = 0
    var isImporting: Bool { importsInFlight > 0 }

    static let renameInProgressMessage = "A rename is in progress — try again in a moment."

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
    @Published var flagFilter: LibraryFlagFilter = .all
    @Published var labelFilter: LibraryLabelFilter = .all
    /// Duplicate review (Photo ▸ Find Duplicates…): the menu only REQUESTS; `DuplicatesSheetModifier` presents unless
    /// another sheet is up (same shape as the keyword sheet's flags).
    @Published var duplicatesSheetRequested = false
    @Published var duplicatesSheetPresented = false
    let duplicates = DuplicatesModel()
    /// The keyword sheet's snapshot of the photo ids it edits; `nil` = sheet closed. Lives here so the Photo-menu
    /// item (Scene level) and the Library toolbar reach the same sheet.
    @Published var keywordSheetPhotoIDs: [Int64]?
    /// Set by the Photo menu's "Edit Keywords…" (a Scene-level command that can't see the other sheets'
    /// state); `KeywordSheetModifier` performs it — or drops it while another sheet/dialog is up — then clears it.
    @Published var keywordSheetRequested = false
    /// The keyword the grid is filtered to; `nil` = no keyword filter.
    @Published var keywordFilterID: Int64?
    /// Faces and people (see `FacesModel`): the people list, which photos each person is in, and the Library's Person filter.
    @Published private(set) var people: [PersonSummary] = []
    @Published private(set) var personIDsByPhotoID: [Int64: Set<Int64>] = [:]
    /// The cached camera data (EXIF) the Library search's `iso:`/`camera:`/`date:`… fields read; see `CatalogModel+Metadata.swift`.
    @Published private(set) var metadataByPhotoID: [Int64: PhotoMetadata] = [:]
    /// Non-nil while the background metadata scan runs ("Reading camera data… 120/1097").
    @Published private(set) var metadataScanProgress: MetadataScanner.Progress?
    var metadataScanTask: Task<Void, Never>?
    var metadataScanWanted = false
    var didFullMetadataPass = false
    var metadataCheckedPhotoCount: Int?
    var metadataRetryRequested = false
    /// Identifies the current scan so a late progress update from an earlier one is dropped.
    var metadataScanGeneration = 0
    @Published var personFilterID: Int64?
    @Published var peopleSheetRequested = false
    @Published var peopleSheetPresented = false
    let faces = FacesModel()
    /// Photo Merge (see `MergeModel`): the Photo / selection menus set `mergeRequested`; `MergeDialogModifier` performs it. `mergeBusy` mirrors
    /// "a merge confirmation is up or a merge is running" so views observing only this model can block on it.
    @Published var mergeRequested: MergeModel.Kind?
    @Published var mergeBusy = false
    let merge = MergeModel()
    /// XMP sidecar read/write (see `XMPModel`): menus set `xmpRequested`; `XMPDialogModifier` performs it. `xmpBusy` mirrors "a confirmation is
    /// up or XMP files are being read/written".
    @Published var xmpRequested: XMPModel.Kind?
    @Published var xmpBusy = false
    /// Move to Trash (see `TrashModel`): `trashRequested` is set by the menus, `TrashDialogModifier` performs it; `trashBusy` mirrors "a confirmation is
    /// up or photos are being moved".
    @Published var trashRequested: TrashModel.Kind?
    @Published var trashBusy = false
    /// Copy Photos into Library… (see `ImportCopyModel`): `importCopyRequested` is set by the menus, `ImportCopyDialogModifier` performs it;
    /// `importCopyBusy` mirrors "a source is being scanned, the options sheet is up or photos are being copied".
    @Published var importCopyRequested = false
    @Published var importCopyBusy = false
    /// A file tool (XMP read/write, Move to Trash, Copy Photos) is up or running: the menus that act on the selection's files wait for it.
    var fileToolBusy: Bool { xmpBusy || trashBusy || importCopyBusy }
    let xmp = XMPModel()
    let trash = TrashModel()
    let importCopy = ImportCopyModel()
    /// Catalog backup / restore (see `CatalogBackupModel`): the File menu sets `backupRequested`; `CatalogBackupDialogModifier` performs it.
    /// `backupBusy` mirrors "a restore confirmation is up or a backup is being written".
    @Published var backupRequested: CatalogBackupModel.Kind?
    @Published var backupBusy = false
    /// Preferences ▸ Back Up Now is running. `backupBusy` has two writers (this and `CatalogBackupModel`); `publishBusy` ORs this in so one can
    /// never clear the other's claim.
    var backUpNowRunning = false
    let catalogBackup = CatalogBackupModel()
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
            to: smartCollectionSourcePhotos, sort: sortOption, minimumRating: minimumRating,
            flagFilter: flagFilter, searchText: searchText,
            labelFilter: labelFilter,
            keywordFilter: keywordFilterID.map { [$0] },
            keywordIDsByPhotoID: keywordIDsByPhotoID,
            keywordNamesByPhotoID: keywordNamesForSearch,
            personFilter: personFilterID,
            personIDsByPhotoID: personIDsByPhotoID,
            metadataByPhotoID: metadataByPhotoID
        )
    }

    /// The photos the sidebar selection means — what Export falls back to when nothing is checked (the filter bar
    /// deliberately does not narrow Export). Equals `photos` except for a smart collection, where it is `photos`
    /// reduced by the collection's criteria (the filter bar then refines that, exactly as for a normal collection).
    ///
    /// While a smart collection is selected `photos` holds ALL photos and the criteria are applied HERE, so every local-first mutator (`updatePhotoInPlace`, `removePhoto`, …) keeps working on the one
    /// real list and a rating/keyword change moves a photo in or out immediately. A smart id that is not (yet) in
    /// `smartCollections` shows NOTHING — never everything (it can only be transient, right after a create).
    var smartCollectionSourcePhotos: [Photo] {
        guard case .smartCollection(let id) = selectedFilter else { return photos }
        guard let smart = smartCollections.first(where: { $0.id == id }) else { return [] }
        return smart.criteria.apply(
            to: photos, keywords: keywords, keywordIDsByPhotoID: keywordIDsByPhotoID,
            // Only built when the collection has a saved search (the only reader).
            keywordNamesByPhotoID: smart.criteria.searchQuery.isEmpty ? [:] : keywordNamesByPhoto(),
            metadataByPhotoID: metadataByPhotoID
        )
    }

    /// The selected smart collection's saved search text ("" when none is selected or it has none).
    var selectedSmartCollectionQuery: String {
        guard case .smartCollection(let id) = selectedFilter else { return "" }
        return smartCollections.first(where: { $0.id == id })?.criteria.searchQuery ?? ""
    }

    /// keyword id → display name (ids are primary keys, so unique).
    private var keywordNamesByID: [Int64: String] {
        Dictionary(uniqueKeysWithValues: keywords.compactMap { keyword in keyword.id.map { ($0, keyword.name) } })
    }

    /// photoID → keyword names (for a text search over keywords).
    private func keywordNamesByPhoto() -> [Int64: [String]] {
        let namesByID = keywordNamesByID
        return keywordIDsByPhotoID.mapValues { $0.compactMap { namesByID[$0] } }
    }

    /// photoID → keyword names, built only while a search is active (the only reader).
    private var keywordNamesForSearch: [Int64: [String]] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return keywordNamesByPhoto()
    }

    /// The current filter fields as a value (sort excluded): what the filter bar checks for its "active" cue.
    var libraryFilterState: LibraryFilterState {
        LibraryFilterState(minimumRating: minimumRating, flagFilter: flagFilter, labelFilter: labelFilter,
                           keywordFilterID: keywordFilterID, searchText: searchText, personFilterID: personFilterID)
    }

    /// The filter bar's Clear button: resets the five filters but KEEPS the sort order (`clearLibraryFilters` below resets it too).
    func clearFiltersKeepingSort() {
        minimumRating = 0
        flagFilter = .all
        labelFilter = .all
        keywordFilterID = nil
        searchText = ""
        personFilterID = nil
    }

    /// Resets all five sort/filter/search fields to their defaults — the
    /// Library grid's "Clear Filters" action, for when they've filtered
    /// the current source set down to nothing.
    func clearLibraryFilters() {
        sortOption = .dateOldest
        minimumRating = 0
        flagFilter = .all
        labelFilter = .all
        keywordFilterID = nil
        searchText = ""
        personFilterID = nil
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
    private var database: CatalogDatabase? { didSet { connectFaces() } }

    /// Gives the People model the database and a way to refresh this model's people list after it changes something.
    private func connectFaces() {
        faces.database = database
        faces.onPeopleChanged = { [weak self] in Task { await self?.refresh() } }
    }
    /// Set if `CatalogDatabase()` failed to open (e.g. the Application
    /// Support directory couldn't be created), or left `nil` while the
    /// background open is still in flight. Either way `importFolder()`
    /// surfaces a message rather than silently no-op'ing.
    private var initError: Error?

    /// The Preferences window's settings, read from the same defaults this model was given (a test injects an isolated suite).
    let preferences: AppPreferences

    /// True once the launch-time open has finished — successfully or not (`initError` says which). Finder / Dock opens that arrive while the
    /// catalog is still opening wait for this instead of being refused (`DropAndOpenModifier`).
    @Published private(set) var openSettled = false

    /// Read-only security-scoped bookmarks for imported folders — kept in
    /// their OWN store (a distinct `UserDefaults` key) rather than reusing
    /// `ImageDocumentModel`'s sidecar-save bookmark store, so this new,
    /// less-tested path can't interfere with that already-shipped one. A
    /// folder ending up with two independently-stored bookmarks (one here
    /// for browsing, one there for sidecar-saving) is an accepted,
    /// harmless redundancy — same underlying `NSOpenPanel` grant, recorded
    /// twice.
    /// Internal, not `private`: `CatalogModelTests` reads/seeds this
    /// directly to exercise `ensureAccessActive(forPhotoAt:)`'s decision
    /// logic — same testability-motivated widening `activeFolders` below
    /// already has, and for the identical reason. Backed by `defaults`
    /// (injected, see below), NOT a hardcoded `UserDefaults.standard` —
    /// reviewer-caught (real, not theoretical): `PhotoAppTests` is hosted
    /// inside the `PhotoApp` target (`TEST_HOST`), so `.standard` in a
    /// test IS the same preferences domain the real, installed app reads —
    /// a test that assigns a whole new dictionary here would silently
    /// replace (not merge with) a real user's actual persisted library-
    /// folder bookmarks. Confirmed happening: an earlier version of this
    /// property's own tests did exactly that, wiping a real
    /// `~/Library/Containers/com.photoapp.PhotoApp/.../com.photoapp.PhotoApp.plist`
    /// entry that several genuinely-imported folders
    /// (`~/Desktop`, `~/Downloads`, `~/Pictures/Bolivia_trip/*`) depended
    /// on — same class of hazard `SidecarFolderAccess`'s own `init(defaults:)`
    /// already exists to avoid; this mirrors that exact shape instead of
    /// reinventing an unsafe one.
    var folderBookmarks: [String: Data] {
        get { defaults.dictionary(forKey: Self.folderBookmarksDefaultsKey) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: Self.folderBookmarksDefaultsKey) }
    }
    private static let folderBookmarksDefaultsKey = "PhotoApp.libraryFolderBookmarks"

    /// Injected so tests never touch the real app's shared `UserDefaults.
    /// standard` domain (see `folderBookmarks`'s own doc comment for why
    /// that's not just a style preference). Defaults to `.standard` for
    /// both real call sites (`init()`, the app's own real usage, and
    /// `init(database:)`, whose callers that DON'T care about folder
    /// access can ignore this parameter entirely) — only `CatalogModelTests`
    /// passes an isolated suite.
    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = AppPreferences(defaults: defaults)
        self.showPhotosInSubfolders = preferences.showPhotosInSubfolders
        Task.detached { [weak self] in
            do {
                let database = try CatalogDatabase()
                // Resolving a bookmark can block (an offline network share, a slow volume), so it happens HERE, off the main actor; only the
                // cheap start/refresh step runs on it. D34: the test host must not start real security scopes or refresh the developer's REAL
                // folder bookmarks in `UserDefaults.standard`; its throwaway temp catalog needs no folder access anyway.
                let resolved: [String: ResolvedBookmark]
                if CatalogDatabase.isRunningUnderXCTest {
                    resolved = [:]
                } else {
                    let saved = await MainActor.run { self?.folderBookmarks ?? [:] }
                    resolved = Self.resolveAll(saved)
                }
                await MainActor.run {
                    self?.database = database
                    if !resolved.isEmpty { self?.activateKnownFolders(resolved: resolved) }
                    self?.openSettled = true
                }
                await self?.refresh()
                if let report = CatalogRestoreReportStore.shared.take() {
                    await MainActor.run { self?.importStatusMessage = report.message }
                }
            } catch {
                await MainActor.run {
                    self?.initError = error
                    self?.openFailureMessage = error.localizedDescription
                    self?.openSettled = true
                    // Shown at launch too (it used to surface only when the user tried to import): a catalog this build refuses to open
                    // (made by a newer version, damaged) must not just look like an empty library.
                    self?.importStatusMessage = "Couldn't open the photo catalog: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Testing seam: takes an already-open catalog and skips both the
    /// asynchronous open above and `activateKnownFolders()` (real sandbox
    /// security scopes — never belongs in a unit test, regardless of
    /// `defaults`). Deliberately does NOT call `refresh()`, so a test
    /// controls exactly when the first load happens instead of racing an
    /// implicit one. Same testability-motivated widening as
    /// `ThumbnailCache` and `PhotoExporter.resized`. `defaults` defaults to
    /// `.standard` for callers that don't care about folder-access state
    /// at all — a test exercising `folderBookmarks`/`ensureAccessActive`
    /// MUST pass an isolated `UserDefaults(suiteName:)` instead (see
    /// `folderBookmarks`'s own doc comment for why).
    init(database: CatalogDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        self.defaults = defaults
        self.preferences = AppPreferences(defaults: defaults)
        self.showPhotosInSubfolders = preferences.showPhotosInSubfolders
        openSettled = true
        connectFaces()
    }

    /// The check every import entry point (panel, drag-and-drop, Finder open) shares: nothing while a rename runs, and a clear message
    /// while the catalog is not open yet. Returns the open database, or nil after setting `importStatusMessage`.
    private func databaseForImport() -> CatalogDatabase? {
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return nil }
        guard let database else {
            importStatusMessage = initError.map { "Couldn't open the photo catalog: \($0.localizedDescription)" }
                ?? "The photo catalog isn't ready yet — try again in a moment."
            return nil
        }
        return database
    }

    func importFolder() {
        guard databaseForImport() != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of photos to import into the catalog."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importFolder(at: folder)
    }

    /// Folder-mirrored nested collections: recursively imports `folder`
    /// and every subfolder, creating (or reusing, on re-import) a
    /// collection per folder and associating each photo with its DIRECT
    /// containing folder's collection. A separate action from
    /// `importFolder()` — that one stays a flat, single-level import,
    /// unchanged.
    func importFolderTree() {
        guard databaseForImport() != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to import as a nested collection tree, mirroring its subfolders."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importFolderTree(at: folder)
    }

    /// Flat import of an already-chosen folder (a panel result, a drop, or a Finder open).
    func importFolder(at folder: URL) { importFolders([.init(url: folder, asTree: false)]) }

    /// Nested-collection import of an already-chosen folder.
    func importFolderTree(at folder: URL) { importFolders([.init(url: folder, asTree: true)]) }

    /// Adds photos that "Copy Photos into Library…" just wrote under `root` (verified copies only): the destination gets the same saved folder
    /// access an imported folder gets (so thumbnails open after a relaunch), then the rows and folder-mirrored collections are written, the
    /// Library refreshed and `.xmp` metadata read for the new photos. Runs inside an `importsInFlight` window so a rename cannot start under it.
    func registerCopiedPhotos(_ urls: [URL], under root: URL) async throws -> (result: ImportResult, accessWarning: String?) {
        guard let database else { throw CatalogDatabaseError(message: "The photo catalog isn't ready yet.") }
        let warning = activateFolderAccess(for: root)
        importsInFlight += 1
        defer { importsInFlight -= 1 }
        let before = Set(try await database.allPhotos().compactMap(\.id))
        let result = try await database.importCopiedFiles(urls, under: root)
        await refresh()
        await autoReadXMP(newerThan: before)
        return (result, warning)
    }

    /// Imports each folder in turn (one catalog write at a time) and reports one combined message. The caller must hold access to every
    /// folder already: a panel result, a dropped URL and a Finder-opened URL all carry a sandbox extension for this launch, and
    /// `activateFolderAccess` turns it into a saved bookmark.
    func importFolders(_ folders: [DroppedItemsPlan.FolderImport]) {
        guard !folders.isEmpty, let database = databaseForImport() else { return }

        // Capture + activate access right away, synchronously — the user just granted it (panel / drop), so there is no extra prompt,
        // matching `ImageDocumentModel.requestFolderAccess`'s existing synchronous `bookmarkData` call. A failure is folded into the
        // eventual summary rather than shown immediately, since an immediate `importStatusMessage` would be overwritten when the import
        // below finishes.
        let jobs = folders.map { (item: $0, accessWarning: activateFolderAccess(for: $0.url)) }

        importsInFlight += 1
        Task.detached { [weak self] in
            var messages: [String] = []
            for job in jobs {
                let folder = job.item.url
                var message: String
                do {
                    if job.item.asTree {
                        // The recursive scan is synchronous, blocking filesystem I/O: it must happen here, off the main actor.
                        if let node = PhotoImporter.scanFolderTree(at: folder) {
                            let before = Set(try await database.allPhotos().compactMap(\.id))
                            let result = try await database.importFolderTree(node)
                            await self?.refresh()
                            await self?.autoReadXMP(newerThan: before)
                            message = await MainActor.run { Self.summary(for: result) }
                        } else {
                            message = "No photos found in that folder."
                        }
                    } else {
                        let urls = PhotoImporter.imageFiles(in: folder)
                        let before = Set(try await database.allPhotos().compactMap(\.id))
                        let result = try await database.importPhotos(at: urls)
                        await self?.refresh()
                        await self?.autoReadXMP(newerThan: before)
                        message = await MainActor.run { Self.summary(for: result) }
                    }
                    if let warning = job.accessWarning { message += " \(warning)" }
                } catch {
                    message = "Import failed: \(error.localizedDescription)"
                }
                messages.append(jobs.count > 1 ? "\(folder.lastPathComponent): \(message)" : message)
            }
            await MainActor.run {
                self?.importsInFlight -= 1
                self?.importStatusMessage = messages.joined(separator: "\n")
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
        defer { isLoaded = true }
        do {
            photoCount = try await database.photoCount()
            collections = try await database.allCollections()
            presets = try await database.allPresets()
            let memberships = try await database.allMemberships()
            membershipsByPhotoID = Dictionary(grouping: memberships, by: \.photoId)
                .mapValues { Set($0.map(\.collectionId)) }
            recomputeFolderPhotoCounts()
            let loadedKeywords = try await database.allKeywords()
            let keywordLinks = try await database.allKeywordLinks()
            keywords = Self.sortedKeywords(loadedKeywords)
            keywordIDsByPhotoID = Dictionary(grouping: keywordLinks, by: \.photoId)
                .mapValues { Set($0.map(\.keywordId)) }
            // Its own do/catch: a failed face read must not stop the photos below from refreshing.
            do {
                people = try await database.peopleSummaries()
                personIDsByPhotoID = try await database.personIDsByPhotoID()
                // A person deleted or merged away while the filter was on: drop the filter instead of showing nothing forever.
                if let filter = personFilterID, !people.contains(where: { $0.id == filter }) { personFilterID = nil }
            } catch {
                people = []
                personIDsByPhotoID = [:]
                personFilterID = nil
            }
            do {
                smartCollections = try await database.allSmartCollections()
                smartCollectionLoadError = nil
            } catch {
                // Report a given failure once, not on every refresh (refresh follows nearly every mutation, so the alert
                // would keep returning and could overwrite an import summary).
                let message = "Couldn't load smart collections: \(error.localizedDescription)"
                if smartCollectionLoadError != message { importStatusMessage = message }
                smartCollectionLoadError = message
            }
            switch selectedFilter {
            case .allPhotos, .smartCollection:
                photos = try await database.allPhotos()
            case .collection(let collectionID):
                let viewed = viewedCollectionIDs(of: collectionID)
                photos = viewed.count > 1
                    ? try await database.photos(inCollections: Array(viewed).sorted())
                    : try await database.photos(inCollection: collectionID)
            }
            // Its own do/catch like the face read: a failed camera-data read keeps the previous map.
            if let loaded = try? await database.allMetadata() { metadataByPhotoID = loaded }
            startMetadataScanIfNeeded()
        } catch {
            // Best-effort — a transient read failure shouldn't blank out
            // an otherwise-valid, already-displayed library.
        }
    }

    /// The catalogued row at `path`, or `nil` if there genuinely isn't
    /// one — queries the database DIRECTLY, not the `photos` array (which
    /// respects `selectedFilter` and would miss a photo outside the
    /// currently-viewed collection). Used by `EnhanceModel` to guard
    /// against enhancing a photo that was opened via `Open…` rather than
    /// imported — see `registerEnhancedPhoto`'s own doc comment for why
    /// that guard matters.
    ///
    /// Reviewer-caught: an earlier version collapsed "not catalogued"
    /// and "database isn't ready yet" into the same `nil` — safe (the
    /// caller-side guard still refuses either way), but it would have
    /// shown the wrong diagnosis to the user in the "not ready" case
    /// (narrow in practice: the Library grid, and therefore anything the
    /// user could have clicked "Enhance" on, implies the database has
    /// already loaded — but cheap to make exact while this API's shape
    /// is still being set). `THROWS` for "not ready"/a genuine read
    /// failure now, matching `registerEnhancedPhoto`'s own error
    /// shape — only a clean, successful "no row at this path" read
    /// returns `nil`.
    func catalogedPhoto(atPath path: String) async throws -> Photo? {
        guard let database else {
            throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.")
        }
        return try await database.photo(atPath: path)
    }

    /// Registers `url` (a freshly-written `PhotoEnhancer` output) as a
    /// new catalog entry, refreshes the Library grid to show it, and
    /// invalidates any stale cached thumbnail for that exact path (a
    /// reused path — see `PhotoExporter.uniqueFileURL`'s own collision
    /// handling — could otherwise still be serving a thumbnail from
    /// whatever USED to be at that name).
    ///
    /// Deliberately does NOT itself grant/verify folder browsing access
    /// (`activeFolders`/`folderBookmarks`) — `EnhanceModel`'s own guard
    /// (only ever enhancing an ALREADY-catalogued photo) means `url`'s
    /// folder was necessarily already imported via `importFolder()`/
    /// `importFolderTree()` at some point, which already activated that
    /// browsing scope. This is a reasoned-through design expectation,
    /// NOT yet a measured fact (reviewer-caught: an earlier version of
    /// this comment overclaimed "live verification confirms this holds"
    /// — that verification hasn't happened yet; `EnhanceModel`/the UI
    /// wiring is a later commit, and PROGRESS.md's own live-verification
    /// checklist for this feature is still outstanding). The live pass,
    /// once it happens, must specifically confirm the enhanced photo's
    /// thumbnail renders with no surprise second `CatalogModel`-side
    /// prompt.
    @discardableResult
    func registerEnhancedPhoto(at url: URL) async throws -> Photo {
        guard let database else {
            throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.")
        }
        let photo = try await database.registerPhoto(at: url)
        invalidateThumbnail(for: url)
        await refresh()
        return photo
    }

    /// After an import: reads the `.xmp` sidecar (or embedded XMP) of every photo that was not in the catalog before and fills ONLY fields still at
    /// their defaults, so a photo already rated/labelled/keyworded in another app arrives that way and a value the user set is never overwritten.
    /// Read-only, silent; runs inside the import's `importsInFlight` window so a rename cannot start under it. A failure is ignored (the manual
    /// "Read Metadata from XMP…" is the explicit path).
    func autoReadXMP(newerThan before: Set<Int64>) async {
        guard preferences.autoReadXMPOnImport else { return }
        guard let database, let all = try? await database.allPhotos() else { return }
        let fresh = all.filter { photo in photo.id.map { !before.contains($0) } ?? false }
        guard !fresh.isEmpty else { return }
        let allPaths = all.map(\.path)
        let reads = await Task.detached { XMPModel.readAll(photos: fresh, allPaths: allPaths) }.value
        _ = try? await applyXMPFields(reads.items, mode: .fillDefaults)
    }

    /// The CURRENT catalog rows for `ids` (after a refresh, so keyword names are current too), in the order given; ids that no longer exist are
    /// dropped. XMP writes use this rather than the rows captured when the menu was clicked (a folder prompt and a background task sit between).
    func freshPhotos(ids: [Int64]) async -> [Photo] {
        guard let database, let all = try? await database.allPhotos() else { return [] }
        await refresh()
        let byID = Dictionary(all.compactMap { photo in photo.id.map { ($0, photo) } }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// The Backups folder next to the catalog (only its parent, the catalog directory, is created if missing; the Backups folder itself is not).
    var backupsFolderURL: URL? {
        (try? CatalogDatabase.defaultCatalogDirectory()).map(CatalogDatabase.backupsDirectory(in:))
    }

    /// Preferences ▸ Back Up Now: a backup into the Backups folder, pruned to the "keep" preference. Returns what to tell the user. Shares
    /// `backupBusy` with File ▸ Back Up Catalog… so the two never run at once.
    func backUpNow(into directory: URL? = nil) async -> String {
        guard !backupBusy, !backUpNowRunning else { return "A backup is already running." }
        guard let database, let folder = directory ?? backupsFolderURL else { return "The photo catalog isn't ready yet — try again in a moment." }
        backUpNowRunning = true
        backupBusy = true
        defer { backUpNowRunning = false; backupBusy = catalogBackup.isBusy }
        do {
            let file = try await database.backUpIntoBackupsFolder(folder, keepNewest: preferences.backupsToKeep)
            return "Backed up as \(file.lastPathComponent)."
        } catch {
            return "Couldn't back up the catalog: \(error.localizedDescription)"
        }
    }

    // MARK: - Photos in subfolders

    /// `folderID` and every folder below it, found breadth-first over the `parentId` links the sidebar draws. Only folder rows count,
    /// each id is visited once (a corrupt parent cycle ends instead of looping), and the result always contains `folderID` itself.
    /// A folder imported AFTER its parent folder was already imported stays a separate root (`findOrCreateFolderCollection` never
    /// re-parents), so it is not below that parent here — the sidebar does not show it there either.
    nonisolated static func descendantFolderIDs(of folderID: Int64, in collections: [PhotoCollection]) -> Set<Int64> {
        let childrenByParent = Dictionary(grouping: collections.filter(\.isFolder), by: \.parentId)
        var seen: Set<Int64> = [folderID]
        var queue = [folderID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in childrenByParent[current] ?? [] {
                guard let id = child.id, seen.insert(id).inserted else { continue }
                queue.append(id)
            }
        }
        return seen
    }

    private func recomputeFolderPhotoCounts() {
        let counts = SidebarRows.folderPhotoCounts(collections: collections, membershipsByPhotoID: membershipsByPhotoID,
                                                   includeSubfolders: showPhotosInSubfolders)
        if counts != folderPhotoCounts { folderPhotoCounts = counts }
    }

    func descendantFolderIDs(of folderID: Int64) -> Set<Int64> { Self.descendantFolderIDs(of: folderID, in: collections) }

    /// The collection ids whose photos the grid shows for `.collection(collectionID)`: just that one, unless it is a folder and
    /// "show photos in subfolders" is on, in which case the folder and all its descendants.
    private func viewedCollectionIDs(of collectionID: Int64) -> Set<Int64> {
        guard showPhotosInSubfolders, collections.first(where: { $0.id == collectionID })?.isFolder == true else { return [collectionID] }
        return descendantFolderIDs(of: collectionID)
    }

    /// Every collection id the current filter shows photos of (empty for All Photos / a smart collection).
    var viewedCollectionIDs: Set<Int64> {
        guard case .collection(let id) = selectedFilter else { return [] }
        return viewedCollectionIDs(of: id)
    }

    /// What the Library is showing, in words (a confirmation names it): All Photos, or the selected collection / smart collection.
    var currentScopeName: String {
        switch selectedFilter {
        case .allPhotos: return "All Photos"
        case .collection(let id):
            guard let collection = collections.first(where: { $0.id == id }) else { return "this collection" }
            return viewedCollectionIDs.count > 1 ? "“\(collection.name)” and its subfolders" : "“\(collection.name)”"
        case .smartCollection(let id): return smartCollections.first { $0.id == id }.map { "“\($0.name)”" } ?? "this smart collection"
        }
    }

    /// After `TrashEngine` moved these photos' files to the Trash: remove exactly their rows (one transaction), forget them in the selection and
    /// the focus, drop their cached thumbnails and re-read the library (`photoCount` must follow: the empty-state logic trusts it).
    func removeTrashedPhotos(ids: [Int64], paths: [String]) async throws {
        guard let database else { throw CatalogDatabaseError(message: "The photo catalog isn't ready yet.") }
        try await database.deletePhotos(ids: ids)
        selectedPhotoIDs.subtract(ids)
        if let focused = focusedPhotoPath, paths.contains(focused) { focusedPhotoPath = nil }
        for path in paths { invalidateThumbnail(for: URL(fileURLWithPath: path)) }
        await refresh()
    }

    /// A consistent snapshot of the live catalog written to `destination` (the engine is `CatalogDatabase.backUp(to:)`).
    func backUpCatalog(to destination: URL) async throws -> CatalogFileInfo {
        guard let database else { throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.") }
        return try await database.backUp(to: destination)
    }

    /// Applies fields read from XMP sidecars (`XMPImportPolicy` decides what changes), in chunks so one huge batch cannot hold the
    /// database queue (which blocks reads too) for long, then refreshes the Library. Returns the ids that really changed.
    func applyXMPFields(_ items: [(photoID: Int64, fields: XMPLibraryFields)], mode: XMPImportPolicy.Mode) async throws -> Set<Int64> {
        guard let database else { throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.") }
        var changed = Set<Int64>()
        for start in stride(from: 0, to: items.count, by: 500) {
            changed.formUnion(try await database.applyLibraryFields(Array(items[start..<min(start + 500, items.count)]), mode: mode))
        }
        if !changed.isEmpty { await refresh() }
        return changed
    }

    // MARK: - Batch rename (Library "Rename Files…")

    /// Every catalogued path → its photo id (the WHOLE catalog, not just the folder/collection on
    /// screen), so the rename plan can refuse a target another photo already owns even if that photo
    /// isn't in view. Empty when the catalog isn't ready.
    func cataloguedPathOwners() async -> [String: Int64] {
        guard let database, let all = try? await database.allPhotos() else { return [:] }
        return Dictionary(all.compactMap { photo in photo.id.map { (photo.path, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The most recent applied rename batch (what "Undo Rename" would undo), if any.
    func lastRenameLog() async -> LoggedRename? {
        guard let database else { return nil }
        return try? await database.lastRenameLog()
    }

    /// Renames `moves` (files + sidecars + catalog rows, all-or-nothing — see `RenameApplier`), then
    /// invalidates the thumbnails at BOTH the old and new paths (the thumbnail cache is keyed by
    /// path), re-points the keyboard focus if it sat on a renamed photo, and refreshes the grid.
    /// The blocking file I/O runs detached, off the main actor.
    func applyRename(_ moves: [RenameMove]) async throws -> Int {
        guard let database else {
            throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.")
        }
        let count = try await Task.detached { try await RenameApplier.apply(moves, database: database) }.value
        await afterRename(moves)
        return count
    }

    /// Undoes the most recent rename batch (see `RenameApplier.undoLast`), with the same cache and
    /// focus housekeeping. Returns how many photos were restored.
    func undoLastRename(expectedBatchID: Int64? = nil) async throws -> Int {
        guard let database else {
            throw CatalogDatabaseError(message: "The photo catalog isn't ready yet — try again in a moment.")
        }
        let log = try await database.lastRenameLog()
        let count = try await Task.detached {
            try await RenameApplier.undoLast(database: database, expectedBatchID: expectedBatchID)
        }.value
        await afterRename((log?.moves ?? []).map(\.inverse))
        return count
    }

    /// Thumbnails are cached by PATH, so both names go stale; focus is tracked by path too. (Known, low
    /// severity: a thumbnail already being decoded for an OLD path when the rename lands can finish after
    /// this invalidation and cache a stale image under that dead path — nothing displays it, and an
    /// Undo invalidates again.)
    private func afterRename(_ moves: [RenameMove]) async {
        for move in moves {
            invalidateThumbnail(for: URL(fileURLWithPath: move.oldPath))
            invalidateThumbnail(for: URL(fileURLWithPath: move.newPath))
            if focusedPhotoPath == move.oldPath { focusedPhotoPath = move.newPath }
        }
        await refresh()
    }

    /// Returns a small thumbnail for `photo`, decoded (and cached) off the
    /// main thread. Requires `photo`'s containing folder to currently have
    /// active security scope — true for a folder imported this session,
    /// and true after a relaunch once `activateKnownFolders()` (run once
    /// at `init`) has resolved its stored bookmark.
    func thumbnail(for photo: Photo) async -> CGImage? {
        let result = await thumbnailCache.thumbnail(for: photo)
        if result == nil { await recoverAccessAfterFailedThumbnail(photo) }
        return result
    }

    /// Roots whose access a failed thumbnail already tried to restore this session (one silent attempt per root, so a folder that stays broken
    /// is not re-resolved for every cell). Never cleared: a grant that goes stale a SECOND time in one session gets no silent recovery (the Editor-open path
    /// still recovers it, with a prompt). Separate from `reactivationTasks`, so a thumbnail recovery and an Editor-open recovery of the same root can each start a
    /// scope (at most one leaked extension per root).
    private var silentRecoveryTried: Set<String> = []
    /// Photos whose failure was already classified as NOT a sandbox problem (corrupt file, offline volume, chmod): not probed again every time a
    /// cell asks for its thumbnail (a `open`+`stat` per cell per scroll could block on a stuck network mount).
    private var thumbnailFailureNotSandbox: Set<String> = []
    /// The recovery in flight per root: concurrent failing cells (a whole screen of them at once) share ONE probe and ONE re-resolve instead of each
    /// starting their own (each unmatched `startAccessingSecurityScopedResource()` leaks a sandbox extension). Same shape as `reactivationTasks`.
    private var thumbnailRecoveryTasks: [String: Task<Void, Never>] = [:]

    /// D31: a thumbnail decode that returns nil is the one moment worth checking WHY (failed decodes are not cached, so this does not run for
    /// every cell). If the file exists and its permission bits allow reading but `open` fails, the folder's security scope has gone stale: re-resolve
    /// its stored bookmark silently — NEVER a panel from a scrolling grid — and ask the grid to request its thumbnails again.
    private func recoverAccessAfterFailedThumbnail(_ photo: Photo) async {
        let path = photo.path
        guard !thumbnailFailureNotSandbox.contains(path),
              let root = PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: path, activeFolders: activeFolders)
                ?? PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: path, activeFolders: Set(folderBookmarks.keys)),
              !silentRecoveryTried.contains(root) else { return }
        // Everything from the checks above through the task assignment below has no suspension point, so a second cell cannot slip in between.
        // A cell that waited on someone else's recovery returns only if that recovery settled the question for ITS photo too: the shared probe looked at
        // a different file, which may have failed for another reason (corrupt, chmod) while this one really is sandbox-denied.
        while let inFlight = thumbnailRecoveryTasks[root] {
            await inFlight.value
            // The finished task's entry is cleared by its creator only when that creator resumes; clear it here too, or this loop would spin on a
            // finished task (awaiting it does not yield) and the creator, on this same actor, would never get to run.
            if thumbnailRecoveryTasks[root] == inFlight { thumbnailRecoveryTasks[root] = nil }
            guard !silentRecoveryTried.contains(root), !thumbnailFailureNotSandbox.contains(path) else { return }
        }
        let probe = readabilityProbe
        let task = Task { [weak self] in
            guard let self else { return }
            guard await Task.detached(operation: { probe(path) }).value == .sandboxDenied else {
                self.thumbnailFailureNotSandbox.insert(path)
                return
            }
            self.silentRecoveryTried.insert(root)
            // On success `reacquireAccess` itself asks the cells under the root to reload (`requestThumbnailsAgain`).
            await self.reacquireAccess(forStaleRoot: root, allowPrompt: false)
        }
        thumbnailRecoveryTasks[root] = task
        await task.value
        if thumbnailRecoveryTasks[root] == task { thumbnailRecoveryTasks[root] = nil } // never clear a NEWER task's entry
    }

    /// True only if `photo`'s file is confirmed genuinely missing — used by
    /// the Library grid and Editor filmstrip to distinguish "deleted" from
    /// "present" (whether just decoded or served from `ThumbnailCache`) or
    /// "can't currently verify." Called UNCONDITIONALLY on every cell
    /// appearance, not gated on a failed decode — reviewer-caught, after
    /// shipping the gated version: `ThumbnailCache` serves an
    /// already-decoded thumbnail forever with no freshness check, so a
    /// photo viewed before its file was deleted would never fail its
    /// decode again, and a check gated on decode failure would never run
    /// for it. Three things all have to hold: `photo.path` sits
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
    /// seconds, and (now that this runs on every appearance, not just a
    /// failed decode) that cost lands on the common path too, not just an
    /// already-slow one. The `&&` below still short-circuits to a single
    /// stat in the ordinary present-file case. `folders`/`path`/`root` are
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

    // MARK: - Relocating missing photos (D5 follow-up, IMPROVEMENTS.md)

    /// Presents a FOLDER picker (not a file picker — reviewer-caught, see
    /// below) for where `photo` was moved to, and updates its catalog row
    /// to point at the same-named file there. Unlike this class's usual
    /// local-first-then-resync mutators, this writes to the database
    /// FIRST and only then reflects the outcome via a full `refresh()` —
    /// relocate has a real, common failure mode a synchronous local check
    /// can't detect at all (the destination path may already be claimed
    /// by a DIFFERENT catalogued row, see `CatalogDatabase.relocatePhotos`'s
    /// own doc comment), so there's nothing safe to assume optimistically
    /// ahead of the write.
    ///
    /// Known gap, not solved this slice: folder-mirrored collection
    /// membership (`importFolderTree`) is NOT updated by a relocate — a
    /// photo keeps its membership in its OLD folder's `PhotoCollection`
    /// even though `folderPath` no longer contains it, and isn't added to
    /// the destination folder's collection even if one already exists.
    /// The sidebar's "Folders" section can therefore list a relocated
    /// photo under a folder it's no longer physically inside.
    ///
    /// A FOLDER picker, not a single-file picker: an earlier draft let the
    /// user pick the exact file directly, then tried to derive and grant
    /// access to its PARENT folder — reviewer-caught as very likely a
    /// silent no-op under this app's sandbox entitlement
    /// (`files.user-selected.read-write`). Powerbox grants a security
    /// scope for exactly the item the user picked in the panel; a file
    /// selection does not extend to its parent directory. Every other
    /// folder-access grant in this app is a folder the user picked in a
    /// DIRECTORY-mode panel (`importFolder`, `importFolderTree`,
    /// `ImageDocumentModel.requestFolderAccess` — the last one's own doc
    /// comment exists specifically because deriving a parent from an
    /// already-picked file isn't sufficient). Matching by filename within
    /// a picked folder (shared with `relocateSelectedPhotos` via
    /// `PhotoImporter.matchByFilename`) sidesteps the problem entirely —
    /// same tradeoff as the batch flow: a renamed (not just moved) file
    /// won't be found this way, accepted for this slice.
    ///
    /// Inherited limitation from `isPhotoConfirmedMissing` (the gate that
    /// controls whether this action is even offered, via the Library
    /// grid's `isMissing`): it requires the photo's ORIGINALLY-IMPORTED
    /// folder root to still exist, to distinguish "deleted" from "can't
    /// verify". So if the user moved/renamed the WHOLE containing folder
    /// (not just this one file out of an intact folder), the photo never
    /// reads as "Missing" in the first place, and this action is never
    /// offered for it. Documented, not solved, this slice.
    func relocatePhoto(_ photo: Photo) async {
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return }
        guard let id = photo.id, let database else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder \"\(photo.filename)\" was moved to."
        panel.prompt = "Locate"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        // Re-check AFTER the panel: a rename/undo may have started while it was up.
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return }
        // Captured, not treated as fatal — `activateFolderAccess` returns
        // a warning for TWO independent failure modes, only one of which
        // actually blocks this relocate: if only the BOOKMARK write
        // failed (access still holds for this session,
        // `activateFolderAccess`'s own doc comment), the relocate can
        // still proceed; only a failed `startAccessingSecurityScopedResource()`
        // means we truly can't read the folder. Folded into the final
        // summary instead of short-circuiting, matching `importFolder`'s
        // own established handling of this exact helper's return value
        // (reviewer-caught: an earlier draft treated ANY warning as fatal
        // and could silently abandon a relocate that would have worked).
        let accessWarning = activateFolderAccess(for: folder)

        // Directory enumeration is real, blocking filesystem I/O —
        // reviewer-caught: must not run on this @MainActor class's own
        // thread, matching `importFolder`/`importFolderTree`'s existing
        // `Task.detached` discipline for the identical concern.
        // Explicit closure return type is REQUIRED, not stylistic: Xcode 27
        // added a `name:` overload to `Task.detached`, and with a labeled
        // tuple result and no contextual type the call became ambiguous.
        // Pinning the return type resolves it. (The Bool-returning
        // `Task.detached` above needs no such help.)
        let matched: (moves: [(photoID: Int64, newPath: String)], unmatchedCount: Int) = await Task.detached {
            PhotoImporter.matchByFilename([photo], in: folder)
        }.value
        let moves = matched.moves
        guard let move = moves.first else {
            importStatusMessage = ["Couldn't find \"\(photo.filename)\" in that folder.", accessWarning]
                .compactMap { $0 }.joined(separator: " ")
            return
        }

        let oldPath = photo.path
        var summary: String
        do {
            let relocated = try await database.relocatePhotos([move])
            if relocated.contains(id) {
                invalidateThumbnail(for: URL(fileURLWithPath: oldPath))
                // Sidecars live next to the ORIGINAL file
                // (`ImageDocumentModel.sidecarURL(for:)`) and are never
                // moved by this action — flagged here rather than solved,
                // since moving one would need write access to the OLD
                // folder too, not otherwise needed anywhere in this app.
                summary = "Relocated \"\(photo.filename)\". If it had saved edits, move its sidecar file too to keep them."
            } else {
                summary = "Couldn't relocate \"\(photo.filename)\" — a different photo is already catalogued at that location."
            }
        } catch {
            summary = "Couldn't relocate \"\(photo.filename)\"."
        }
        if let accessWarning { summary += " \(accessWarning)" }
        importStatusMessage = summary
        await refresh()
    }

    /// Batch counterpart to `relocatePhoto(_:)`. Only the
    /// currently-selected photos that are ACTUALLY confirmed missing get
    /// matched — an unrelated selected photo whose file is already
    /// present is left untouched, not blindly relocated just because a
    /// same-named file happens to exist in the chosen folder. Same
    /// inherited "whole folder moved" limitation as `relocatePhoto(_:)`'s
    /// own doc comment describes.
    func relocateSelectedPhotos() async {
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return }
        guard let database else { return }
        let visibleSelectedIDs = Set(photos.compactMap(\.id)).intersection(selectedPhotoIDs)
        guard !visibleSelectedIDs.isEmpty else { return }
        let candidates = photos.filter { visibleSelectedIDs.contains($0.id ?? -1) }

        var missing: [Photo] = []
        for photo in candidates where await isPhotoConfirmedMissing(photo) {
            missing.append(photo)
        }
        guard !missing.isEmpty else {
            importStatusMessage = "None of the selected photos are missing."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder these \(missing.count) photo(s) were moved to."
        panel.prompt = "Locate"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        // Re-check AFTER the panel: a rename/undo may have started while it was up.
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return }
        // See `relocatePhoto(_:)`'s own doc comment for why this is
        // captured and folded into the summary rather than treated as
        // unconditionally fatal.
        let accessWarning = activateFolderAccess(for: folder)

        // See `relocatePhoto(_:)`'s own doc comment for why this must not
        // run on the main actor.
        // Explicit return type required — see `relocatePhoto(_:)`.
        let matched: (moves: [(photoID: Int64, newPath: String)], unmatchedCount: Int) = await Task.detached {
            PhotoImporter.matchByFilename(missing, in: folder)
        }.value
        let (moves, unmatchedCount) = (matched.moves, matched.unmatchedCount)
        guard !moves.isEmpty else {
            importStatusMessage = ["No matching files found in that folder.", accessWarning]
                .compactMap { $0 }.joined(separator: " ")
            return
        }

        var summary: String
        do {
            let relocated = try await database.relocatePhotos(moves)
            for move in moves where relocated.contains(move.photoID) {
                if let oldPath = candidates.first(where: { $0.id == move.photoID })?.path {
                    invalidateThumbnail(for: URL(fileURLWithPath: oldPath))
                }
            }
            await refresh()
            let conflictCount = moves.count - relocated.count
            summary = "Relocated \(relocated.count) of \(missing.count) photo(s)."
            if unmatchedCount > 0 { summary += " \(unmatchedCount) not found in that folder." }
            if conflictCount > 0 { summary += " \(conflictCount) skipped (already catalogued at that location)." }
            if relocated.count > 0 {
                // See `relocatePhoto(_:)`'s own doc comment — sidecars
                // (saved edits) are never moved by this action.
                summary += " Move any saved-edit sidecar files too, to keep their edits."
            }
        } catch {
            await refresh()
            summary = "Couldn't relocate the selected photos."
        }
        if let accessWarning { summary += " \(accessWarning)" }
        importStatusMessage = summary
    }

    /// One monotonically-increasing counter per photo path, bumped every
    /// time that photo's thumbnail is invalidated — lets a grid cell
    /// re-fetch its thumbnail (and re-read `hasEdits`) WHILE the grid
    /// stays on screen for the SAME path, not just the next time the grid
    /// is rebuilt from scratch. Before this, the distinction didn't
    /// matter: EVERY earlier `invalidateThumbnail(for:)` call site
    /// invalidates a path that either has no on-screen cell to refresh at
    /// all (`removePhoto`'s own just-deleted photo) or invalidates the
    /// OLD path of a photo that just moved (`relocatePhoto`/
    /// `relocateSelectedPhotos`, whose cell is already re-keyed onto the
    /// NEW path by the time this runs) — never the SAME path a
    /// currently-visible cell is still showing. `PasteSettingsModel`'s
    /// batch paste (shipped) was the first caller that DOES invalidate a
    /// path while a cell showing that exact path can be on screen, by
    /// writing sidecars for photos visible in an already-open grid;
    /// `registerEnhancedPhoto` (above) is a second, different case — a
    /// brand-new path the grid has never shown before, where this same
    /// mechanism still matters for a reused path (see
    /// `PhotoExporter.uniqueFileURL`'s own collision handling).
    @Published private(set) var thumbnailRevisions: [String: Int] = [:]

    /// Drops the cached thumbnail for the photo at `url`. Callers:
    /// `ImageDocumentModel.onSidecarSaved` via `ContentView`,
    /// `relocatePhoto`/`relocateSelectedPhotos`, `removePhoto` (none of
    /// these need a same-path grid refresh — see `thumbnailRevisions`'
    /// own doc comment for why), `PasteSettingsModel`'s batch paste, and
    /// `registerEnhancedPhoto` (above). Should be called once the actual
    /// file write it's invalidating for has finished on disk — calling it
    /// any earlier would let a cell's re-fetch race ahead of the write
    /// and read stale data. Sync wrapper (matching this class's other
    /// mutators) —
    /// the actual invalidation hops to the `ThumbnailCache` actor via a
    /// `Task`, which then bumps `thumbnailRevisions` AFTER that
    /// invalidation completes (not before) — bumping first would let a
    /// cell's own concurrent re-fetch run ahead of the cache actually
    /// being cleared and simply SERVE the still-cached stale bitmap under
    /// the new revision number, rather than re-decoding.
    func invalidateThumbnail(for url: URL) {
        let path = url.path
        Task {
            await thumbnailCache.invalidate(path: path)
            thumbnailRevisions[path, default: 0] += 1
        }
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

    /// The actual `Photo` values behind `selectedPhotoIDs`, intersected
    /// with `photos` — NOT `selectedPhotoIDs.count`/a raw ID lookup,
    /// because `selectedPhotoIDs` can hold "ghost" ids: `toggleMembership`
    /// does NOT prune a photo's selection when it removes that photo from
    /// the currently-viewed collection's grid, so a photo toggled OUT of
    /// the collection being viewed can stay in `selectedPhotoIDs` while no
    /// longer part of the current Collection/Folder source set (see
    /// `addSelectedPhotos(to:)`'s own doc comment for the full story).
    ///
    /// This intersects against `photos` (the current Collection/Folder
    /// scope), NOT `displayedPhotos` (which ALSO applies the search/
    /// rating/flag filters) — matching `ContentView.photosToExport`'s own
    /// `photos`-not-`displayedPhotos` scope (that property additionally
    /// falls back to ALL of `photos` when nothing is selected, which this
    /// one deliberately does not — see this feature's own planning notes
    /// on why a batch paste must never silently default to "everything").
    /// A photo hidden by an active search but still checked is therefore
    /// still included here, same as it already is for Export/"Add to
    /// Collection" today; this property doesn't change that, only names
    /// it.
    ///
    /// `ContentView.selectedPhotosVisibleInGrid` forwards to this;
    /// intended to eventually replace `addSelectedPhotos(to:)`/
    /// `relocateSelectedPhotos()`'s own ad hoc copies of the same filter
    /// too, not done here to keep this change scoped.
    var selectedPhotos: [Photo] {
        photos.filter { isSelected($0) }
    }

    /// The selected photos that the Library grid is actually showing (`selectedPhotos` also holds ones hidden by the current filters): what a
    /// merge acts on, so photos the user cannot see are never merged.
    var selectedPhotosInDisplayedGrid: [Photo] {
        let visible = Set(displayedPhotos.compactMap(\.id))
        return selectedPhotos.filter { $0.id.map(visible.contains) ?? false }
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

    /// Sets `photo`'s pick/reject flag — same shape/reasoning as `setRating`,
    /// minus the clamp (`FlagStatus` has no invalid value to guard against).
    func setFlagStatus(_ status: FlagStatus, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        updatePhotoInPlace(id: id) { $0.flagStatus = status }
        Task.detached { [weak self] in
            do { try await database.setFlagStatus(status, for: id) } catch { await self?.refresh() }
        }
    }

    /// Sets the flag of every photo in `photoIDs` (duplicate review). Local-first like the single-photo setter; the
    /// database write is ONE transaction and its returned ids (photos that still existed) are what the caller reports.
    /// Returns nil when the write FAILED (local state is then re-read from the database), so the caller never reports a
    /// failure as "rejected 0".
    func setFlagStatus(_ status: FlagStatus, forPhotoIDs photoIDs: [Int64]) async -> Set<Int64>? {
        guard let database else { return nil }
        guard !photoIDs.isEmpty else { return [] }
        for id in photoIDs { updatePhotoInPlace(id: id) { $0.flagStatus = status } }
        do {
            return try await database.setFlagStatus(status, forPhotoIDs: photoIDs)
        } catch {
            await refresh()
            return nil
        }
    }

    /// Begins a duplicate scan of the photos the Library is currently drawing from (all photos, a collection, or a smart
    /// collection's source). Refuses while a rename is in progress (it moves files under the scan).
    func beginDuplicateScan() {
        guard !isRenameInProgress else { duplicates.statusMessage = Self.renameInProgressMessage; return }
        guard let database else { duplicates.statusMessage = "The photo catalog isn't ready yet — try again in a moment."; return }
        duplicates.scan(photos: smartCollectionSourcePhotos, database: database)
    }

    /// True while a Library tool sheet (keywords, duplicates, people) is up or one of their scans runs; batch rename must not start then.
    var toolSheetIsBusy: Bool {
        keywordSheetPhotoIDs != nil || duplicatesSheetPresented || duplicates.isScanning || peopleSheetPresented || faces.isWorking || mergeBusy || xmpBusy || trashBusy || importCopyBusy || backupBusy
    }

    /// The People sheet's scan: finds faces in the photos the Library is currently drawing from, then regroups ALL stored faces.
    /// Same guards as the duplicate scan (a rename moves files under it).
    func beginFaceScan() {
        guard !isRenameInProgress else { faces.statusMessage = Self.renameInProgressMessage; return }
        guard let database else { faces.statusMessage = "The photo catalog isn't ready yet — try again in a moment."; return }
        faces.scanAndGroup(photos: smartCollectionSourcePhotos, database: database)
    }

    /// Sets `photo`'s color label — same local-first shape/reasoning as `setFlagStatus`.
    func setColorLabel(_ label: ColorLabel, for photo: Photo) {
        guard let database, let id = photo.id else { return }
        updatePhotoInPlace(id: id) { $0.colorLabel = label }
        Task.detached { [weak self] in
            do { try await database.setColorLabel(label, for: id) } catch { await self?.refresh() }
        }
    }

    /// Removes `photo` from the catalog (D5, IMPROVEMENTS.md) — catalog
    /// row only, the original file on disk is never touched (see
    /// `CatalogDatabase.deletePhoto`'s own doc comment). Local-first, same
    /// shape/failure-resync reasoning as `setRating`/`setFlagStatus`, but
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
        guard !isRenameInProgress else { importStatusMessage = Self.renameInProgressMessage; return }
        guard let database, let id = photo.id else { return }
        let before = photos.count
        photos.removeAll { $0.id == id }
        // Keep the empty-state decision honest: `photoCount` is only re-read by `refresh()`, which this path skips on success.
        // Only when the list actually got shorter (a repeated Remove on the same cell must not under-count).
        if photos.count < before { photoCount = max(0, photoCount - 1) }
        selectedPhotoIDs.remove(id)
        membershipsByPhotoID.removeValue(forKey: id)
        recomputeFolderPhotoCounts()
        keywordIDsByPhotoID.removeValue(forKey: id)
        personIDsByPhotoID.removeValue(forKey: id)
        metadataByPhotoID.removeValue(forKey: id)
        invalidateThumbnail(for: URL(fileURLWithPath: photo.path))
        Task.detached { [weak self] in
            do { try await database.deletePhoto(id: id) } catch { await self?.refresh() }
        }
    }

    // MARK: - Smart collections

    /// The filter bar's current criteria in saveable form: the four filter fields AND the search text (normalised: text that
    /// restricts nothing, like `iso:`, is dropped). The sort order is not part of a smart collection.
    var currentFilterCriteria: SmartCollectionCriteria {
        SmartCollectionCriteria(
            minimumRating: minimumRating, flag: flagFilter, label: labelFilter,
            keywordKey: keywordFilterID.flatMap { id in keywords.first { $0.id == id }?.nameKey },
            searchQuery: SmartCollectionCriteria.normalizedQuery(searchText)
        )
    }

    /// Why the search box cannot be saved right now (an unreadable field value would save a collection that matches nothing).
    var saveBlockedBySearch: String? {
        SearchQuery(parsing: searchText).invalidTerms.first.map { "Can't read \"\($0)\" in the search box: fix it before saving." }
    }

    /// Resets the fields a smart collection saves, search text included (a search left in the box would be ANDed on top of
    /// the saved one and the grid would no longer show exactly what was saved). The sort order is left as the user set it. The
    /// person filter is neither saved nor cleared here (a smart collection has no person criterion yet).
    private func clearSavedFilterCriteria() {
        minimumRating = 0
        flagFilter = .all
        labelFilter = .all
        keywordFilterID = nil
        searchText = ""
    }

    /// Whether there is anything in the filter bar worth saving.
    var hasSaveableFilterCriteria: Bool { !currentFilterCriteria.isEmpty && saveBlockedBySearch == nil }

    /// Saves the filter bar as a new smart collection, then resets the bar and selects the new row so the grid shows
    /// exactly what was saved. Failures (empty/duplicate name) are reported via `importStatusMessage`.
    @discardableResult
    func saveFiltersAsSmartCollection(name: String) async -> Bool {
        guard let database else { return false }
        if let blocked = saveBlockedBySearch { importStatusMessage = blocked; return false }
        let criteria = currentFilterCriteria
        guard !criteria.isEmpty else {
            importStatusMessage = "Set a rating, flag, label or keyword filter, or type a search, first, then save it."
            return false
        }
        do {
            let created = try await database.createSmartCollection(name: name, criteria: criteria)
            await refresh()
            guard let id = created.id else { return true }
            clearSavedFilterCriteria()
            selectedFilter = .smartCollection(id)
            return true
        } catch {
            importStatusMessage = error.localizedDescription
            return false
        }
    }

    func renameSmartCollection(_ smart: SmartCollection, to name: String) async {
        guard let database, let id = smart.id else { return }
        do {
            try await database.renameSmartCollection(id: id, to: name)
        } catch {
            importStatusMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Replaces the collection's criteria with the filter bar's current ones. The collection being viewed keeps
    /// being viewed; the bar is reset so the grid shows exactly what was saved.
    func updateSmartCollectionFromFilters(_ smart: SmartCollection) async {
        guard let database, let id = smart.id else { return }
        if let blocked = saveBlockedBySearch { importStatusMessage = blocked; return }
        let criteria = currentFilterCriteria
        guard !criteria.isEmpty else {
            importStatusMessage = "Set a rating, flag, label or keyword filter, or type a search, first, then update the smart collection from it."
            return
        }
        do {
            try await database.updateSmartCollectionCriteria(id: id, to: criteria)
            await refresh()
            if selectedFilter == .smartCollection(id) { clearSavedFilterCriteria() }
        } catch {
            importStatusMessage = error.localizedDescription
            await refresh()
        }
    }

    /// Deletes the smart collection (no photo is affected). The sidebar selection falls back to All Photos only
    /// AFTER the write lands — flipping it first would let a refresh triggered by the flip re-fetch the row and
    /// restore it (the same race `deleteCollection` documents).
    func deleteSmartCollection(_ smart: SmartCollection) async {
        guard let database, let id = smart.id else { return }
        do {
            try await database.deleteSmartCollection(id: id)
        } catch {
            importStatusMessage = error.localizedDescription
            await refresh()
            return
        }
        smartCollections.removeAll { $0.id == id }
        if selectedFilter == .smartCollection(id) { selectedFilter = .allPhotos }
        await refresh()
    }

    // MARK: - Keywords

    /// Opens the keyword sheet over the selected photos that belong to the current source set (`selectedPhotos`).
    /// NOT filtered by the search/rating/keyword filters: photos the filters hide stay selected and are edited
    /// too (same as Rename/Paste), which the sheet title discloses. No-op for an empty selection.
    func beginEditingKeywords() {
        let ids = selectedPhotos.compactMap(\.id)
        guard !ids.isEmpty else { return }
        keywordSheetPhotoIDs = ids
    }

    static func sortedKeywords(_ list: [Keyword]) -> [Keyword] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// keywordID → how many photos carry it, across the whole catalog. One pass; callers build it once per render.
    var keywordPhotoCounts: [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for set in keywordIDsByPhotoID.values { for id in set { counts[id, default: 0] += 1 } }
        return counts
    }

    /// Keyword display names (sorted case-insensitively, like the sheet) for each of `photos` that has any — what an
    /// export embeds. A value snapshot, safe to hand to a detached task.
    func keywordNames(for photos: [Photo]) -> [Int64: [String]] {
        let namesByID = keywordNamesByID
        var result: [Int64: [String]] = [:]
        for photo in photos {
            guard let id = photo.id, let ids = keywordIDsByPhotoID[id] else { continue }
            let names = ids.compactMap { namesByID[$0] }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if !names.isEmpty { result[id] = names }
        }
        return result
    }

    /// Adds the keywords parsed from `input` (see `KeywordName.parse`) to `photoIDs`. The write
    /// finds-or-creates keywords, so ids are only known afterwards: this one updates state from
    /// the database result instead of guessing locally. Returns the parsed names (empty = nothing typed).
    @discardableResult
    func addKeywords(_ input: String, to photoIDs: [Int64]) -> [String] {
        let names = KeywordName.parse(input)
        guard let database, !names.isEmpty else { return names }
        Task { [weak self] in
            // No local guess: find-or-create gives ids only now, and refresh() replaces the maps wholesale.
            do {
                _ = try await database.addKeywords(names, to: photoIDs)
            } catch {
                self?.importStatusMessage = "Couldn't add keywords: \(error.localizedDescription)"
            }
            await self?.refresh()
        }
        return names
    }

    /// Detaches `keywordID` from `photoIDs` — local-first like `setRating`.
    func removeKeyword(id keywordID: Int64, from photoIDs: [Int64]) {
        guard let database else { return }
        for photoID in photoIDs {
            keywordIDsByPhotoID[photoID]?.remove(keywordID)
            if keywordIDsByPhotoID[photoID]?.isEmpty == true { keywordIDsByPhotoID.removeValue(forKey: photoID) }
        }
        Task.detached { [weak self] in
            do { try await database.removeKeyword(id: keywordID, from: photoIDs) } catch { await self?.refresh() }
        }
    }

    /// Deletes the keyword everywhere (its links cascade). Clears the filter if it pointed at it. `refresh()`
    /// deliberately does NOT clear a dangling `keywordFilterID` (a stale in-flight read could wrongly drop a
    /// just-chosen filter); this is the only place a keyword disappears.
    func deleteKeyword(id keywordID: Int64) {
        guard let database else { return }
        keywords.removeAll { $0.id == keywordID }
        for photoID in Array(keywordIDsByPhotoID.keys) {
            keywordIDsByPhotoID[photoID]?.remove(keywordID)
            if keywordIDsByPhotoID[photoID]?.isEmpty == true { keywordIDsByPhotoID.removeValue(forKey: photoID) }
        }
        if keywordFilterID == keywordID { keywordFilterID = nil }
        Task.detached { [weak self] in
            do { try await database.deleteKeyword(id: keywordID) } catch { await self?.refresh() }
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
    /// shape and failure-resync reasoning as `setRating`/`setFlagStatus`,
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
        let viewed = viewedCollectionIDs
        let affectsCurrentFilter = viewed.contains(collectionID)

        if willBeMember {
            membershipsByPhotoID[photoID, default: []].insert(collectionID)
        } else {
            membershipsByPhotoID[photoID]?.remove(collectionID)
            // With subfolders shown, the photo stays in the grid while it is still a member of another viewed folder.
            if affectsCurrentFilter, membershipsByPhotoID[photoID, default: []].isDisjoint(with: viewed) {
                photos.removeAll { $0.id == photoID }
            }
        }
        recomputeFolderPhotoCounts()

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
        recomputeFolderPhotoCounts()

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
        if viewedCollectionIDs.contains(collectionID) {
            await refresh()
        }
    }

    // MARK: - Folder access (read-only, persisted across relaunches)

    /// Shows a directory-mode `NSOpenPanel` asking the user to re-grant
    /// access to `folder`, returning the URL they picked (or `nil` on
    /// cancel). Extracted into an injectable closure — the real
    /// `NSOpenPanel().runModal()` call blocks on real UI, so no automated
    /// test may ever reach it; this is what lets
    /// `ensureAccessActive(forPhotoAt:)`'s OWN decision logic stay fully
    /// testable, same "inject the untestable side effect" shape
    /// `PhotoEnhancer.commitExclusively`'s own `nextCandidate` closure
    /// already established for a different real-race problem. Tests
    /// substitute a closure that returns a value directly, with no panel
    /// ever shown.
    /// How `ensureAccessActive` and the thumbnail recovery classify an unreadable file (injectable: tests cannot produce a real sandbox denial).
    var readabilityProbe: @Sendable (String) -> FileReadability = { FileReadability.probe($0) }

    var folderReGrantPrompt: (URL) -> URL? = { folder in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message =
            "\(AppInfo.name) lost access to \"\(folder.lastPathComponent)\". Choose this folder again to open its photos."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Per-root in-flight reactivation tasks — reviewer-caught (round 1 of
    /// this method's own review): without this, a second concurrent call
    /// for the SAME stale root (a rapid second ⌘→ or filmstrip tap while
    /// the first call's re-grant panel is still up — `NSOpenPanel.runModal()`
    /// spins a nested run loop that keeps servicing the main queue, so a
    /// second `Task` genuinely CAN interleave and run to completion before
    /// the first one's panel closes) would race ahead into its OWN
    /// `document.load(from:)` independently. Since `ImageDocumentModel
    /// .load(from:)`'s own `loadGeneration` guard lets the LATER-STARTING
    /// call win regardless of which photo the user actually meant to end
    /// up on, the first (slower) call's eventual, correct `load` could
    /// silently overwrite the second (faster) one's already-succeeded
    /// result — landing the user on the wrong photo after a spurious
    /// error. Serializing concurrent callers for the same root behind ONE
    /// attempt closes this.
    private var reactivationTasks: [String: Task<Void, Never>] = [:]

    /// Re-verifies that `path` is actually readable before every
    /// Library/filmstrip/⌘←→-driven `ImageDocumentModel.load(from:)` (which
    /// has no reference to this class and no way to do this itself),
    /// self-healing if it isn't. `File > Open…`
    /// (`ImageDocumentModel.openImage()`) doesn't need this — `NSOpenPanel`
    /// grants it fresh access every time.
    ///
    /// Deliberately does NOT re-call `startAccessingSecurityScopedResource()`
    /// on an already-working root on every open — reviewer-caught (round 1):
    /// an earlier version of this method did exactly that, unconditionally,
    /// which LEAKS one unmatched start per open (there is no matching
    /// `stop` anywhere in this file, by design — see
    /// `activateKnownFolders`'s own doc comment — so a redundant start
    /// just accumulates). Only a confirmed-unreadable file pays that cost,
    /// via `reacquireAccess` below, not every ordinary open.
    ///
    /// LIVE-REPRODUCED (2026-09-25) in two stages, against this machine's
    /// own real library (one specific photo, `~/Downloads/IMG_9806.jpg`) —
    /// not just reasoned about, and NOT a demonstration that this was the
    /// ORIGINAL bug report's own root cause (that report's own trigger —
    /// a failure immediately after importing a folder — is still
    /// undiagnosed; the immediate cause reproduced here was a DIFFERENT,
    /// already-disclosed incident this same session where a test bug
    /// wiped the real `folderBookmarks` store, leaving `activeFolders`
    /// empty). What IS demonstrated: (1) an earlier draft returned
    /// immediately whenever `confirmedActiveFolderRoot` found no covering
    /// entry in `activeFolders` at all, which reproduced the exact
    /// symptom (no re-grant prompt, generic "Couldn't open" error) — fixed
    /// by falling back to a derived candidate folder when no tracked root
    /// covers the photo; (2) the fallback then STILL failed to prompt,
    /// because the liveness probe at the time
    /// (`FileManager.fileExists(atPath:)`) reads `true` for a real file
    /// this sandboxed process has NO read access to at all — existence
    /// and readability are not the same fact here — fixed by probing
    /// readability directly (see the nested `Task` below). Since the
    /// probe reacts to any unreadable file regardless of cause, it should
    /// also cover the original report's own trigger, but that specific
    /// claim has NOT been separately live-verified.
    func ensureAccessActive(forPhotoAt path: String) async {
        // Tries a currently-active root first (the common case), then a
        // folder that HAS a stored bookmark but never made it into
        // `activeFolders` (e.g. a start that failed at launch — reviewer-
        // caught, round 3: falling straight to the photo's own immediate
        // folder here would miss a bookmark stored for an ANCESTOR folder
        // and prompt for access a silent re-resolve would have recovered),
        // and only then falls back to the photo's own immediate folder as
        // a last resort when nothing at all is tracked for it.
        let root = PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: path, activeFolders: activeFolders)
            ?? PhotoImporter.confirmedActiveFolderRoot(forPhotoAt: path, activeFolders: Set(folderBookmarks.keys))
            ?? (path as NSString).deletingLastPathComponent
        guard !root.isEmpty else { return }

        if let inFlight = reactivationTasks[root] {
            await inFlight.value
            return
        }

        // The probe itself runs INSIDE the registered task, not before it
        // — reviewer-caught (round 2, self-caught while writing this
        // method's own concurrent-callers test): probing first and only
        // registering `reactivationTasks[root]` afterward leaves an
        // `await`-wide window where a second concurrent caller can ALSO
        // observe "nothing in flight yet" and create its own duplicate
        // task, defeating the serialization this is for. Everything from
        // the `if let inFlight` check above through this assignment has
        // NO suspension point, so — Swift's actor-reentrancy model (an
        // actor-isolated function only yields at `await`) — it runs as
        // one atomic unit against any OTHER caller scheduled on this same
        // `@MainActor`.
        let task = Task { [weak self] in
            guard let self else { return }
            // Off the main actor — a file open can block for real on a
            // slow/unmounted network volume, same reasoning as
            // `isPhotoConfirmedMissing`'s own `Task.detached`.
            //
            // LIVE-MEASURED (2026-09-25), not theorized: this was
            // originally a bare `FileManager.fileExists(atPath: root)` —
            // reviewer-caught (round 2) as possibly insufficient ("a
            // metadata read, not a data read"), and CONFIRMED insufficient
            // by directly reproducing the bug: `fileExists` reads `true`
            // for a real file this sandboxed process has NO read access
            // to at all — existence and readability are not the same
            // fact here.
            //
            // Checking existence AND readability together, not readability
            // alone, is itself a reviewer-caught (round 3) correction: a
            // file that's genuinely been DELETED also fails to open, but
            // treating that the same as a lost-access failure would wrongly
            // evict a still-good root from `activeFolders` (breaking
            // `isPhotoConfirmedMissing` for every sibling photo in that
            // folder), leak one more unmatched security-scope start for a
            // recovery that can't possibly help, and show a re-grant panel
            // that can't fix a deletion — `load(from:)`'s own existing
            // "may be missing" error already covers a genuinely-gone file
            // correctly on its own.
            let probe = self.readabilityProbe
            // Only a SANDBOX denial is evidence of a lost grant (D32): a missing file, a plain chmod and any other failure cannot be fixed by
            // evicting the folder, starting another scope or showing a re-grant panel.
            let needsRecovery = await Task.detached { probe(path) == .sandboxDenied }.value
            guard needsRecovery else { return } // the common case: access still holds, nothing to do
            await self.reacquireAccess(forStaleRoot: root)
        }
        reactivationTasks[root] = task
        await task.value
        reactivationTasks.removeValue(forKey: root)
    }

    /// `root` just failed `ensureAccessActive`'s readability probe — either
    /// a previously-active entry that's gone stale, or a freshly-derived
    /// candidate that was never tracked at all. Re-resolves its bookmark
    /// and re-starts it, or falls back to `folderReGrantPrompt`. This DOES
    /// cost one more unmatched security-scope start per recovery (there is
    /// no matching `stop` anywhere in this file, by design) — acceptable
    /// because it only runs when a real problem was just confirmed, not on
    /// every ordinary open.
    @discardableResult
    private func reacquireAccess(forStaleRoot root: String, allowPrompt: Bool = true) async -> Bool {
        activeFolders.remove(root)
        if let data = folderBookmarks[root] {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() {
                activeFolders.insert(root)
                // Reviewer-caught (round 1): `isStale` being true but the
                // resolve+start still succeeding is routine (e.g. after a
                // system update), not a real access loss — silently
                // refresh the stored bookmark instead of bothering the
                // user with a prompt for something that already self-healed.
                if isStale, let refreshed = try? resolved.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
                ) {
                    folderBookmarks[root] = refreshed
                }
                requestThumbnailsAgain(under: root)
                return true
            }
        }
        // The silent variant (thumbnail recovery) never shows a panel: a failed re-resolve just reports false.
        guard allowPrompt else { return false }

        // No bookmark, or it didn't resolve/start even after the retry
        // above. Deliberately does NOT delete `folderBookmarks[root]` here
        // — reviewer-caught (round 1): this could be a TRANSIENT failure
        // (an external drive not currently mounted, a network share
        // that's down), and destroying an otherwise-still-good bookmark
        // before the user has a chance to just reconnect it is worse than
        // leaving it in place. `activateFolderAccess` below overwrites it
        // on a successful re-grant; a decline leaves it untouched for a
        // future retry once whatever's wrong resolves itself.
        let folder = URL(fileURLWithPath: root)
        guard let grantedURL = folderReGrantPrompt(folder), grantedURL.coversAccess(to: folder) else {
            importStatusMessage = "Couldn't restore access to \"\(folder.lastPathComponent)\" — this photo may not open."
            return false
        }
        if let warning = activateFolderAccess(for: grantedURL) {
            importStatusMessage = warning
        }
        requestThumbnailsAgain(under: root)
        if grantedURL.path != root { requestThumbnailsAgain(under: grantedURL.path) } // a parent grant may cover other spinning roots too
        return true
    }

    /// Access to `root` was just restored: the grid and filmstrip cells under it that already failed a decode (and are showing a spinner) are
    /// asked to request their thumbnails again (`thumbnailRevisions` is part of a cell's task identity). Found live 2026-10-20: after an
    /// Editor-open recovery the cells kept spinning until something else reloaded them.
    func requestThumbnailsAgain(under root: String) {
        for candidate in photos where candidate.path.hasPrefix(root + "/") {
            thumbnailRevisions[candidate.path, default: 0] += 1
        }
    }

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
        // Every import/relocate/grant passes through here, including a re-import that adds no rows: a photo the camera-data scan
        // skipped for lack of access gets another chance at the next refresh.
        requestMetadataRetry()
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
        } else if readabilityProbe(folder.path) == .readable {
            // A dropped / Finder-opened URL can carry a process-wide sandbox extension instead of a scoped one: reading works, so no warning
            // (the bookmark above is what a later launch relies on).
        } else {
            warning = "Couldn't get access to \"\(folder.lastPathComponent)\" — its photos may not be viewable this session."
        }
        return warning
    }

    /// A saved folder bookmark after resolving it.
    struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    /// Resolves every saved folder bookmark (blocking file-system work: call off the main actor). A bookmark that cannot be resolved is simply
    /// absent from the result.
    nonisolated static func resolveAll(
        _ bookmarks: [String: Data], resolve: (Data) -> ResolvedBookmark? = CatalogModel.resolveBookmark
    ) -> [String: ResolvedBookmark] {
        bookmarks.compactMapValues(resolve)
    }

    /// Activates the resolved folder bookmarks at launch. There is deliberately no matching `stop` call anywhere — the scope is meant to stay
    /// open for the app's entire lifetime (the OS reclaims it on quit), since `ImageDocumentModel.load(from:)`'s `CIImage(contentsOf:)` decode
    /// is lazy and can re-read the file well after `load` returns, so a scope that closed early would produce intermittent, hard-to-explain
    /// read failures.
    ///
    /// A bookmark that could not be resolved (absent from `resolved`), will not start, or now points at a different folder than its key is KEPT,
    /// never deleted (found live 2026-10-19 in a real sandbox: this used to drop it, so launching the app while an external drive or card was not
    /// connected permanently lost that folder's grant and every later photo from it needed a re-grant panel). It stays in `folderBookmarks` and
    /// is retried when a photo from the folder is opened (`ensureAccessActive` → `reacquireAccess`, which re-resolves silently first) and at the
    /// next launch. A bookmark that resolves but is flagged stale (a system update) is started and silently refreshed — the same routine
    /// self-heal `reacquireAccess` does — instead of being dropped. `start`/`refresh` are injectable so the decisions are unit-tested without real
    /// security scopes.
    func activateKnownFolders(
        resolved: [String: ResolvedBookmark],
        start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        refresh: (URL) -> Data? = { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    ) {
        for (path, bookmark) in resolved {
            // A stale bookmark of a moved or renamed folder resolves to the NEW location: that grants nothing at the key's path.
            guard bookmark.url.coversAccess(to: URL(fileURLWithPath: path)), start(bookmark.url) else { continue }
            activeFolders.insert(path)
            if bookmark.isStale, let refreshed = refresh(bookmark.url) { folderBookmarks[path] = refreshed }
        }
    }

    nonisolated static func resolveBookmark(_ data: Data) -> ResolvedBookmark? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    private static func summary(for result: ImportResult) -> String {
        let importedPart = "Imported \(result.inserted) photo\(result.inserted == 1 ? "" : "s")"
        guard result.skipped > 0 else { return "\(importedPart)." }
        return "\(importedPart) (\(result.skipped) already in catalog)."
    }
}

// MARK: - Camera-data scan (field-based search)

/// The background camera-data scan behind field-based search (`MetadataScanner`). It never blocks the main thread, never
/// touches a photo file beyond reading its header, and runs without any user action: once per app session over the whole
/// library (the scan's own stat pass catches files edited elsewhere and is cheap when nothing changed), and again whenever
/// the library's photo count changes (an import, an Enhance/merge output, a removal).
extension CatalogModel {
    /// "Reading camera data… 120/1097" while a scan runs, else nil.
    var metadataScanStatusText: String? {
        guard let progress = metadataScanProgress else { return nil }
        return "Reading camera data… \(progress.completed)/\(progress.total)"
    }

    /// Asks the next `refresh()` to scan the photos that have no camera-data row yet (including ones an earlier scan had to
    /// skip). Called whenever folder access is (re)activated.
    func requestMetadataRetry() { metadataRetryRequested = true }

    /// Starts a scan when none is running and the library needs one; a request that arrives mid-scan is remembered and
    /// runs once the current scan ends. Called at the end of every `refresh()`.
    func startMetadataScanIfNeeded() {
        guard database != nil else { return }
        let countChanged = metadataCheckedPhotoCount != photoCount
        guard !didFullMetadataPass || countChanged || metadataRetryRequested else { return }
        if metadataScanTask != nil {
            metadataScanWanted = true
            return
        }
        guard let database else { return }
        let fullPass = !didFullMetadataPass
        metadataCheckedPhotoCount = photoCount
        didFullMetadataPass = true
        metadataRetryRequested = false
        metadataScanGeneration += 1
        let generation = metadataScanGeneration
        let owner = WeakCatalogModel(self)
        metadataScanTask = Task {
            let everything = (try? await database.allPhotos()) ?? []
            let cached = (try? await database.allMetadata()) ?? [:]
            // Photos with no row include the ones a previous scan SKIPPED (no access, unreadable), so a retry is just this.
            let targets = fullPass ? everything : MetadataScanner.photosNeedingScan(everything, cached: cached)
            if !targets.isEmpty {
                let sink = MetadataProgressSink { progress in
                    Task { @MainActor in
                        // Only while THIS scan is still the current one: a late update must not resurrect the status or
                        // show an earlier scan's count under the next scan.
                        guard let model = owner.model, model.metadataScanTask != nil, model.metadataScanGeneration == generation
                        else { return }
                        model.metadataScanProgress = progress
                    }
                }
                _ = try? await Task.detached(priority: .utility) {
                    try await MetadataScanner.scan(photos: targets, database: database, progress: { sink.report($0) })
                }.value
            }
            await owner.model?.finishMetadataScan(database: database)
        }
    }

    private func finishMetadataScan(database: CatalogDatabase) async {
        if let loaded = try? await database.allMetadata() { metadataByPhotoID = loaded }
        metadataScanProgress = nil
        metadataScanTask = nil
        if metadataScanWanted {
            metadataScanWanted = false
            startMetadataScanIfNeeded()
        }
    }
}

/// A weak reference that can cross into a `Sendable` closure (the scan task must not keep the model alive).
final class WeakCatalogModel: @unchecked Sendable {
    weak var model: CatalogModel?
    init(_ model: CatalogModel) { self.model = model }
}

/// Hands scan progress to the main actor, at most once per 10 photos (and for the last one), so a big library does not
/// flood the UI with one update per file.
final class MetadataProgressSink: @unchecked Sendable {
    private let deliver: @Sendable (MetadataScanner.Progress) -> Void
    init(_ deliver: @escaping @Sendable (MetadataScanner.Progress) -> Void) { self.deliver = deliver }

    func report(_ progress: MetadataScanner.Progress) {
        if progress.completed % 10 == 0 || progress.completed == progress.total { deliver(progress) }
    }
}
