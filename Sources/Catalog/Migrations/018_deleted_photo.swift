import GRDB

/// Migrations are append-only (never edit 001-017). Adds "Recently Deleted": one `deleted_photo` row per photo that "Move to Trash" took
/// out of the Library, written in the SAME transaction as the row delete (`CatalogDatabase.trashPhotos`). The row is a SNAPSHOT, not a
/// hidden photo row: `snapshot` is JSON (`DeletedPhotoSnapshot`: the photo rows with their original ids, keyword names, collection
/// memberships, info and stack membership), `schemaVersion` says which JSON layout it is, `trashedPath` is where the Finder's Trash put
/// the file (NULL when the mover did not say). It references NOTHING (no foreign key to `photo`): the photo row is gone by design.
/// Purely additive; older builds refuse a catalog that carries it, as for every migration.
enum Migration018DeletedPhoto {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("018_deleted_photo") { db in
            try db.create(table: "deleted_photo") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("originalPath", .text).notNull()
                table.column("trashedPath", .text)
                table.column("deletedAt", .datetime).notNull()
                table.column("schemaVersion", .integer).notNull()
                table.column("snapshot", .text).notNull()
            }
        }
    }
}
