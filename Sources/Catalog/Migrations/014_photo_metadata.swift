import GRDB

/// Migrations are append-only (never edit 001-013). Adds the camera-data cache behind field-based search: one
/// `photo_metadata` row per photo holding the EXIF fields the Library search understands (capture date, ISO, camera, lens,
/// focal length, aperture, shutter, pixel size) AS READ FROM THE FILE, tied to the file's size + modification time at read
/// time (a row is only trusted while the file still has both) and to `readerRevision`, so a reader that learns a new field
/// can invalidate old rows. A photo with no usable EXIF still gets a row (every payload column NULL) so it is not re-read
/// on every launch. A SEPARATE table rather than new `photo` columns: dozens of tests and callers construct `Photo` with
/// every field. Cascades with the photo like `photo_fingerprint`. Purely additive.
enum Migration014PhotoMetadata {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("014_photo_metadata") { db in
            try db.create(table: "photo_metadata") { table in
                table.column("photoId", .integer).notNull().primaryKey()
                    .references("photo", onDelete: .cascade)
                table.column("fileSize", .integer).notNull()
                table.column("mtime", .double).notNull()
                table.column("readerRevision", .integer).notNull()
                table.column("captureDate", .double)
                table.column("iso", .integer)
                table.column("cameraMake", .text)
                table.column("cameraModel", .text)
                table.column("lens", .text)
                table.column("focalLength", .double)
                table.column("aperture", .double)
                table.column("shutter", .double)
                table.column("pixelWidth", .integer)
                table.column("pixelHeight", .integer)
                table.column("scannedAt", .datetime).notNull()
            }
        }
    }
}
