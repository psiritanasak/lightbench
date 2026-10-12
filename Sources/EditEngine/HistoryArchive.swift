import CryptoKit
import Foundation

/// A compact, self-describing JSON form of an `EditHistory` timeline (entries + cursor), for persisting a photo's edit
/// history inside its sidecar under the reserved key `"_history"`.
///
/// Entries can hold large blobs — AI subject-mask PNGs are base64 strings inside `EditState` — so a naive "one full state
/// per entry" would be tens of MB for a 100-entry history. Instead (generically, with NO per-field list: this codebase's
/// recurring stale-enumeration bug class):
/// - every entry's state is encoded with `EditState`'s own `Codable` to a JSON object;
/// - entry 0 stores the whole object, every later entry stores a KEY-LEVEL DELTA against its predecessor
///   (`key -> new value`, `key -> {"$del": true}` for a removed key);
/// - any string value of `blobThreshold` characters or more, anywhere inside a stored value, is replaced by
///   `{"$blob": "<sha256 hex>"}` and its bytes are kept ONCE in an archive-level `blobs` map.
///
/// Numbers round-trip bit-exactly through `JSONEncoder` -> `JSONSerialization` -> `JSONDecoder` (measured: 20k random Doubles,
/// extremes, Int.max/min, 2^53+1) EXCEPT negative zero, which comes back as +0.0 (`JSONSerialization` parses `-0` as the
/// integer 0); `EditState ==` treats them as equal, so nothing observable changes.
///
/// Decoding is all-or-nothing: an unknown version, a dangling blob reference, a malformed entry or an entry whose
/// reconstructed object does not decode as an `EditState` yields `nil` — a partially trusted history is worse than none.
struct HistoryArchive {
    static let version = 1
    static let blobThreshold = 1024
    /// The sidecar key this archive lives under (an underscore: never an `EditState` field name).
    static let sidecarKey = "_history"

    var entries: [HistoryEntry]
    var currentIndex: Int

    init(entries: [HistoryEntry], currentIndex: Int) {
        self.entries = entries
        self.currentIndex = currentIndex
    }

    init(_ history: EditHistory) {
        self.init(entries: history.entries, currentIndex: history.currentIndex)
    }

    // MARK: - Encoding

    /// The JSON-compatible object (`[String: Any]`) for this archive, or nil if a state cannot be encoded. One-shot
    /// convenience; a long-lived caller (the document model, which saves every ~second while editing) should keep an
    /// `Encoder` so unchanged entries are not re-encoded and re-hashed — with a 300 KB mask that was ~3 s per save in a
    /// Debug build (measured: 101 entries, `encode=3171ms`) and ~10 s at 1 MB.
    func jsonObject() -> [String: Any]? { Encoder().jsonObject(for: self) }

    /// Encodes archives while caching each entry's blob-extracted JSON object by its (immutable) `id`: only entries it
    /// has not seen are encoded. Thread-safe (a lock guards the cache).
    // @unchecked Sendable: all mutable state is guarded by the lock.
    final class Encoder: @unchecked Sendable {
        /// Per entry: its blob-extracted object and the HASHES of the blobs it references. The blob BYTES live once, in
        /// `blobStore`, so N entries sharing a mask hold one string, not N (a per-entry copy cost ~100 MB at 1 MB x 101).
        private struct Cached { var object: [String: Any]; var hashes: Set<String> }
        private var cache: [UUID: Cached] = [:]
        private var blobStore: [String: String] = [:]
        private let lock = NSLock()

        init() {}

        func jsonObject(for archive: HistoryArchive) -> [String: Any]? {
            guard archive.entries.indices.contains(archive.currentIndex) else { return nil }
            lock.lock(); defer { lock.unlock() }
            var live: [UUID: Cached] = [:]
            var liveHashes: Set<String> = []
            var newBlobs: [String: String] = [:]
            var previous: [String: Any] = [:]
            var encodedEntries: [[String: Any]] = []
            for entry in archive.entries {
                let cached: Cached
                if let hit = cache[entry.id] {
                    cached = hit
                } else {
                    guard let data = try? JSONEncoder().encode(entry.state),
                          let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                    var own: [String: String] = [:]
                    let object = raw.mapValues { HistoryArchive.extractBlobs($0, into: &own) }
                    for (hash, string) in own where blobStore[hash] == nil && newBlobs[hash] == nil { newBlobs[hash] = string }
                    cached = Cached(object: object, hashes: Set(own.keys))
                }
                live[entry.id] = cached
                liveHashes.formUnion(cached.hashes)
                var delta: [String: Any] = [:]
                for (key, value) in cached.object where !HistoryArchive.same(previous[key], value) { delta[key] = value }
                for key in previous.keys where cached.object[key] == nil { delta[key] = ["$del": true] }
                encodedEntries.append(["id": entry.id.uuidString, "summary": entry.summary, "delta": delta])
                previous = cached.object
            }
            blobStore.merge(newBlobs) { first, _ in first }
            blobStore = blobStore.filter { liveHashes.contains($0.key) } // blobs no entry references any more are dropped
            cache = live // entries that left the timeline are dropped
            return ["v": HistoryArchive.version, "cursor": archive.currentIndex, "entries": encodedEntries, "blobs": blobStore]
        }
    }

    // MARK: - Decoding

    /// Rebuilds the archive from `object`, or nil if it is not a valid version-1 archive.
    ///
    /// COST: every entry is re-serialised with its blobs resolved, so decoding grows with entries x blob size (measured,
    /// Debug build, 101 entries: 218 ms with a 300 KB mask, 657 ms at 1 MB). Callers MUST run it off the main thread.
    ///
    /// When `expectedCurrentState` is given, the CURRENT entry's reconstructed JSON object must equal it exactly (the
    /// consistency rule: a history whose current state is not the sidecar's own state is stale and must not be trusted).
    /// The caller must pass the sidecar's own state object with the `"_history"` key REMOVED, parsed by `JSONSerialization`
    /// from the same bytes — anything else makes every restore silently return nil.
    ///
    /// Restored states share one `Data` buffer per distinct mask blob (`intern`) instead of N copies.
    static func decode(_ object: Any, requiringCurrentState expectedCurrentState: [String: Any]? = nil) -> HistoryArchive? {
        guard let root = object as? [String: Any], (root["v"] as? Int) == version,
              let cursor = root["cursor"] as? Int,
              let rawEntries = root["entries"] as? [[String: Any]], !rawEntries.isEmpty, rawEntries.indices.contains(cursor),
              let blobs = root["blobs"] as? [String: String] else { return nil }
        var state: [String: Any] = [:]
        var entries: [HistoryEntry] = []
        var currentObject: [String: Any] = [:]
        var internTable: [Data: Data] = [:]
        for (index, raw) in rawEntries.enumerated() {
            guard let idString = raw["id"] as? String, let id = UUID(uuidString: idString),
                  let summary = raw["summary"] as? String, let delta = raw["delta"] as? [String: Any] else { return nil }
            for (key, value) in delta {
                if let marker = value as? [String: Any], marker.count == 1, marker["$del"] as? Bool == true {
                    state[key] = nil
                } else {
                    state[key] = value
                }
            }
            guard let resolved = resolveBlobs(state, blobs) as? [String: Any],
                  JSONSerialization.isValidJSONObject(resolved),
                  let data = try? JSONSerialization.data(withJSONObject: resolved),
                  let decoded = try? JSONDecoder().decode(EditState.self, from: data) else { return nil }
            entries.append(HistoryEntry(id: id, state: Self.interned(decoded, &internTable), summary: summary))
            if index == cursor { currentObject = resolved }
        }
        // `jump(to:)` finds an entry by id: a corrupt archive with a duplicated id would make jumps ambiguous.
        guard Set(entries.map(\.id)).count == entries.count else { return nil }
        if let expectedCurrentState, !same(currentObject, expectedCurrentState) { return nil }
        return HistoryArchive(entries: entries, currentIndex: cursor)
    }

    // MARK: - Helpers

    /// Makes equal mask blobs share ONE `Data` buffer across the restored entries (the live `EditHistory` shares them
    /// through copy-on-write; decoding each entry separately would give every entry its own copy — ~100 MB for a 1 MB mask
    /// over 101 entries). This is the one place that lists the `Data`-bearing `EditState` fields (the masks' subject and depth PNGs and the Style's
    /// `styleSkinMaskPNG`); a new
    /// blob field added later would still round-trip correctly, only without the memory sharing.
    fileprivate static func interned(_ state: EditState, _ table: inout [Data: Data]) -> EditState {
        guard state.styleSkinMaskPNG != nil || state.masks.contains(where: { $0.subjectMaskPNG != nil || !$0.subjectInstancePNGs.isEmpty || $0.depthRasterPNG != nil }) else { return state }
        func share(_ data: Data) -> Data {
            if let existing = table[data] { return existing }
            table[data] = data
            return data
        }
        var copy = state
        copy.styleSkinMaskPNG = copy.styleSkinMaskPNG.map(share)
        for index in copy.masks.indices {
            copy.masks[index].subjectMaskPNG = copy.masks[index].subjectMaskPNG.map(share)
            copy.masks[index].subjectInstancePNGs = copy.masks[index].subjectInstancePNGs.map(share)
            copy.masks[index].depthRasterPNG = copy.masks[index].depthRasterPNG.map(share)
        }
        return copy
    }

    /// Replaces every long string inside `value` with a `{"$blob": hash}` reference, recording the string once.
    fileprivate static func extractBlobs(_ value: Any, into blobs: inout [String: String]) -> Any {
        if let string = value as? String {
            guard string.utf8.count >= blobThreshold else { return string }
            let hash = SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
            blobs[hash] = string
            return ["$blob": hash]
        }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { extractBlobs($0, into: &blobs) } }
        if let array = value as? [Any] { return array.map { extractBlobs($0, into: &blobs) } }
        return value
    }

    /// The inverse of `extractBlobs`; a dangling reference makes the result contain a sentinel that fails the caller's
    /// `isValidJSONObject`/decode, so it can never be mistaken for real data.
    private static func resolveBlobs(_ value: Any, _ blobs: [String: String]) -> Any {
        if let dictionary = value as? [String: Any] {
            if dictionary.count == 1, let hash = dictionary["$blob"] as? String {
                return blobs[hash] ?? Double.nan // NaN is not valid JSON: the decode fails
            }
            return dictionary.mapValues { resolveBlobs($0, blobs) }
        }
        if let array = value as? [Any] { return array.map { resolveBlobs($0, blobs) } }
        return value
    }

    /// JSON-value equality via Foundation (numbers compare by value; nil only equals nil). `isEqual` also treats -0 == 0 and
    /// `true` == 1 as equal — harmless here because `Codable` fixes each key's JSON TYPE (a key is never a Bool in one entry
    /// and a number in another), and `EditState ==` itself treats ±0 as equal.
    fileprivate static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }
}

extension EditHistory {
    /// Rebuilds a history from persisted entries. nil for an empty list or a cursor outside it. The `limit + 1` rule
    /// is re-applied: surplus entries are dropped from the abandoned-redo tail first, then from the oldest end.
    init?(restoring entries: [HistoryEntry], currentIndex: Int, limit: Int = 100) {
        guard !entries.isEmpty, entries.indices.contains(currentIndex) else { return nil }
        var kept = entries
        var cursor = currentIndex
        while kept.count > limit + 1 {
            if kept.count - 1 > cursor { kept.removeLast() } else { kept.removeFirst(); cursor -= 1 }
        }
        self.init(restoredEntries: kept, currentIndex: cursor, limit: limit)
    }
}
