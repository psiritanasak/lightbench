import GRDB

/// Migrations are append-only (never edit 001-012). Adds on-device face recognition data, all in the catalog only (never written
/// to sidecars or exports):
/// - `person`: a group of faces the user can name. `name` / `nameKey` are nullable (an automatically found person has no name yet);
///   `nameKey` (see `KeywordName.key(for:)`) is UNIQUE, and SQLite allows many NULLs under UNIQUE, so any number of unnamed people.
/// - `face`: one row per detected face: its box (normalised, in the ORIENTED image, origin top-left), capture quality, the feature
///   print of its padded crop (+ the print and detector revisions that produced it, so an OS change invalidates it), a small crop
///   for tiles, and the person it belongs to (`ON DELETE SET NULL`: deleting a person leaves the faces unassigned). `isConfirmed`
///   marks an assignment the USER made, which regrouping never changes. Cascades with the photo.
/// - `face_scan`: one row per scanned photo, so a photo with ZERO faces is not rescanned; trusted only while the file's size and
///   modification time and both revisions still match (like `photo_fingerprint`).
/// - `face_exclusion`: "this face is not that person", which survives regrouping.
/// Purely additive.
enum Migration013Faces {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("013_faces") { db in
            try db.create(table: "person") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text)
                table.column("nameKey", .text).unique()
                table.column("isHidden", .boolean).notNull().defaults(to: false)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "face") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("photoId", .integer).notNull().references("photo", onDelete: .cascade)
                table.column("x", .double).notNull()
                table.column("y", .double).notNull()
                table.column("w", .double).notNull()
                table.column("h", .double).notNull()
                table.column("quality", .double).notNull()
                table.column("detectRevision", .integer).notNull()
                table.column("printRevision", .integer).notNull()
                table.column("featurePrint", .blob).notNull()
                table.column("crop", .blob)
                table.column("personId", .integer).references("person", onDelete: .setNull)
                table.column("isConfirmed", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "face_photoId", on: "face", columns: ["photoId"])
            try db.create(index: "face_personId", on: "face", columns: ["personId"])
            try db.create(table: "face_scan") { table in
                table.column("photoId", .integer).notNull().primaryKey().references("photo", onDelete: .cascade)
                table.column("fileSize", .integer).notNull()
                table.column("mtime", .double).notNull()
                table.column("detectRevision", .integer).notNull()
                table.column("printRevision", .integer).notNull()
                table.column("faceCount", .integer).notNull()
                table.column("scannedAt", .datetime).notNull()
            }
            try db.create(table: "face_exclusion") { table in
                table.column("faceId", .integer).notNull().references("face", onDelete: .cascade)
                table.column("personId", .integer).notNull().references("person", onDelete: .cascade)
                table.primaryKey(["faceId", "personId"])
            }
            // The primary key covers lookups by face; the cascade from `person` and a merge look up by person.
            try db.create(index: "face_exclusion_personId", on: "face_exclusion", columns: ["personId"])
        }
    }
}
