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
    nonisolated static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingLastPathComponent().appendingPathComponent(photoURL.lastPathComponent + ".photoapp.json")
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
    static func read(forPhotoAt url: URL) -> ReadResult {
        let sidecar = sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return .missing }
        guard let data = try? Data(contentsOf: sidecar) else { return .undecodable }
        guard let state = try? JSONDecoder().decode(EditState.self, from: data) else { return .undecodable }
        return .decoded(state)
    }

    /// Encodes and atomically writes `state` as `url`'s sidecar. Byte-
    /// identical to `ImageDocumentModel.saveSidecarNow`'s own original
    /// write (`JSONEncoder()` defaults, `.atomic`) — a lift, not a
    /// rewrite.
    static func write(_ state: EditState, forPhotoAt url: URL) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: sidecarURL(for: url), options: .atomic)
    }
}
