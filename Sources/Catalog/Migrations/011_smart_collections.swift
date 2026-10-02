import GRDB

/// Migrations are append-only (never edit 001-010). Adds Smart Collections: saved, named filter criteria that are
/// re-evaluated live. `criteria` is JSON text (GRDB persists a nested Codable value as a JSON string, like
/// `preset.editState`). There is deliberately NO foreign key to `keyword`: a criterion names its keyword by
/// `nameKey` inside the JSON, so deleting a keyword never cascades into (or invalidates) a smart collection — the
/// criterion just stops matching anything. Name uniqueness is enforced in Swift (`CatalogDatabase`), not by a
/// `UNIQUE`/`COLLATE NOCASE` column, because SQLite's NOCASE only folds ASCII. Purely additive.
enum Migration011SmartCollections {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("011_smart_collections") { db in
            try db.create(table: "smart_collection") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("criteria", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
    }
}
