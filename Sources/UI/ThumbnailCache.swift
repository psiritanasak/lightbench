import CoreGraphics
import Foundation

/// Small off-main thumbnail cache, keyed by file path. An `actor` gives
/// free in-flight de-duplication: two concurrent requests for the same
/// path (SwiftUI's `.task(id:)` re-firing on scroll/relayout is a
/// realistic way to trigger this) await the SAME decode rather than
/// triggering it twice.
///
/// Backed by `NSCache`, not a plain dictionary — a library grid exists
/// specifically to scale to a large, growing catalog, so every thumbnail
/// ever scrolled into view must NOT stay resident forever. `NSCache`
/// evicts under memory pressure and once `totalCostLimit` is exceeded
/// (cost tracked per-thumbnail as its approximate decoded byte size).
///
/// Internal (not `private`), and in its own file rather than at the bottom
/// of `CatalogModel.swift`, so `ThumbnailCacheTests` can exercise it
/// directly — the same private→internal-for-testability precedent
/// `PhotoExporter.resized`/`uniqueDestinationURL` already document. Worth
/// it here specifically because this type's concurrency and invalidation
/// logic (see `generation` below) is the subtlest code in the Library
/// path and already produced one reviewer-caught race.
actor ThumbnailCache {
    private static let maxPixelSize = 240
    /// ~1165 thumbnails at 240px RGBA before eviction kicks in. Bumped up
    /// from an original 64MB (~270 thumbnails) after a live report:
    /// re-sorting the Library grid scrambles which photos land in the
    /// LazyVGrid's currently-rendered window, so previously off-screen
    /// (evicted or never-decoded) photos show a placeholder until they
    /// decode — a bigger cache means a resort is far less likely to have
    /// evicted photos the user already scrolled past earlier in the same
    /// session. Still bounded, not sized to hold an entire large library
    /// resident at once — 256MB is a small, easily-affordable cost on any
    /// Mac this app targets.
    private static let totalCostLimit = 256 * 1024 * 1024

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = totalCostLimit
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    /// Per-path monotonic counter, bumped by `invalidate(path:)`.
    /// Reviewer-caught: `Task.cancel()` on `Never`-throwing tasks whose
    /// body never checks `Task.isCancelled` (true here — `ThumbnailGenerator`
    /// is a plain synchronous decode/render) is PURELY COSMETIC, not actual
    /// cancellation — a slow decode started BEFORE an `invalidate()` call
    /// can still finish AFTER it and would otherwise silently overwrite a
    /// newer, correct cache entry with stale data. Each in-flight request
    /// captures the generation at start; on completion it only touches the
    /// cache/`inFlight` bookkeeping if its generation is still current —
    /// if a newer `invalidate()` ran while it was decoding, it just hands
    /// its (possibly-stale) result back to whichever caller was already
    /// awaiting IT specifically, without polluting shared state that a
    /// later, newer request now owns.
    private var generation: [String: Int] = [:]

    /// Loads `photo`'s saved `EditState` (via `PhotoExporter.loadEditState`
    /// — `.identity` if none, the common case) so the thumbnail reflects
    /// actual edits, not just the original file. Only paid on a cache MISS
    /// — a cache hit still returns with no sidecar read at all, so
    /// repeat-scroll performance is unchanged from before this existed.
    ///
    /// The plain `Task { }` below is CORRECT AS-IS — do not "fix" it to
    /// `Task.detached` on the theory that `Task.init`'s
    /// `@_inheritActorContext` pins the decode to this actor's serial
    /// executor and therefore serializes every thumbnail. That theory is
    /// plausible, was written up as a performance bug, and is FALSE here.
    /// MEASURED on 2026-08-28 against this exact code (see
    /// `ThumbnailCacheTests.testDecodesRunInParallel` and
    /// `IMPROVEMENTS.md`'s struck-through P1):
    /// - 8 concurrent decodes vs the same 8 sequential: ratio 0.32, i.e.
    ///   already ~3x parallel. Switching to `Task.detached` measured 0.32
    ///   as well — no change whatsoever.
    /// - A cache HIT requested while 8 decodes were in flight returned in
    ///   0.0 ms, so the actor is demonstrably not held for the decode's
    ///   duration either.
    /// The mechanism: `@_inheritActorContext` only actually inherits this
    /// actor's isolation when the closure captures the isolated `self`.
    /// This one captures `photo` and `path` only — `Self.maxPixelSize` is
    /// a static access that captures nothing — so the body is nonisolated
    /// and runs on the global concurrent executor. That rule is spelled
    /// with a leading underscore and is still evolving, which is why the
    /// measurements above, not a citation, are what this comment rests on.
    ///
    /// COROLLARY, and the reason this is worth more than trivia:
    /// referencing any INSTANCE member inside this closure (demoting
    /// `maxPixelSize` from `static`, say) would capture `self`, silently
    /// flip the body to actor-isolated, and create the very
    /// serialized-decode bug P1 wrongly claimed was already there.
    /// `ThumbnailCacheTests.testDecodesRunInParallel` is the guard against
    /// exactly that.
    ///
    /// `Task.detached` would additionally drop priority and task-local
    /// propagation, so it is a downgrade for no measured gain.
    func thumbnail(for photo: Photo) async -> CGImage? {
        let path = photo.path
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[path] { return await existing.value }

        let requestGeneration = generation[path, default: 0]
        let task = Task<CGImage?, Never> {
            let editState = PhotoExporter.loadEditState(for: photo)
            return ThumbnailGenerator.thumbnail(
                for: URL(fileURLWithPath: path), maxPixelSize: Self.maxPixelSize, editState: editState
            )
        }
        inFlight[path] = task
        let result = await task.value
        // See `generation`'s doc comment — skip touching shared state
        // entirely if this path was invalidated while we were decoding.
        guard generation[path, default: 0] == requestGeneration else { return result }
        inFlight[path] = nil
        if let result {
            cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        }
        return result
    }

    /// Drops `path`'s cached thumbnail and bumps its generation (see
    /// `generation`'s doc comment for why a `Task.cancel()` alone wouldn't
    /// be sufficient here) — called when that photo's sidecar is saved.
    /// Clears `inFlight[path]` too: NOT to stop the old decode (it can't),
    /// but so the NEXT caller for this path starts a fresh request instead
    /// of awaiting the stale one already running. Does NOT proactively
    /// regenerate anything; the next `thumbnail(for:)` call (naturally
    /// triggered by returning to the Library, since `LibraryGridView` is
    /// torn down and recreated on every Editor↔Library switch) will decode
    /// fresh.
    func invalidate(path: String) {
        generation[path, default: 0] += 1
        cache.removeObject(forKey: path as NSString)
        inFlight[path] = nil
    }
}
