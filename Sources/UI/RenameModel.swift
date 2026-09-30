import Foundation

/// What `RenameModel` needs from the rest of the app at the moment it acts — closures, so it never
/// holds the Editor/Export/Enhance/Paste models itself (and can be checked again at APPLY time,
/// not just when the sheet opened).
struct RenameProviders {
    /// The path of the photo open in the Editor, if any.
    var openPhotoPath: () -> String?
    /// A user-facing reason a rename/undo must not run right now (a photo is loading, an export or
    /// Enhance is running, a paste confirmation is open), or nil.
    var busyReason: () -> String?
}

/// Owns the Library's "Rename Files…" sheet (template, live preview, apply) and "Undo Rename".
/// `@StateObject` on `PhotoAppApp` so the Photo menu's items and the Library toolbar act on the
/// SAME instance (same reasoning as `PasteSettingsModel`).
///
/// This is the first feature that changes the on-disk NAMES of the user's original photos, so the
/// discipline (from the commit-3 review of `RenameEngine`) is enforced HERE at both apply time and
/// undo time, not just when the sheet opens:
/// - refuse while the photo is open in the Editor or a load is in flight (its debounced sidecar save
///   would otherwise write to the OLD sidecar path — IMPROVEMENTS.md D28's hazard class);
/// - refuse while an Export/Enhance/Paste is running (a temp-window read would see "no sidecar");
/// - single flight: `isWorking` is set SYNCHRONOUSLY before any `await`, so a double-click can't
///   start two batches;
/// - RE-PLAN against fresh disk/catalog state immediately before applying and refuse if it differs
///   from the preview the user confirmed;
/// - hold write access (a security-scoped bookmark) for EVERY folder involved, at undo too.
///
/// Capture dates are read ONCE per sheet (off the main thread), never per keystroke.
@MainActor
final class RenameModel: ObservableObject {
    enum Request: Equatable {
        case rename
        case undo
    }

    /// Set by the Photo menu (a Scene-level construct that can't reach `ContentView`'s selection or
    /// its Export/Enhance state); `ContentView` observes it, clears it, and acts with its own providers.
    @Published var request: Request?

    @Published var isPresentingSheet = false
    @Published var template = NamingTemplate.defaultTemplate { didSet { recomputePlan() } }
    @Published var sequenceStartText = "1" { didSet { recomputePlan() } }
    @Published private(set) var plan: RenamePlan?
    @Published private(set) var templateError: NamingError?
    @Published private(set) var sequenceStartMessage: String?
    @Published private(set) var isLoadingDates = false
    @Published private(set) var isLoadingOwners = false
    @Published private(set) var isWorking = false
    @Published private(set) var canUndo = false
    /// A failure shown INSIDE the sheet (so it stays open for the user to adjust).
    @Published var sheetError: String?
    /// A result shown as an alert after the sheet closes (success, or an undo outcome).
    @Published var statusMessage: String?

    private(set) var targets: [Photo] = []
    private var captureDates: [Int64: Date] = [:]
    private var datesLoaded = false
    private var pathOwners: [String: Int64] = [:]
    private var openPhotoPath: String?
    private var providers: RenameProviders?
    private weak var catalog: CatalogModel?
    private let folderAccess = SidecarFolderAccess()

    /// Held write access to a set of folders; `release()` stops the security scopes.
    struct WriteAccess {
        var release: () -> Void
    }

    /// TEST SEAM: replaces the real folder-access flow (an `NSOpenPanel` + security-scoped
    /// bookmarks, neither of which a unit test can drive). Return nil to simulate a decline.
    var acquireWriteAccess: ((Set<URL>) -> WriteAccess?)?

    private static let accessMessage =
        "PhotoApp needs permission to rename photos in this folder. Choose the folder to grant access."

    var photoCount: Int { targets.count }

    /// The Rename button's enabled state: a fully-loaded, fully-clean plan and nothing in flight.
    var canApply: Bool {
        (plan?.isApplicable ?? false) && !isWorking && !isLoadingDates && !isLoadingOwners
    }

    /// Bumped by every `begin`, so a slow background read (capture dates, catalog path owners) from an
    /// EARLIER sheet can never install its results into a LATER one.
    private var generation = 0

    // MARK: - Sheet

    /// Opens the sheet for `photos` (already in the Library grid's displayed order — which is also
    /// the `{seq}` order).
    func begin(photos: [Photo], catalog: CatalogModel, providers: RenameProviders) {
        // A sheet that was requested but never appeared (SwiftUI drops a presentation made while another
        // is up) would otherwise leave `isPresentingSheet` true forever and block every later rename.
        if isPresentingSheet && !sheetIsVisible && !isWorking { isPresentingSheet = false }
        guard !isWorking, !isPresentingSheet else { return }
        if let reason = providers.busyReason() {
            statusMessage = reason
            return
        }
        guard !photos.isEmpty else {
            statusMessage = "Select the photos to rename first."
            return
        }
        generation += 1
        let myGeneration = generation
        self.catalog = catalog
        self.providers = providers
        targets = photos
        captureDates = [:]
        datesLoaded = false
        isLoadingDates = false
        pathOwners = [:]
        openPhotoPath = providers.openPhotoPath()
        plan = nil
        sheetError = nil
        isLoadingOwners = true
        isPresentingSheet = true
        recomputePlan()
        Task { [weak self] in
            let owners = await catalog.cataloguedPathOwners()
            await MainActor.run {
                guard let self, self.generation == myGeneration else { return }
                self.pathOwners = owners
                self.isLoadingOwners = false
                self.recomputePlan()
            }
        }
    }

    /// Reported by `RenameSheetView.onAppear`/`onDisappear`.
    private(set) var sheetIsVisible = false

    func sheetDidAppear() { sheetIsVisible = true }

    func sheetDidDisappear() {
        sheetIsVisible = false
        isPresentingSheet = false
    }

    func cancel() {
        guard !isWorking else { return }
        isPresentingSheet = false
    }

    private func environment() -> RenameEnvironment {
        let owners = pathOwners
        return RenameEnvironment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            catalogPhotoID: { owners[$0] },
            openPhotoPath: openPhotoPath
        )
    }

    /// The starting sequence number the user typed, or nil (with `sequenceStartMessage` set).
    private func parsedStart() -> Int? {
        let trimmed = sequenceStartText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= 0 else {
            sequenceStartMessage = "Start number must be 0 or higher."
            return nil
        }
        sequenceStartMessage = nil
        return value
    }

    /// Builds the plan for the CURRENT template/start against the CURRENT environment, without
    /// publishing it (so `performApply` can compare a fresh plan to the confirmed one).
    private func makePlan() -> RenamePlan? {
        guard case .success(let compiled) = NamingTemplate.compile(template) else { return nil }
        guard let start = parsedStart() else { return nil }
        return RenamePlan.make(
            photos: targets, template: compiled, sequenceStart: start, captureDates: captureDates,
            environment: environment()
        )
    }

    private func recomputePlan() {
        guard isPresentingSheet else { return }
        switch NamingTemplate.compile(template) {
        case .failure(let error):
            templateError = error
            plan = nil
            return
        case .success(let compiled):
            templateError = nil
            if compiled.usesCaptureDate { loadCaptureDatesIfNeeded() }
        }
        plan = makePlan()
    }

    /// Reads every target's capture date ONCE, off the main thread, the first time a date token is used.
    private func loadCaptureDatesIfNeeded() {
        guard !datesLoaded, !isLoadingDates else { return }
        isLoadingDates = true
        let myGeneration = generation
        let items = targets.compactMap { photo in photo.id.map { ($0, URL(fileURLWithPath: photo.path), photo.importedAt) } }
        Task { [weak self] in
            let dates = await Task.detached { () -> [Int64: Date] in
                var result: [Int64: Date] = [:]
                for (id, url, imported) in items { result[id] = CaptureDate.read(from: url, fallback: imported) }
                return result
            }.value
            await MainActor.run {
                guard let self, self.generation == myGeneration else { return }
                self.captureDates = dates
                self.datesLoaded = true
                self.isLoadingDates = false
                self.recomputePlan()
            }
        }
    }

    // MARK: - Apply

    /// The sheet's "Rename" button. Single flight: `isWorking` flips synchronously.
    func apply() {
        guard !isWorking else { return }
        isWorking = true
        catalog?.isRenameInProgress = true // catalog import/locate/remove refuse meanwhile
        sheetError = nil
        Task { await performApply() }
    }

    private func performApply() async {
        defer {
            isWorking = false
            catalog?.isRenameInProgress = false
        }
        guard let catalog, let providers else { return }

        if let reason = providers.busyReason() {
            report(reason)
            return
        }
        // Re-plan against FRESH state; refuse if it differs from what the user confirmed.
        pathOwners = await catalog.cataloguedPathOwners()
        openPhotoPath = providers.openPhotoPath()
        let confirmed = plan
        let fresh = makePlan()
        plan = fresh
        guard let fresh, fresh.isApplicable else {
            report("Things changed since the preview — review it and try again.")
            return
        }
        guard fresh == confirmed else {
            report("The preview changed — review it, then press Rename again.")
            return
        }

        let moves = fresh.renames
        let folders = Set(moves.map { URL(fileURLWithPath: $0.oldPath).deletingLastPathComponent() })
        guard let access = acquire(folders) else { return }
        defer { access.release() }

        // RE-CHECK after the (possibly modal) folder prompt — while an `NSOpenPanel` is up, scheduled
        // main-actor work (a photo load, a debounced save) keeps running, so everything checked above
        // may be stale. Synchronous, with NO `await` between here and the rename (the same shape as
        // `PasteSettingsModel`'s `canProceed`).
        if let reason = providers.busyReason() {
            report(reason)
            return
        }
        openPhotoPath = providers.openPhotoPath()
        let recheck = makePlan()
        guard recheck == fresh else {
            plan = recheck
            report("Things changed while waiting for folder access — review the preview and try again.")
            return
        }

        do {
            let count = try await catalog.applyRename(moves)
            isPresentingSheet = false
            canUndo = true
            statusMessage = "Renamed \(count) photo\(count == 1 ? "" : "s"). Use Undo Rename to put the names back."
        } catch {
            // `report`, not `sheetError`: if the sheet vanished mid-apply the message (which may be the
            // "files couldn't be put back — use Locate…" one) must still reach the user as an alert.
            report(error.localizedDescription)
        }
    }

    // MARK: - Undo

    /// "Undo Rename": puts the most recent batch back. Same guards as apply (Editor, busy, access).
    func undo(catalog: CatalogModel, providers: RenameProviders) {
        guard !isWorking else { return }
        isWorking = true
        catalog.isRenameInProgress = true
        Task { await performUndo(catalog: catalog, providers: providers) }
    }

    private func performUndo(catalog: CatalogModel, providers: RenameProviders) async {
        defer {
            isWorking = false
            catalog.isRenameInProgress = false
        }
        if let reason = providers.busyReason() {
            statusMessage = reason
            return
        }
        guard let log = await catalog.lastRenameLog() else {
            canUndo = false
            statusMessage = "There is no rename to undo."
            return
        }
        func openPhotoIsInBatch() -> Bool {
            guard let open = providers.openPhotoPath() else { return false }
            return log.moves.contains { RenamePlan.isSamePath($0.newPath, open) || RenamePlan.isSamePath($0.oldPath, open) }
        }
        if openPhotoIsInBatch() {
            statusMessage = RenameBlock.openInEditor.message
            return
        }
        let folders = Set(log.moves.map { URL(fileURLWithPath: $0.newPath).deletingLastPathComponent() })
        guard let access = acquire(folders) else { return }
        defer { access.release() }
        // Re-check after the (possibly modal) folder prompt, with no `await` before acting (see `performApply`).
        if let reason = providers.busyReason() {
            statusMessage = reason
            return
        }
        if openPhotoIsInBatch() {
            statusMessage = RenameBlock.openInEditor.message
            return
        }
        do {
            let count = try await catalog.undoLastRename(expectedBatchID: log.batchID)
            canUndo = await catalog.lastRenameLog() != nil
            statusMessage = "Restored \(count) photo\(count == 1 ? "" : "s") to their previous names."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshCanUndo(catalog: CatalogModel) async {
        canUndo = await catalog.lastRenameLog() != nil
    }

    // MARK: - Folder access

    /// Write access for every folder (scopes started, released via the returned handle), or nil with the
    /// reason surfaced. `acquireWriteAccess` replaces all of this in tests.
    private func acquire(_ folders: Set<URL>) -> WriteAccess? {
        if let acquireWriteAccess { return acquireWriteAccess(folders) }
        guard let granted = grantAccess(to: folders) else { return nil }
        let started = granted.filter { $0.startAccessingSecurityScopedResource() }
        guard started.count == granted.count else {
            started.forEach { $0.stopAccessingSecurityScopedResource() }
            report("Couldn't get write access to every folder — nothing was changed.")
            return nil
        }
        return WriteAccess { started.forEach { $0.stopAccessingSecurityScopedResource() } }
    }

    /// Write access for every folder, one prompt per not-yet-granted folder. Nil (with the reason
    /// surfaced) if the user declines any: a partial grant would strand a half-renamed batch.
    private func grantAccess(to folders: Set<URL>) -> [URL]? {
        var granted: [URL] = []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            switch folderAccess.resolveOrRequest(for: folder, message: Self.accessMessage) {
            case .granted(let url):
                if !granted.contains(url) { granted.append(url) }
            case .declined:
                report("Folder access was declined — nothing was renamed.")
                return nil
            case .failed(let error):
                report("Couldn't get access to the folder: \(error.localizedDescription)")
                return nil
            }
        }
        return granted
    }

    /// Shows a failure where the user is looking: inside the sheet if it's open, else as an alert.
    private func report(_ message: String) {
        if isPresentingSheet { sheetError = message } else { statusMessage = message }
    }
}
