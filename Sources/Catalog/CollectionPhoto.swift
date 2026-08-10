import Foundation
import GRDB

/// The many-to-many join row between `PhotoCollection` and `Photo`. No
/// autoincrement id — its composite primary key (`collectionId`,
/// `photoId`, see `Migrations/003_collections.swift`) is the row's whole
/// identity, so this conforms to `PersistableRecord` (not
/// `MutablePersistableRecord`) and needs no `didInsert`.
struct CollectionPhoto: Codable, Equatable, Sendable {
    var collectionId: Int64
    var photoId: Int64
}

// MARK: - GRDB conformances

extension CollectionPhoto: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "collection_photo"

    enum Columns {
        static let collectionId = Column(CodingKeys.collectionId)
        static let photoId = Column(CodingKeys.photoId)
    }
}
