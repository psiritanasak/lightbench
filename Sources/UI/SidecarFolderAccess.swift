import AppKit
import Foundation

/// Resolves (or lazily requests via `NSOpenPanel`) per-folder security-
/// scoped bookmark access for reading/writing a photo's sidecar file —
/// extracted from `ImageDocumentModel`'s own originally-private bookmark
/// logic (a behavior-preserving lift, not a rewrite). This extraction's own
/// purpose: a planned batch "paste settings onto other photos" feature will
/// need to request/reuse the SAME persisted grants `ImageDocumentModel`
/// already uses for photos it never opened in the Editor, rather than
/// duplicating the bookmark store or — worse — silently reusing
/// `CatalogModel`'s SEPARATE `PhotoApp.libraryFolderBookmarks` scope, which
/// would break the load-bearing invariant "a sidecar exists ⇒ a sidecar
/// bookmark exists for its folder" that `ImageDocumentModel.
/// loadSidecarIfReachable` depends on.
///
/// Two independent instances (one per consumer) share state correctly,
/// since the only real state is `UserDefaults` — this type is otherwise
/// stateless. `declinedFolders`-style decline tracking deliberately does
/// NOT live here: each consumer's own decline-suppression policy is its
/// own business (`ImageDocumentModel` suppresses re-prompting across many
/// rapid slider-driven saves within one folder; a batch paste runs once
/// per explicit user click, where re-prompting on the NEXT click is
/// correct, not annoying).
@MainActor
final class SidecarFolderAccess {
    enum Outcome {
        case granted(URL)
        case declined
        case failed(Error)
    }

    private let defaults: UserDefaults
    private static let folderBookmarksDefaultsKey = "PhotoApp.sidecarFolderBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One resolvable, persisted security-scoped bookmark per folder the
    /// user has granted sidecar access to — keyed by the folder's own
    /// path. Backed by `UserDefaults` (small, simple; `Data` is a valid
    /// property-list type). Same storage key as the original
    /// `ImageDocumentModel.folderBookmarks` — an existing user's already-
    /// granted folders keep working after this refactor.
    private var folderBookmarks: [String: Data] {
        get { defaults.dictionary(forKey: Self.folderBookmarksDefaultsKey) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: Self.folderBookmarksDefaultsKey) }
    }

    /// Resolves an EXISTING bookmark for `folder`, if one is stored, still
    /// valid, AND actually covers `folder` (see `URL.coversAccess(to:)`).
    /// Drops (and returns `nil` for) a stale, unresolvable, OR mismatched
    /// entry rather than surfacing an error — self-healing: the next save
    /// attempt simply re-prompts. Never prompts itself — that's
    /// `resolveOrRequest(for:message:)`'s job.
    ///
    /// The `coversAccess(to:)` check here (not just staleness) is
    /// reviewer-caught: every write
    /// path to `folderBookmarks` NOW refuses to persist a mismatched
    /// bookmark (see `resolveOrRequest`'s own doc comment) — but that
    /// guard didn't exist until this round of fixes, so an entry saved by
    /// OLDER code (any build before it), or a bookmark whose target
    /// folder was later moved/renamed out from under it, could already be
    /// sitting in a real user's `UserDefaults` pointing at the wrong
    /// folder. Without this check, `resolvedURL` would keep returning
    /// that wrong folder silently forever — the exact "stuck permanently,
    /// no panel, no recovery short of manually clearing UserDefaults"
    /// failure the last two rounds of fixes were about, just reachable
    /// through pre-existing data instead of a fresh mis-click. Checking
    /// it HERE, in the one function both `resolvedURL` and (transitively)
    /// `resolveOrRequest` funnel through, heals it for old data too —
    /// automatically, the next time anything asks for that folder.
    func resolvedURL(for folder: URL) -> URL? {
        guard let data = folderBookmarks[folder.path] else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ), !isStale, resolved.coversAccess(to: folder) else {
            folderBookmarks.removeValue(forKey: folder.path)
            return nil
        }
        return resolved
    }

    /// Resolves an existing bookmark for `folder`, or shows a directory-
    /// mode `NSOpenPanel` (with `message`) to request one, persisting a
    /// new bookmark on success. `.declined` for a user cancel — a normal,
    /// silent outcome, not an error; the CALLER decides whether/how to
    /// remember the decline. `.failed` only for a genuine, unexpected
    /// error AFTER the user already said yes (e.g. `bookmarkData(options:)`
    /// itself throwing) — the caller should surface this one, unlike a
    /// plain decline.
    func resolveOrRequest(for folder: URL, message: String) -> Outcome {
        if let resolved = resolvedURL(for: folder) {
            return .granted(resolved)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = message
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let grantedURL = panel.url else {
            return .declined
        }
        do {
            let bookmarkData = try grantedURL.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            // Only persisted under `folder`'s OWN key if `grantedURL`
            // actually COVERS `folder` — reviewer-caught, a genuine
            // "stuck forever" bug: `NSOpenPanel` doesn't constrain the
            // user to stay in the folder it's pre-navigated to
            // (`panel.directoryURL` above is a starting point, not a
            // restriction), so a user can navigate elsewhere and grant
            // access to a DIFFERENT folder entirely. Persisting THAT
            // folder's bookmark under the REQUESTED folder's key would
            // mean every future call for `folder` silently resolves to
            // the wrong directory with no panel — for a caller that
            // (like `EnhanceModel`) separately checks the returned URL
            // against what it asked for, this turns one wrong click into
            // a PERMANENT lockout, since a retry finds the bad bookmark
            // already "resolved" and never re-prompts.
            //
            // "Covers" is deliberately NOT "is exactly" — reviewer-caught,
            // a real, already-working, already-shipped
            // pattern is granting a PARENT folder (e.g. the whole library
            // root) once, which macOS security scoping correctly extends
            // to every descendant file — an initial version of this fix
            // that required an EXACT match broke that pattern, turning a
            // single one-time grant into a repeated re-prompt on every
            // subsequent sidecar save/paste in a child folder. `coversAccess
            // (to:)` below accepts `folder` itself OR any ancestor of it.
            // `grantedURL` is still returned either way — this only
            // changes whether the bookmark is SAVED, not what a caller
            // sees for THIS call.
            if grantedURL.coversAccess(to: folder) {
                folderBookmarks[folder.path] = bookmarkData
            }
            return .granted(grantedURL)
        } catch {
            return .failed(error)
        }
    }
}

extension URL {
    /// True if `self` IS `folder`, or is an ANCESTOR directory of it —
    /// the two cases where a security-scoped grant on `self` legitimately
    /// covers access to `folder` (macOS extends a folder's own security
    /// scope to its entire subtree). Resolves symlinks on both sides
    /// (e.g. `/tmp` vs `/private/tmp`) and compares path COMPONENTS
    /// case-insensitively (APFS is case-insensitive-but-preserving by
    /// default) — component-wise, not a raw string prefix check, so
    /// `/a/Photo` does NOT wrongly count as covering `/a/Photos` (a
    /// sibling whose name happens to start the same way).
    ///
    /// Not airtight on a case-SENSITIVE volume (case-sensitive APFS,
    /// most SMB/NFS shares) — the same class of accepted, documented gap
    /// `PhotoImporter.matchByFilename`'s own doc comment already logs for
    /// filename matching (comparing case-insensitively is wrong on a
    /// case-sensitive volume). Reviewer-corrected: this does NOT mean a
    /// later caller would silently read/write into the wrong sibling
    /// folder (`Photos` vs `photos`) — every caller still writes to the
    /// REQUESTED folder's own path while merely holding the (wrong)
    /// sibling's security scope, so on a real case-sensitive volume the
    /// realistic failure is a sandbox access-denied error at the actual
    /// file operation, not a silent write somewhere else. Still worth
    /// avoiding (an avoidable error is better than none), just not the
    /// more alarming failure mode an earlier version of this comment
    /// claimed.
    ///
    /// Not `private`/an extension rather than a `SidecarFolderAccess`
    /// static method: `EnhanceModel` reuses this exact comparison for its
    /// own "does what I was granted actually cover the folder I asked
    /// for" check, so the two checks can't silently drift apart.
    /// `nonisolated`-equivalent by construction (a plain `URL` extension,
    /// no actor isolation involved) — directly testable from a plain
    /// (non-`@MainActor`) test, same reasoning as `EnhanceModel
    /// .summary`/`.describe`.
    func coversAccess(to folder: URL) -> Bool {
        let selfComponents = resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let folderComponents = folder.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        guard selfComponents.count <= folderComponents.count else { return false }
        return Array(folderComponents.prefix(selfComponents.count)) == selfComponents
    }
}
