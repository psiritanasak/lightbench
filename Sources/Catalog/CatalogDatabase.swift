import Foundation
import GRDB

/// The result of a folder import: how many photos were newly catalogued
/// vs. already present (re-importing the same folder is idempotent, keyed
/// on `Photo.path`'s `UNIQUE` constraint).
struct ImportResult: Equatable, Sendable {
    var inserted: Int
    var skipped: Int
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
    convenience init() throws {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PhotoApp", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let dbURL = supportDir.appendingPathComponent("catalog.sqlite")
        try self.init(path: dbURL.path)
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
                let path = url.path
                if try Photo.filter(Photo.Columns.path == path).fetchCount(db) > 0 {
                    skipped += 1
                    continue
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
                inserted += 1
            }
            return ImportResult(inserted: inserted, skipped: skipped)
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
    func setRating(_ rating: Int, for photoID: Int64) async throws {
        let clamped = min(max(rating, 0), 5)
        try await dbQueue.write { db in
            try Photo.filter(Photo.Columns.id == photoID)
                .updateAll(db, Photo.Columns.rating.set(to: clamped))
        }
    }

    /// Sets `photoID`'s flagged state.
    func setFlagged(_ isFlagged: Bool, for photoID: Int64) async throws {
        try await dbQueue.write { db in
            try Photo.filter(Photo.Columns.id == photoID)
                .updateAll(db, Photo.Columns.isFlagged.set(to: isFlagged))
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
}
