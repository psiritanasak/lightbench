import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// The drag payload of library thumbnails. Declared under `UTExportedTypeDeclarations` in `project.yml`.
    static let lightbenchLibraryPhotos = UTType(exportedAs: "com.photoapp.PhotoApp.library-photos", conformingTo: .data)
}

/// Photo ids dragged from the grid onto a sidebar collection, visible ONLY inside this app (`.ownProcess`). Deliberately offers NO URL, file URL or image representation: the
/// window-level Finder drop (`DropAndOpenModifier`, `URL`) can never match it, so a grid drag can never become an import.
struct LibraryPhotoDrag: Codable, Transferable, Equatable {
    let photoIDs: [Int64]

    static var transferRepresentation: some TransferRepresentation {
        // `.ownProcess`: only THIS app's drop targets can see the payload. Without it Finder accepted the drag and wrote an unopenable
        // clipping file on the Desktop (found by hand 2026-11-27).
        CodableRepresentation(contentType: .lightbenchLibraryPhotos).visibility(.ownProcess)
    }
}
