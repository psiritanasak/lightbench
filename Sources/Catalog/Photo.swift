import Foundation
import GRDB

/// Lightroom-style three-state cull flag. Raw values are what the
/// `flagStatus` column stores; `rejected` is negative so a plain integer
/// sort would put rejects first, and `none` is `0` so the migration's
/// `defaults(to: 0)` means "unflagged".
enum FlagStatus: Int, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case rejected = -1
    case none = 0
    case picked = 1
}

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
/// `rating` added in `Migrations/002_ratings_and_flags.swift` (Phase 4
/// slice 3); `flagStatus` replaced that migration's boolean `isFlagged` in
/// `Migrations/007_pick_reject_flags.swift`. Defaults here (`0`/`.none`)
/// match those migrations' own `defaults(to:)`, so existing construction
/// sites (e.g. `CatalogDatabase.importPhotos`, which never sets these two
/// fields) keep compiling unchanged. `rating`'s valid range (0...5) is enforced
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
    var flagStatus: FlagStatus = .none
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
        static let flagStatus = Column(CodingKeys.flagStatus)
    }

    /// GRDB calls this after a successful `INSERT` so `id` reflects the
    /// autoincremented rowid SQLite assigned, mirroring the record's own
    /// `id` field for any caller that inserted a fresh `Photo` (id: nil).
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
