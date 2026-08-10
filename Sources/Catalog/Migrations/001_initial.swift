import GRDB

/// Migrations are append-only (`CLAUDE.md` convention: "DB migrations are
/// append-only, in `Sources/Catalog/Migrations/`") — this file, once
/// shipped, must never be edited again. A future schema change adds a NEW
/// `00X_something.swift` file and a new `migrator.registerMigration(...)`
/// call, never a change to this one.
enum Migration001Initial {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("001_initial") { db in
            try db.create(table: Photo.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
                table.column("filename", .text).notNull()
                table.column("fileSize", .integer)
                table.column("importedAt", .datetime).notNull()
            }
        }
    }
}
