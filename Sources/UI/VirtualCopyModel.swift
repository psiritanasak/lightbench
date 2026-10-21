import Foundation

/// "Create Virtual Copy": a second, independently editable version of a photo (its own catalog row, rating, flag, label, keywords,
/// collections and edit file) over the SAME image file. Owned by `CatalogModel`, like `trash`/`xmp`. The decisions are
/// `VirtualCopyFiles` (the version's edit file) and `CatalogDatabase.createVirtualCopy` (the row); this class is the flow around them.
///
/// Order matters: the edit file is written FIRST (a failure creates nothing), then the row; if the row cannot be inserted, the file this
/// call just wrote is removed again (it is the only file this model ever deletes, and only one it created itself a moment earlier).
/// Never creates a copy of a photo whose file is missing, and never touches the image file.
@MainActor
final class VirtualCopyModel {
    private let folderAccess: SidecarFolderAccessing

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess()) {
        self.folderAccess = folderAccess
    }

    /// Creates one copy of each of `photos` and returns the user-facing summary. `flushEdits` writes the open photo's pending (debounced)
    /// edits to its edit file first, so a copy made from the open photo carries what is on screen.
    func create(from photos: [Photo], catalog: CatalogModel, flushEdits: () -> Void = {}) async -> String {
        guard !catalog.isRenameInProgress else { return CatalogModel.renameInProgressMessage }
        guard let database = catalog.databaseForVirtualCopies else { return "The photo catalog isn't ready yet — try again in a moment." }
        guard !photos.isEmpty else { return "Select a photo first." }
        flushEdits()
        var created = 0
        var problems: [String] = []
        for source in photos {
            do {
                try await createOne(from: source, database: database)
                created += 1
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problems.append("\"\(source.filename)\": \(reason)")
            }
        }
        if created > 0 { await catalog.refresh() }
        var parts: [String] = []
        if created > 0 { parts.append("Created \(created) virtual cop\(created == 1 ? "y" : "ies")") }
        if !problems.isEmpty { parts.append("couldn't copy " + problems.joined(separator: "; ")) }
        return parts.joined(separator: "; ") + "."
    }

    private func createOne(from source: Photo, database: CatalogDatabase) async throws {
        let photoURL = URL(fileURLWithPath: source.path)
        guard FileManager.default.fileExists(atPath: photoURL.path) else { throw VirtualCopyFiles.Failure.fileMissing }
        let folder = photoURL.deletingLastPathComponent()
        let message = "Allow access to “\(folder.lastPathComponent)” so a virtual copy's edits can be saved next to the photo."
        let granted: URL
        switch folderAccess.resolveOrRequest(for: folder, message: message) {
        case .granted(let url): granted = url
        case .declined: throw CatalogDatabaseError(message: "folder access was not granted")
        case .failed(let error): throw error
        }
        guard granted.coversAccess(to: folder), granted.startAccessingSecurityScopedResource() else {
            throw CatalogDatabaseError(message: "folder access is no longer available")
        }
        defer { granted.stopAccessingSecurityScopedResource() }
        guard let key = VirtualCopyFiles.newVersionKey(forPhotoAt: photoURL) else {
            throw CatalogDatabaseError(message: "no free version name could be chosen")
        }
        let written = try VirtualCopyFiles.writeVersionSidecar(from: source, versionKey: key)
        do {
            _ = try await database.createVirtualCopy(of: source, versionKey: key)
        } catch {
            if let written { try? FileManager.default.removeItem(at: written) } // our own file, written a moment ago
            throw error
        }
    }
}
