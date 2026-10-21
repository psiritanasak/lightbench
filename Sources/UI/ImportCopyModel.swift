import AppKit
import Foundation

/// "Copy Photos into Library…": copy a folder of photos (an SD card, say) into a folder on this Mac, optionally into date subfolders and
/// renamed, verify every copy, and add them to the Library. Owned by `CatalogModel` like `xmp`/`trash`, so the Scene-level menus reach it;
/// `ImportCopyDialogModifier` presents the sheet, progress and result. The decisions are `ImportCopyPlan` (names, folders, sidecars) and
/// `ImportCopyEngine` (the verified copies); this class is the flow around them.
///
/// Safety rules (tested): the source is only READ; both folders are chosen in a panel (so the sandbox grants read / write for the run);
/// nothing starts while a rename, export, merge or any other file tool is busy, and that is checked again before every photo; only photos
/// whose verified copy reached the destination are added to the Library.
@MainActor
final class ImportCopyModel: ObservableObject {
    /// A scanned source, waiting for the user's options.
    struct Setup: Equatable {
        let sourceFolder: URL
        /// In copy order: capture time, then name (so `{seq}` counts chronologically).
        let sources: [ImportCopySource]
        var totalBytes: Int64 { sources.reduce(0) { $0 + $1.fileSize } }
    }

    @Published private(set) var setup: Setup? { didSet { publishBusy() } }
    @Published var options: ImportCopyOptions
    @Published private(set) var destination: URL?
    @Published private(set) var isScanning = false { didSet { publishBusy() } }
    @Published private(set) var isWorking = false { didSet { publishBusy() } }
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0
    @Published var statusMessage: String?
    /// Shown inside the sheet (a refusal that leaves the sheet open).
    @Published private(set) var sheetError: String?

    var isBusy: Bool { isScanning || isWorking || setup != nil }

    private weak var catalog: CatalogModel?
    private func publishBusy() { catalog?.importCopyBusy = isBusy }

    private let preferences: AppPreferences
    private let chooseFolder: (_ message: String, _ prompt: String, _ canCreate: Bool) -> URL?
    private let environment: ImportCopyEngine.Environment
    /// The only way an original leaves the source folder in Move mode (the Finder's Trash). Under XCTest the default refuses.
    private let mover: TrashEngine.Mover

    /// Move mode only: the sheet asks "Copy N photos, then move the originals to the Trash?" first (destructive role, no default button).
    @Published var confirmingMove = false

    init(
        preferences: AppPreferences = .shared,
        chooseFolder: @escaping (String, String, Bool) -> URL? = ImportCopyModel.runPanel,
        environment: ImportCopyEngine.Environment = .live,
        mover: @escaping TrashEngine.Mover = TrashEngine.systemTrash
    ) {
        self.preferences = preferences
        self.chooseFolder = chooseFolder
        self.environment = environment
        self.mover = mover
        options = preferences.importCopyOptions
    }

    nonisolated static func runPanel(message: String, prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Begin: choose and scan the source

    func begin(providers: RenameProviders, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isBusy else { return }
        if let reason = refusal(providers, catalog) { statusMessage = reason; return }
        guard let source = chooseFolder("Choose the folder to copy photos from (for example a memory card).", "Choose", false) else { return }
        isScanning = true
        // The panel's grant covers this launch; it must be held while the files are read.
        let accessing = source.startAccessingSecurityScopedResource()
        Task {
            defer { isScanning = false }
            let sources = await Task.detached { Self.scan(source) }.value
            if accessing { source.stopAccessingSecurityScopedResource() }
            if let reason = refusal(providers, catalog) { statusMessage = reason; return }
            guard !sources.isEmpty else { statusMessage = "No photos were found in “\(source.lastPathComponent)”."; return }
            options = preferences.importCopyOptions
            destination = nil
            sheetError = nil
            setup = Setup(sourceFolder: source, sources: sources)
        }
    }

    /// Every supported photo under `folder` (subfolders included, packages and symlinked folders skipped by `PhotoImporter`), with its
    /// capture date and size, sorted by capture time then name. Blocking file I/O: call off the main actor.
    nonisolated static func scan(_ folder: URL) -> [ImportCopySource] {
        guard let root = PhotoImporter.scanFolderTree(at: folder) else { return [] }
        func flatten(_ node: FolderScanNode) -> [URL] { node.imageFiles + node.children.flatMap(flatten) }
        let sources: [ImportCopySource] = flatten(root).map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            let fallback = (attributes?[.modificationDate] as? Date) ?? Date()
            return ImportCopySource(url: url, fileSize: size, captureDate: CaptureDate.read(from: url, fallback: fallback))
        }
        return sources.sorted {
            ($0.captureDate, $0.url.lastPathComponent.lowercased(), $0.url.path) < ($1.captureDate, $1.url.lastPathComponent.lowercased(), $1.url.path)
        }
    }

    // MARK: - The sheet

    func chooseDestination() {
        guard let setup, !isWorking else { return }
        guard let folder = chooseFolder("Choose (or create) the folder the photos are copied into.", "Choose", true) else { return }
        sheetError = Self.destinationProblem(folder, source: setup.sourceFolder, mode: options.mode)
        destination = sheetError == nil ? folder : nil
    }

    var templateError: NamingError? { NamingTemplate.validate(options.renameTemplate) }

    var canCopy: Bool { setup != nil && destination != nil && templateError == nil && !isWorking }

    /// The first few copies' final paths, relative to the destination, for the sheet's preview.
    func previewLines(limit: Int = 4) -> [String] {
        guard let setup, let destination, templateError == nil else { return [] }
        // No disk access here (this runs on every sheet redraw, possibly against a card): the names come from the pure rules alone.
        let offDisk = ImportCopyPlan.Environment(isRegularFile: { _ in true }, exists: { _ in false })
        let plan = ImportCopyPlan.make(sources: Array(setup.sources.prefix(limit)), destination: destination, options: options, environment: offDisk)
        return plan.items.map { item in
            let relative = item.destination.path.replacingOccurrences(of: destination.path + "/", with: "")
            if case .blocked(let reason) = item.kind { return "\(item.source.lastPathComponent) — \(reason)" }
            return "\(item.source.lastPathComponent) → \(relative)"
        }
    }

    func cancel() {
        guard !isWorking else { return }
        confirmingMove = false
        setup = nil
        destination = nil
        sheetError = nil
    }

    /// The destination may not be the source folder or anything inside it: that would write into the source tree. In Move mode it may not CONTAIN the
    /// source folder either (a planned destination folder could then be the source's own folder, and an original could be mistaken for its copy).
    nonisolated static func destinationProblem(_ destination: URL, source: URL, mode: ImportCopyOptions.Mode = .copy) -> String? {
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
        let d = key(destination), s = key(source)
        if d == s || d.hasPrefix(s + "/") { return "Choose a folder outside the one the photos come from." }
        if mode == .move, s.hasPrefix(d + "/") { return "To move photos, choose a destination that does not contain the folder they come from." }
        return nil
    }

    // MARK: - Run

    /// What the sheet's primary button calls: Copy runs at once; Move asks for the destructive confirmation first.
    func requestStart(providers: RenameProviders, catalog: CatalogModel) {
        guard canCopy else { return }
        if options.mode == .move {
            if let setup, let destination, let problem = Self.destinationProblem(destination, source: setup.sourceFolder, mode: .move) { sheetError = problem; return }
            confirmingMove = true
        } else {
            confirm(providers: providers, catalog: catalog)
        }
    }

    /// `moveConfirmed` must be true for Move mode (only the confirmation dialog's destructive button passes it): without it a Move request
    /// is turned into the confirmation, so no wiring slip can start trashing originals unasked.
    func confirm(providers: RenameProviders, catalog: CatalogModel, moveConfirmed: Bool = false) {
        self.catalog = catalog
        guard let setup, let destination, canCopy else { return }
        // The mode may have been switched after the destination was chosen.
        if let problem = Self.destinationProblem(destination, source: setup.sourceFolder, mode: options.mode) { sheetError = problem; confirmingMove = false; return }
        if options.mode == .move, !moveConfirmed { confirmingMove = true; return }
        confirmingMove = false
        if let reason = refusal(providers, catalog) { sheetError = reason; return }
        let chosen = options
        preferences.importCopyOptions = chosen
        self.setup = nil
        isWorking = true
        progressDone = 0
        progressTotal = setup.sources.count
        Task {
            defer { isWorking = false; self.destination = nil }
            await run(setup: setup, destination: destination, options: chosen, providers: providers, catalog: catalog)
        }
    }

    private func refusal(_ providers: RenameProviders, _ catalog: CatalogModel) -> String? {
        if catalog.isRenameInProgress { return CatalogModel.renameInProgressMessage }
        return providers.busyReason()
    }

    private func run(setup: Setup, destination: URL, options: ImportCopyOptions, providers: RenameProviders, catalog: CatalogModel) async {
        let readScope = setup.sourceFolder.startAccessingSecurityScopedResource()
        let writeScope = destination.startAccessingSecurityScopedResource()
        defer {
            if readScope { setup.sourceFolder.stopAccessingSecurityScopedResource() }
            if writeScope { destination.stopAccessingSecurityScopedResource() }
        }

        let plan = await Task.detached { ImportCopyPlan.make(sources: setup.sources, destination: destination, options: options) }.value
        if let error = plan.templateError { statusMessage = error.errorDescription ?? "The name template is not valid."; return }
        if plan.copyItems.isEmpty { statusMessage = Self.summary(Self.emptyOutcome(blocked: plan), registered: nil); return }
        let environment = self.environment
        if let problem = ImportCopyEngine.spaceProblem(plan: plan, destination: destination, environment: environment) {
            statusMessage = problem
            return
        }
        if let reason = refusal(providers, catalog) { statusMessage = reason; return }

        let skip = options.skipAlreadyCopied
        let mode = options.mode
        let mover = self.mover
        if mode == .move {
            // Photos already in the Library must not be moved away from their rows (that would leave rows pointing at missing files):
            // Library photos are trashed with "Move Rejected / Selected to Trash…", which also removes their rows.
            func canonical(_ path: String) -> String {
                URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            }
            let known = Set((await catalog.cataloguedPathOwners()).keys.map(canonical))
            let inLibrary = plan.copyItems.filter { known.contains(canonical($0.source.path)) }
            if !inLibrary.isEmpty {
                statusMessage = "\(inLibrary.count) of these photos are already in the Library, so they cannot be moved away from it from here. Use Copy, or trash them from the Library (Photo ▸ Move Selected to Trash…). Nothing was copied or moved."
                return
            }
        }
        // `.move` only: the photo open in the Editor is copied but never trashed.
        let isProtected: @MainActor @Sendable (URL) -> Bool = { url in providers.openPhotoPath().map { TrashPlan.samePhoto($0, url.path) } ?? false }
        // Built here, on the main actor, so the detached copy only calls back through these two closures.
        let gate: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.refusal(providers, catalog) == nil
        }
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.progressDone = done; self?.progressTotal = total }
        }
        let outcome = await Task.detached {
            await ImportCopyEngine.apply(
                plan: plan, skipAlreadyCopied: skip, mode: mode, environment: environment, mover: mover, isProtected: isProtected, gate: gate, progress: progress
            )
        }.value

        var registered: Registration?
        // Identical files that were already there are registered too: an earlier run may have copied them and then stopped before the Library
        // heard about them (registering twice is harmless).
        let toRegister = outcome.copied + outcome.skippedDestinations
        if !toRegister.isEmpty {
            do {
                let (result, warning) = try await catalog.registerCopiedPhotos(toRegister, under: destination)
                registered = Registration(added: result.inserted, accessWarning: warning, error: nil)
            } catch {
                registered = Registration(added: 0, accessWarning: nil, error: error.localizedDescription)
            }
        }
        statusMessage = Self.summary(outcome, registered: registered, mode: mode)
    }

    // MARK: - Summary (pure, testable)

    struct Registration: Equatable {
        let added: Int
        let accessWarning: String?
        let error: String?
    }

    nonisolated static func emptyOutcome(blocked plan: ImportCopyPlan) -> ImportCopyEngine.Outcome {
        var outcome = ImportCopyEngine.Outcome()
        for item in plan.blockedItems {
            if case .blocked(let reason) = item.kind { outcome.blocked.append(.init(source: item.source, reason: reason)) }
        }
        return outcome
    }

    nonisolated static func summary(
        _ outcome: ImportCopyEngine.Outcome, registered: Registration?, mode: ImportCopyOptions.Mode = .copy
    ) -> String {
        func photos(_ n: Int) -> String { "\(n) photo" + (n == 1 ? "" : "s") }
        var lines: [String] = []
        if outcome.copied.isEmpty {
            lines.append("No photos were copied.")
        } else {
            lines.append("Copied \(photos(outcome.copied.count)) and checked each copy against the original.")
        }
        if !outcome.skippedIdentical.isEmpty { lines.append("\(photos(outcome.skippedIdentical.count)) already there (identical), skipped.") }
        if !outcome.failed.isEmpty {
            let first = outcome.failed.prefix(3).map { "\($0.source.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            lines.append("\(photos(outcome.failed.count)) could not be copied:\n\(first)" + (outcome.failed.count > 3 ? "\n…" : ""))
        }
        if !outcome.blocked.isEmpty { lines.append("\(photos(outcome.blocked.count)) skipped (not copyable files).") }
        if !outcome.companionFailures.isEmpty {
            lines.append("\(outcome.companionFailures.count) edit / XMP file\(outcome.companionFailures.count == 1 ? "" : "s") could not be copied alongside.")
        }
        if outcome.stoppedEarly { lines.append("Stopped early because another task started; the rest were left untouched.") }
        if let registered {
            if let error = registered.error {
                lines.append("The files were copied but could not be added to the Library: \(error)")
            } else {
                lines.append("Added \(photos(registered.added)) to the Library.")
                if let warning = registered.accessWarning { lines.append(warning) }
            }
        }
        if mode == .move {
            if !outcome.movedToTrash.isEmpty {
                var text = "Moved \(photos(outcome.movedToTrash.count)) from the source folder to the Trash"
                if outcome.companionsTrashed > 0 { text += " with \(outcome.companionsTrashed) edit / XMP file" + (outcome.companionsTrashed == 1 ? "" : "s") }
                lines.append(text + ".")
            }
            if !outcome.notMoved.isEmpty {
                let first = outcome.notMoved.prefix(3).map { "\($0.source.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
                lines.append("\(photos(outcome.notMoved.count)) copied but NOT moved (still in the source folder):\n\(first)" + (outcome.notMoved.count > 3 ? "\n…" : ""))
            }
            if outcome.companionsNotTrashed > 0 {
                lines.append("\(outcome.companionsNotTrashed) edit / XMP file\(outcome.companionsNotTrashed == 1 ? "" : "s") stayed in the source folder.")
            }
            lines.append("Nothing was permanently deleted: the originals are in the Trash (a memory card keeps them in its own Trash while it is mounted — use Put Back in the Finder to restore one).")
        } else {
            lines.append("Your original photos were not changed.")
        }
        return lines.joined(separator: "\n")
    }

    /// The sheet's one-line promise about the originals, which must match the chosen mode.
    nonisolated static func sheetIntro(mode: ImportCopyOptions.Mode) -> String {
        switch mode {
        case .copy: return "Every copy is checked against the original before it is added; the originals are never changed or deleted."
        case .move: return "Every copy is checked against the original before it is added; each original then goes to the Trash (Move mode)."
        }
    }

    nonisolated static func moveConfirmationTitle(count: Int) -> String {
        "Copy \(count) photo\(count == 1 ? "" : "s"), then move the originals to the Trash?"
    }

    nonisolated static func moveConfirmationMessage(source: String, destination: String) -> String {
        "Each photo from “\(source)” is copied to “\(destination)”, flushed to the destination disk and checked against the original. Only then is the original — with its edit file and XMP — moved to the Trash. A photo whose copy cannot be confirmed, or whose edit / XMP files did not all arrive, stays where it is.\n\nNothing is permanently deleted: the Finder's Trash has a Put Back command."
    }
}
