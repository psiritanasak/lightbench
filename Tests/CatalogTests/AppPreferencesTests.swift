import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Every test uses its own `UserDefaults` suite (removed in tearDown): the test host is the real app, so `.standard` is the developer's.
@MainActor
final class AppPreferencesTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AppPreferencesTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: store

    func testDefaultsReproduceTheBehaviourBeforeThePreferencesExisted() {
        let prefs = AppPreferences(defaults: makeDefaults())
        XCTAssertTrue(prefs.cullAutoAdvance)
        XCTAssertTrue(prefs.cullStartUnflaggedOnly)
        XCTAssertTrue(prefs.autoReadXMPOnImport)
        XCTAssertEqual(prefs.backupsToKeep, 5)
        XCTAssertEqual(prefs.backupsToKeep, CatalogDatabase.defaultBackupsToKeep, "the launch backup's own default agrees")
    }

    func testValuesRoundTripThroughASecondStoreOnTheSameDefaults() {
        let defaults = makeDefaults()
        let prefs = AppPreferences(defaults: defaults)
        prefs.cullAutoAdvance = false
        prefs.cullStartUnflaggedOnly = false
        prefs.autoReadXMPOnImport = false
        prefs.backupsToKeep = 12
        let again = AppPreferences(defaults: defaults)
        XCTAssertFalse(again.cullAutoAdvance)
        XCTAssertFalse(again.cullStartUnflaggedOnly)
        XCTAssertFalse(again.autoReadXMPOnImport)
        XCTAssertEqual(again.backupsToKeep, 12)
    }

    func testShowPhotosInSubfoldersDefaultsToOffAndRoundTrips() {
        let defaults = makeDefaults()
        XCTAssertFalse(AppPreferences(defaults: defaults).showPhotosInSubfolders, "off by default: nothing changes for existing users")
        AppPreferences(defaults: defaults).showPhotosInSubfolders = true
        XCTAssertTrue(AppPreferences(defaults: defaults).showPhotosInSubfolders)
        XCTAssertEqual(AppPreferences.Key.showPhotosInSubfolders, "prefs.v1.showPhotosInSubfolders")
        defaults.set("yes", forKey: AppPreferences.Key.showPhotosInSubfolders)
        XCTAssertFalse(AppPreferences(defaults: defaults).showPhotosInSubfolders, "garbage falls back to the default")
    }

    func testGarbageInTheDefaultsFallsBackToTheDefaultsNeverCrashes() {
        let defaults = makeDefaults()
        defaults.set("yes", forKey: AppPreferences.Key.cullAutoAdvance)
        defaults.set(3.5, forKey: AppPreferences.Key.cullStartUnflaggedOnly)
        defaults.set(Data([1, 2]), forKey: AppPreferences.Key.autoReadXMPOnImport)
        defaults.set("many", forKey: AppPreferences.Key.backupsToKeep)
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.cullAutoAdvance)
        XCTAssertTrue(prefs.cullStartUnflaggedOnly)
        XCTAssertTrue(prefs.autoReadXMPOnImport)
        XCTAssertEqual(prefs.backupsToKeep, 5)
    }

    func testAnOutOfRangeStoredBackupCountIsIgnoredAndASettingIsClamped() {
        let defaults = makeDefaults()
        let prefs = AppPreferences(defaults: defaults)
        defaults.set(0, forKey: AppPreferences.Key.backupsToKeep)
        XCTAssertEqual(prefs.backupsToKeep, 5, "0 would delete every backup")
        defaults.set(-4, forKey: AppPreferences.Key.backupsToKeep)
        XCTAssertEqual(prefs.backupsToKeep, 5)
        defaults.set(10_000, forKey: AppPreferences.Key.backupsToKeep)
        XCTAssertEqual(prefs.backupsToKeep, 5)
        prefs.backupsToKeep = 0
        XCTAssertEqual(prefs.backupsToKeep, 1)
        prefs.backupsToKeep = 999
        XCTAssertEqual(prefs.backupsToKeep, 30)
    }

    func testTheSharedStoreInTheTestHostIsNotTheDevelopersRealPreferences() {
        XCTAssertTrue(CatalogDatabase.isRunningUnderXCTest)
        let probe = "prefs.v1.probe-\(UUID().uuidString)"
        AppPreferences.shared.defaults.set(true, forKey: probe)
        defer { AppPreferences.shared.defaults.removeObject(forKey: probe) }
        XCTAssertNil(UserDefaults.standard.object(forKey: probe), "shared must be an isolated suite under XCTest")
    }

    // MARK: the window's model

    func testThePreferencesModelStartsFromTheStoreAndWritesEveryChangeThrough() {
        let defaults = makeDefaults()
        let store = AppPreferences(defaults: defaults)
        store.cullAutoAdvance = false
        let model = PreferencesModel(store: store)
        XCTAssertFalse(model.cullAutoAdvance)
        XCTAssertTrue(model.autoReadXMPOnImport)
        model.cullAutoAdvance = true
        model.cullStartUnflaggedOnly = false
        model.autoReadXMPOnImport = false
        model.backupsToKeep = 9
        XCTAssertTrue(store.cullAutoAdvance)
        XCTAssertFalse(store.cullStartUnflaggedOnly)
        XCTAssertFalse(store.autoReadXMPOnImport)
        XCTAssertEqual(store.backupsToKeep, 9)
    }

    func testTheModelClampsTheBackupCountBothWays() {
        let store = AppPreferences(defaults: makeDefaults())
        let model = PreferencesModel(store: store)
        model.backupsToKeep = 0
        XCTAssertEqual(model.backupsToKeep, 1)
        XCTAssertEqual(store.backupsToKeep, 1)
        model.backupsToKeep = 500
        XCTAssertEqual(model.backupsToKeep, 30)
        XCTAssertEqual(store.backupsToKeep, 30)
    }

    // MARK: wiring: culling

    private func cullModel(prefs: AppPreferences, flags: [FlagStatus]) -> CullModel {
        var rows: [Int64: Photo] = [:]
        for (i, flag) in flags.enumerated() {
            let id = Int64(i + 1)
            rows[id] = Photo(id: id, path: "/tmp/prefs-cull-\(id).jpg", filename: "p\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                             rating: 0, flagStatus: flag, colorLabel: .none)
        }
        let model = CullModel()
        model.preferences = prefs
        model.configure(CullEnvironment(photos: { rows.keys.sorted().compactMap { rows[$0] } }, rows: { rows }))
        return model
    }

    func testACullPassStartsOnUnflaggedPhotosAndAdvancesByDefault() {
        let model = cullModel(prefs: AppPreferences(defaults: makeDefaults()), flags: [.none, .picked, .none])
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertTrue(model.onlyUnflagged)
        XCTAssertTrue(model.autoAdvance)
    }

    func testTurningOffUnflaggedOnlyStartsThePassOnEverything() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.cullStartUnflaggedOnly = false
        let model = cullModel(prefs: prefs, flags: [.none, .picked, .none])
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertFalse(model.onlyUnflagged)
        XCTAssertEqual(model.counts.picked, 1, "the flagged photo is in the pass")
        XCTAssertEqual(model.counts.unflagged, 2)
    }

    func testTurningOffAutoAdvanceReachesTheSession() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.cullAutoAdvance = false
        let model = cullModel(prefs: prefs, flags: [.none, .none])
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertFalse(model.autoAdvance)
    }

    func testWithTheUnflaggedPreferenceOffAPassStartsOnTheFlaggedPhotoItWasAskedFor() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.cullStartUnflaggedOnly = false
        let model = cullModel(prefs: prefs, flags: [.none, .picked, .none])
        XCTAssertTrue(model.begin(startingAtPath: "/tmp/prefs-cull-2.jpg"))
        XCTAssertEqual(model.current?.id, 2, "no unflagged-only adjustment of the start photo when the preference is off")
    }

    func testWithTheUnflaggedPreferenceOnTheStartMovesPastAFlaggedPhoto() {
        let model = cullModel(prefs: AppPreferences(defaults: makeDefaults()), flags: [.none, .picked, .none])
        XCTAssertTrue(model.begin(startingAtPath: "/tmp/prefs-cull-2.jpg"))
        XCTAssertEqual(model.current?.id, 3)
    }

    func testTheInPassToggleStillWorksWhenThePreferenceIsOffAndAutoAdvanceIsReadAgainPerPass() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.cullStartUnflaggedOnly = false
        let model = cullModel(prefs: prefs, flags: [.none, .picked, .none])
        XCTAssertTrue(model.begin(startingAtPath: nil))
        model.setOnlyUnflagged(true)
        XCTAssertTrue(model.onlyUnflagged)
        model.autoAdvance = false
        prefs.cullAutoAdvance = true
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertTrue(model.autoAdvance, "a new pass reads the preference again")
    }

    // MARK: wiring: XMP auto-read

    func testAutoReadOnImportIsSkippedWhenThePreferenceIsOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let db = try CatalogDatabase(inMemory: true)
        let catalog = CatalogModel(database: db, defaults: defaults)
        let url = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: url)
        _ = try await db.importPhotos(at: [url])
        try XMPSidecarStore.write(XMPLibraryFields(rating: 4, isRejected: false), forPhotoAt: url)

        AppPreferences(defaults: defaults).autoReadXMPOnImport = false
        await catalog.autoReadXMP(newerThan: [])
        let off = try await db.allPhotos().first?.rating
        XCTAssertEqual(off, 0, "with the preference off the import pass reads nothing")

        AppPreferences(defaults: defaults).autoReadXMPOnImport = true
        await catalog.autoReadXMP(newerThan: [])
        let on = try await db.allPhotos().first?.rating
        XCTAssertEqual(on, 4)
    }

    // MARK: wiring: backups

    private func backupsFolder() throws -> (root: URL, backups: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (dir, backups)
    }

    private func seed(_ kind: CatalogBackupKind, days: ClosedRange<Int>, in folder: URL) throws -> [String] {
        try days.map { day in
            let name = CatalogDatabase.backupFileName(kind, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400))
            try Data([1]).write(to: folder.appendingPathComponent(name))
            return name
        }
    }

    func testBackUpNowWritesAValidManualBackupAndPrunesOnlyTheManualPool() async throws {
        let (_, backups) = try backupsFolder()
        let defaults = makeDefaults()
        AppPreferences(defaults: defaults).backupsToKeep = 2
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: defaults)
        let manual = try seed(.manual, days: 1...3, in: backups)
        let daily = try seed(.automatic, days: 1...3, in: backups)
        let safety = try seed(.preMigration, days: 1...3, in: backups) + (try seed(.beforeRestore, days: 1...3, in: backups))

        let message = await catalog.backUpNow(into: backups)

        XCTAssertTrue(message.hasPrefix("Backed up as catalog-"), message)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        let written = try XCTUnwrap(names.first { $0.hasSuffix("-manual.sqlite") && !manual.contains($0) }, "the new manual file exists")
        XCTAssertNoThrow(try CatalogDatabase.inspectCatalogFile(at: backups.appendingPathComponent(written)), "and is a valid catalog")
        XCTAssertEqual(names.filter { $0.hasSuffix("-manual.sqlite") }.count, 2, "the manual pool is pruned to the preference")
        XCTAssertTrue(Set(daily).isSubset(of: names), "daily backups are never touched by Back Up Now")
        XCTAssertTrue(Set(safety).isSubset(of: names), "neither are the safety backups")
        XCTAssertFalse(catalog.backupBusy, "the busy flag is released")
    }

    func testRepeatedBackUpNowNeverPushesOutTheDailyBackups() async throws {
        let (_, backups) = try backupsFolder()
        let defaults = makeDefaults()
        AppPreferences(defaults: defaults).backupsToKeep = 1
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: defaults)
        let daily = try seed(.automatic, days: 1...5, in: backups)
        for _ in 0..<3 { _ = await catalog.backUpNow(into: backups) }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        XCTAssertTrue(Set(daily).isSubset(of: names))
    }

    func testThePruneNeverRemovesTheFileJustWrittenEvenWhenAFutureStampedOneSortsNewer() throws {
        let (_, backups) = try backupsFolder()
        let future = CatalogDatabase.backupFileName(.manual, at: Date(timeIntervalSince1970: 4_000_000_000))
        let fresh = CatalogDatabase.backupFileName(.manual, at: Date(timeIntervalSince1970: 1_800_000_000))
        try Data([1]).write(to: backups.appendingPathComponent(future))
        try Data([1]).write(to: backups.appendingPathComponent(fresh))
        CatalogDatabase.pruneBackups(in: backups, keepNewest: 1, kinds: [.manual], protecting: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appendingPathComponent(fresh).path))
    }

    func testTheLaunchPruneKeepsAtLeastFiveOfEachSafetyKindWhateverTheSettingIs() throws {
        let (_, backups) = try backupsFolder()
        let safety = try seed(.preMigration, days: 1...7, in: backups)
        let daily = try seed(.automatic, days: 1...7, in: backups)
        CatalogDatabase.pruneBackups(in: backups, keepNewest: 1, safetyKeepAtLeast: 5)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        XCTAssertEqual(names.filter { safety.contains($0) }.count, 5)
        XCTAssertEqual(names.filter { daily.contains($0) }.count, 1)
    }

    func testTheBackupDialogPublishingIdleDoesNotClearBackUpNowsClaim() throws {
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: makeDefaults())
        let dialog = CatalogBackupModel()
        dialog.seams.chooseDestination = { _ in nil } // a cancelled save panel: the request only attaches the catalog
        dialog.request(.backUp, catalog: catalog)
        catalog.backUpNowRunning = true
        catalog.backupBusy = true
        dialog.pendingRestore = nil // the dialog model publishes ITS state (idle)
        XCTAssertTrue(catalog.backupBusy, "Back Up Now's claim survives")
        catalog.backUpNowRunning = false
        dialog.pendingRestore = nil
        XCTAssertFalse(catalog.backupBusy, "and once it finishes the dialog's idle state wins")
    }

    func testBackUpNowRefusesWhileAnotherBackupRuns() async throws {
        let catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: makeDefaults())
        catalog.backupBusy = true
        let message = await catalog.backUpNow(into: FileManager.default.temporaryDirectory.appendingPathComponent("never-\(UUID().uuidString)"))
        XCTAssertEqual(message, "A backup is already running.")
        XCTAssertTrue(catalog.backupBusy, "it must not clear a flag it does not own")
    }

    // MARK: rendering

    func testThePreferencesWindowRendersItsContent() throws {
        let defaults = makeDefaults()
        let model = PreferencesModel(store: AppPreferences(defaults: defaults)) // every toggle on
        let view = PreferencesView(model: model, showPhotosInSubfolders: .constant(false), isBackupBusy: false, backUpNow: { "" }, backupsFolder: { nil }).tint(Theme.controlTint).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        // Only the text is checked: an offscreen, inactive window does not draw checked toggles in the tint colour, so a "never blue"
        // assertion here would pass even with a blue tint (verified by mutation). Grey controls are a live-check item (IMPROVEMENTS.md D69).
        var light = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.6, c.greenComponent > 0.6, c.blueComponent > 0.6 { light += 1 }
            }
        }
        XCTAssertGreaterThan(light, 200, "the window's text is drawn")
    }

    // MARK: wiring pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheSettingsSceneAndTheLaunchBackupUseThePreferences() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Settings {"))
        XCTAssertTrue(app.contains("PreferencesView(model: preferences, showPhotosInSubfolders: $catalog.showPhotosInSubfolders, isBackupBusy: catalog.backupBusy"))
        XCTAssertTrue(try source("Sources/Catalog/CatalogDatabase.swift").contains("keepNewest: AppPreferences.shared.backupsToKeep"))
        XCTAssertTrue(try source("Sources/Catalog/CatalogDatabase+Backup.swift").contains("safetyKeepAtLeast: defaultBackupsToKeep"), "the launch prune protects the safety backups")
    }
}
