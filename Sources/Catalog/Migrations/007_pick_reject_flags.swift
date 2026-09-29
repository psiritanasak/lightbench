import GRDB

/// Migrations are append-only (never edit 001-006). Replaces
/// `002_ratings_and_flags`'s boolean `photo.isFlagged` with a three-state
/// `flagStatus` (-1 rejected, 0 none, 1 picked — see `FlagStatus`).
/// Existing flagged photos become Picks, so no user data is lost.
///
/// `drop(column:)` needs SQLite 3.35+ (macOS 12+; this project's floor is
/// 14). `isFlagged` has no index or foreign key, which is what makes a
/// plain column drop legal. Dropping it, rather than leaving it behind,
/// avoids two sources of truth for one concept.
enum Migration007PickRejectFlags {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("007_pick_reject_flags") { db in
            try db.alter(table: Photo.databaseTableName) { table in
                table.add(column: "flagStatus", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "UPDATE photo SET flagStatus = 1 WHERE isFlagged = 1")
            try db.alter(table: Photo.databaseTableName) { table in
                table.drop(column: "isFlagged")
            }
        }
    }
}
