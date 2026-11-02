import Foundation
import GRDB

/// Recently Deleted (`Migration018DeletedPhoto`, `DeletedPhotoSnapshot`). Rules:
/// - The snapshot is written in the SAME write transaction as the row delete (`trashPhotos`): both happen or neither does.
/// - One entry per ROOT: a master (its virtual copies travel inside the snapshot, with their original ids), or a virtual copy trashed on
///   its own while its master stays.
/// - A restore is CATALOG-ONLY and re-inserts the rows with their ORIGINAL ids (the rename log and sidecar keys line up). It is refused
///   unless the file exists at the original path (`fileExists`, judged inside the restore), when another master row owns the path, or when
///   a copy's master is gone. Nothing here touches a file.
extension CatalogDatabase {
    // MARK: Trashing

    /// Snapshots, then removes, the rows of `ids` (same cascades as `deletePhotos`) in ONE transaction. `trashedPaths` maps a photo id to
    /// where the Finder's Trash put its file (absent when unknown). Ids that no longer exist are ignored. Returns how many rows were removed.
    @discardableResult
    func trashPhotos(ids: [Int64], trashedPaths: [Int64: String], editFiles: [Int64: [String]] = [:], deletedAt: Date = Date()) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            try Self.writeDeletedSnapshots(db, ids: ids, trashedPaths: trashedPaths, editFiles: editFiles, deletedAt: deletedAt)
            return try Photo.filter(ids.contains(Photo.Columns.id)).deleteAll(db)
        }
    }

    private static func writeDeletedSnapshots(_ db: Database, ids: [Int64], trashedPaths: [Int64: String], editFiles: [Int64: [String]], deletedAt: Date) throws {
        let rows = try Photo.filter(ids.contains(Photo.Columns.id)).fetchAll(db)
        let doomed = Set(rows.compactMap(\.id))
        let encoder = JSONEncoder()
        for root in rows.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            guard let rootID = root.id else { continue }
            // A copy whose master goes too is inside the master's snapshot.
            if let master = root.masterId, doomed.contains(master) { continue }
            var members = [root]
            if root.masterId == nil {
                members += try Photo.filter(Photo.Columns.masterId == rootID).order(Photo.Columns.id).fetchAll(db)
            }
            var snapshot = DeletedPhotoSnapshot(rows: [], info: nil, stack: nil, editFilePaths: editFiles[rootID])
            for photo in members {
                guard let photoID = photo.id else { continue }
                let keywords = try String.fetchAll(db, sql: """
                    SELECT keyword.name FROM photo_keyword JOIN keyword ON keyword.id = photo_keyword.keywordId
                    WHERE photo_keyword.photoId = ? ORDER BY keyword.name
                    """, arguments: [photoID])
                let collections = try Row.fetchAll(db, sql: """
                    SELECT collection.id AS id, collection.name AS name, collection.folderPath AS folderPath FROM collection_photo
                    JOIN collection ON collection.id = collection_photo.collectionId
                    WHERE collection_photo.photoId = ? ORDER BY collection.id
                    """, arguments: [photoID]).map { DeletedPhotoSnapshot.CollectionRef(id: $0["id"], name: $0["name"], folderPath: $0["folderPath"]) }
                snapshot.rows.append(.init(photo: photo, keywords: keywords, collections: collections))
            }
            if root.masterId == nil {
                if let row = try Row.fetchOne(db, sql: "SELECT title, caption, creator, copyright FROM photo_info WHERE photoId = ?", arguments: [rootID]) {
                    snapshot.info = PhotoInfo(title: row["title"], caption: row["caption"], creator: row["creator"], copyright: row["copyright"])
                }
                if let member = try Row.fetchOne(db, sql: "SELECT stackId, addedManually FROM photo_stack_member WHERE photoId = ?", arguments: [rootID]) {
                    let stackID: Int64 = member["stackId"]
                    let stack = try PhotoStack.fetchOne(db, key: stackID)
                    let memberIDs = try Int64.fetchAll(db, sql: "SELECT photoId FROM photo_stack_member WHERE stackId = ? ORDER BY photoId", arguments: [stackID])
                    snapshot.stack = .init(
                        stackId: stackID, isManual: stack?.isManual ?? false, wasCover: stack?.coverPhotoId == rootID,
                        addedManually: member["addedManually"], memberIDs: memberIDs
                    )
                }
            }
            try db.execute(sql: """
                INSERT INTO deleted_photo (originalPath, trashedPath, deletedAt, schemaVersion, snapshot) VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    root.path, trashedPaths[rootID], deletedAt, DeletedPhotoSnapshot.currentSchemaVersion,
                    String(decoding: try encoder.encode(snapshot), as: UTF8.self)
                ])
        }
    }

    // MARK: Reading

    /// Newest first. An entry whose snapshot cannot be read (a newer layout) is skipped, never guessed at.
    func deletedPhotoEntries() async throws -> [DeletedPhotoEntry] {
        try await dbQueue.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: "SELECT id, originalPath, trashedPath, deletedAt, schemaVersion, snapshot FROM deleted_photo ORDER BY deletedAt DESC, id DESC")
                .compactMap { row -> DeletedPhotoEntry? in
                    let version: Int = row["schemaVersion"]
                    let json: String = row["snapshot"]
                    guard version <= DeletedPhotoSnapshot.currentSchemaVersion,
                          let snapshot = try? decoder.decode(DeletedPhotoSnapshot.self, from: Data(json.utf8)),
                          let first = snapshot.rows.first else { return nil }
                    let path: String = row["originalPath"]
                    return DeletedPhotoEntry(
                        id: row["id"], originalPath: path, trashedPath: row["trashedPath"], deletedAt: row["deletedAt"], snapshot: snapshot,
                        blocker: try Self.blocker(db, root: first.photo, path: path)
                    )
                }
        }
    }

    /// Entries that cannot be read (a layout from a newer build, or damaged JSON): shown so they can be removed.
    func unreadableDeletedPhotos() async throws -> [UnreadableDeletedPhoto] {
        try await dbQueue.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: "SELECT id, originalPath, deletedAt, schemaVersion, snapshot FROM deleted_photo ORDER BY deletedAt DESC, id DESC").compactMap { row in
                let version: Int = row["schemaVersion"]
                let json: String = row["snapshot"]
                let readable = version <= DeletedPhotoSnapshot.currentSchemaVersion
                    && ((try? decoder.decode(DeletedPhotoSnapshot.self, from: Data(json.utf8)))?.rows.first != nil)
                return readable ? nil : UnreadableDeletedPhoto(id: row["id"], originalPath: row["originalPath"], deletedAt: row["deletedAt"])
            }
        }
    }

    private static func blocker(_ db: Database, root: Photo, path: String) throws -> DeletedPhotoBlocker? {
        if let master = root.masterId {
            return try Photo.filter(Photo.Columns.id == master).fetchCount(db) == 0 ? .masterMissing : nil
        }
        return try Photo.filter(Photo.Columns.path == path).filter(Photo.Columns.versionKey == nil).fetchCount(db) > 0 ? .pathInUse : nil
    }

    // MARK: Restoring

    /// Puts the entry's rows back (original ids), in ONE transaction, and removes the entry. `fileExists` is asked about the original path
    /// inside the transaction; the restore is refused unless it answers true.
    func restoreDeletedPhoto(id: Int64, fileExists: @escaping @Sendable (String) -> Bool) async throws -> DeletedPhotoRestoreOutcome {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT originalPath, schemaVersion, snapshot FROM deleted_photo WHERE id = ?", arguments: [id]),
                  (row["schemaVersion"] as Int) <= DeletedPhotoSnapshot.currentSchemaVersion,
                  let snapshot = try? JSONDecoder().decode(DeletedPhotoSnapshot.self, from: Data((row["snapshot"] as String).utf8)),
                  let first = snapshot.rows.first, let rootID = first.photo.id
            else { return .notFound }
            let path: String = row["originalPath"]
            switch try Self.blocker(db, root: first.photo, path: path) {
            case .pathInUse: return .pathInUse
            case .masterMissing: return .masterMissing
            case nil: break
            }
            guard fileExists(path) else { return .fileMissing }
            if snapshot.editFilePaths?.contains(where: { !fileExists($0) }) == true { return .editFileMissing }
            let ids = snapshot.rows.compactMap(\.photo.id)
            if try Photo.filter(ids.contains(Photo.Columns.id)).fetchCount(db) > 0 { return .idInUse }

            var report = DeletedPhotoRestoreReport()
            var missing: [String] = []
            for entry in snapshot.rows {
                var photo = entry.photo
                try photo.insert(db) // keeps `photo.id`: the ORIGINAL id
                guard let photoID = photo.id else { continue }
                if photo.isVirtualCopy { report.restoredCopies += 1 }
                for name in entry.keywords {
                    let key = KeywordName.key(for: name)
                    var keywordID = try Int64.fetchOne(db, sql: "SELECT id FROM keyword WHERE nameKey = ?", arguments: [key])
                    if keywordID == nil {
                        var keyword = Keyword(id: nil, name: name, nameKey: key, createdAt: Date())
                        try keyword.insert(db)
                        keywordID = keyword.id
                    }
                    if let keywordID { try PhotoKeyword(keywordId: keywordID, photoId: photoID).insert(db, onConflict: .ignore) }
                }
                for collection in entry.collections {
                    if let target = try Self.currentCollectionID(db, collection) {
                        try CollectionPhoto(collectionId: target, photoId: photoID).insert(db, onConflict: .ignore)
                    } else if !missing.contains(collection.name) {
                        missing.append(collection.name)
                    }
                }
            }
            report.missingCollections = missing
            if let info = snapshot.info, !info.isEmpty,
               try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_info WHERE photoId = ?", arguments: [rootID]) == 0 {
                try db.execute(sql: """
                    INSERT INTO photo_info (photoId, title, caption, creator, copyright, updatedAt) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [rootID, info.title, info.caption, info.creator, info.copyright, Date()])
            }
            if let stack = snapshot.stack { report.stackRestored = try Self.restoreStack(db, stack, photoID: rootID) }
            try db.execute(sql: "DELETE FROM deleted_photo WHERE id = ?", arguments: [id])
            return .restored(report)
        }
    }

    /// The collection a membership goes back to: the same id when it still exists, else a folder collection for the same folder path.
    private static func currentCollectionID(_ db: Database, _ ref: DeletedPhotoSnapshot.CollectionRef) throws -> Int64? {
        if try PhotoCollection.filter(key: ref.id).fetchCount(db) > 0 { return ref.id }
        guard let folderPath = ref.folderPath else { return nil }
        return try Int64.fetchOne(db, sql: "SELECT id FROM collection WHERE folderPath = ? ORDER BY id LIMIT 1", arguments: [folderPath])
    }

    /// Back into its old stack when that still exists; else a NEW stack with the members that are still in the Library and unstacked,
    /// but only when that makes at least two (a one-photo stack never exists).
    private static func restoreStack(_ db: Database, _ ref: DeletedPhotoSnapshot.StackRef, photoID: Int64) throws -> Bool {
        if try PhotoStack.filter(key: ref.stackId).fetchCount(db) > 0 {
            try PhotoStackMember(photoId: photoID, stackId: ref.stackId, addedManually: ref.addedManually).insert(db, onConflict: .ignore)
            // The cover was set NULL when the photo went; it is the cover again unless the stack picked another since.
            if ref.wasCover {
                try db.execute(sql: "UPDATE photo_stack SET coverPhotoId = ? WHERE id = ? AND coverPhotoId IS NULL", arguments: [photoID, ref.stackId])
            }
            return true
        }
        var others: [Int64] = []
        for memberID in ref.memberIDs where memberID != photoID {
            let exists = try Photo.filter(Photo.Columns.id == memberID).filter(Photo.Columns.masterId == nil).fetchCount(db) > 0
            let free = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_stack_member WHERE photoId = ?", arguments: [memberID]) == 0
            if exists && free { others.append(memberID) }
        }
        guard !others.isEmpty else { return false }
        var stack = PhotoStack(id: nil, isManual: ref.isManual, coverPhotoId: ref.wasCover ? photoID : nil, createdAt: Date())
        try stack.insert(db)
        guard let stackID = stack.id else { return false }
        try PhotoStackMember(photoId: photoID, stackId: stackID, addedManually: ref.addedManually).insert(db)
        for memberID in others { try PhotoStackMember(photoId: memberID, stackId: stackID, addedManually: false).insert(db) } // their own flag is not in the snapshot
        return true
    }

    // MARK: Forgetting

    /// Removes list entries only (snapshot rows); no file and no photo is touched.
    func forgetDeletedPhotos(ids: [Int64]) async throws {
        try await dbQueue.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM deleted_photo WHERE id = ?", arguments: [id]) }
        }
    }

    func forgetAllDeletedPhotos() async throws {
        try await dbQueue.write { db in try db.execute(sql: "DELETE FROM deleted_photo") }
    }
}
