import GRDB

/// Migrations are append-only (never edit 001-018). Adds `face.isSmall`: a face found only by the optional small-face pass (the whole
/// photo searched in tiles at high resolution). Small faces are stored and shown but are NEVER grouped automatically (grouping reads only
/// `isSmall = 0` rows), so the 0.45 grouping threshold, measured on larger faces, never meets them. Existing rows get 0.
/// Purely additive; older builds refuse a catalog that carries it, as for every migration.
enum Migration019FaceSmall {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("019_face_small") { db in
            try db.alter(table: "face") { table in
                table.add(column: "isSmall", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
