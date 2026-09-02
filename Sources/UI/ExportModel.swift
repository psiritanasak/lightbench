import AppKit
import Foundation

/// The UI-facing coordinator for batch export (Phase 5 slice 1) —
/// deliberately kept in `Sources/UI`, not `Sources/Rendering`, mirroring
/// `CatalogModel`'s own separation from `Sources/Catalog` (the actual
/// export engine, `PhotoExporter`, stays UI-free).
struct ExportProgress: Equatable {
    var completed: Int
    var total: Int
}

@MainActor
final class ExportModel: ObservableObject {
    @Published var isPresentingOptions = false
    @Published var settings = ExportSettings()
    @Published var statusMessage: String?
    @Published private(set) var isExporting = false
    @Published private(set) var progress: ExportProgress?

    /// Opens the format/quality/resize options sheet. The destination
    /// folder is picked AFTER the user confirms those options, in
    /// `runExport(photos:)`.
    func beginExport() {
        isPresentingOptions = true
    }

    /// Prompts for a destination folder, then exports every photo in
    /// `photos` into it using the current `settings`. One photo failing
    /// to export doesn't abort the batch — each is attempted
    /// independently and the final status message reports both counts.
    func runExport(photos: [Photo]) {
        guard !isExporting else { return }
        guard !photos.isEmpty else {
            statusMessage = "No photos to export."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to export \(photos.count) photo\(photos.count == 1 ? "" : "s") into."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let rawDestination = panel.url else { return }

        // Live debugging of this feature found the app's sandbox
        // entitlement was `user-selected.read-only` (`project.yml`) —
        // a hard sandbox-profile cap that made every export write fail
        // with "Operation not permitted" regardless of thread, write API,
        // or destination folder; fixed by changing it to
        // `user-selected.read-write` (re-verified live that the Open…
        // picker, which broke under this same entitlement once before,
        // still works). This bookmark round-trip (rather than using
        // `rawDestination` directly) was added and tested alongside that
        // entitlement fix, mirroring `ImageDocumentModel.requestFolderAccess`'s
        // own working pattern — kept as the proven-together combination
        // rather than stripped back down and re-verified in isolation.
        guard
            let bookmarkData = try? rawDestination.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        else {
            statusMessage = "Couldn't get access to the destination folder."
            return
        }
        var isStale = false
        guard
            let destination = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        else {
            statusMessage = "Couldn't get access to the destination folder."
            return
        }

        isExporting = true
        progress = ExportProgress(completed: 0, total: photos.count)
        let settingsSnapshot = settings

        Task.detached { [weak self] in
            // `startAccessingSecurityScopedResource()` is called here, on
            // the SAME execution context as the writes it's guarding —
            // live-tested working in this configuration. This was only
            // ever tested together with the bookmark round-trip above and
            // the read-write entitlement fix, all applied at once; its
            // necessity independent of those wasn't isolated (Apple
            // documents this call as process-scoped, not thread-scoped,
            // so it may not be required) — kept as part of the
            // proven-together combination rather than re-verified alone.
            guard destination.startAccessingSecurityScopedResource() else {
                await MainActor.run {
                    self?.isExporting = false
                    self?.progress = nil
                    self?.statusMessage = "Couldn't get access to the destination folder."
                }
                return
            }
            defer { destination.stopAccessingSecurityScopedResource() }
            var succeeded = 0
            var failed = 0
            var firstFailureMessage: String?
            for (index, photo) in photos.enumerated() {
                let editState = PhotoExporter.loadEditState(for: photo)
                do {
                    _ = try await PhotoExporter.export(photo, editState: editState, to: destination, settings: settingsSnapshot)
                    succeeded += 1
                } catch {
                    failed += 1
                    if firstFailureMessage == nil {
                        firstFailureMessage = error.localizedDescription
                    }
                }
                await MainActor.run {
                    self?.progress = ExportProgress(completed: index + 1, total: photos.count)
                }
            }
            await MainActor.run {
                self?.isExporting = false
                self?.progress = nil
                self?.statusMessage = Self.summary(succeeded: succeeded, failed: failed, firstFailureMessage: firstFailureMessage)
            }
        }
    }

    private static func summary(succeeded: Int, failed: Int, firstFailureMessage: String?) -> String {
        let part = "Exported \(succeeded) photo\(succeeded == 1 ? "" : "s")."
        guard failed > 0 else { return part }
        var message = "\(part) \(failed) failed."
        if let firstFailureMessage {
            message += " First error: \(firstFailureMessage)"
        }
        return message
    }
}
