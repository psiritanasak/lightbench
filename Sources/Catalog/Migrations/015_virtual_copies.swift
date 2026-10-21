import GRDB

/// Migrations are append-only (never edit 001-014). Adds Virtual Copies: several independent edit versions of ONE file, each its own
/// `photo` row (its own rating/flag/label/keywords/collections/sidecar) pointing at the shared file.
///
/// `photo.path` was a column-level `UNIQUE` (001), which SQLite cannot drop in place, so the table is rebuilt the documented way
/// (create `photo_new`, copy, drop, rename). GRDB runs a migration with foreign keys OFF and verifies `foreign_key_check` before
/// committing, so dropping the old table does NOT cascade-delete the children (collection_photo, photo_keyword, photo_fingerprint,
/// face, face_scan, photo_metadata, rename_entry ...) and their references to `photo(id)` resolve again once the new table is renamed.
/// Row ids are copied verbatim, and the AUTOINCREMENT counter is carried over so a deleted id is never reissued.
///
/// New columns: `versionName` (the copy's display name, "Copy N"; NULL for a master), `masterId` (the master row a copy belongs to; NULL for every existing photo, CASCADE so removing a master row removes
/// its copies' rows) and `versionKey` (a short UUID naming the copy's sidecar, NULL for a master). Uniqueness moves to two indexes:
/// masters stay unique by `path` (a PARTIAL index, `versionKey IS NULL`), and `(path, versionKey)` is unique for copies.
enum Migration015VirtualCopies {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("015_virtual_copies") { db in
            let oldSequence = try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'photo'")
            try db.create(table: "photo_new") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull()
                table.column("filename", .text).notNull()
                table.column("fileSize", .integer)
                table.column("importedAt", .datetime).notNull()
                table.column("rating", .integer).notNull().defaults(to: 0)
                table.column("flagStatus", .integer).notNull().defaults(to: 0)
                table.column("colorLabel", .integer).notNull().defaults(to: 0)
                table.column("masterId", .integer).references("photo", onDelete: .cascade) // names the FINAL table (a self-reference to photo_new would not be rewritten by the rename)
                table.column("versionKey", .text)
                table.column("versionName", .text)
            }
            try db.execute(sql: """
                INSERT INTO photo_new (id, path, filename, fileSize, importedAt, rating, flagStatus, colorLabel)
                SELECT id, path, filename, fileSize, importedAt, rating, flagStatus, colorLabel FROM photo
                """)
            try db.drop(table: "photo")
            try db.rename(table: "photo_new", to: "photo")
            if let oldSequence {
                try db.execute(sql: "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'photo'", arguments: [oldSequence])
            }
            try db.execute(sql: "CREATE UNIQUE INDEX photo_master_path ON photo(path) WHERE versionKey IS NULL")
            try db.execute(sql: "CREATE UNIQUE INDEX photo_path_version ON photo(path, versionKey)")
            try db.create(index: "photo_masterId", on: "photo", columns: ["masterId"])
        }
    }
}
