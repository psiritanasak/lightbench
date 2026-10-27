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

/// Lightroom-style color label. Raw values are what the `colorLabel` column
/// stores; `none` is `0` so `Migrations/008_color_labels.swift`'s
/// `defaults(to: 0)` means "no label". Purple has no default keyboard key
/// (Lightroom's own 6-9 map to red/yellow/green/blue) and is menu-only.
enum ColorLabel: Int, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case none = 0
    case red = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5
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
/// `Migrations/007_pick_reject_flags.swift`; `colorLabel` added in
/// `Migrations/008_color_labels.swift`. Defaults here (`0`/`.none`/`.none`)
/// match those migrations' own `defaults(to:)`, so existing construction
/// sites (e.g. `CatalogDatabase.importPhotos`, which never sets these three
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
    /// Added in `Migrations/008_color_labels.swift`; default matches its `defaults(to: 0)`.
    var colorLabel: ColorLabel = .none
    /// Added in `Migrations/015_virtual_copies.swift`: the MASTER row this virtual copy belongs to (nil for a master, i.e. every
    /// photo imported the ordinary way). A copy is its own row (own rating/flag/label/keywords/collections) over the SAME file.
    var masterId: Int64?
    /// A short random token naming the copy's own sidecar (`<file>.<versionKey>.photoapp.json`); nil for a master.
    var versionKey: String?
    /// The copy's display name ("Copy 1", "Copy 2" ...); nil for a master.
    var versionName: String?

    /// True for a virtual copy (a row with a `versionKey`).
    var isVirtualCopy: Bool { versionKey != nil }

    /// Which EDIT SET this row is: the path for a master (exactly what `path` always meant), path + versionKey for a copy. Use this,
    /// not `path`, wherever a cache/selection/"is this the open photo" decision is about the edits rather than the file.
    var editKey: String { Self.editKey(path: path, versionKey: versionKey) }

    static func editKey(path: String, versionKey: String?) -> String {
        guard let versionKey else { return path }
        return path + "\u{1F}" + versionKey
    }

    /// The inverse of `editKey(path:versionKey:)`: a key with the unit separator is a copy's (path, version key); anything else is a
    /// master's path. The LAST separator wins, which is the one `editKey` appends.
    static func splitEditKey(_ key: String) -> (path: String, versionKey: String?) {
        guard let separator = key.lastIndex(of: "\u{1F}") else { return (key, nil) }
        return (String(key[..<separator]), String(key[key.index(after: separator)...]))
    }
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
        static let colorLabel = Column(CodingKeys.colorLabel)
        static let masterId = Column(CodingKeys.masterId)
        static let versionKey = Column(CodingKeys.versionKey)
        static let versionName = Column(CodingKeys.versionName)
    }

    /// GRDB calls this after a successful `INSERT` so `id` reflects the
    /// autoincremented rowid SQLite assigned, mirroring the record's own
    /// `id` field for any caller that inserted a fresh `Photo` (id: nil).
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
