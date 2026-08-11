import GRDB

/// Migrations are append-only (`001_initial.swift`/`002_ratings_and_flags.swift`/
/// `003_collections.swift` are never edited again). First migration to
/// add a foreign key via `ALTER TABLE` (`003`'s FKs were only ever on
/// `CREATE TABLE`), and the first self-referencing one — `parentId`
/// points back at `collection.id`, forming a tree.
///
/// `folderPath` is deliberately NOT `UNIQUE` at the SQL level — SQLite
/// disallows adding a `UNIQUE` column via `ALTER TABLE ADD COLUMN`.
/// Idempotency (one collection row per on-disk folder) is instead
/// enforced in application code: `CatalogDatabase`'s find-or-create logic
/// always checks-then-inserts inside a single `dbQueue.write`
/// transaction, which GRDB serializes — no race is possible. A
/// deliberate simplification, not an oversight.
enum Migration004FolderCollections {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("004_folder_collections") { db in
            try db.alter(table: "collection") { table in
                table.add(column: "parentId", .integer)
                    .references("collection", onDelete: .cascade)
                table.add(column: "isFolder", .boolean).notNull().defaults(to: false)
                table.add(column: "folderPath", .text)
            }
        }
    }
}
