import Foundation
import GRDB

/// A catalogued photo: metadata/path only, per Phase 4 slice 1's explicit
/// scope. The original file itself is never touched — this row just
/// records where it lives and when it was imported, matching the app's
/// non-destructive invariant (`CLAUDE.md`: "original files are never
/// modified").
///
/// `path` is the natural key (`UNIQUE` in the schema, see
/// `Migrations/001_initial.swift`), which is what makes re-importing the
/// same folder idempotent — see `CatalogDatabase.importPhotos`.
///
/// `rating`/`isFlagged` added in `Migrations/002_ratings_and_flags.swift`
/// (Phase 4 slice 3). Defaults here (`0`/`false`) match that migration's
/// own `defaults(to:)`, so existing construction sites (e.g.
/// `CatalogDatabase.importPhotos`, which never sets these two fields)
/// keep compiling unchanged. `rating`'s valid range (0...5) is enforced
/// at the call site that sets it (`CatalogDatabase.setRating`), not here
/// — matching this project's `EditState` precedent of not
/// self-enforcing ranges in the model.
struct Photo: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var path: String
    var filename: String
    var fileSize: Int64?
    var importedAt: Date
    var rating: Int = 0
    var isFlagged: Bool = false
}

// MARK: - GRDB conformances

extension Photo: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "photo"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let path = Column(CodingKeys.path)
        static let filename = Column(CodingKeys.filename)
        static let fileSize = Column(CodingKeys.fileSize)
        static let importedAt = Column(CodingKeys.importedAt)
        static let rating = Column(CodingKeys.rating)
        static let isFlagged = Column(CodingKeys.isFlagged)
    }

    /// GRDB calls this after a successful `INSERT` so `id` reflects the
    /// autoincremented rowid SQLite assigned, mirroring the record's own
    /// `id` field for any caller that inserted a fresh `Photo` (id: nil).
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
