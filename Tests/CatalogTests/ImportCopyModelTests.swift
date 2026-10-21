import XCTest
@testable import PhotoApp

@MainActor
final class ImportCopyModelTests: XCTestCase {
    private var root: URL!
    private var card: URL!
    private var dest: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var model: ImportCopyModel!
    private var suiteName = ""
    private var preferences: AppPreferences!
    private var panelAnswers: [URL?] = []
    private var panelCalls = 0
    private let busyBox = BusyBox()
    private var busy: String? {
        get { busyBox.value }
        set { busyBox.value = newValue }
    }
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("ImportCopyModelTests-\(UUID().uuidString)", isDirectory: true)
        card = root.appendingPathComponent("card", isDirectory: true)
        dest = root.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "ImportCopyModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        catalog = CatalogModel(database: db, defaults: defaults)
        preferences = AppPreferences(defaults: defaults)
        busy = nil
        panelAnswers = []
        panelCalls = 0
        makeModel()
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private let trashLog = TrashLog()

    private func makeModel(environment: ImportCopyEngine.Environment = .live) {
        let log = trashLog
        model = ImportCopyModel(
            preferences: preferences,
            chooseFolder: { [unowned self] _, _, _ in
                panelCalls += 1
                return panelAnswers.isEmpty ? nil : panelAnswers.removeFirst()
            },
            environment: environment,
            mover: { url in
                log.record(url)
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("ImportCopyModelTests-trash-\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: target) // a "Trash" in the temp folder, never the real one
                return target
            }
        )
    }

    private var providers: RenameProviders { RenameProviders(openPhotoPath: { nil }, busyReason: { [busyBox] in busyBox.value }) }

    @discardableResult
    private func photo(_ name: String, _ text: String = "x", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? card).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func beginAndWait() async throws {
        panelAnswers = [card]
        model.begin(providers: providers, catalog: catalog)
        try await waitUntil(model.setup != nil || model.statusMessage != nil)
    }

    private func copyAll(to destination: URL? = nil) async throws {
        panelAnswers = [destination ?? dest]
        model.chooseDestination()
        model.confirm(providers: providers, catalog: catalog)
        try await waitUntil(!model.isWorking && model.statusMessage != nil)
    }

    // MARK: begin

    func testBeginScansTheSourceAndOpensTheSheetAndMirrorsTheBusyFlag() async throws {
        try photo("b.jpg"); try photo("a.jpg"); try photo("sub/c.jpg"); try photo("notes.txt")
        panelAnswers = [card]
        model.begin(providers: providers, catalog: catalog)
        XCTAssertTrue(catalog.importCopyBusy, "scanning counts as busy")
        try await waitUntil(model.setup != nil)
        XCTAssertEqual(model.setup?.sources.count, 3)
        XCTAssertTrue(catalog.importCopyBusy, "the open sheet counts as busy")
        model.cancel()
        XCTAssertNil(model.setup)
        XCTAssertFalse(catalog.importCopyBusy)
    }

    func testBeginIsRefusedWhileAnotherToolIsBusyAndNoPanelOpens() async throws {
        try photo("a.jpg")
        busy = "A rename is running."
        try await beginAndWait()
        XCTAssertNil(model.setup)
        XCTAssertEqual(model.statusMessage, "A rename is running.")
        XCTAssertEqual(panelCalls, 0)
    }

    func testACancelledPanelDoesNothing() async throws {
        panelAnswers = [nil]
        model.begin(providers: providers, catalog: catalog)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.setup)
        XCTAssertNil(model.statusMessage)
        XCTAssertFalse(catalog.importCopyBusy)
    }

    func testAFolderWithoutPhotosSaysSo() async throws {
        try photo("notes.txt")
        try await beginAndWait()
        XCTAssertNil(model.setup)
        XCTAssertTrue(model.statusMessage?.contains("No photos") == true)
        XCTAssertFalse(catalog.importCopyBusy)
    }

    // MARK: the sheet

    func testTheDestinationCannotBeTheSourceFolder() async throws {
        try photo("a.jpg")
        try await beginAndWait()
        panelAnswers = [card]
        model.chooseDestination()
        XCTAssertNil(model.destination)
        XCTAssertNotNil(model.sheetError)
        XCTAssertFalse(model.canCopy)
    }

    func testTheDestinationCannotBeInsideTheSourceFolderEither() async throws {
        try photo("a.jpg")
        let inside = card.appendingPathComponent("Imported", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try await beginAndWait()
        panelAnswers = [inside]
        model.chooseDestination()
        XCTAssertNil(model.destination)
        XCTAssertNotNil(model.sheetError)
        XCTAssertNil(ImportCopyModel.destinationProblem(dest, source: card))
        XCTAssertNotNil(ImportCopyModel.destinationProblem(URL(fileURLWithPath: card.path.uppercased()), source: card), "case-insensitive")
    }

    func testCanCopyNeedsADestinationAndAValidTemplate() async throws {
        try photo("a.jpg")
        try await beginAndWait()
        XCTAssertFalse(model.canCopy)
        panelAnswers = [dest]
        model.chooseDestination()
        XCTAssertTrue(model.canCopy)
        model.options.renameTemplate = "{bogus}"
        XCTAssertFalse(model.canCopy)
    }

    func testThePreviewShowsTheFirstFinalPaths() async throws {
        try photo("a.jpg"); try photo("b.jpg")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.renameTemplate = "shot_{seq:2}"
        XCTAssertEqual(model.previewLines().count, 2)
        XCTAssertTrue(model.previewLines().allSatisfy { $0.contains("→ shot_") })
    }

    // MARK: run

    func testCopyingAddsVerifiedPhotosToTheLibraryAndLeavesTheSourceAlone() async throws {
        let a = try photo("a.jpg", "AAA"); let b = try photo("b.jpg", "BBB")
        try await beginAndWait()
        try await copyAll()
        let names = try await db.allPhotos().map(\.filename).sorted()
        XCTAssertEqual(names, ["a.jpg", "b.jpg"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.jpg")), Data("AAA".utf8))
        XCTAssertEqual(try Data(contentsOf: a), Data("AAA".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("BBB".utf8))
        XCTAssertTrue(model.statusMessage?.contains("Copied 2 photos") == true)
        XCTAssertTrue(model.statusMessage?.contains("original photos were not changed") == true)
        XCTAssertFalse(catalog.importCopyBusy)
        let collections = try await db.allCollections()
        XCTAssertTrue(collections.contains { $0.folderPath == dest.path })
    }

    func testConfirmIsRefusedWhileAnotherToolIsBusyAndKeepsTheSheet() async throws {
        try photo("a.jpg")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        busy = "Photos are being moved to the Trash — wait for it to finish."
        model.confirm(providers: providers, catalog: catalog)
        XCTAssertNotNil(model.setup)
        XCTAssertEqual(model.sheetError, busy)
        XCTAssertFalse(model.isWorking)
        let count = try await db.allPhotos().count
        XCTAssertEqual(count, 0)
    }

    func testAToolStartingMidRunStopsItAndTheRestIsLeftUntouched() async throws {
        try photo("a.jpg", "AAA"); try photo("b.jpg", "BBB"); try photo("c.jpg", "CCC")
        var environment = ImportCopyEngine.Environment.live
        let box = busyBox
        let flip: @Sendable () -> Void = { box.value = "Export is running." }
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            if source.lastPathComponent == "a.jpg" { flip() }
        }
        makeModel(environment: environment)
        try await beginAndWait()
        try await copyAll()
        let names = try await db.allPhotos().map(\.filename)
        XCTAssertEqual(names, ["a.jpg"], "only the photo copied before the other tool started is added")
        XCTAssertTrue(model.statusMessage?.contains("Stopped early") == true)
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("c.jpg").path))
    }

    func testAnIdenticalFileAlreadyInTheDestinationIsRegisteredEvenThoughItIsSkipped() async throws {
        try photo("a.jpg", "SAME")
        try photo("a.jpg", "SAME", in: dest) // an earlier, interrupted run copied it but the Library never heard
        try await beginAndWait()
        try await copyAll()
        let names = try await db.allPhotos().map(\.filename)
        XCTAssertEqual(names, ["a.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a (2).jpg").path))
    }

    func testTheOptionsUsedAreRememberedForNextTime() async throws {
        try photo("a.jpg")
        try await beginAndWait()
        model.options.subfolders = .isoDate
        model.options.renameTemplate = "{date}_{seq:3}"
        model.options.skipAlreadyCopied = false
        try await copyAll()
        let saved = preferences.importCopyOptions
        XCTAssertEqual(saved.subfolders, .isoDate)
        XCTAssertEqual(saved.renameTemplate, "{date}_{seq:3}")
        XCTAssertFalse(saved.skipAlreadyCopied)
    }

    func testStoredOptionsThatAreNoLongerValidFallBackToDefaults() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("nonsense", forKey: AppPreferences.Key.importCopySubfolders)
        defaults.set("", forKey: AppPreferences.Key.importCopyTemplate)
        XCTAssertEqual(AppPreferences(defaults: defaults).importCopyOptions, ImportCopyOptions())
    }

    // MARK: move (originals to the Trash)

    func testMoveAsksForTheConfirmationAndDoesNothingWithoutIt() async throws {
        let a = try photo("a.jpg", "AAA")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        model.confirm(providers: providers, catalog: catalog) // not confirmed
        XCTAssertTrue(model.confirmingMove)
        XCTAssertNotNil(model.setup, "the sheet stays open")
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(trashLog.urls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a.jpg").path), "nothing was copied either")
    }

    func testThePrimaryButtonOpensTheConfirmationInMoveModeAndRunsAtOnceInCopyMode() async throws {
        let a = try photo("a.jpg", "AAA")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        model.requestStart(providers: providers, catalog: catalog)
        XCTAssertTrue(model.confirmingMove)
        XCTAssertFalse(model.isWorking)
        model.cancel()
        XCTAssertFalse(model.confirmingMove)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    func testConfirmedMoveCopiesVerifiesAndSendsTheOriginalsToTheTrash() async throws {
        let a = try photo("a.jpg", "AAA"); let b = try photo("b.jpg", "BBB")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        model.confirm(providers: providers, catalog: catalog, moveConfirmed: true)
        try await waitUntil(!model.isWorking && model.statusMessage != nil)
        XCTAssertEqual(Set(trashLog.urls.map(\.lastPathComponent)), ["a.jpg", "b.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: a.path) || fm.fileExists(atPath: b.path))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.jpg")), Data("AAA".utf8))
        let names = try await db.allPhotos().map(\.filename).sorted()
        XCTAssertEqual(names, ["a.jpg", "b.jpg"], "the Library holds the copies")
        XCTAssertTrue(model.statusMessage?.contains("Moved 2 photos") == true)
        XCTAssertTrue(model.statusMessage?.contains("Nothing was permanently deleted") == true)
    }

    func testMoveIsNeverRememberedForTheNextRun() async throws {
        try photo("a.jpg", "AAA")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        model.confirm(providers: providers, catalog: catalog, moveConfirmed: true)
        try await waitUntil(!model.isWorking && model.statusMessage != nil)
        XCTAssertEqual(preferences.importCopyOptions.mode, .copy)
        try photo("c.jpg", "CCC")
        model.statusMessage = nil
        try await beginAndWait()
        XCTAssertEqual(model.options.mode, .copy, "the next sheet starts as Copy")
    }

    func testMoveRefusesPhotosThatAreAlreadyInTheLibraryAndChangesNothing() async throws {
        let a = try photo("a.jpg", "AAA")
        _ = try await db.importPhotos(at: [a]) // the card was imported in place earlier
        await catalog.refresh()
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        model.confirm(providers: providers, catalog: catalog, moveConfirmed: true)
        try await waitUntil(!model.isWorking && model.statusMessage != nil)
        XCTAssertTrue(model.statusMessage?.contains("already in the Library") == true)
        XCTAssertTrue(trashLog.urls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a.jpg").path), "nothing was copied")
    }

    func testMoveNeverTrashesThePhotoOpenInTheEditor() async throws {
        let a = try photo("a.jpg", "AAA"); let b = try photo("b.jpg", "BBB")
        try await beginAndWait()
        panelAnswers = [dest]
        model.chooseDestination()
        model.options.mode = .move
        let open = RenameProviders(openPhotoPath: { a.path }, busyReason: { nil })
        model.confirm(providers: open, catalog: catalog, moveConfirmed: true)
        try await waitUntil(!model.isWorking && model.statusMessage != nil)
        XCTAssertEqual(trashLog.urls.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertTrue(model.statusMessage?.contains("open in the Editor") == true)
    }

    func testMoveRefusesADestinationThatContainsTheSourceFolder() {
        let source = URL(fileURLWithPath: "/Lib/2026", isDirectory: true)
        XCTAssertNotNil(ImportCopyModel.destinationProblem(URL(fileURLWithPath: "/Lib"), source: source, mode: .move))
        XCTAssertNil(ImportCopyModel.destinationProblem(URL(fileURLWithPath: "/Lib"), source: source, mode: .copy), "Copy may")
        XCTAssertNil(ImportCopyModel.destinationProblem(URL(fileURLWithPath: "/Elsewhere"), source: source, mode: .move))
    }

    func testTheSheetIntroNeverPromisesTheOriginalsStayWhenMovingThem() {
        XCTAssertTrue(ImportCopyModel.sheetIntro(mode: .copy).contains("never changed or deleted"))
        XCTAssertFalse(ImportCopyModel.sheetIntro(mode: .move).contains("never changed or deleted"))
        XCTAssertTrue(ImportCopyModel.sheetIntro(mode: .move).contains("Trash"))
    }

    func testMoveConfirmationTextNamesTheFoldersAndStatesNothingIsPermanentlyDeleted() {
        XCTAssertEqual(ImportCopyModel.moveConfirmationTitle(count: 1), "Copy 1 photo, then move the originals to the Trash?")
        let message = ImportCopyModel.moveConfirmationMessage(source: "DCIM", destination: "Trip")
        XCTAssertTrue(message.contains("DCIM") && message.contains("Trip"))
        XCTAssertTrue(message.contains("Nothing is permanently deleted"))
    }

    func testTheDialogHasADestructiveConfirmationWithNoDefaultButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/UI/ImportCopyDialogModifier.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Button(\"Copy and Move to Trash\", role: .destructive)"))
        XCTAssertFalse(source.contains("defaultAction"), "Return must not confirm a destructive dialog")
        let prefs = try String(contentsOf: root.appendingPathComponent("Sources/Catalog/AppPreferences.swift"), encoding: .utf8)
        XCTAssertFalse(prefs.contains("importCopyMode"), "the Move choice is never stored")
    }

    func testTheMoveSummaryReportsMovedAndKeptOriginals() {
        var outcome = ImportCopyEngine.Outcome()
        outcome.copied = [URL(fileURLWithPath: "/d/a.jpg"), URL(fileURLWithPath: "/d/b.jpg")]
        outcome.movedToTrash = [URL(fileURLWithPath: "/c/a.jpg")]
        outcome.notMoved = [.init(source: URL(fileURLWithPath: "/c/b.jpg"), reason: "Could not move the original to the Trash: read-only")]
        outcome.companionsTrashed = 1
        let text = ImportCopyModel.summary(outcome, registered: .init(added: 2, accessWarning: nil, error: nil), mode: .move)
        XCTAssertTrue(text.contains("Moved 1 photo from the source folder to the Trash with 1 edit / XMP file."))
        XCTAssertTrue(text.contains("1 photo copied but NOT moved"))
        XCTAssertTrue(text.contains("b.jpg: Could not move the original to the Trash: read-only"))
        XCTAssertFalse(text.contains("Your original photos were not changed."))
    }

    // MARK: summary

    func testSummaryReportsEverythingAndAlwaysSaysTheOriginalsAreUnchanged() {
        var outcome = ImportCopyEngine.Outcome()
        outcome.copied = [URL(fileURLWithPath: "/d/a.jpg")]
        outcome.skippedIdentical = [URL(fileURLWithPath: "/c/b.jpg")]
        outcome.failed = [.init(source: URL(fileURLWithPath: "/c/c.jpg"), reason: "Copy failed")]
        outcome.stoppedEarly = true
        let text = ImportCopyModel.summary(outcome, registered: .init(added: 1, accessWarning: nil, error: nil))
        XCTAssertTrue(text.contains("Copied 1 photo"))
        XCTAssertTrue(text.contains("1 photo already there"))
        XCTAssertTrue(text.contains("c.jpg: Copy failed"))
        XCTAssertTrue(text.contains("Stopped early"))
        XCTAssertTrue(text.contains("Added 1 photo to the Library"))
        XCTAssertTrue(text.hasSuffix("Your original photos were not changed."))
    }

    func testSummaryWhenNothingWasCopiedOrTheLibraryWriteFailed() {
        XCTAssertTrue(ImportCopyModel.summary(.init(), registered: nil).contains("No photos were copied."))
        var outcome = ImportCopyEngine.Outcome()
        outcome.copied = [URL(fileURLWithPath: "/d/a.jpg")]
        let text = ImportCopyModel.summary(outcome, registered: .init(added: 0, accessWarning: nil, error: "disk full"))
        XCTAssertTrue(text.contains("could not be added to the Library: disk full"))
    }
}

/// What the injected "Trash" was asked to take.
private final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func record(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A tiny box a `@Sendable` test closure can flip to simulate another tool starting mid-run.
private final class BusyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
