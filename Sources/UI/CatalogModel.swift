import AppKit
import Foundation

/// The UI-facing wrapper around `CatalogDatabase` — deliberately kept in
/// `Sources/UI`, not `Sources/Catalog`, so the Catalog module itself stays
/// free of SwiftUI/AppKit (`CLAUDE.md`: "Keep modules separated... No UI
/// imports in EditEngine" — the same principle applies to Catalog).
///
/// This is Phase 4 slice 1's whole surface: pick a folder, import its
/// photos' metadata into the catalog DB. No browsing/grid UI yet — that's
/// a later slice, per the user's explicitly chosen scope.
@MainActor
final class CatalogModel: ObservableObject {
    @Published private(set) var photoCount: Int = 0
    @Published var importStatusMessage: String?

    /// `nil` until the background open+migrate in `init()` completes (or
    /// forever, if it failed — see `initError`). `CatalogDatabase()`
    /// itself does real, synchronous I/O (creating the Application
    /// Support directory, opening the SQLite file, running migrations),
    /// so it must NOT be called directly from this `@MainActor` init —
    /// that would block app launch, violating `CLAUDE.md`'s "DB access
    /// never blocks the main thread". Instead `init()` kicks off a
    /// detached `Task` that does the open off-main and hops back only to
    /// publish the result.
    private var database: CatalogDatabase?
    /// Set if `CatalogDatabase()` failed to open (e.g. the Application
    /// Support directory couldn't be created), or left `nil` while the
    /// background open is still in flight. Either way `importFolder()`
    /// surfaces a message rather than silently no-op'ing.
    private var initError: Error?

    init() {
        Task.detached { [weak self] in
            do {
                let database = try CatalogDatabase()
                let count = try await database.photoCount()
                await MainActor.run {
                    guard let self else { return }
                    self.database = database
                    self.photoCount = count
                }
            } catch {
                await MainActor.run { self?.initError = error }
            }
        }
    }

    func importFolder() {
        guard let database else {
            importStatusMessage = initError.map { "Couldn't open the photo catalog: \($0.localizedDescription)" }
                ?? "The photo catalog isn't ready yet — try again in a moment."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of photos to import into the catalog."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        Task.detached { [weak self] in
            let urls = PhotoImporter.imageFiles(in: folder)
            do {
                let result = try await database.importPhotos(at: urls)
                let newCount = try await database.photoCount()
                await MainActor.run {
                    guard let self else { return }
                    self.photoCount = newCount
                    self.importStatusMessage = Self.summary(for: result)
                }
            } catch {
                await MainActor.run {
                    self?.importStatusMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func summary(for result: ImportResult) -> String {
        let importedPart = "Imported \(result.inserted) photo\(result.inserted == 1 ? "" : "s")"
        guard result.skipped > 0 else { return "\(importedPart)." }
        return "\(importedPart) (\(result.skipped) already in catalog)."
    }
}
