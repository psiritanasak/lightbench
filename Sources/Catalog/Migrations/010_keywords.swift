import GRDB

/// Migrations are append-only (never edit 001-009). Adds keywords: a `keyword` table and the many-to-many
/// `photo_keyword` join. `nameKey` is the lowercased, NFC-normalized form of `name` (see `KeywordName.key(for:)`)
/// and carries the UNIQUE constraint — SQLite's `COLLATE NOCASE` only folds ASCII, so it would treat "Éclair" and
/// "éclair" as different keywords. `name` keeps the spelling the user first typed. Both foreign keys cascade, like
/// `collection_photo`: deleting a photo (or a keyword) removes its links, never leaving orphans. Purely additive.
enum Migration010Keywords {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("010_keywords") { db in
            try db.create(table: "keyword") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("nameKey", .text).notNull().unique()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "photo_keyword") { table in
                table.column("keywordId", .integer).notNull()
                    .references("keyword", onDelete: .cascade)
                table.column("photoId", .integer).notNull()
                    .references("photo", onDelete: .cascade)
                table.primaryKey(["keywordId", "photoId"])
            }
            try db.create(index: "photo_keyword_photoId", on: "photo_keyword", columns: ["photoId"])
        }
    }
}
