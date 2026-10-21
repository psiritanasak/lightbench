import Foundation

/// Finds faces in catalogued photos and stores them (`face`, `face_scan`). Read-only on the photo files: it stats and decodes
/// thumbnails and writes only catalog rows. Same shape as `DuplicateScanner`: sequential, CANCELLABLE between photos (rows computed
/// before a cancel are saved first, so the next scan resumes), run from a detached task — it blocks.
///
/// A photo is skipped while its `face_scan` record still matches the file's size and modification time and both revisions, so a
/// photo with ZERO faces is not rescanned either. A photo that cannot be decoded is NOT recorded (retried next time, cheap).
enum FaceScanner {
    /// The file-system and Vision operations, injectable so tests need neither real files nor Vision.
    struct Environment: Sendable {
        var stat: @Sendable (_ path: String) -> (size: Int64, mtime: Double)?
        var detect: @Sendable (_ path: String) -> [FaceDetector.DetectedFace]?

        static let live = Environment(
            stat: DuplicateScanner.Environment.live.stat,
            detect: { FaceDetector.detect(inFileAt: URL(fileURLWithPath: $0)) })
    }

    struct Progress: Equatable, Sendable {
        var completed: Int
        var total: Int
    }

    struct Result: Equatable, Sendable {
        /// Photos looked at this run (skipped-as-current ones included in `alreadyCurrent`).
        var scanned: Int
        var alreadyCurrent: Int
        var facesFound: Int
        /// Photos whose file could not be stat'ed (missing, offline): not scanned, never "missing".
        var skipped: Int
        /// Photos that exist but could not be decoded.
        var undecodable: Int
        var wasCancelled: Bool
    }

    static let saveBatch = 100

    /// Saves from a task that is NOT cancelled (a cancelled task's GRDB writes throw, losing exactly the rows a cancel should keep).
    static func persistToDatabase(_ database: CatalogDatabase) -> @Sendable ([FaceScanResult]) async throws -> Void {
        { results in try await Task.detached { try await database.saveFaceScans(results) }.value }
    }

    static func scan(
        photos: [Photo],
        database: CatalogDatabase,
        environment: Environment = .live,
        persist: (@Sendable ([FaceScanResult]) async throws -> Void)? = nil,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let persist = persist ?? persistToDatabase(database)
        // Virtual copies are never scanned on their own: they share their master's file, and a copy inherits the master's result.
        let scannable = photos.filter { !$0.isVirtualCopy }.compactMap { photo in photo.id.map { (id: $0, photo: photo) } }
        var result = Result(scanned: 0, alreadyCurrent: 0, facesFound: 0, skipped: 0, undecodable: 0, wasCancelled: false)
        if Task.isCancelled { result.wasCancelled = true; return result }
        let cached: [Int64: FaceScanRecord]
        do {
            cached = try await database.faceScans(forPhotoIDs: scannable.map(\.id))
        } catch is CancellationError {
            result.wasCancelled = true
            return result
        }

        // Pass 1: stat everything (cheap): current size/mtime decide which records are still trusted.
        var stats: [Int64: (size: Int64, mtime: Double)] = [:]
        for item in scannable {
            if Task.isCancelled { break }
            if let stat = environment.stat(item.photo.path) { stats[item.id] = stat } else { result.skipped += 1 }
        }

        // A cancel during pass 1 must still be reported even if no photo reached pass 2's own check.
        if Task.isCancelled { result.wasCancelled = true }
        // Pass 2: detect where needed.
        var pending: [FaceScanResult] = []
        let total = stats.count
        var completed = 0
        for item in scannable {
            guard let stat = stats[item.id] else { continue }
            if Task.isCancelled { result.wasCancelled = true; break }
            completed += 1
            result.scanned += 1
            if let record = cached[item.id], record.isCurrent(fileSize: stat.size, mtime: stat.mtime,
                                                              detectRevision: FaceDetector.detectRevision, printRevision: FeaturePrintGenerator.revision) {
                result.alreadyCurrent += 1
                progress(Progress(completed: completed, total: total))
                continue
            }
            guard let detected = environment.detect(item.photo.path) else {
                result.undecodable += 1
                progress(Progress(completed: completed, total: total))
                continue
            }
            let faces = detected.map { face in
                Face(id: nil, photoId: item.id, x: face.x, y: face.y, w: face.w, h: face.h, quality: face.quality,
                     detectRevision: FaceDetector.detectRevision, printRevision: FeaturePrintGenerator.revision,
                     featurePrint: face.featurePrint, crop: face.crop, personId: nil, isConfirmed: false)
            }
            result.facesFound += faces.count
            pending.append(FaceScanResult(
                scan: FaceScanRecord(photoId: item.id, fileSize: stat.size, mtime: stat.mtime, detectRevision: FaceDetector.detectRevision,
                                     printRevision: FeaturePrintGenerator.revision, faceCount: faces.count, scannedAt: Date()),
                faces: faces))
            if pending.count >= saveBatch {
                try await persist(pending)
                pending.removeAll()
            }
            progress(Progress(completed: completed, total: total))
        }
        if !pending.isEmpty { try await persist(pending) }
        return result
    }
}
