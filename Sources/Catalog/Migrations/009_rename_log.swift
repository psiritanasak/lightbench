import GRDB

/// Migrations are append-only (never edit 001-008). Adds the log that makes a
/// batch rename undoable (Library "Rename Files…", batch-rename commit 3):
/// `rename_batch` (one row per applied batch) and `rename_entry` (one row per
/// renamed photo: its id, old path and new path).
///
/// Only the MOST RECENT batch is ever kept — `CatalogDatabase.renamePhotos`
/// deletes older batches in the same transaction that writes the new one, so
/// the log can never disagree with the catalog about what "undo" would do.
/// `rename_entry.batchId` cascades on delete (removing a batch removes its
/// entries). `photoId` deliberately has NO foreign key: if a photo is removed
/// from the catalog after a rename, its entry must survive so an undo can
/// notice and REFUSE, rather than silently reverting only part of a batch.
enum Migration009RenameLog {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("009_rename_log") { db in
            try db.create(table: "rename_batch") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "rename_entry") { table in
                table.column("batchId", .integer).notNull()
                    .references("rename_batch", onDelete: .cascade)
                table.column("photoId", .integer).notNull()
                table.column("oldPath", .text).notNull()
                table.column("newPath", .text).notNull()
                table.primaryKey(["batchId", "photoId"])
            }
        }
    }
}
