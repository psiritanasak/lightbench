import Foundation

/// State behind Photo ▸ Recently Deleted…. Catalog-only: restoring re-inserts catalog rows (`CatalogDatabase.restoreDeletedPhoto`); no
/// file is ever moved, copied or deleted by this class (a source-pin test checks it). The user returns a file with Put Back in the Finder.
@MainActor
final class RecentlyDeletedModel: ObservableObject {
    struct Row: Equatable, Identifiable {
        let entry: DeletedPhotoEntry
        let status: RecentlyDeletedStatus
        var id: Int64 { entry.id }
    }

    @Published private(set) var rows: [Row] = []
    /// Entries whose snapshot cannot be read; they can only be removed.
    @Published private(set) var unreadable: [UnreadableDeletedPhoto] = []
    @Published var statusMessage: String?
    /// How the footer draws `statusMessage` (set with it): a result is `.info`, a refusal or a partial restore `.caution`, a failure `.error`.
    @Published var statusTone: SheetStatus.Tone = .info
    @Published private(set) var isWorking = false

    /// Whether a file exists at a path (a read-only check; injectable for tests).
    private let fileExists: @Sendable (String) -> Bool

    init(fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    func load(catalog: CatalogModel) async {
        guard let database = catalog.database else { rows = []; unreadable = []; return }
        let exists = fileExists
        do {
            let entries = try await database.deletedPhotoEntries()
            unreadable = try await database.unreadableDeletedPhotos()
            rows = await Task.detached {
                entries.map {
                    Row(entry: $0, status: RecentlyDeletedStatus.of(
                        blocker: $0.blocker, fileExists: exists($0.originalPath),
                        editFilesExist: $0.editFilePaths.allSatisfy(exists), isCopy: $0.isVirtualCopyEntry
                    ))
                }
            }.value
        } catch {
            statusMessage = "Couldn't read Recently Deleted: \(error.localizedDescription)"; statusTone = .error
        }
    }

    /// Restores one entry. The database re-checks the file and the path inside its own transaction.
    func restore(_ id: Int64, catalog: CatalogModel) async {
        guard !isWorking, let database = catalog.database else { return }
        guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; statusTone = .caution; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await database.restoreDeletedPhoto(id: id, fileExists: fileExists)
            statusMessage = Self.message(for: outcome, name: rows.first { $0.id == id }?.entry.name ?? "The photo")
            statusTone = Self.tone(for: outcome)
            if case .restored = outcome { await catalog.refresh() }
        } catch {
            statusMessage = "Couldn't restore: \(error.localizedDescription)"; statusTone = .error
        }
        await load(catalog: catalog)
    }

    /// Removes one entry from the list (snapshot only; no file is touched).
    func forget(_ id: Int64, catalog: CatalogModel) async {
        guard let database = catalog.database else { return }
        do { try await database.forgetDeletedPhotos(ids: [id]) } catch { statusMessage = "Couldn't update the list: \(error.localizedDescription)"; statusTone = .error }
        await load(catalog: catalog)
    }

    func emptyList(catalog: CatalogModel) async {
        guard let database = catalog.database else { return }
        do { try await database.forgetAllDeletedPhotos() } catch { statusMessage = "Couldn't update the list: \(error.localizedDescription)"; statusTone = .error }
        await load(catalog: catalog)
    }

    /// The footer tone of a restore outcome: a restore is `.info`, or `.caution` when some collections no longer exist; a refusal that
    /// asks the user to do something first (put the file back) is `.caution`; a restore that cannot happen at all is `.error`.
    nonisolated static func tone(for outcome: DeletedPhotoRestoreOutcome) -> SheetStatus.Tone {
        switch outcome {
        case .restored(let report): return report.missingCollections.isEmpty ? .info : .caution
        case .notFound, .fileMissing, .editFileMissing: return .caution
        case .pathInUse, .masterMissing, .idInUse: return .error
        }
    }

    nonisolated static func message(for outcome: DeletedPhotoRestoreOutcome, name: String) -> String {
        switch outcome {
        case .restored(let report):
            var text = "Restored \(name)"
            if report.restoredCopies > 0 { text += " with \(report.restoredCopies) virtual cop\(report.restoredCopies == 1 ? "y" : "ies")" }
            text += "."
            if !report.missingCollections.isEmpty {
                text += " Not put back into collections that no longer exist: \(report.missingCollections.joined(separator: ", "))."
            }
            return text
        case .notFound: return "That entry is no longer in the list."
        case .fileMissing: return "\(name) is not at its original location yet. In the Finder, open the Trash and choose Put Back, then try again."
        case .pathInUse: return "\(name) was not restored: its original location is used by another photo in the Library."
        case .masterMissing: return "\(name) was not restored: the photo this virtual copy belongs to is not in the Library."
        case .editFileMissing: return "\(name) is not ready: its edit file is still in the Trash. In the Finder, Put Back the edit file (and XMP sidecar) too, then try again."
        case .idInUse: return "\(name) was not restored: the Library already has a photo with its old identity."
        }
    }

    nonisolated static let explanation =
        "Photos you moved to the Trash from Lightbench are listed here. Lightbench never takes a file out of the Trash: in the Finder, open the Trash, "
        + "select the photo TOGETHER with its edit file (.photoapp.json) and XMP sidecar and choose Put Back, then come back and press Restore to bring back its ratings, keywords, collections and info. "
        + "Emptying the Finder's Trash deletes the files for good."
}
