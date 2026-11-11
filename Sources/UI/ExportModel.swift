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
    @Published var settings: ExportSettings {
        didSet { if settings != oldValue { store.save(settings) } }
    }
    /// The result of the last export, taken by `feedbackAlert`. Written ONCE per completed action.
    @Published var feedback: Feedback?
    @Published private(set) var isExporting = false
    @Published private(set) var progress: ExportProgress?

    private let store: ExportSettingsStore
    nonisolated static let feedbackTitle = "Export"

    init(store: ExportSettingsStore = ExportSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    /// Opens the format/quality/resize options sheet. The destination
    /// folder is picked AFTER the user confirms those options, in
    /// `runExport(photos:keywordsByPhotoID:infoByPhotoID:)`.
    func beginExport() {
        // Original (a byte copy that keeps the GPS) is never armed from an earlier sheet: this model lives as long as the window.
        settings.kind = .rendered
        isPresentingOptions = true
    }

    /// Prompts for a destination folder, then exports every photo in
    /// `photos` into it using the current `settings`. One photo failing
    /// to export doesn't abort the batch — each is attempted
    /// independently and the final status message reports both counts.
    func runExport(photos: [Photo], keywordsByPhotoID: [Int64: [String]], infoByPhotoID: [Int64: PhotoInfo] = [:]) {
        guard !isExporting else { return }
        let originalCount = photos.count
        guard !photos.isEmpty else {
            feedback = Feedback(kind: .nothingToDo, title: Self.feedbackTitle, message: "No photos to export.")
            return
        }
        // Original files: virtual copies share their master's file, so each FILE is copied once. Done BEFORE the panel so
        // its count is the number of files that will really be copied.
        let settingsSnapshot = settings
        let isOriginal = settingsSnapshot.kind == .original
        let batch = isOriginal ? PhotoExporter.photosForOriginalExport(photos) : photos
        let duplicatesSkipped = originalCount - batch.count

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let wording = ExportSheetRules.folderPanel(count: batch.count, kind: settingsSnapshot.kind)
        panel.message = wording.message
        panel.prompt = wording.prompt
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
            feedback = .error(Self.feedbackTitle, "Couldn't get access to the destination folder.")
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
            feedback = .error(Self.feedbackTitle, "Couldn't get access to the destination folder.")
            return
        }

        isExporting = true
        progress = ExportProgress(completed: 0, total: batch.count)

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
                    self?.feedback = .error(Self.feedbackTitle, "Couldn't get access to the destination folder.")
                }
                return
            }
            defer { destination.stopAccessingSecurityScopedResource() }
            var succeeded = 0
            var failed = 0
            var firstFailureMessage: String?
            var overLimit = 0
            var truncated = 0
            var written: [URL] = []
            for (index, photo) in batch.enumerated() {
                do {
                    if isOriginal {
                        let result = try PhotoExporter.exportOriginal(photo, to: destination, settings: settingsSnapshot, sequenceIndex: index)
                        if result.sourceWasTruncated { truncated += 1 }
                        written.append(result.url)
                    } else {
                        let editState = PhotoExporter.loadEditState(for: photo)
                        let outcome = try await PhotoExporter.exportReporting(
                            photo, editState: editState, to: destination, settings: settingsSnapshot, sequenceIndex: index,
                            keywords: photo.id.flatMap { keywordsByPhotoID[$0] } ?? [],
                            info: photo.id.flatMap { infoByPhotoID[$0] } ?? PhotoInfo()
                        )
                        if outcome.overLimit { overLimit += 1 }
                        written.append(outcome.url)
                    }
                    succeeded += 1
                } catch {
                    failed += 1
                    if firstFailureMessage == nil {
                        firstFailureMessage = error.localizedDescription
                    }
                }
                await MainActor.run {
                    self?.progress = ExportProgress(completed: index + 1, total: batch.count)
                }
            }
            await MainActor.run {
                self?.isExporting = false
                self?.progress = nil
                self?.feedback = ExportSummary.feedback(
                    succeeded: succeeded, failed: failed, firstFailureMessage: firstFailureMessage,
                    overLimit: overLimit, original: isOriginal, truncated: truncated, duplicatesSkipped: duplicatesSkipped,
                    written: written
                )
            }
        }
    }
}
