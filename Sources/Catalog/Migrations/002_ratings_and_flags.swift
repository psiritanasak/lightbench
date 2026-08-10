import GRDB

/// Migrations are append-only (`001_initial.swift` is never edited again —
/// see its own header comment). This is the first migration to ALTER an
/// existing table rather than create one; GRDB's `DatabaseMigrator` runs
/// unapplied migrations in registration order against whatever schema
/// version is already on disk, so an existing `catalog.sqlite` from
/// slices 1/2 (which only ran `001_initial`) picks this up automatically
/// on next launch — no data loss, no manual migration step.
enum Migration002RatingsAndFlags {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("002_ratings_and_flags") { db in
            try db.alter(table: Photo.databaseTableName) { table in
                table.add(column: "rating", .integer).notNull().defaults(to: 0)
                table.add(column: "isFlagged", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
