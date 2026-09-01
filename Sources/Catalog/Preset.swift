import Foundation
import GRDB

/// A named, saved snapshot of a photo's color/tone "look" (Phase 5 slice 2)
/// — catalog-wide, not tied to any one photo, same shape as `PhotoCollection`.
///
/// `editState` is the one field that differs from every other record in
/// this file's siblings (`Photo`, `PhotoCollection`): it's a nested
/// `Codable` value, not a scalar. GRDB's Codable-record support
/// auto-serializes it to a JSON TEXT column (see `Migrations/005_presets.swift`'s
/// own doc comment for why `.text`, not `.blob`) with no extra code here —
/// the same underlying mechanism that already lets `EditState`'s own
/// schema-tolerant `Codable` (see its `// MARK: - Custom decoding`
/// extension) survive new fields being added across sessions, reused as-is.
///
/// Only ever applies its COLOR/TONE fields to a target photo — never crop/
/// straighten/perspective/flip or the placed `redEyePoints`, both specific
/// to one photo's composition. See `EditState.applyingPreset(onto:)`.
struct Preset: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var editState: EditState
    var createdAt: Date
}

// MARK: - GRDB conformances

extension Preset: FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "preset"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
