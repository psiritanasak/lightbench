import GRDB

/// Migrations are append-only. Adds the EXIF orientation (1...8) to the camera-data cache so the Library's justified-rows layout can tell a
/// portrait phone photo (stored landscape, orientation 6 or 8) from a landscape one without decoding it. Nullable: older rows have none until the
/// reader (revision 2) re-reads them, and a file without the tag stays NULL (read as "upright"). Purely additive.
enum Migration020PhotoMetadataOrientation {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("020_photo_metadata_orientation") { db in
            try db.alter(table: "photo_metadata") { table in
                table.add(column: "orientation", .integer)
            }
        }
    }
}
