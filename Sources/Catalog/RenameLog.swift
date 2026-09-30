import Foundation
import GRDB

/// One photo's rename: which catalog row, from where, to where (full paths).
/// The unit both the catalog update and the rename log operate on.
struct RenameMove: Equatable, Sendable {
    var photoID: Int64
    var oldPath: String
    var newPath: String

    /// The same move backwards — what an undo, or a rollback after a failed
    /// catalog write, applies.
    var inverse: RenameMove { RenameMove(photoID: photoID, oldPath: newPath, newPath: oldPath) }
}

/// The most recent applied batch, as stored in `rename_batch`/`rename_entry`
/// (`Migrations/009_rename_log.swift`).
struct LoggedRename: Equatable, Sendable {
    var batchID: Int64
    var createdAt: Date
    var moves: [RenameMove]
}

/// Why a catalog rename (or an undo) was refused. Nothing is changed when any
/// of these is thrown — the whole batch is one transaction.
enum RenameCatalogError: Error, Equatable, LocalizedError {
    case photoMissing(Int64)
    case pathChanged(Int64)
    case pathTaken(String)
    case noLoggedRename

    var errorDescription: String? {
        switch self {
        case .photoMissing:
            return "A photo in this rename is no longer in the catalog."
        case .pathChanged:
            return "A photo was moved or renamed since — nothing was changed."
        case .pathTaken(let path):
            return "Another catalogued photo already uses \"\(URL(fileURLWithPath: path).lastPathComponent)\"."
        case .noLoggedRename:
            return "There is no rename to undo."
        }
    }
}

struct RenameBatchRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rename_batch"
    var id: Int64?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct RenameEntryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "rename_entry"
    var batchId: Int64
    var photoId: Int64
    var oldPath: String
    var newPath: String
}
