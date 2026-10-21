import Foundation

/// Reads (or reuses from the `photo_metadata` cache) the camera data for a set of photos. It never modifies a photo file:
/// it stats and reads headers only, and its only writes are cache rows. Mirrors `DuplicateScanner`: sequential, CANCELLABLE
/// (`Task.isCancelled` between photos; rows read before a cancel are saved first so the next scan resumes from the cache),
/// and meant to run from a detached task because it blocks on file I/O.
///
/// A photo whose file cannot be stat'ed OR that ImageIO cannot open (missing, unreadable, offline volume, a folder this
/// sandbox has no access to right now, or simply not an image) is SKIPPED and never stored, so it is retried next time: a
/// permission failure must never be remembered as "this photo has no camera data". An image that opens but carries no EXIF
/// gets an all-nil row, so it is not re-read on every launch.
enum MetadataScanner {
    struct Environment: Sendable {
        var stat: @Sendable (_ path: String) -> (size: Int64, mtime: Double)?
        var read: @Sendable (_ path: String) -> PhotoMetadataReader.Fields?

        static let live = Environment(
            stat: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return (size, modified.timeIntervalSince1970)
            },
            read: { PhotoMetadataReader.read(from: URL(fileURLWithPath: $0)) }
        )
    }

    struct Progress: Equatable, Sendable {
        var completed: Int
        var total: Int
    }

    struct Result: Equatable, Sendable {
        /// Rows written this run (new or refreshed).
        var scanned: Int
        /// Photos whose cache row was already current.
        var reused: Int
        /// Photos whose file could not be stat'ed or opened by ImageIO (retried on a later scan, never stored).
        var skipped: Int
        var wasCancelled: Bool
    }

    /// How many new rows are buffered before a cache write.
    static let saveBatch = 100

    /// Saves rows from a task that is NOT cancelled (a cancelled task's GRDB write throws and would lose the rows).
    static func persistToDatabase(_ database: CatalogDatabase) -> @Sendable ([PhotoMetadata]) async throws -> Void {
        { rows in try await Task.detached { try await database.saveMetadata(rows) }.value }
    }

    /// Photos that have no cache row, or a row from an older reader revision. Pure, so the UI can decide whether to start a
    /// scan without touching the disk. It deliberately does NOT compare sizes: `Photo.fileSize` is only written at import
    /// and on rename/relocate (never when a file is edited elsewhere) while a row's size is the size at the last scan, so
    /// comparing them would never settle for an externally-edited file and would miss a change made after the scan. Changed
    /// files are caught by `scan` itself, whose stat pass compares size + modification time and is cheap when nothing changed.
    static func photosNeedingScan(_ photos: [Photo], cached: [Int64: PhotoMetadata]) -> [Photo] {
        photos.filter { photo in
            guard let id = photo.id, !photo.isVirtualCopy else { return false }
            guard let row = cached[id] else { return true }
            return row.readerRevision != PhotoMetadata.currentReaderRevision
        }
    }

    static func scan(
        photos: [Photo],
        database: CatalogDatabase,
        environment: Environment = .live,
        persist: (@Sendable ([PhotoMetadata]) async throws -> Void)? = nil,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let persist = persist ?? persistToDatabase(database)
        // Virtual copies are never scanned on their own: they share their master's file, and a copy inherits the master's result.
        let scannable = photos.filter { !$0.isVirtualCopy }.compactMap { photo in photo.id.map { (id: $0, path: photo.path) } }
        if Task.isCancelled { return Result(scanned: 0, reused: 0, skipped: 0, wasCancelled: true) }
        let cached: [Int64: PhotoMetadata]
        do {
            cached = try await database.metadata(forPhotoIDs: scannable.map(\.id))
        } catch is CancellationError {
            return Result(scanned: 0, reused: 0, skipped: 0, wasCancelled: true)
        }

        var pending: [PhotoMetadata] = []
        var scanned = 0, reused = 0, skipped = 0, completed = 0
        var cancelled = false
        for item in scannable {
            if Task.isCancelled { cancelled = true; break }
            guard let stat = environment.stat(item.path) else {
                skipped += 1
                completed += 1
                progress(Progress(completed: completed, total: scannable.count))
                continue
            }
            if let row = cached[item.id], row.isCurrent(fileSize: stat.size, mtime: stat.mtime) {
                reused += 1
            } else {
                guard let fields = environment.read(item.path) else {
                    skipped += 1
                    completed += 1
                    progress(Progress(completed: completed, total: scannable.count))
                    continue
                }
                pending.append(PhotoMetadata(
                    photoId: item.id, fileSize: stat.size, mtime: stat.mtime,
                    readerRevision: PhotoMetadata.currentReaderRevision,
                    captureDate: fields.captureDate, iso: fields.iso, cameraMake: fields.cameraMake,
                    cameraModel: fields.cameraModel, lens: fields.lens, focalLength: fields.focalLength,
                    aperture: fields.aperture, shutter: fields.shutter, pixelWidth: fields.pixelWidth,
                    pixelHeight: fields.pixelHeight, scannedAt: Date()
                ))
                scanned += 1
                if pending.count >= saveBatch {
                    try await persist(pending)
                    pending.removeAll()
                }
            }
            completed += 1
            progress(Progress(completed: completed, total: scannable.count))
        }
        if !pending.isEmpty { try await persist(pending) }
        return Result(scanned: scanned, reused: reused, skipped: skipped, wasCancelled: cancelled)
    }
}
