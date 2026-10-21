import SwiftUI

/// Which of the Library grid's "nothing to show" screens applies. Pure, so the rules are testable without a view.
///
/// The three cases look alike but need different words: a brand-new LIBRARY (offer to import), an empty COLLECTION in a library that has
/// photos (say how to fill it — importing again would be the wrong advice), and the first moments after launch before the catalog has been
/// read (show nothing at all rather than flashing "no photos").
enum LibraryEmptyKind: Equatable {
    /// Photos are shown: no empty state.
    case hasPhotos
    /// The catalog has not been read yet.
    case loading
    case emptyLibrary
    case emptyCollection
    /// The catalog could not be opened at all.
    case openFailed

    /// `photoCount` is the whole catalog's size; `shownCount` is what the selected collection / folder holds (before sort / filter).
    /// `refresh()` publishes `photoCount` BEFORE `photos`, so "the catalog has photos but nothing is shown" with All Photos selected is just
    /// data in transit (right after an import), never an empty collection: it stays `.loading` (blank) until the list arrives.
    static func of(isLoaded: Bool, photoCount: Int, shownCount: Int, isCollectionSelected: Bool, openFailed: Bool = false) -> LibraryEmptyKind {
        if openFailed { return .openFailed }
        if shownCount > 0 { return .hasPhotos }
        guard isLoaded else { return .loading }
        if photoCount == 0 { return .emptyLibrary }
        return isCollectionSelected ? .emptyCollection : .loading
    }
}

/// The Library of a brand-new install: what to do first, with the two import actions right there.
struct LibraryEmptyLibraryView: View {
    @ObservedObject var catalog: CatalogModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text("Add your photos")
                .font(.title2.weight(.semibold))
            Text("Choose a folder to import. Lightbench works on your photos where they already are and never changes the originals.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Import Folder\u{2026}") { catalog.importFolder() }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                Button("Import Folder Tree\u{2026}") { catalog.importFolderTree() }
                    .buttonStyle(.flat)
                    .help("Imports the folder and every subfolder, mirroring them as collections.")
            }
            .disabled(catalog.isRenameInProgress)
            Text("or drop a folder here")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A collection (or folder) with no photos in a library that has some.
struct LibraryEmptyCollectionView: View {
    /// A folder-mirrored collection holds only the photos directly inside that folder: "add photos to it" would be wrong advice.
    var isFolder = false
    /// "Show Photos in Subfolders" is on, so an empty folder is empty all the way down.
    var includesSubfolders = false
    /// The setting itself is on (even if this folder has no subfolders): advice must not tell the user to turn on what is already on.
    var subfolderSettingOn = false

    private var title: String {
        guard isFolder else { return "This collection is empty" }
        return includesSubfolders ? "No photos in this folder or its subfolders" : "No photos directly in this folder"
    }

    private var advice: String {
        guard isFolder else {
            return "Select photos in All Photos, then choose \u{201c}Add to Collection\u{201d} from the selection menu in the toolbar."
        }
        return (includesSubfolders || subfolderSettingOn)
            ? "Import photos from this folder, or choose another folder."
            : "Photos in its subfolders are shown under those subfolders, or here with \u{201c}Show Photos in Subfolders\u{201d} (right-click the folder)."
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : "rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.headline)
            Text(advice)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The catalog itself could not be opened: say so (the launch alert is gone after one click) and what can be done.
struct CatalogOpenFailedView: View {
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warning)
            Text("The photo catalog couldn\u{2019}t be opened")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text("Your photos and their edits are untouched. You can bring back a saved copy with File \u{25B8} Restore Catalog from Backup\u{2026}, then relaunch.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Editor with no photo open. Appears only after `appearDelay`: opening a photo from the Library switches to the Editor a moment BEFORE
/// the load starts (it awaits folder access first), and the hint must not flash — or take a click — during that gap.
struct EditorNoPhotoView: View {
    var appearDelay: TimeInterval = 0.4
    var showLibrary: () -> Void
    @State private var visible = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text("No photo open")
                .font(.headline)
            Text("Pick a photo in the Library, or drop one here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button("Show Library", action: showLibrary)
                .buttonStyle(.flat)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .task {
            if appearDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(appearDelay * 1_000_000_000)) }
            visible = true
        }
    }
}
