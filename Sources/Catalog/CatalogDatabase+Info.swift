import Foundation
import GRDB

/// Library info (title, caption, creator, copyright; `Migration016PhotoInfo`). Rows are keyed by the photograph, which is the
/// MASTER photo row: a virtual copy has no row of its own.
extension CatalogDatabase {
    /// Every stored info, keyed by photo id (only masters appear; callers inherit for copies).
    func allInfo() async throws -> [Int64: PhotoInfo] {
        try await dbQueue.read { db in
            var result: [Int64: PhotoInfo] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT photoId, title, caption, creator, copyright FROM photo_info") {
                let id: Int64 = row["photoId"]
                result[id] = PhotoInfo(title: row["title"], caption: row["caption"], creator: row["creator"], copyright: row["copyright"])
            }
            return result
        }
    }

    /// Sets the `fields` of `info` (normalized by `InfoText`) on the photographs of `photoIDs`; fields not in `fields` keep each
    /// photo's own value. Ids that no longer exist are skipped; an id that names a virtual copy is resolved to its MASTER, so no row
    /// is ever created for a copy. A row whose four values end up empty is deleted. Chunked (one SQL variable per id).
    func setInfo(_ info: PhotoInfo, forPhotoIDs photoIDs: [Int64], fields: InfoFields) async throws {
        guard !fields.isEmpty else { return }
        try await dbQueue.write { db in
            var masterIDs = Set<Int64>()
            for start in stride(from: 0, to: photoIDs.count, by: 500) {
                let chunk = Array(photoIDs[start..<min(start + 500, photoIDs.count)])
                for photo in try Photo.filter(chunk.contains(Photo.Columns.id)).fetchAll(db) {
                    if let id = photo.masterId ?? photo.id { masterIDs.insert(id) }
                }
            }
            let now = Date()
            for id in masterIDs.sorted() {
                let existing = try Row.fetchOne(
                    db, sql: "SELECT title, caption, creator, copyright FROM photo_info WHERE photoId = ?", arguments: [id]
                ).map { PhotoInfo(title: $0["title"], caption: $0["caption"], creator: $0["creator"], copyright: $0["copyright"]) }
                let updated = (existing ?? PhotoInfo()).applying(info, fields: fields)
                if updated.isEmpty {
                    try db.execute(sql: "DELETE FROM photo_info WHERE photoId = ?", arguments: [id])
                } else if updated != existing {
                    try db.execute(sql: """
                        INSERT INTO photo_info (photoId, title, caption, creator, copyright, updatedAt) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(photoId) DO UPDATE SET title = excluded.title, caption = excluded.caption,
                            creator = excluded.creator, copyright = excluded.copyright, updatedAt = excluded.updatedAt
                        """, arguments: [id, updated.title, updated.caption, updated.creator, updated.copyright, now])
                }
            }
        }
    }
}
