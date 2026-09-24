import XCTest
@testable import PhotoApp

/// `URL.coversAccess(to:)` is pure comparison logic pulled out specifically
/// so it's directly testable — the rest of `SidecarFolderAccess`
/// (`NSOpenPanel`, `UserDefaults`) stays untested by this codebase's own
/// established precedent for `@MainActor`/file-I/O-driven types.
final class SidecarFolderAccessTests: XCTestCase {
    func testIdenticalURLsCoverEachOther() {
        let url = URL(fileURLWithPath: "/tmp/Photos")
        XCTAssertTrue(url.coversAccess(to: url))
    }

    func testDifferentSiblingFoldersDoNotCoverEachOther() {
        XCTAssertFalse(
            URL(fileURLWithPath: "/tmp/Photos").coversAccess(to: URL(fileURLWithPath: "/tmp/OtherPhotos"))
        )
    }

    /// The exact real-world case `coversAccess(to:)` exists to handle
    /// correctly: `/tmp` is itself a symlink to `/private/tmp` on macOS —
    /// a naive `.path ==` would wrongly report these as unrelated.
    func testSymlinkedPathsCoverEachOther() {
        XCTAssertTrue(
            URL(fileURLWithPath: "/tmp").coversAccess(to: URL(fileURLWithPath: "/private/tmp"))
        )
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(
            URL(fileURLWithPath: "/tmp/Photos").coversAccess(to: URL(fileURLWithPath: "/tmp/photos"))
        )
    }

    func testCompletelyUnrelatedPathsDoNotCoverEachOther() {
        XCTAssertFalse(
            URL(fileURLWithPath: "/tmp/Photos").coversAccess(to: URL(fileURLWithPath: "/Users/someone/Pictures"))
        )
    }

    /// The real-world pattern this comparison must NOT break — reviewer-
    /// caught: an earlier version of this comparison
    /// required an exact match, which broke the already-shipped "grant a
    /// parent folder once" pattern `ImageDocumentModel`'s own sidecar
    /// saves already rely on. A folder's own security scope legitimately
    /// extends to every descendant.
    func testAncestorFolderCoversADescendant() {
        XCTAssertTrue(
            URL(fileURLWithPath: "/tmp/Library").coversAccess(to: URL(fileURLWithPath: "/tmp/Library/2024/Trip"))
        )
    }

    /// The mirror-image direction must NOT hold — a child folder's grant
    /// does not cover its own parent (you can't write to a folder you
    /// were never actually given access to just because you have access
    /// to something inside it).
    func testDescendantFolderDoesNotCoverItsAncestor() {
        XCTAssertFalse(
            URL(fileURLWithPath: "/tmp/Library/2024/Trip").coversAccess(to: URL(fileURLWithPath: "/tmp/Library"))
        )
    }

    /// Pins the component-wise (not raw string prefix) comparison —
    /// reviewer-caught: a naive `hasPrefix` check would wrongly treat
    /// `/tmp/Photo` as covering `/tmp/Photos`, since the STRING "Photo"
    /// is a prefix of the string "Photos", even though `Photo` and
    /// `Photos` are two distinct SIBLING folders with no ancestor
    /// relationship at all.
    func testSimilarlyNamedSiblingIsNotMistakenForAnAncestor() {
        XCTAssertFalse(
            URL(fileURLWithPath: "/tmp/Photo").coversAccess(to: URL(fileURLWithPath: "/tmp/Photos/2024"))
        )
    }

    // MARK: - resolvedURL self-healing

    /// Reviewer-caught: every WRITE
    /// path into `folderBookmarks` now refuses to persist a mismatched
    /// bookmark (see `resolveOrRequest`'s own doc comment) — but that
    /// guard didn't always exist, so a real user's `UserDefaults` can
    /// already contain an entry saved by older code (or a folder that
    /// was later moved/renamed out from under its own bookmark).
    /// `resolvedURL` itself must refuse to trust ANY stored entry that
    /// doesn't actually cover the folder it's filed under, not just rely
    /// on every future write being correct — otherwise a single piece of
    /// stale data locks that folder out permanently, with no panel and no
    /// recovery short of clearing `UserDefaults` by hand. Seeds the
    /// mismatch directly into an isolated `UserDefaults` suite (the only
    /// way to simulate pre-existing bad data — `resolveOrRequest`'s own
    /// write path can no longer produce one).
    @MainActor
    func testResolvedURLDropsAndSelfHealsAMismatchedStoredBookmark() throws {
        let suiteName = "SidecarFolderAccessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A REAL, validly-resolvable bookmark — for `realFolder` — but
        // deliberately stored under a DIFFERENT, unrelated folder's key,
        // simulating exactly the stale/mismatched data this fix guards
        // against.
        let realFolder = FileManager.default.temporaryDirectory
        let bookmarkData = try realFolder.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let requestedFolder = URL(fileURLWithPath: "/tmp/unrelated-folder-\(UUID().uuidString)")
        // Matches `SidecarFolderAccess`'s own private storage key/shape
        // exactly (`folderBookmarksDefaultsKey`/`folderBookmarks`) — there's
        // no other seam to inject pre-existing "bad" data through, since
        // this type's own write path can no longer produce it.
        defaults.set([requestedFolder.path: bookmarkData], forKey: "PhotoApp.sidecarFolderBookmarks")

        let folderAccess = SidecarFolderAccess(defaults: defaults)
        let resolved = folderAccess.resolvedURL(for: requestedFolder)

        XCTAssertNil(resolved, "a bookmark that doesn't cover the folder it's filed under must never be trusted")
        let remaining = defaults.dictionary(forKey: "PhotoApp.sidecarFolderBookmarks") as? [String: Data] ?? [:]
        XCTAssertNil(remaining[requestedFolder.path], "the mismatched entry must be dropped, so the NEXT call re-prompts instead of repeating the same silent failure")
    }
}
