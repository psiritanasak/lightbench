import GRDB

/// Migrations are append-only (never edit 001-007). Adds `photo.colorLabel`
/// (0 none, 1 red, 2 yellow, 3 green, 4 blue, 5 purple — see `ColorLabel`).
/// Purely additive: every existing row becomes "no label", so no data
/// conversion is needed.
enum Migration008ColorLabels {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("008_color_labels") { db in
            try db.alter(table: Photo.databaseTableName) { table in
                table.add(column: "colorLabel", .integer).notNull().defaults(to: 0)
            }
        }
    }
}
