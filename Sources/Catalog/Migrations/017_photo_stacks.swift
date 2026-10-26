import GRDB

/// Migrations are append-only (never edit 001-016; 017 is edited only while uncommitted). Adds photo stacks:
/// - `photo_stack`: one stack (automatic or manual, with an optional cover);
/// - `photo_stack_member`: puts a MASTER photo in AT MOST ONE stack (`photoId` is the primary key; a virtual copy never has a row,
///   it follows its master in the grid). Deleting a photo removes its membership (cascade), deleting a stack removes its members
///   (cascade), deleting the cover photo leaves the stack with no cover (SET NULL);
/// - `photo_stack_exclusion`: photos the user took out of a stack ("unstack"); automatic runs never stack them again
///   (the `face_exclusion` pattern);
/// - a trigger that deletes a stack as soon as it has fewer than two members, however the member went away (a write here, or a
///   photo deletion cascading into `photo_stack_member`: SQLite fires triggers for foreign-key cascade actions), so a one-member
///   stack can never exist. Purely additive.
enum Migration017PhotoStacks {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("017_photo_stacks") { db in
            try db.create(table: "photo_stack") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("isManual", .integer).notNull().defaults(to: 0)
                table.column("coverPhotoId", .integer).references("photo", onDelete: .setNull)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "photo_stack_coverPhotoId", on: "photo_stack", columns: ["coverPhotoId"])
            try db.create(table: "photo_stack_member") { table in
                table.column("photoId", .integer).primaryKey().references("photo", onDelete: .cascade)
                table.column("stackId", .integer).notNull().references("photo_stack", onDelete: .cascade)
                table.column("addedManually", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "photo_stack_member_stackId", on: "photo_stack_member", columns: ["stackId"])
            try db.create(table: "photo_stack_exclusion") { table in
                table.column("photoId", .integer).primaryKey().references("photo", onDelete: .cascade)
                table.column("createdAt", .datetime).notNull()
            }
            try db.execute(sql: """
                CREATE TRIGGER photo_stack_member_dissolve_small AFTER DELETE ON photo_stack_member
                BEGIN
                    DELETE FROM photo_stack WHERE id = OLD.stackId
                    AND (SELECT COUNT(*) FROM photo_stack_member WHERE stackId = OLD.stackId) < 2;
                END
                """)
        }
    }
}
