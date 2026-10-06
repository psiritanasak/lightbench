import GRDB

/// Migrations are append-only (never edit 001-011). Adds the duplicate-detection cache: one `photo_fingerprint` row per
/// photo holding the file's size + modification time AS SEEN WHEN IT WAS COMPUTED (a row is only trusted while the file
/// still has both), an optional streamed SHA-256 (`contentHash`, computed lazily — only for files that share a size with
/// another photo) and an optional Vision feature print (`featurePrint` blob + the request `featurePrintRevision` it came
/// from, so an OS that changes the revision invalidates it). Cascades with the photo like `photo_keyword`. Purely additive.
enum Migration012PhotoFingerprint {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("012_photo_fingerprint") { db in
            try db.create(table: "photo_fingerprint") { table in
                table.column("photoId", .integer).notNull().primaryKey()
                    .references("photo", onDelete: .cascade)
                table.column("fileSize", .integer).notNull()
                table.column("mtime", .double).notNull()
                table.column("contentHash", .text)
                table.column("featurePrint", .blob)
                table.column("featurePrintRevision", .integer)
                table.column("computedAt", .datetime).notNull()
            }
        }
    }
}
