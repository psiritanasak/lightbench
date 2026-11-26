import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// The drag payload of library thumbnails. Declared under `UTExportedTypeDeclarations` in `project.yml`.
    static let lightbenchLibraryPhotos = UTType(exportedAs: "com.photoapp.PhotoApp.library-photos", conformingTo: .data)
}

/// Photo ids dragged from the grid onto a sidebar collection. Deliberately offers NO URL, file URL or image representation: the
/// window-level Finder drop (`DropAndOpenModifier`, `URL`) can never match it, so a grid drag can never become an import.
struct LibraryPhotoDrag: Codable, Transferable, Equatable {
    let photoIDs: [Int64]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lightbenchLibraryPhotos)
    }
}
