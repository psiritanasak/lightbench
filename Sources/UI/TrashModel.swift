import AppKit
import Foundation

/// "Move Rejected to Trash…" and "Move Selected to Trash…" in the Library. Owned by `CatalogModel` like `xmp`/`merge`, so the Scene-level Photo
/// menu and the selection menu reach it; `TrashDialogModifier` presents the confirmation, progress and result. The decisions are
/// `TrashPlan` (what moves) and `TrashEngine` (the moves); this class is the flow around them.
///
/// Safety rules (tested): nothing happens without a destructive-role confirmation that states the scope; files go to the Trash only
/// (never deleted); the photo open in the Editor is never moved; the targets come from what the Library SHOWS (never the hidden part of the
/// library); everything that can change during a folder-access prompt — a rename, a photo load, a flag change, the open photo — is checked
/// AGAIN afterwards on fresh rows; a photo whose file did not reach the Trash keeps its Library row.
@MainActor
final class TrashModel: ObservableObject {
    enum Kind: Equatable {
        /// The photos flagged Rejected among those the Library is showing.
        case rejected
        /// The selected photos among those the Library is showing.
        case selected
    }

    struct Request: Equatable {
        let kind: Kind
        let photos: [Photo]
        /// What the Library was showing when asked (named in the confirmation).
        let scope: String
        /// Virtual copies that go WITH a targeted master (known when the request was made): named in the confirmation.
        var copiesWithMasters = 0
        /// Targeted virtual copies: only their edits and rows go; the shared image file stays.
        var copiesOnly: Int { photos.filter(\.isVirtualCopy).count }
    }

    /// What a run did, for the result alert.
    struct Result: Equatable {
        var trashed = 0
        var companions = 0
        var companionsFailed = 0
        var failed: [TrashEngine.Failure] = []
        /// Photos that became the open one after the plan was made and were left alone.
        var lateSkippedOpen: [String] = []
        /// The run was stopped by something starting mid-way (the reason), and how many photos were left untouched.
        var stoppedBecause: String?
        var notAttempted = 0
        var skipped: [TrashPlan.Skipped] = []
        var noAccess = 0
        /// Photos that were no longer rejected when the run started (a flag changed while a prompt was up).
        var noLongerRejected = 0
        /// The files are in the Trash but the Library rows could not be removed.
        var catalogError: String?
    }

    @Published var pending: Request? { didSet { publishBusy() } }
    @Published private(set) var isWorking = false { didSet { publishBusy() } }
    @Published var statusMessage: String?

    var isBusy: Bool { isWorking || pending != nil }

    private weak var catalog: CatalogModel?
    private func publishBusy() { catalog?.trashBusy = isBusy }

    private let folderAccess: SidecarFolderAccessing
    private let mover: TrashEngine.Mover

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess(), mover: @escaping TrashEngine.Mover = TrashEngine.systemTrash) {
        self.folderAccess = folderAccess
        self.mover = mover
    }

    // MARK: - Request

    /// `shown`: the photos the Library is showing, in grid order (`displayedPhotos`) for `.rejected`, the selected visible ones for `.selected`.
    func request(_ kind: Kind, shown: [Photo], scope: String, providers: RenameProviders, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isBusy else { return }
        guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }
        if let reason = providers.busyReason() { statusMessage = reason; return }
        let targets = Self.targets(kind, from: shown)
        guard !targets.isEmpty else {
            statusMessage = kind == .rejected ? "There are no rejected photos in what the Library is showing." : "Select at least one photo first."
            return
        }
        let masterIDs = Set(targets.filter { !$0.isVirtualCopy }.compactMap(\.id))
        let targetIDs = Set(targets.compactMap(\.id))
        // Copies of a targeted master that are not themselves targeted: they leave with the master's file.
        let withMasters = catalog.photos.filter { copy in
            guard let masterID = copy.masterId, masterIDs.contains(masterID), let id = copy.id else { return false }
            return !targetIDs.contains(id)
        }.count
        pending = Request(kind: kind, photos: targets, scope: scope, copiesWithMasters: withMasters)
    }

    func cancel() { pending = nil }

    // MARK: - Run

    /// Runs `request` (the value the dialog handed its button, not `pending`, which may already be cleared).
    func confirm(_ request: Request, providers: RenameProviders, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isWorking else { return }
        pending = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            await run(request, providers: providers, catalog: catalog)
        }
    }

    /// Whether anything that makes moving files unsafe is going on right now.
    private func refusal(_ providers: RenameProviders, _ catalog: CatalogModel) -> String? {
        if catalog.isRenameInProgress { return CatalogModel.renameInProgressMessage }
        return providers.busyReason()
    }

    private func run(_ request: Request, providers: RenameProviders, catalog: CatalogModel) async {
        if let reason = refusal(providers, catalog) { statusMessage = reason; return }

        // 1. Folder access: one prompt per distinct folder not yet granted (moving a file needs write access to its folder).
        var scopes: [String: URL] = [:]
        let folders = XMPModel.distinctFolders(of: request.photos)
        for folder in folders {
            switch folderAccess.resolveOrRequest(
                for: folder, message: "Allow access to “\(folder.lastPathComponent)” so its photos can be moved to the Trash."
            ) {
            case .declined: continue
            case .failed(let error): statusMessage = error.localizedDescription; return
            case .granted(let granted):
                if granted.coversAccess(to: folder) { scopes[folder.standardizedFileURL.path] = granted }
            }
        }
        // 2. A modal prompt above pumps the run loop: re-check everything before touching a file.
        if let reason = refusal(providers, catalog) { statusMessage = reason; return }

        var result = Result()
        let fresh = await catalog.freshPhotos(ids: request.photos.compactMap(\.id))
        let stillTargets = Self.targets(request.kind, from: fresh)
        result.noLongerRejected = request.kind == .rejected ? fresh.count - stillTargets.count : 0
        let reachable = stillTargets.filter { scopes[XMPModel.folderPath(of: $0)] != nil }
        result.noAccess = stillTargets.count - reachable.count
        guard !reachable.isEmpty else { statusMessage = Self.summary(result); return }

        let started = scopes.values.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }

        // 3. Plan. The photo open in the Editor is skipped here, and checked AGAIN right before each photo moves (`gate`).
        let allPaths = Array(await catalog.cataloguedPathOwners().keys)
        let copiesOfMasters = await catalog.copiesByMaster()
        let plan = await Task.detached { [openPath = providers.openPhotoPath()] in
            TrashPlan.make(photos: reachable, openPhotoPath: openPath, cataloguedPaths: allPaths, copiesOfMasters: copiesOfMasters)
        }.value
        if let reason = refusal(providers, catalog) { statusMessage = reason; return }
        result.skipped = plan.skipped
        guard !plan.isEmpty else { statusMessage = Self.summary(result); return }

        // 4. Move, then drop the rows of exactly the photos whose file reached the Trash.
        let mover = self.mover
        let gate: @MainActor (TrashPlan.Item) -> TrashEngine.Gate = { item in
            if let reason = self.refusal(providers, catalog) { return .stop(reason) }
            if let open = providers.openPhotoPath(), TrashPlan.samePhoto(open, item.photoURL.path) { return .skipOpen }
            return .proceed
        }
        // Off the main actor: the moves block on the file system; only the gate hops back for its checks.
        let outcome = await Task.detached { await TrashEngine.apply(plan, mover: mover, gate: gate) }.value
        // Photos, not catalog rows (a duplicate row of the same file would otherwise count twice).
        result.trashed = plan.items.filter { outcome.trashedIDs.contains($0.photoID) }.count
        result.companions = outcome.companionsTrashed
        result.companionsFailed = outcome.companionsFailed
        result.failed = outcome.failures
        result.lateSkippedOpen = outcome.lateSkippedOpen
        result.stoppedBecause = outcome.stoppedBecause
        result.notAttempted = outcome.notAttempted
        if !outcome.trashedIDs.isEmpty {
            // A virtual copy trashed on its own leaves the shared file in place: its path must not drop the master's focus/thumbnail.
            let paths = plan.items.filter { !$0.isVersionOnly && outcome.trashedIDs.contains($0.photoID) }.map { $0.photoURL.path }
            do { try await catalog.removeTrashedPhotos(ids: outcome.trashedIDs, paths: paths) } catch { result.catalogError = error.localizedDescription }
        }
        statusMessage = Self.summary(result)
    }

    // MARK: - Pure helpers (testable)

    nonisolated static func targets(_ kind: Kind, from photos: [Photo]) -> [Photo] {
        switch kind {
        case .rejected: return photos.filter { $0.flagStatus == .rejected }
        case .selected: return photos
        }
    }

    nonisolated static func confirmationTitle(_ request: Request) -> String {
        let n = request.photos.count
        return "Move \(n) \(n == 1 ? "photo" : "photos") to the Trash?"
    }

    nonisolated static func confirmationMessage(_ request: Request) -> String {
        let n = request.photos.count
        let what: String
        switch request.kind {
        case .rejected: what = "the \(n) rejected \(n == 1 ? "photo" : "photos") in \(request.scope) that the Library is showing (its filters and search apply)"
        case .selected: what = "the \(n) selected \(n == 1 ? "photo" : "photos") in \(request.scope)"
        }
        var copies = ""
        if request.copiesWithMasters > 0 {
            let c = request.copiesWithMasters
            copies += "\(c) virtual cop\(c == 1 ? "y" : "ies") of these photos \(c == 1 ? "goes" : "go") with them (the file they share is moved). "
        }
        if request.copiesOnly > 0 {
            let c = request.copiesOnly
            copies += "\(c) selected virtual cop\(c == 1 ? "y is" : "ies are") removed on their own: only their edits go, the image file stays. "
        }
        return "Moves \(what) to the Trash, with each photo's edit file and XMP sidecar. " + copies
            + "A shared .xmp (same name as a RAW or JPEG that stays) is kept. The photo open in the Editor is skipped.\n\n"
            + "Nothing is permanently deleted: in the Trash, choose Put Back to restore a file, then import its folder again. "
            + "The photos are removed from the Library, and their ratings, labels, keywords, collections and face data go with them."
    }

    nonisolated static func summary(_ r: Result) -> String {
        func photos(_ n: Int) -> String { "\(n) photo" + (n == 1 ? "" : "s") }
        var parts: [String] = []
        if r.trashed > 0 {
            var text = "Moved \(photos(r.trashed)) to the Trash"
            if r.companions > 0 { text += " with \(r.companions) edit / XMP file" + (r.companions == 1 ? "" : "s") }
            parts.append(text)
        } else {
            parts.append("Nothing was moved to the Trash")
        }
        let open = r.skipped.filter { $0.reason == .openInEditor }.map(\.name) + r.lateSkippedOpen
        if !open.isEmpty { parts.append("skipped \(open.joined(separator: ", ")) because it is open in the Editor") }
        let missing = r.skipped.filter { $0.reason == .missingOnDisk }
        if !missing.isEmpty { parts.append("\(photos(missing.count)) skipped because the file is not on disk (use Remove from Library instead)") }
        let notFiles = r.skipped.filter { $0.reason == .notAFile }
        if !notFiles.isEmpty { parts.append("\(photos(notFiles.count)) skipped because they are folders or other non-files (use Remove from Library instead)") }
        if let stopped = r.stoppedBecause { parts.append("stopped early (\(stopped)) with \(photos(r.notAttempted)) left untouched") }
        if r.noLongerRejected > 0 { parts.append("\(photos(r.noLongerRejected)) skipped because they are no longer rejected") }
        if r.noAccess > 0 { parts.append("\(photos(r.noAccess)) skipped (folder access not granted)") }
        if !r.failed.isEmpty { parts.append("\(photos(r.failed.count)) could not be moved and stay in the Library (\(r.failed.first?.message ?? "unknown error"))") }
        if r.companionsFailed > 0 { parts.append("\(r.companionsFailed) edit / XMP file\(r.companionsFailed == 1 ? "" : "s") could not be moved") }
        if let error = r.catalogError { parts.append("the photos are in the Trash but the Library could not be updated (\(error)); remove them with Remove from Library") }
        return parts.joined(separator: "; ") + "."
    }
}
