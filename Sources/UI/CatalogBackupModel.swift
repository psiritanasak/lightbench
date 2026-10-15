import AppKit
import Foundation
import UniformTypeIdentifiers

/// File ▸ "Back Up Catalog…" and "Restore Catalog from Backup…" (the engine is `CatalogDatabase+Backup.swift`). Owned by `CatalogModel` like
/// `xmp`/`merge`, so the Scene-level menu can reach it; `CatalogBackupDialogModifier` presents the confirmation, progress and result.
///
/// Back up: a save panel picks the file, then a consistent snapshot of the live catalog is written there. Restore: an open panel picks a
/// backup, it is validated (healthy, a catalog, not from a newer build), the user confirms, and it is STAGED; the swap happens the next
/// time the app starts (`CatalogDatabase.applyPendingRestore`), because the running app holds the catalog open and every model caches
/// its rows. Nothing in the user's photo folders is touched.
@MainActor
final class CatalogBackupModel: ObservableObject {
    enum Kind: Equatable { case backUp, restore }

    struct RestoreRequest: Equatable {
        let url: URL
        let info: CatalogFileInfo
    }

    /// The panels and the catalog location, injectable so tests never open a real panel or touch the real catalog folder.
    struct Seams {
        var chooseDestination: @MainActor (_ suggestedName: String) -> URL? = CatalogBackupModel.runSavePanel
        var chooseBackupFile: @MainActor () -> URL? = CatalogBackupModel.runOpenPanel
        var catalogDirectory: () throws -> URL = { try CatalogDatabase.defaultCatalogDirectory() }
        var now: () -> Date = { Date() }
    }

    @Published var pendingRestore: RestoreRequest? { didSet { publishBusy() } }
    @Published private(set) var isWorking = false { didSet { publishBusy() } }
    @Published var statusMessage: String?

    var seams = Seams()

    var isBusy: Bool { isWorking || pendingRestore != nil }

    private weak var catalog: CatalogModel?
    private func publishBusy() { catalog?.backupBusy = isBusy || (catalog?.backUpNowRunning ?? false) }

    // MARK: Requests

    func request(_ kind: Kind, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isBusy else { return }
        switch kind {
        case .backUp: backUp(catalog: catalog)
        case .restore: chooseRestore()
        }
    }

    private func backUp(catalog: CatalogModel) {
        let name = Self.suggestedBackupName(at: seams.now())
        guard let destination = seams.chooseDestination(name) else { return } // cancelled
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let info = try await catalog.backUpCatalog(to: destination)
                statusMessage = Self.backedUpMessage(photoCount: info.photoCount, fileName: destination.lastPathComponent)
            } catch {
                statusMessage = "Couldn't back up the catalog: \(Self.describe(error))"
            }
        }
    }

    private func chooseRestore() {
        guard let file = seams.chooseBackupFile() else { return } // cancelled
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let info = try await Task.detached { try CatalogDatabase.inspectCatalogFile(at: file) }.value
                pendingRestore = RestoreRequest(url: file, info: info)
            } catch {
                statusMessage = "That backup can't be used: \(Self.describe(error))"
            }
        }
    }

    func cancelRestore() { pendingRestore = nil }

    /// Stages the confirmed restore. `request` is the value the dialog's button was handed (not `pendingRestore`, which may already be cleared).
    func confirmRestore(_ request: RestoreRequest) {
        guard !isWorking else { return }
        pendingRestore = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let directory = try seams.catalogDirectory()
                let info = try await Task.detached { try CatalogDatabase.stageRestore(from: request.url, into: directory) }.value
                statusMessage = Self.stagedMessage(photoCount: info.photoCount)
            } catch {
                statusMessage = "Couldn't prepare the restore: \(Self.describe(error)) Your catalog was not changed."
            }
        }
    }

    // MARK: Text (pure)

    nonisolated static func suggestedBackupName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(AppInfo.name) Catalog \(formatter.string(from: date)).sqlite"
    }

    nonisolated static func photos(_ count: Int) -> String { "\(count) photo\(count == 1 ? "" : "s")" }

    nonisolated static func backedUpMessage(photoCount: Int, fileName: String) -> String {
        "Backed up the catalog (\(photos(photoCount))) to “\(fileName)”.\n\n"
            + "It holds ratings, flags, labels, keywords, collections, presets and people. Your edits are stored next to your photos, not in the catalog, "
            + "and folder permissions are not included (on a new Mac, import the folders again)."
    }

    nonisolated static func restoreConfirmationTitle(_ request: RestoreRequest) -> String { "Restore the catalog from “\(request.url.lastPathComponent)”?" }

    nonisolated static func restoreConfirmationMessage(_ request: RestoreRequest) -> String {
        var text = "This backup has \(photos(request.info.photoCount)). Ratings, flags, labels, keywords and collections go back to how they were in it, "
            + "including anything you changed since. Your current catalog is kept in the Backups folder. Edits stored next to your photos are not affected. "
            + "The restore finishes the next time \(AppInfo.name) starts."
        if request.info.needsMigration { text += " This backup is from an older version; it is updated when it opens." }
        return text
    }

    nonisolated static func stagedMessage(photoCount: Int) -> String {
        "Ready to restore a catalog with \(photos(photoCount)). Quit and reopen \(AppInfo.name) to finish. Your current catalog will be kept in the Backups folder."
    }

    private nonisolated static func describe(_ error: Error) -> String {
        let text = (error as? CatalogDatabaseError)?.message ?? error.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: Real panels (`runModal`, so `NSApp.modalWindow` still marks a panel as open for the rename guard)

    private static let sqliteType = UTType(filenameExtension: "sqlite") ?? .data

    private static func runSavePanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [sqliteType]
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the catalog backup."
        panel.prompt = "Back Up"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [sqliteType]
        panel.message = "Choose a catalog backup to restore."
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
