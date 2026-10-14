import CoreGraphics
import Foundation

/// Screen-sized previews for the cull view, with neighbour prefetch. Same shape as `ThumbnailCache` (an `actor` for free in-flight
/// de-duplication, `NSCache` so memory stays bounded) but keyed by path AND pixel size, and holding only a handful of large images
/// instead of a catalog's worth of small ones.
///
/// Prefetch runs on ONE worker task that decodes the wanted photos in order and checks for cancellation between them, so a fast
/// run of next-key presses abandons the stale neighbours instead of queueing behind them (a single decode cannot be interrupted — the
/// generator is synchronous — but at most one is wasted). RAW photos still go through `RawDecoder.RenderGate` like every RAW decode,
/// so a RAW prefetch can queue behind other RAW work; that is accepted and documented rather than worked around.
///
/// The decode closure below deliberately captures no instance member (only `photo`, `path` and `pixelSize`), for the same reason
/// `ThumbnailCache.thumbnail(for:)` documents at length: capturing `self` would pin the decode to this actor and serialise decodes.
actor CullPreviewCache {
    /// Long-edge pixel size for a view: the view's long edge in points times the backing scale, kept between a floor (tiny windows) and
    /// a cap (memory: a 3200 px preview is ~41 MB as RGBA8).
    static func targetPixelSize(viewLongEdge: Double, scale: Double) -> Int {
        guard viewLongEdge.isFinite, scale.isFinite, viewLongEdge > 0, scale > 0 else { return minPixelSize }
        // Rounded UP to a step so a live window resize does not start a fresh full decode (and cache key) at every pixel.
        let wanted = Int((viewLongEdge * scale).rounded(.up))
        let stepped = (wanted + sizeStep - 1) / sizeStep * sizeStep
        return min(maxPixelSize, max(minPixelSize, stepped))
    }

    static let sizeStep = 256

    static let minPixelSize = 512
    static let maxPixelSize = 3200
    /// How many previews stay resident: the current photo plus two neighbours each way, and a little slack.
    static let countLimit = 8
    private static let totalCostLimit = 400 * 1024 * 1024

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var generation: [String: Int] = [:]
    /// The cache keys stored per path, so `invalidate` can drop every size (the sizes in use are arbitrary, not just the extremes).
    private var keysByPath: [String: Set<String>] = [:]
    private var prefetchWorker: Task<Void, Never>?

    /// Compare / Survey keep several previews resident at once (one per visible cell, plus slack); the loupe's default is `countLimit`.
    func setCountLimit(_ limit: Int) { cache.countLimit = max(Self.countLimit, limit) }

    private static func key(_ path: String, _ pixelSize: Int) -> String { "\(pixelSize)|\(path)" }

    /// The cached preview for `photo` at `pixelSize`, without decoding anything.
    func cached(for photo: Photo, pixelSize: Int) -> CGImage? {
        cache.object(forKey: Self.key(photo.path, pixelSize) as NSString)
    }

    /// The preview for `photo`: from the cache, from a decode already running for the same size, or a fresh decode (edits applied from
    /// the photo's saved sidecar, like the grid thumbnail).
    func preview(for photo: Photo, pixelSize: Int) async -> CGImage? {
        let path = photo.path
        let key = Self.key(path, pixelSize)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let requestGeneration = generation[path, default: 0]
        let task = Task<CGImage?, Never> {
            let editState = PhotoExporter.loadEditState(for: photo)
            return await ThumbnailGenerator.thumbnail(for: URL(fileURLWithPath: path), maxPixelSize: pixelSize, editState: editState)
        }
        inFlight[key] = task
        let result = await task.value
        guard generation[path, default: 0] == requestGeneration else { return result }
        inFlight[key] = nil
        if let result {
            cache.setObject(result, forKey: key as NSString, cost: result.bytesPerRow * result.height)
            keysByPath[path, default: []].insert(key)
        }
        return result
    }

    /// Makes `photos` (nearest first) the wanted set: replaces any earlier prefetch (it stops before its next photo) and decodes the
    /// ones not yet cached, in order.
    func setWanted(_ photos: [Photo], pixelSize: Int) {
        // The new worker starts only after the cancelled one has finished its current decode, so there is only ever ONE prefetch
        // decode running (plus the view's own `preview` for the current photo); a chain of cancelled workers ends immediately.
        let old = prefetchWorker
        old?.cancel()
        prefetchWorker = Task { [weak self] in
            await old?.value
            for photo in photos {
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.cached(for: photo, pixelSize: pixelSize) != nil { continue }
                _ = await self.preview(for: photo, pixelSize: pixelSize)
            }
        }
    }

    /// Whether a decode for `photo` at `pixelSize` is running right now (tests wait on this instead of sleeping).
    func isDecoding(_ photo: Photo, pixelSize: Int) -> Bool { inFlight[Self.key(photo.path, pixelSize)] != nil }

    /// Suspends until the current prefetch worker has finished or been cancelled (tests, and "settle" in the view).
    func idle() async { await prefetchWorker?.value }

    /// Stops prefetching (leaving the cull view).
    func cancelPrefetch() {
        prefetchWorker?.cancel()
        prefetchWorker = nil
    }

    /// Drops every size of `path` (its edits changed, or the file did).
    func invalidate(path: String) {
        generation[path, default: 0] += 1
        for key in keysByPath[path] ?? [] { cache.removeObject(forKey: key as NSString) }
        keysByPath[path] = nil
        for key in inFlight.keys where key.hasSuffix("|" + path) { inFlight[key] = nil }
    }

    /// Empties the cache (leaving the cull view).
    func removeAll() {
        cancelPrefetch()
        // A decode still running must not write its (large) result into the cache we are emptying.
        for key in inFlight.keys { if let path = key.split(separator: "|", maxSplits: 1).last { generation[String(path), default: 0] += 1 } }
        cache.removeAllObjects()
        keysByPath.removeAll()
        inFlight.removeAll()
    }
}
