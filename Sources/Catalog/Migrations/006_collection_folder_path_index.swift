import GRDB

/// Migrations are append-only (never edit 001-005). `collection.folderPath`
/// (added by `004_folder_collections.swift`, deliberately not `UNIQUE` at
/// the SQL level — see that migration's own doc comment) has been queried
/// by two lookups (`CatalogDatabase.findOrCreateFolderCollection`'s own
/// existing-row check, and `registerPhoto`'s folder-membership lookup)
/// since it was added, with no index — this is the first index anywhere
/// in this schema. Plain
/// (non-unique) index: uniqueness is still enforced in application code,
/// not at the SQL level, matching `004`'s own reasoning exactly.
enum Migration006CollectionFolderPathIndex {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("006_collection_folder_path_index") { db in
            try db.create(index: "collection_on_folderPath", on: "collection", columns: ["folderPath"])
        }
    }
}
