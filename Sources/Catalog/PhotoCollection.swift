import Foundation
import GRDB

/// A user-created album — Phase 4 slice 4. Named `PhotoCollection`, not
/// `Collection`: this project is a single Swift module (no per-directory
/// targets), so a bare `struct Collection` would shadow `Swift.Collection`
/// project-wide, a real risk given how pervasive that protocol is. The
/// SQL table itself is still named `collection` (no ambiguity at the SQL
/// layer, only the Swift type name matters here).
///
/// Membership is a separate many-to-many relation (`CollectionPhoto`),
/// not a field on `Photo` or here — see `Migrations/003_collections.swift`.
///
/// `parentId`/`isFolder`/`folderPath` added in
/// `Migrations/004_folder_collections.swift` (folder-mirrored nested
/// collections): a folder-derived collection has `isFolder == true` and
/// `folderPath` set to the on-disk directory it mirrors; `parentId`
/// points at its parent collection's `id` (`nil` for a tree root, same
/// as every pre-existing manual collection). Defaults here match the
/// migration's own `defaults(to:)`, so `CatalogDatabase.createCollection`'s
/// existing `PhotoCollection(id:name:createdAt:)` construction keeps
/// compiling unchanged.
struct PhotoCollection: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var createdAt: Date
    var parentId: Int64? = nil
    var isFolder: Bool = false
    var folderPath: String? = nil
}

// MARK: - GRDB conformances

extension PhotoCollection: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "collection"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let createdAt = Column(CodingKeys.createdAt)
        static let parentId = Column(CodingKeys.parentId)
        static let isFolder = Column(CodingKeys.isFolder)
        static let folderPath = Column(CodingKeys.folderPath)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
