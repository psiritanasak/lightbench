import Foundation

/// Computes (or reuses from the `photo_fingerprint` cache) the duplicate-detection data for a set of photos. It never
/// modifies a photo file: it stats, hashes and decodes thumbnails read-only, and its only writes are cache rows.
///
/// Work is sequential and CANCELLABLE (`Task.isCancelled` is checked between photos); rows computed before a cancel are
/// saved first, so the next scan resumes from the cache instead of starting over. Run it from a detached task — it blocks.
enum DuplicateScanner {
    /// The three file-system/Vision operations, injectable so tests need neither real files nor Vision.
    struct Environment: Sendable {
        var stat: @Sendable (_ path: String) -> (size: Int64, mtime: Double)?
        var hash: @Sendable (_ path: String) -> String?
        var featurePrint: @Sendable (_ path: String) -> Data?

        static let live = Environment(
            stat: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return (size, modified.timeIntervalSince1970)
            },
            hash: { FileHasher.sha256Hex(ofFileAt: URL(fileURLWithPath: $0)) },
            featurePrint: { FeaturePrintGenerator.fingerprint(ofFileAt: URL(fileURLWithPath: $0)) }
        )
    }

    struct Progress: Equatable, Sendable {
        var completed: Int
        var total: Int
    }

    struct Result: Equatable, Sendable {
        var candidates: [DuplicateCandidate]
        /// Photos whose file could not be stat'ed (missing, unreadable, offline volume): not scanned, never "missing".
        var skipped: Int
        /// Photos that were scanned but whose image could not be decoded for a feature print (still hashed if needed).
        var withoutFeaturePrint: Int
        var wasCancelled: Bool
    }

    /// How many new rows are buffered before a cache write.
    static let saveBatch = 100

    /// Saves rows from a task that is NOT cancelled: a cancelled task's GRDB writes throw `CancellationError`, which would
    /// lose exactly the rows a cancel is supposed to keep.
    static func persistToDatabase(_ database: CatalogDatabase) -> @Sendable ([PhotoFingerprint]) async throws -> Void {
        { rows in try await Task.detached { try await database.saveFingerprints(rows) }.value }
    }

    static func scan(
        photos: [Photo],
        database: CatalogDatabase,
        environment: Environment = .live,
        persist: (@Sendable ([PhotoFingerprint]) async throws -> Void)? = nil,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let persist = persist ?? persistToDatabase(database)
        let scannable = photos.compactMap { photo in photo.id.map { (id: $0, photo: photo) } }
        // A task cancelled before it starts has done nothing; GRDB's async calls would throw CancellationError.
        if Task.isCancelled { return Result(candidates: [], skipped: 0, withoutFeaturePrint: 0, wasCancelled: true) }
        let cached: [Int64: PhotoFingerprint]
        do {
            cached = try await database.fingerprints(forPhotoIDs: scannable.map(\.id))
        } catch is CancellationError {
            // Cancelled between the check above and the read: still a cancel, not a failure.
            return Result(candidates: [], skipped: 0, withoutFeaturePrint: 0, wasCancelled: true)
        }

        // Pass 1: stat everything (cheap) — current size/mtime decide cache validity and which files need hashing.
        var stats: [Int64: (size: Int64, mtime: Double)] = [:]
        var skipped = 0
        for item in scannable {
            if Task.isCancelled { break }
            if let stat = environment.stat(item.photo.path) { stats[item.id] = stat } else { skipped += 1 }
        }
        var photosPerSize: [Int64: Int] = [:]
        for stat in stats.values { photosPerSize[stat.size, default: 0] += 1 }

        // Pass 2: per photo, reuse what is current, compute what is missing.
        var candidates: [DuplicateCandidate] = []
        var pending: [PhotoFingerprint] = []
        var withoutFeaturePrint = 0
        var completed = 0
        let total = stats.count
        var cancelled = Task.isCancelled
        for item in scannable {
            guard let stat = stats[item.id] else { continue }
            if Task.isCancelled { cancelled = true; break }
            let valid = cached[item.id].flatMap { $0.isCurrent(fileSize: stat.size, mtime: stat.mtime) ? $0 : nil }
            var hash = valid?.contentHash
            var printData = valid?.featurePrint
            var printRevision = valid?.featurePrintRevision
            var changed = valid == nil

            if hash == nil, photosPerSize[stat.size, default: 0] > 1 {
                hash = environment.hash(item.photo.path)
                changed = changed || hash != nil
            }
            let printIsUsable = printData.flatMap { FeaturePrintVector.vector(from: $0) } != nil
                && printRevision == FeaturePrintGenerator.revision
            if !printIsUsable {
                printData = environment.featurePrint(item.photo.path)
                printRevision = printData == nil ? nil : FeaturePrintGenerator.revision
                changed = changed || printData != nil
            }
            let vector = printData.flatMap { FeaturePrintVector.vector(from: $0) }
            if vector == nil { withoutFeaturePrint += 1 }

            if changed {
                pending.append(PhotoFingerprint(
                    photoId: item.id, fileSize: stat.size, mtime: stat.mtime, contentHash: hash,
                    featurePrint: vector == nil ? nil : printData, featurePrintRevision: vector == nil ? nil : printRevision,
                    computedAt: Date()
                ))
                if pending.count >= saveBatch {
                    try await persist(pending)
                    pending.removeAll()
                }
            }
            candidates.append(DuplicateCandidate(
                id: item.id, rating: item.photo.rating, flag: item.photo.flagStatus, fileSize: stat.size,
                importedAt: item.photo.importedAt, contentHash: hash, featurePrint: vector
            ))
            completed += 1
            progress(Progress(completed: completed, total: total))
        }
        if !pending.isEmpty { try await persist(pending) }
        return Result(candidates: candidates, skipped: skipped, withoutFeaturePrint: withoutFeaturePrint, wasCancelled: cancelled)
    }
}
