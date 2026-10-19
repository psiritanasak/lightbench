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

    init(
        preferences: AppPreferences = .shared,
        chooseFolder: @escaping (String, String, Bool) -> URL? = ImportCopyModel.runPanel,
        environment: ImportCopyEngine.Environment = .live
    ) {
        self.preferences = preferences
        self.chooseFolder = chooseFolder
        self.environment = environment
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
        sheetError = Self.destinationProblem(folder, source: setup.sourceFolder)
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
        setup = nil
        destination = nil
        sheetError = nil
    }

    /// The destination may not be the source folder or anything inside it: that would write into the source tree.
    nonisolated static func destinationProblem(_ destination: URL, source: URL) -> String? {
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
        let d = key(destination), s = key(source)
        if d == s || d.hasPrefix(s + "/") { return "Choose a folder outside the one the photos come from." }
        return nil
    }

    // MARK: - Run

    func confirm(providers: RenameProviders, catalog: CatalogModel) {
        self.catalog = catalog
        guard let setup, let destination, canCopy else { return }
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
        // Built here, on the main actor, so the detached copy only calls back through these two closures.
        let gate: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.refusal(providers, catalog) == nil
        }
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.progressDone = done; self?.progressTotal = total }
        }
        let outcome = await Task.detached {
            await ImportCopyEngine.apply(plan: plan, skipAlreadyCopied: skip, environment: environment, gate: gate, progress: progress)
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
        statusMessage = Self.summary(outcome, registered: registered)
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

    nonisolated static func summary(_ outcome: ImportCopyEngine.Outcome, registered: Registration?) -> String {
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
        lines.append("Your original photos were not changed.")
        return lines.joined(separator: "\n")
    }
}
