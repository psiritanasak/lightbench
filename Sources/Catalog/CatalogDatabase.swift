import Foundation
import GRDB

/// The result of a folder import: how many photos were newly catalogued
/// vs. already present (re-importing the same folder is idempotent, keyed
/// on `Photo.path`'s `UNIQUE` constraint).
struct ImportResult: Equatable, Sendable {
    var inserted: Int
    var skipped: Int
}

/// Thrown only in the "should be impossible" case where GRDB's own
/// `didInsert` callback somehow left a just-inserted record's `id` unset
/// — lets callers avoid a force-unwrap (`CLAUDE.md`: "no force-unwraps
/// outside tests") while still surfacing a real error instead of
/// crashing if that invariant is ever violated.
struct CatalogDatabaseError: Error {
    let message: String
}

/// Owns the catalog's GRDB connection and every query against it. No UI
/// import — `CLAUDE.md`: "Keep modules separated: Catalog / EditEngine /
/// Rendering / UI." Every public method is `async` and does its actual
/// work on GRDB's own background queue, honoring "DB access never blocks
/// the main thread" — callers `await` these from a background `Task`
/// (see `CatalogModel.importFolder` in the UI layer).
final class CatalogDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    /// Opens (creating if needed) the on-disk catalog at
    /// `Application Support/PhotoApp/catalog.sqlite`. This lives inside
    /// the app's own sandbox container, so — unlike the user's photo
    /// files — it needs no security-scoped bookmark to read or write.
    /// Under XCTest the catalog lives in a throwaway temp directory instead
    /// — see `defaultCatalogDirectory(isRunningUnderXCTest:)`.
    convenience init() throws {
        let supportDir = try Self.defaultCatalogDirectory()
        let dbURL = supportDir.appendingPathComponent("catalog.sqlite")
        try self.init(path: dbURL.path)
    }

    /// True when this process was launched by the XCTest runner. `PhotoAppTests`
    /// is hosted by the app itself, so the app's own launch-time code runs
    /// inside the test host — anything there that touches real user state
    /// (the catalog, `UserDefaults.standard` folder bookmarks) must check
    /// this. Any of the runner's environment markers counts (OR, not AND): a
    /// missing marker fails OPEN — silently back to the real catalog, which
    /// is exactly the D34 bug — so accept every one we know of.
    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }

    /// Where `init()` keeps `catalog.sqlite`, WITHOUT creating anything (D34,
    /// IMPROVEMENTS.md). With the real Application Support directory, launching
    /// the test host used to make `xcodebuild test` silently apply pending
    /// migrations to the developer's real catalog before any backup could be
    /// taken. Under XCTest this is a directory unique to THIS process inside
    /// the temp directory (never deleted by us — the OS cleans temp — because
    /// wiping a shared fixed path would delete the catalog another live test
    /// host, e.g. under parallel testing, still has open).
    /// `isRunningUnderXCTest` is a parameter so both branches are unit-testable
    /// from inside a test process.
    static func catalogDirectoryURL(isRunningUnderXCTest: Bool = CatalogDatabase.isRunningUnderXCTest) throws -> URL {
        let fileManager = FileManager.default
        if isRunningUnderXCTest {
            return fileManager.temporaryDirectory.appendingPathComponent(
                "PhotoApp-XCTest-catalog-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
            )
        }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("PhotoApp", isDirectory: true)
    }

    /// `catalogDirectoryURL`, created if missing — what `init()` uses.
    static func defaultCatalogDirectory(
        isRunningUnderXCTest: Bool = CatalogDatabase.isRunningUnderXCTest
    ) throws -> URL {
        let dir = try catalogDirectoryURL(isRunningUnderXCTest: isRunningUnderXCTest)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Opens a catalog at an explicit path.
    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrate(dbQueue)
    }

    /// Opens an in-memory catalog — used by tests, never by the app
    /// itself (keeps `CatalogDatabaseTests` fast and disk/network-free).
    init(inMemory: Bool) throws {
        precondition(inMemory, "use init(path:) for an on-disk catalog")
        dbQueue = try DatabaseQueue()
        try Self.migrate(dbQueue)
    }

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        Migration001Initial.register(in: &migrator)
        Migration002RatingsAndFlags.register(in: &migrator)
        Migration003Collections.register(in: &migrator)
        Migration004FolderCollections.register(in: &migrator)
        Migration005Presets.register(in: &migrator)
        Migration006CollectionFolderPathIndex.register(in: &migrator)
        Migration007PickRejectFlags.register(in: &migrator)
        Migration008ColorLabels.register(in: &migrator)
        Migration009RenameLog.register(in: &migrator)
        Migration010Keywords.register(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    /// Inserts every URL not already present (matched on `path`),
    /// ignoring ones already catalogued. Metadata-only, per this slice's
    /// scope — never opens/decodes the image itself.
    func importPhotos(at urls: [URL]) async throws -> ImportResult {
        try await dbQueue.write { db in
            var inserted = 0
            var skipped = 0
            for url in urls {
                let (_, wasInserted) = try Self.insertPhotoIfNeeded(url: url, db: db)
                if wasInserted { inserted += 1 } else { skipped += 1 }
            }
            return ImportResult(inserted: inserted, skipped: skipped)
        }
    }

    /// Inserts `url` as a new `Photo` if no row with that `path` already
    /// exists, or returns the existing row's id unchanged. Shared by
    /// `importPhotos` (above) and `importFolderTree` (below) so a photo
    /// swept up by BOTH a flat import and a later folder-tree import ends
    /// up as exactly one row either way — `wasInserted` lets each caller
    /// still report its own inserted-vs-skipped counts.
    private static func insertPhotoIfNeeded(url: URL, db: Database) throws -> (photoID: Int64, wasInserted: Bool) {
        let path = url.path
        if let existing = try Photo.filter(Photo.Columns.path == path).fetchOne(db), let id = existing.id {
            return (id, false)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = attributes?[.size] as? Int64
        var photo = Photo(
            id: nil,
            path: path,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            importedAt: Date()
        )
        try photo.insert(db)
        guard let id = photo.id else {
            throw CatalogDatabaseError(message: "insert(db) did not assign photo.id")
        }
        return (id, true)
    }

    /// Registers `url` as a catalogued `Photo` (reusing an existing row
    /// at the same path, exactly like `insertPhotoIfNeeded`), and — if
    /// `url`'s DIRECT containing folder already has a folder-mirrored
    /// collection (`isFolder == true`, from an earlier `importFolderTree`
    /// — see that method's own doc comment), joins it. NEVER creates a
    /// new collection — `PhotoEnhancer`'s own output (the first caller,
    /// via `CatalogModel.registerEnhancedPhoto`) is a single new file
    /// written directly into an already-catalogued folder, not a fresh
    /// import, so there is no user-initiated "import this as a
    /// collection" action backing a new one.
    ///
    /// Idempotent: registering the SAME path twice (e.g. Enhance,
    /// deleted, then Enhance again reusing the exact name — see
    /// `PhotoExporter.uniqueFileURL`'s own orphan-sidecar-aware naming)
    /// reuses the existing row rather than duplicating it, matching
    /// `insertPhotoIfNeeded`'s own established behavior.
    func registerPhoto(at url: URL) async throws -> Photo {
        try await dbQueue.write { db in
            let (photoID, _) = try Self.insertPhotoIfNeeded(url: url, db: db)
            let folderPath = url.deletingLastPathComponent().path
            if let folderCollection = try PhotoCollection
                .filter(PhotoCollection.Columns.isFolder == true)
                .filter(PhotoCollection.Columns.folderPath == folderPath)
                .fetchOne(db), let collectionID = folderCollection.id {
                try CollectionPhoto(collectionId: collectionID, photoId: photoID).insert(db, onConflict: .ignore)
            }
            guard let photo = try Photo.filter(Photo.Columns.id == photoID).fetchOne(db) else {
                throw CatalogDatabaseError(message: "registerPhoto: row for id \(photoID) disappeared immediately after insert/lookup")
            }
            return photo
        }
    }

    /// The catalogued row at `path`, if any — used by
    /// `CatalogModel.catalogedPhoto(atPath:)` to check whether a photo is
    /// in the catalog at all before `PhotoEnhancer` acts on it (a photo
    /// opened via `Open…` rather than imported has no row here).
    func photo(atPath path: String) async throws -> Photo? {
        try await dbQueue.read { db in
            try Photo.filter(Photo.Columns.path == path).fetchOne(db)
        }
    }

    func photoCount() async throws -> Int {
        try await dbQueue.read { db in
            try Photo.fetchCount(db)
        }
    }

    func allPhotos() async throws -> [Photo] {
        try await dbQueue.read { db in
            // `id` is a tie-breaker: two imports fast enough to land in the
            // same `Date()` tick would otherwise sort arbitrarily on
            // `importedAt` alone (SQLite makes no ordering guarantee among
            // equal keys).
            try Photo.order(Photo.Columns.importedAt, Photo.Columns.id).fetchAll(db)
        }
    }

    /// Sets `photoID`'s star rating, clamped to 0...5 — the project's
    /// first `UPDATE` (every prior write was an `INSERT`, in
    /// `importPhotos` above). Clamping happens here, not in `Photo`
    /// itself, matching this project's `EditState` precedent of not
    /// self-enforcing ranges in the model.
    ///
    /// `CatalogModel.setRating` MIRRORS this clamp for its optimistic local
    /// update, and the two must stay in sync: that caller no longer re-reads
    /// the stored value, so widening or narrowing the range here without
    /// changing it there would let the grid display a rating this method
    /// actually rejected.
    func setRating(_ rating: Int, for photoID: Int64) async throws {
        let clamped = min(max(rating, 0), 5)
        try await dbQueue.write { db in
            try Photo.filter(Photo.Columns.id == photoID)
                .updateAll(db, Photo.Columns.rating.set(to: clamped))
        }
    }

    /// Sets `photoID`'s color label.
    func setColorLabel(_ label: ColorLabel, for photoID: Int64) async throws {
        try await dbQueue.write { db in
            try Photo.filter(Photo.Columns.id == photoID)
                .updateAll(db, Photo.Columns.colorLabel.set(to: label))
        }
    }

    /// Sets `photoID`'s pick/reject flag.
    func setFlagStatus(_ status: FlagStatus, for photoID: Int64) async throws {
        try await dbQueue.write { db in
            try Photo.filter(Photo.Columns.id == photoID)
                .updateAll(db, Photo.Columns.flagStatus.set(to: status))
        }
    }

    /// Removes `photoID` from the catalog (D5, IMPROVEMENTS.md) — the
    /// project's first row-DELETE on `photo` (the only prior DELETE
    /// precedent is `setMembership`'s `CollectionPhoto...deleteAll` below).
    /// The photo's `collection_photo` memberships are cleaned up
    /// automatically by the `ON DELETE CASCADE` FK from
    /// `Migrations/003_collections.swift` — no explicit cleanup needed
    /// here, and `CatalogDatabaseTests` exercises this cascade directly
    /// rather than just trusting the migration comment. Deleting a
    /// nonexistent ID is a silent no-op (`deleteAll` on an empty filter),
    /// matching this file's other mutators' tolerance of stale IDs.
    ///
    /// Catalog-only: the original file on disk is never touched. This app
    /// only holds READ-ONLY security-scoped bookmarks on imported folders,
    /// so it has no write access to delete the file even if it wanted to
    /// — see `CatalogModel`'s folder-bookmark handling.
    func deletePhoto(id: Int64) async throws {
        try await dbQueue.write { db in
            _ = try Photo.filter(Photo.Columns.id == id).deleteAll(db)
        }
    }

    /// Relocates each `(photoID, newPath)` pair in ONE transaction (D5
    /// follow-up: point the catalog at a photo's new location after it was
    /// moved on disk, not deleted). Skips any pair whose destination is
    /// already claimed by a DIFFERENT catalogued row — checked via the
    /// same `path == ...` probe `insertPhotoIfNeeded` already uses, EXCLUDING
    /// the photo's own current row (reviewer-caught: without that
    /// exclusion, relocating a photo back to its own already-current path
    /// — a stale `isMissing` snapshot, or the file having been restored —
    /// would find itself and get reported as "a different photo is
    /// already there," which is false; excluding self makes that a
    /// harmless successful no-op instead) — rather than aborting the
    /// whole batch: unlike `addPhotos`'s FK violation (a rare edge case
    /// there), a naming collision here is a plausible, common outcome of
    /// a batch move (the destination folder may have already been
    /// separately imported).
    ///
    /// Fetch-mutate-update, not `updateAll` with a fixed assignment list
    /// — reviewer-caught: a failed `attributesOfItem` read (network
    /// hiccup, permissions) must leave the EXISTING `fileSize` alone, not
    /// null it out; only overwriting `fileSize` when a fresh read
    /// actually succeeds is what a fixed `updateAll(... .set(to: nil))`
    /// can't express without first fetching the row anyway. Returns the
    /// IDs actually relocated, so callers can report a partial-success
    /// summary rather than an all-or-nothing result.
    func relocatePhotos(_ moves: [(photoID: Int64, newPath: String)]) async throws -> Set<Int64> {
        try await dbQueue.write { db in
            var relocated: Set<Int64> = []
            for move in moves {
                guard try Photo.filter(Photo.Columns.path == move.newPath)
                    .filter(Photo.Columns.id != move.photoID)
                    .fetchCount(db) == 0
                else { continue }
                guard var photo = try Photo.filter(Photo.Columns.id == move.photoID).fetchOne(db) else { continue }
                photo.path = move.newPath
                photo.filename = URL(fileURLWithPath: move.newPath).lastPathComponent
                if let fileSize = (try? FileManager.default.attributesOfItem(atPath: move.newPath))?[.size] as? Int64 {
                    photo.fileSize = fileSize
                }
                try photo.update(db)
                relocated.insert(move.photoID)
            }
            return relocated
        }
    }

    // MARK: - Batch rename (Library "Rename Files…")

    /// Points each catalog row at its renamed file and logs the batch, in ONE
    /// transaction (any throw leaves both the rows and the log untouched).
    /// The files themselves were already moved by `RenameEngine`; this is the
    /// catalog half. Returns the new batch's id.
    ///
    /// Every move must still match reality: the row must exist and currently
    /// hold `oldPath` (else `.pathChanged`/`.photoMissing`), and no photo
    /// OUTSIDE the batch may hold a `newPath` (else `.pathTaken`). Paths are
    /// updated in two passes — to unique temporary values, then to the finals
    /// — because a chain (a→b while b→c) or a swap would otherwise trip the
    /// `path` UNIQUE constraint mid-batch. Row ids never change, so collection
    /// memberships, ratings, flags and labels ride along untouched.
    ///
    /// Older batches are deleted in the same transaction: only the most
    /// recent rename is undoable.
    func renamePhotos(_ moves: [RenameMove]) async throws -> Int64 {
        // File sizes are read BEFORE taking the writer lock — no disk I/O inside the write closure.
        let sizes = Self.fileSizes(atPaths: moves.map(\.newPath))
        return try await dbQueue.write { db in
            try Self.applyPathMoves(moves, sizes: sizes, in: db)
            _ = try RenameBatchRecord.deleteAll(db)
            var batch = RenameBatchRecord(id: nil, createdAt: Date())
            try batch.insert(db)
            guard let batchID = batch.id else { throw RenameCatalogError.noLoggedRename }
            for move in moves {
                try RenameEntryRecord(
                    batchId: batchID, photoId: move.photoID, oldPath: move.oldPath, newPath: move.newPath
                ).insert(db)
            }
            return batchID
        }
    }

    /// The most recent applied rename batch, if any.
    func lastRenameLog() async throws -> LoggedRename? {
        try await dbQueue.read { db in
            guard let batch = try RenameBatchRecord.order(Column("id").desc).fetchOne(db), let batchID = batch.id else {
                return nil
            }
            let entries = try RenameEntryRecord.filter(Column("batchId") == batchID)
                .order(Column("photoId")).fetchAll(db)
            return LoggedRename(
                batchID: batchID, createdAt: batch.createdAt,
                moves: entries.map { RenameMove(photoID: $0.photoId, oldPath: $0.oldPath, newPath: $0.newPath) }
            )
        }
    }

    /// Rows in `rename_entry` — lets a test prove older batches were really deleted
    /// (same testing-seam precedent as `insertCollectionForTesting`).
    func renameEntryCountForTesting() async throws -> Int {
        try await dbQueue.read { db in try RenameEntryRecord.fetchCount(db) }
    }

    /// Checks — WITHOUT changing anything — that undoing `log` is still valid:
    /// every photo exists and still sits at its logged `newPath`. Called before
    /// any file is moved back, so an undo of a stale batch is refused up front.
    func validateUndo(of log: LoggedRename) async throws {
        try await dbQueue.read { db in
            for move in log.moves {
                guard let photo = try Photo.filter(Photo.Columns.id == move.photoID).fetchOne(db) else {
                    throw RenameCatalogError.photoMissing(move.photoID)
                }
                guard photo.path == move.newPath else { throw RenameCatalogError.pathChanged(move.photoID) }
            }
        }
    }

    /// The catalog half of an undo: puts every row back at its `oldPath` and
    /// deletes the batch, in one transaction (the files were already moved
    /// back). Refuses, changing nothing, if any row has moved since.
    func revertRenameBatch(_ log: LoggedRename) async throws {
        let sizes = Self.fileSizes(atPaths: log.moves.map(\.oldPath))
        try await dbQueue.write { db in
            try Self.applyPathMoves(log.moves.map(\.inverse), sizes: sizes, in: db)
            _ = try RenameBatchRecord.filter(Column("id") == log.batchID).deleteAll(db)
        }
    }

    private static func fileSizes(atPaths paths: [String]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in paths {
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 { sizes[path] = size }
        }
        return sizes
    }

    /// Shared by `renamePhotos` and `revertRenameBatch`: validates every move
    /// against current rows, then rewrites paths in two passes (temp → final).
    private static func applyPathMoves(_ moves: [RenameMove], sizes: [String: Int64], in db: Database) throws {
        let batchIDs = Set(moves.map(\.photoID))
        var photos: [Int64: Photo] = [:]
        for move in moves {
            guard let photo = try Photo.filter(Photo.Columns.id == move.photoID).fetchOne(db) else {
                throw RenameCatalogError.photoMissing(move.photoID)
            }
            guard photo.path == move.oldPath else { throw RenameCatalogError.pathChanged(move.photoID) }
            // Case-insensitive for ASCII only (SQLite NOCASE): SQLite's `=` is case-sensitive but APFS isn't, so a
            // catalogued photo at a differently-cased path could be the very same file. This is a best-effort catalog
            // guard — non-ASCII case (É/é) and NFC/NFD forms can still alias here; the engine's RENAME_EXCL is what
            // guarantees no FILE is ever overwritten.
            let taken = try Photo.filter(Photo.Columns.path.collating(.nocase) == move.newPath)
                .filter(!batchIDs.contains(Photo.Columns.id)).fetchCount(db)
            guard taken == 0 else { throw RenameCatalogError.pathTaken(move.newPath) }
            photos[move.photoID] = photo
        }
        // Pass 1: park every row on a unique temporary path so pass 2 can't collide.
        for move in moves {
            guard var photo = photos[move.photoID] else { continue }
            photo.path = "\(move.oldPath).renaming-\(move.photoID)"
            try photo.update(db)
            photos[move.photoID] = photo
        }
        // Pass 2: final paths.
        for move in moves {
            guard var photo = photos[move.photoID] else { continue }
            photo.path = move.newPath
            photo.filename = URL(fileURLWithPath: move.newPath).lastPathComponent
            if let size = sizes[move.newPath] { photo.fileSize = size }
            try photo.update(db)
        }
    }

    // MARK: - Presets (Phase 5 slice 2)

    /// Ordered by `name`, same reasoning as `allCollections()` — a picker
    /// list is more scannable alphabetically.
    func allPresets() async throws -> [Preset] {
        try await dbQueue.read { db in
            try Preset.order(Preset.Columns.name).fetchAll(db)
        }
    }

    /// `onConflict: .replace` makes saving under an existing name
    /// transparently overwrite the old preset rather than erroring or
    /// duplicating — the expected Lightroom-style behavior, and avoids a
    /// separate "overwrite?" confirmation UI for v1.
    func createPreset(name: String, editState: EditState) async throws -> Preset {
        try await dbQueue.write { db in
            var preset = Preset(id: nil, name: name, editState: editState, createdAt: Date())
            try preset.insert(db, onConflict: .replace)
            return preset
        }
    }

    /// Deleting a nonexistent ID is a silent no-op, matching `deletePhoto`.
    func deletePreset(id: Int64) async throws {
        try await dbQueue.write { db in
            _ = try Preset.filter(Preset.Columns.id == id).deleteAll(db)
        }
    }

    // MARK: - Collections (Phase 4 slice 4)

    /// Ordered by `name`, not `createdAt` (unlike `allPhotos()`) — a
    /// sidebar list is more scannable alphabetically as it grows.
    func allCollections() async throws -> [PhotoCollection] {
        try await dbQueue.read { db in
            try PhotoCollection.order(PhotoCollection.Columns.name).fetchAll(db)
        }
    }

    func createCollection(name: String) async throws -> PhotoCollection {
        try await dbQueue.write { db in
            var collection = PhotoCollection(id: nil, name: name, createdAt: Date())
            try collection.insert(db)
            return collection
        }
    }

    /// Test-only seam (reviewer-caught, Enhance/Super Resolution review
    /// round: `registerPhoto`'s own `isFolder == true` filter had NO
    /// direct test — every real write path only ever produces
    /// `isFolder: false` with a `nil` folderPath, or `isFolder: true`
    /// with a real one, via `findOrCreateFolderCollection`, so a
    /// same-shape-but-wrong row is otherwise unreachable through the
    /// public API). Inserts `collection` completely as-given, bypassing
    /// every other write method's own shape-enforcing logic — exists
    /// specifically so a test can construct the one row shape
    /// (`isFolder: false` with a non-nil `folderPath`) production code
    /// never produces, and confirm `registerPhoto` still correctly
    /// refuses to join it.
    ///
    /// Caution for future test authors (reviewer-noted, round 2, not
    /// currently triggered by any test): `findOrCreateFolderCollection`'s
    /// own lookup matches on `folderPath` ALONE, without also checking
    /// `isFolder` — a real row this seam can produce but production code
    /// cannot. A test that inserts an `isFolder: false` row at some
    /// `folderPath` and later imports a real folder tree at that SAME
    /// path would silently have `importFolderTree` adopt this non-folder
    /// row as if it were a folder collection. Not an issue for anything
    /// in this file today, but worth knowing before reusing this seam
    /// more broadly.
    func insertCollectionForTesting(_ collection: PhotoCollection) async throws -> PhotoCollection {
        try await dbQueue.write { db in
            var collection = collection
            try collection.insert(db)
            return collection
        }
    }

    /// Renames `id` to `name` (D5, IMPROVEMENTS.md) — the project's first
    /// `UPDATE` on any table other than `photo` (`setRating`/`setFlagStatus`/`setColorLabel`
    /// above are the only prior precedent for this shape). Trimming/empty
    /// validation happens in `CatalogModel`, not here — this method trusts
    /// its input, matching `createCollection`'s own split of concerns.
    /// Renaming a nonexistent ID is a silent no-op (`updateAll` on an empty
    /// filter), matching this file's other mutators' tolerance of stale IDs.
    func renameCollection(id: Int64, to name: String) async throws {
        try await dbQueue.write { db in
            _ = try PhotoCollection.filter(PhotoCollection.Columns.id == id)
                .updateAll(db, PhotoCollection.Columns.name.set(to: name))
        }
    }

    /// Removes collection `id` (D5, IMPROVEMENTS.md) — the project's first
    /// row-DELETE on `collection`. Photos themselves are never touched;
    /// only the collection row and its `collection_photo` membership rows
    /// go, the latter via the `ON DELETE CASCADE` FK from
    /// `Migrations/003_collections.swift` — `CatalogDatabaseTests`
    /// exercises this cascade directly rather than just trusting the
    /// migration's own comment. If `id` names a FOLDER collection
    /// (`isFolder == true`), this ALSO recursively deletes its entire
    /// subtree, since `parentId` is itself `ON DELETE CASCADE` and
    /// self-referencing (`Migrations/004_folder_collections.swift`) —
    /// `CatalogModel`/`CollectionSidebarView` deliberately don't expose
    /// this method for folder rows in this slice (see IMPROVEMENTS.md's
    /// D5 write-up for why), but the database layer itself doesn't
    /// distinguish, so this doc comment records the real behavior for
    /// whoever extends this later. Deleting a nonexistent ID is a silent
    /// no-op, matching `deletePhoto`.
    func deleteCollection(id: Int64) async throws {
        try await dbQueue.write { db in
            _ = try PhotoCollection.filter(PhotoCollection.Columns.id == id).deleteAll(db)
        }
    }

    /// Every photo in `collectionID`, via its `collection_photo` join
    /// rows. Does not affect `allPhotos()` — collection membership is a
    /// separate relation, not a filter on the base library.
    func photos(inCollection collectionID: Int64) async throws -> [Photo] {
        try await dbQueue.read { db in
            let photoIDs = try CollectionPhoto
                .filter(CollectionPhoto.Columns.collectionId == collectionID)
                .fetchAll(db)
                .map(\.photoId)
            return try Photo
                .filter(photoIDs.contains(Photo.Columns.id))
                .order(Photo.Columns.importedAt, Photo.Columns.id)
                .fetchAll(db)
        }
    }

    /// Every membership row in the catalog — `CatalogModel` uses this to
    /// build a photoID→collectionIDs map for cheap, synchronous per-cell
    /// checkmark lookups rather than a query per grid cell.
    func allMemberships() async throws -> [CollectionPhoto] {
        try await dbQueue.read { db in try CollectionPhoto.fetchAll(db) }
    }

    /// Adds or removes `photoID` from `collectionID`. `onConflict: .ignore`
    /// on the add path makes toggling on an already-member photo a no-op
    /// rather than a primary-key-violation error — the composite primary
    /// key (`collectionId`, `photoId`) is what makes this collapse
    /// correctly instead of inserting a duplicate.
    func setMembership(photoID: Int64, collectionID: Int64, isMember: Bool) async throws {
        try await dbQueue.write { db in
            if isMember {
                try CollectionPhoto(collectionId: collectionID, photoId: photoID)
                    .insert(db, onConflict: .ignore)
            } else {
                try CollectionPhoto
                    .filter(CollectionPhoto.Columns.collectionId == collectionID)
                    .filter(CollectionPhoto.Columns.photoId == photoID)
                    .deleteAll(db)
            }
        }
    }

    /// Adds every photo in `photoIDs` to `collectionID` in ONE batched
    /// transaction (D5 follow-up: batch-add from a Library multi-select) —
    /// not N separate `setMembership` calls, mirroring `importFolderTree`'s
    /// own established "one `dbQueue.write`, many rows" shape below.
    /// Add-only: unlike `setMembership`, there's no `isMember` direction,
    /// since a batch selection can be a mix of members/non-members and
    /// "add all" is the only unambiguous semantic for that case.
    /// `onConflict: .ignore` per row makes an already-member photo a
    /// no-op, the same idempotency `setMembership`'s add path relies on.
    /// A since-deleted photo ID in the batch would trip the
    /// `collection_photo` FK and abort the whole transaction — not
    /// specially guarded per-row here, matching `importPhotos`/
    /// `importFolderTree`'s own tolerance for not isolating individual
    /// rows; the caller resyncs local state via a full `refresh()` on any
    /// failure.
    func addPhotos(_ photoIDs: [Int64], toCollection collectionID: Int64) async throws {
        try await dbQueue.write { db in
            for photoID in photoIDs {
                try CollectionPhoto(collectionId: collectionID, photoId: photoID)
                    .insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: - Keywords

    func allKeywords() async throws -> [Keyword] {
        try await dbQueue.read { db in try Keyword.fetchAll(db) }
    }

    func allKeywordLinks() async throws -> [PhotoKeyword] {
        try await dbQueue.read { db in try PhotoKeyword.fetchAll(db) }
    }

    /// Attaches `names` to every photo in `photoIDs` in ONE transaction, creating keywords that do not exist yet.
    /// Names are normalized (`KeywordName.normalize`) and de-duplicated by `KeywordName.key(for:)`; a keyword that
    /// already exists under any spelling is reused (its stored spelling is kept). Idempotent: attaching again is
    /// a no-op (`onConflict: .ignore`). Photo ids that no longer exist are skipped instead of tripping the foreign
    /// key and aborting the whole batch (a stale selection after a removal). Keywords are created even when
    /// `photoIDs` is empty or entirely stale (no photo attached) — "add to my keyword list". Returns the keywords
    /// involved, in the order of `names`.
    @discardableResult
    func addKeywords(_ names: [String], to photoIDs: [Int64]) async throws -> [Keyword] {
        try await dbQueue.write { db in
            var seen = Set<String>()
            var wanted: [String] = []
            for raw in names {
                guard let name = KeywordName.normalize(raw), seen.insert(KeywordName.key(for: name)).inserted else { continue }
                wanted.append(name)
            }
            // Chunked: each id binds one SQL variable (SQLite's default limit is 32766).
            var existingPhotoIDs = Set<Int64>()
            for chunk in stride(from: 0, to: photoIDs.count, by: 500).map({ Array(photoIDs[$0..<min($0 + 500, photoIDs.count)]) }) {
                existingPhotoIDs.formUnion(try Int64.fetchAll(db, Photo.filter(chunk.contains(Photo.Columns.id)).select(Photo.Columns.id)))
            }
            var result: [Keyword] = []
            for name in wanted {
                let key = KeywordName.key(for: name)
                var keyword: Keyword
                if let found = try Keyword.filter(Keyword.Columns.nameKey == key).fetchOne(db) {
                    keyword = found
                } else {
                    keyword = Keyword(id: nil, name: name, nameKey: key, createdAt: Date())
                    try keyword.insert(db)
                }
                if let keywordID = keyword.id {
                    for photoID in photoIDs where existingPhotoIDs.contains(photoID) {
                        try PhotoKeyword(keywordId: keywordID, photoId: photoID).insert(db, onConflict: .ignore)
                    }
                }
                result.append(keyword)
            }
            return result
        }
    }

    /// Detaches keyword `id` from `photoIDs` (the keyword itself stays, even if no photo uses it any more).
    func removeKeyword(id: Int64, from photoIDs: [Int64]) async throws {
        try await dbQueue.write { db in
            for chunk in stride(from: 0, to: photoIDs.count, by: 500).map({ Array(photoIDs[$0..<min($0 + 500, photoIDs.count)]) }) {
                _ = try PhotoKeyword
                    .filter(PhotoKeyword.Columns.keywordId == id)
                    .filter(chunk.contains(PhotoKeyword.Columns.photoId))
                    .deleteAll(db)
            }
        }
    }

    /// Deletes the keyword everywhere (its links cascade).
    func deleteKeyword(id: Int64) async throws {
        try await dbQueue.write { db in
            _ = try Keyword.filter(Keyword.Columns.id == id).deleteAll(db)
        }
    }

    // MARK: - Folder-mirrored nested collections

    /// Imports an entire recursively-scanned folder tree: every folder
    /// becomes (or reuses) a `PhotoCollection` row, every image becomes
    /// (or reuses, via `insertPhotoIfNeeded`) a `Photo` row and a
    /// membership in its DIRECT folder's collection, and every subfolder
    /// recurses with its own collection as the new parent. The whole tree
    /// is one `dbQueue.write` — atomic, and what makes find-or-create
    /// idempotency (no SQL-level `UNIQUE` on `folderPath`, see
    /// `Migrations/004_folder_collections.swift`) safe: GRDB serializes
    /// all writes on this queue, so no other write can interleave and
    /// race a check-then-insert here.
    func importFolderTree(_ node: FolderScanNode, parentCollectionID: Int64? = nil) async throws -> ImportResult {
        try await dbQueue.write { db in
            try Self.importNode(node, parentCollectionID: parentCollectionID, db: db)
        }
    }

    private static func importNode(_ node: FolderScanNode, parentCollectionID: Int64?, db: Database) throws -> ImportResult {
        let collectionID = try findOrCreateFolderCollection(
            name: node.url.lastPathComponent,
            folderPath: node.url.path,
            parentID: parentCollectionID,
            db: db
        )

        var result = ImportResult(inserted: 0, skipped: 0)
        for url in node.imageFiles {
            let (photoID, wasInserted) = try insertPhotoIfNeeded(url: url, db: db)
            try CollectionPhoto(collectionId: collectionID, photoId: photoID).insert(db, onConflict: .ignore)
            if wasInserted { result.inserted += 1 } else { result.skipped += 1 }
        }

        for child in node.children {
            let childResult = try importNode(child, parentCollectionID: collectionID, db: db)
            result.inserted += childResult.inserted
            result.skipped += childResult.skipped
        }

        return result
    }

    /// Reuses an existing collection row for `folderPath` if one exists
    /// (this is the "re-import reuses the same tree" idempotency — see
    /// `importFolderTree`'s own doc comment for why no SQL `UNIQUE`
    /// constraint is needed), otherwise creates a new one marked
    /// `isFolder: true`.
    private static func findOrCreateFolderCollection(
        name: String,
        folderPath: String,
        parentID: Int64?,
        db: Database
    ) throws -> Int64 {
        if let existing = try PhotoCollection
            .filter(PhotoCollection.Columns.folderPath == folderPath)
            .fetchOne(db), let id = existing.id {
            return id
        }
        var collection = PhotoCollection(
            id: nil,
            name: name,
            createdAt: Date(),
            parentId: parentID,
            isFolder: true,
            folderPath: folderPath
        )
        try collection.insert(db)
        guard let id = collection.id else {
            throw CatalogDatabaseError(message: "insert(db) did not assign collection.id")
        }
        return id
    }
}
