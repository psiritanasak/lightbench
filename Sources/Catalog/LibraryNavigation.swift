import Foundation

/// Stepping between photos without going back to the Library grid — the
/// Editor's ⌘←/⌘→ commands (`PhotoAppApp`'s "Photo" menu).
///
/// Pure, SwiftUI/GRDB-independent, and extracted as its own type purely so it
/// gets direct unit test coverage, exactly like its neighbour
/// `LibraryFilterSort` (and `CropAspectMath`, `CompareLayout`,
/// `ZoomPanGeometry` before it).
///
/// The caller passes the array to walk, which is deliberately
/// `CatalogModel.displayedPhotos` — the post-sort/filter/search list the grid
/// itself renders — so ⌘→ always goes to the photo the user would SEE next,
/// not to some hidden catalog order.
enum LibraryNavigation {
    /// The photos before and after the open VERSION (matched on `Photo.editKey`, so with a virtual copy open the master is a neighbour, not
    /// the starting point). `nil` for an unknown key.
    static func neighbors(ofEditKey editKey: String?, in photos: [Photo]) -> (previous: Photo?, next: Photo?) {
        (neighbor(of: editKey, in: photos, offset: -1), neighbor(of: editKey, in: photos, offset: 1))
    }

    /// The photo `offset` positions away from the one at `currentPath`.
    ///
    /// Returns `nil` — meaning the corresponding menu item disables — when:
    /// - there is no open photo (`currentPath` is `nil`),
    /// - the open photo isn't in `photos` at all (it was filtered out of the
    ///   current view, or the sidebar moved to a collection it isn't in), so
    ///   there is no honest "next" to move to, or
    /// - the step would run past either end. Navigation deliberately does NOT
    ///   wrap around, matching Photos and Lightroom.
    ///
    /// Matching is plain string equality on `Photo.path` against a path taken
    /// from `ImageDocumentModel.currentURL`. When the photo was opened FROM
    /// the catalog — the grid's tap-to-open, or a previous step through this
    /// very function — both sides came from the same stored string via
    /// `URL(fileURLWithPath: photo.path)`, so they agree by construction.
    ///
    /// A photo opened through `ImageDocumentModel.openImage()`'s `NSOpenPanel`
    /// is the exception: that URL can normalize differently from the string
    /// stored at import (`/tmp` vs `/private/tmp` being the classic macOS
    /// case), so an equivalent-but-differently-spelled path simply won't
    /// match. That degrades to the same safe outcome as a photo genuinely
    /// absent from the displayed set — both commands disable — rather than to
    /// a wrong jump. This is the same normalization caveat `PROGRESS.md`
    /// records for `invalidateThumbnail(for:)`.
    static func neighbor(of currentPath: String?, in photos: [Photo], offset: Int) -> Photo? {
        guard let currentPath, let index = photos.firstIndex(where: { $0.editKey == currentPath }) else { return nil }
        let target = index + offset
        guard photos.indices.contains(target) else { return nil }
        return photos[target]
    }
}
