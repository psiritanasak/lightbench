import Foundation
import GRDB

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

    private let randomKey: () -> UInt32

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess(), randomKey: @escaping () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) {
        self.folderAccess = folderAccess
        self.randomKey = randomKey
    }

    /// Creates one copy of each of `photos` and returns the user-facing summary. `flushEdits` writes the open photo's pending (debounced)
    /// edits to its edit file first, so a copy made from the open photo carries what is on screen.
    func create(from photos: [Photo], catalog: CatalogModel, flushEdits: () -> Void = {}, openVersion: (editKey: String, state: EditState)? = nil) async -> String {
        guard !catalog.isRenameInProgress else { return CatalogModel.renameInProgressMessage }
        guard let database = catalog.databaseForVirtualCopies else { return "The photo catalog isn't ready yet — try again in a moment." }
        guard !photos.isEmpty else { return "Select a photo first." }
        flushEdits()
        var created = 0
        var problems: [String] = []
        for source in photos {
            do {
                try await createOne(from: source, database: database, liveState: openVersion.flatMap { $0.editKey == source.editKey ? $0.state : nil })
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

    private func createOne(from source: Photo, database: CatalogDatabase, liveState: EditState?) async throws {
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
        // A key only avoids existing FILES; an unedited copy has none, so a key already used by a row for this path shows up as a unique-index
        // failure: retry with a fresh key (bounded) rather than reporting an error.
        for attempt in 0..<8 {
            guard let key = VirtualCopyFiles.newVersionKey(forPhotoAt: photoURL, random: randomKey) else {
                throw CatalogDatabaseError(message: "no free version name could be chosen")
            }
            let written = try VirtualCopyFiles.writeVersionSidecar(from: source, versionKey: key, liveState: liveState)
            do {
                _ = try await database.createVirtualCopy(of: source, versionKey: key)
                return
            } catch {
                if let written { try? FileManager.default.removeItem(at: written) } // our own file, written a moment ago
                let taken = (error as? DatabaseError)?.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
                if !taken || attempt == 7 { throw error }
            }
        }
    }
}
