import Foundation
import GRDB

extension CatalogDatabase {
    // MARK: Photo metadata (field-based search cache)

    /// The cached metadata for `photoIDs` (absent ids simply have no entry). Callers must still check
    /// `PhotoMetadata.isCurrent` against the file before trusting one.
    func metadata(forPhotoIDs photoIDs: [Int64]) async throws -> [Int64: PhotoMetadata] {
        try await dbQueue.read { db in
            var result: [Int64: PhotoMetadata] = [:]
            for start in stride(from: 0, to: photoIDs.count, by: 500) {
                let chunk = Array(photoIDs[start..<min(start + 500, photoIDs.count)])
                for row in try PhotoMetadata.filter(chunk.contains(PhotoMetadata.Columns.photoId)).fetchAll(db) {
                    result[row.photoId] = row
                }
            }
            return result
        }
    }

    /// Every cached row, keyed by photo id (what `CatalogModel.refresh()` loads for the Library search). Rows that are
    /// stale against their file are still returned: staleness is the scanner's concern, search just uses what is cached. That includes rows from an OLDER reader revision, so a revision bump that FIXES a parse (rather than adding a field) leaves old values searchable until the rescan finishes.
    func allMetadata() async throws -> [Int64: PhotoMetadata] {
        try await dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try PhotoMetadata.fetchAll(db).map { ($0.photoId, $0) })
        }
    }

    /// Inserts or REPLACES whole rows. Rows for photos that no longer exist are skipped instead of tripping the foreign
    /// key and aborting the batch.
    func saveMetadata(_ rows: [PhotoMetadata]) async throws {
        try await dbQueue.write { db in
            var existing = Set<Int64>()
            let ids = rows.map(\.photoId)
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                existing.formUnion(try Int64.fetchAll(db, Photo.filter(chunk.contains(Photo.Columns.id)).select(Photo.Columns.id)))
            }
            for row in rows where existing.contains(row.photoId) { try row.save(db) }
        }
    }
}
