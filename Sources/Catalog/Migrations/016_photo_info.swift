import GRDB

/// Migrations are append-only (never edit 001-015). Adds the Library's descriptive text: one `photo_info` row per photograph
/// (title, caption, creator, copyright). A separate table, not new `photo` columns (the `photo_metadata` reasoning: `Photo` is
/// built field-by-field in many places). `photoId` is the primary key and cascades with the photo. A text column holds '' for
/// "no value"; a row whose four values are all empty is never stored (`CatalogDatabase.setInfo` deletes it). Info belongs to the
/// photograph, so a virtual copy never has a row of its own. Purely additive.
enum Migration016PhotoInfo {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("016_photo_info") { db in
            try db.create(table: "photo_info") { table in
                table.column("photoId", .integer).primaryKey().references("photo", onDelete: .cascade)
                table.column("title", .text).notNull().defaults(to: "")
                table.column("caption", .text).notNull().defaults(to: "")
                table.column("creator", .text).notNull().defaults(to: "")
                table.column("copyright", .text).notNull().defaults(to: "")
                table.column("updatedAt", .datetime).notNull()
            }
        }
    }
}
