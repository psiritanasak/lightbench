import Foundation

/// Pure file I/O for a photo's sidecar (`<photo>.photoapp.json`) — no UI
/// import, safe to call off-main, matching `PhotoExporter`'s own module
/// placement/doc-comment convention (photo-file-I/O that crosses the
/// Catalog/EditEngine boundary belongs in `Rendering`, not `EditEngine`
/// itself — see CLAUDE.md's own "no UI imports in EditEngine" rule, which
/// this type's own concern — file paths and their JSON content — already
/// sits outside anyway). Bookmark/security-scope resolution and any
/// `NSOpenPanel` prompting are NOT this type's job — see
/// `SidecarFolderAccess` (`Sources/UI/`) for that. A caller here is
/// expected to already be inside an active security-scoped access window
/// (`startAccessingSecurityScopedResource()`) when reading/writing a real
/// sandboxed folder; this type does no scope handling of its own.
enum SidecarStore {
    /// The outcome of reading a photo's sidecar file — distinguishes "no
    /// sidecar exists" from "a sidecar exists but couldn't be read/
    /// decoded". `ImageDocumentModel.loadSidecarIfReachable`'s own
    /// `EditState?` return type collapses all three into `nil`, which is
    /// CORRECT for that caller (load must stay silent regardless of which
    /// case it is). A read-modify-write caller cannot collapse them the
    /// same way — silently clobbering an unreadable/undecodable sidecar
    /// with a fresh merge would destroy whatever produced it, rather than
    /// safely skipping it.
    ///
    /// Reviewer-caught (a real, not theoretical, data-loss hazard): `.missing`
    /// must mean "no file at this path," NOT "reading it failed for any
    /// reason" — a sandbox-permission hiccup, a not-yet-downloaded iCloud
    /// file, or any other I/O error on an EXISTING file must map to
    /// `.undecodable` (never-write), not `.missing` (safe-to-write onto
    /// identity). Collapsing those two was the bug: it would have let a
    /// batch paste "successfully" overwrite a sidecar it merely failed to
    /// READ, not one that was actually absent.
    enum ReadResult: Equatable {
        case missing
        case decoded(EditState)
        case undecodable
    }

    /// The sidecar path for a given photo URL — same directory, original
    /// filename with `.photoapp.json` appended (e.g. `MyPhoto.jpg` →
    /// `MyPhoto.jpg.photoapp.json`). Moved here verbatim from
    /// `ImageDocumentModel.sidecarURL(for:)`, which now forwards to this
    /// — a behavior-preserving lift, not a rewrite, so `LibraryGridView`,
    /// `PhotoExporter`, and every existing test that calls the
    /// `ImageDocumentModel` entry point keep working unchanged.
    ///
    /// A virtual copy (`Photo.versionKey`) keeps its OWN edit file next to the shared image: `MyPhoto.jpg.<versionKey>.photoapp.json`.
    /// `versionKey: nil` (the default, every pre-virtual-copy caller) is the master's file, byte-for-byte the old name.
    nonisolated static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingLastPathComponent().appendingPathComponent(photoURL.lastPathComponent + ".photoapp.json")
    }

    /// The edit file of one VERSION: `nil` for a malformed key (never "repaired" into another version's valid key, never a path), the
    /// master's file for `versionKey == nil`.
    nonisolated static func versionedSidecarURL(for photoURL: URL, versionKey: String?) -> URL? {
        guard let versionKey else { return sidecarURL(for: photoURL) }
        guard isValidVersionKey(versionKey) else { return nil }
        return photoURL.deletingLastPathComponent().appendingPathComponent(photoURL.lastPathComponent + "." + versionKey + ".photoapp.json")
    }

    /// The edit file of THIS catalog row: the master's `<file>.photoapp.json`, or a virtual copy's own version file.
    /// `nil` when the row carries a malformed version key: such a row has no usable edit file, and no path is ever built from it.
    nonisolated static func sidecarURL(for photo: Photo) -> URL? {
        versionedSidecarURL(for: URL(fileURLWithPath: photo.path), versionKey: photo.versionKey)
    }

    /// A version key is exactly this many lowercase hex characters (see `CatalogDatabase.createVirtualCopy`).
    nonisolated static let versionKeyLength = 8

    nonisolated static func isValidVersionKey(_ key: String) -> Bool {
        key.utf8.count == versionKeyLength && key.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The version keys of every virtual-copy edit file that sits beside `photoURL` on disk (`<file>.<key>.photoapp.json`), found by
    /// listing the folder; sorted. Used by file-moving code (rename, trash) that must carry or remove a photo's copies' edit files.
    nonisolated static func versionSidecarKeys(forPhotoAt photoURL: URL) -> [String] {
        let folder = photoURL.deletingLastPathComponent().path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return versionSidecarKeys(inNames: names, forFileNamed: photoURL.lastPathComponent)
    }

    /// The same, from an already-listed folder (`names` = the entries' file names): what a pure planner uses.
    nonisolated static func versionSidecarKeys(inNames names: [String], forFileNamed fileName: String) -> [String] {
        let prefix = fileName + "."
        let suffix = ".photoapp.json"
        return names.compactMap { name -> String? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
            let key = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            return isValidVersionKey(key) ? key : nil
        }.sorted()
    }

    /// The version edit files of the copies named by `keys` (a master's copies, from the catalog), beside `photoURL`.
    nonisolated static func versionSidecarURLs(forMasterAt photoURL: URL, keys: [String]) -> [URL] {
        keys.compactMap { versionedSidecarURL(for: photoURL, versionKey: $0) }
    }

    /// Reads and decodes a photo's sidecar. Pure file I/O — no bookmark or
    /// security-scope handling; the caller must already be inside an
    /// active scope for a real sandboxed folder.
    ///
    /// Checks `fileExists` FIRST, deliberately not `try? Data(contentsOf:)`
    /// alone — the latter throws identically whether the file is genuinely
    /// absent OR present-but-unreadable, and those two cases must NOT
    /// collapse into the same `.missing` result (see `ReadResult`'s own
    /// doc comment for the data-loss hazard this specifically closes).
    static func read(forPhotoAt url: URL, versionKey: String? = nil) -> ReadResult {
        guard let sidecar = versionedSidecarURL(for: url, versionKey: versionKey) else { return .undecodable } // never read, never overwritten
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return .missing }
        guard let data = try? Data(contentsOf: sidecar) else { return .undecodable }
        guard let state = try? JSONDecoder().decode(EditState.self, from: data) else { return .undecodable }
        return .decoded(state)
    }

    /// The persisted edit history inside `url`'s sidecar (under `HistoryArchive.sidecarKey`), or nil when there is none, it is
    /// malformed, or it is STALE: the archive's current entry must equal the sidecar's own state object exactly (a sidecar
    /// rewritten by batch Paste or an older build, or any edit made since, fails this and the history is dropped).
    /// COSTLY (re-serialises every entry): call it off the main thread, inside an active security-scope window.
    static func readHistory(forPhotoAt url: URL, versionKey: String? = nil) -> HistoryArchive? {
        guard let file = versionedSidecarURL(for: url, versionKey: versionKey),
              let data = try? Data(contentsOf: file),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let history = object.removeValue(forKey: HistoryArchive.sidecarKey) else { return nil }
        return HistoryArchive.decode(history, requiringCurrentState: object)
    }

    /// Like `write(_:forPhotoAt:)`, plus the edit history (`HistoryArchive.Encoder.jsonObject`) under the reserved
    /// `"_history"` key of the same JSON object. `EditState`'s tolerant decode ignores unknown keys, so every other reader
    /// (thumbnails, Export, Paste, Enhance, older builds) still reads the state unchanged.
    static func write(_ state: EditState, historyObject: [String: Any], forPhotoAt url: URL, versionKey: String? = nil) throws {
        let stateData = try JSONEncoder().encode(state)
        guard var object = try JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object[HistoryArchive.sidecarKey] = historyObject
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let file = versionedSidecarURL(for: url, versionKey: versionKey) else { throw CocoaError(.fileWriteInvalidFileName) }
        try data.write(to: file, options: .atomic)
    }

    /// Encodes and atomically writes `state` as `url`'s sidecar. Byte-
    /// identical to `ImageDocumentModel.saveSidecarNow`'s own original
    /// write (`JSONEncoder()` defaults, `.atomic`) — a lift, not a
    /// rewrite.
    static func write(_ state: EditState, forPhotoAt url: URL, versionKey: String? = nil) throws {
        let data = try JSONEncoder().encode(state)
        guard let file = versionedSidecarURL(for: url, versionKey: versionKey) else { throw CocoaError(.fileWriteInvalidFileName) }
        try data.write(to: file, options: .atomic)
    }
}
