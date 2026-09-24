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

    /// Resolves an EXISTING bookmark for `folder`, if one is stored and
    /// still valid. Drops (and returns `nil` for) a stale or unresolvable
    /// entry rather than surfacing an error — self-healing: the next save
    /// attempt simply re-prompts. Never prompts itself — that's
    /// `resolveOrRequest(for:message:)`'s job.
    func resolvedURL(for folder: URL) -> URL? {
        guard let data = folderBookmarks[folder.path] else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ), !isStale else {
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
            folderBookmarks[folder.path] = bookmarkData
            return .granted(grantedURL)
        } catch {
            return .failed(error)
        }
    }
}
