import GRDB

/// Migrations are append-only (`001_initial.swift`/`002_ratings_and_flags.swift`
/// are never edited again). First migration to introduce a foreign key, a
/// composite primary key, and a second table in one migration.
///
/// `collection_photo` is the many-to-many join table between `collection`
/// and `photo`; its composite primary key (`collectionId`, `photoId`)
/// makes a duplicate membership row impossible at the schema level, and
/// `onDelete: .cascade` on both foreign keys means deleting a collection
/// or a photo automatically cleans up its membership rows (GRDB enables
/// `PRAGMA foreign_keys` by default, not overridden anywhere in
/// `CatalogDatabase`, so these are enforced).
enum Migration003Collections {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("003_collections") { db in
            try db.create(table: "collection") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "collection_photo") { table in
                table.column("collectionId", .integer).notNull()
                    .references("collection", onDelete: .cascade)
                table.column("photoId", .integer).notNull()
                    .references("photo", onDelete: .cascade)
                table.primaryKey(["collectionId", "photoId"])
            }
        }
    }
}
