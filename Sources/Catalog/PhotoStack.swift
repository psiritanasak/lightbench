import Foundation
import GRDB

/// One stack row (`Migration017PhotoStacks`). A stack the user ever touched is `isManual`; an automatic run never changes it.
struct PhotoStack: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var isManual: Bool
    /// The master the stack shows when collapsed; nil means "first visible member".
    var coverPhotoId: Int64?
    var createdAt: Date
}

extension PhotoStack: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "photo_stack"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let isManual = Column(CodingKeys.isManual)
        static let coverPhotoId = Column(CodingKeys.coverPhotoId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One membership row: a MASTER photo in a stack.
struct PhotoStackMember: Codable, Equatable, Sendable {
    var photoId: Int64
    var stackId: Int64
    /// True when the user put this photo in the stack (as opposed to a planner run).
    var addedManually: Bool
}

extension PhotoStackMember: FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "photo_stack_member"

    enum Columns {
        static let photoId = Column(CodingKeys.photoId)
        static let stackId = Column(CodingKeys.stackId)
    }
}

/// A stack with its member (master) ids, as the model and `StackDisplay` consume it. `memberIDs` is sorted ascending.
struct StackSnapshot: Equatable, Hashable, Identifiable, Sendable {
    var id: Int64
    var isManual: Bool
    var coverPhotoID: Int64?
    var memberIDs: [Int64]
}
