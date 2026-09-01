import GRDB

/// Migrations are append-only. Phase 5 slice 2 (Presets): a new,
/// standalone `preset` table — no `ALTER TABLE` needed, so unlike
/// `collection.name` (see `004`'s own doc comment on why `folderPath`
/// isn't `UNIQUE`), `name` CAN be declared `UNIQUE` here, since SQLite's
/// restriction is specifically on adding a `UNIQUE` column to an
/// already-existing table via `ALTER TABLE ADD COLUMN` — a fresh
/// `CREATE TABLE` has no such limit.
///
/// `editState` is a `.text` column holding the preset's saved `EditState`
/// as JSON, written by GRDB's own Codable-record support (see
/// `Preset.swift`) — no manual encode/decode in this file. `.text`, not
/// `.blob`: GRDB's Codable-record support actually persists nested
/// `Codable` values as a JSON STRING (verified against the vendored GRDB
/// source, not assumed), matching what GRDB's own docs recommend for a
/// JSON column — an earlier draft of this migration declared `.blob`,
/// which "worked" only because SQLite's BLOB affinity means "no type
/// conversion", silently storing the text verbatim.
enum Migration005Presets {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("005_presets") { db in
            try db.create(table: Preset.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull().unique()
                table.column("editState", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
    }
}
