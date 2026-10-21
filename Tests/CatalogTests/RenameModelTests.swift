import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoApp

/// `RenameModel` end to end against REAL files and an in-memory catalog. Only the folder-access flow
/// (an `NSOpenPanel` + security scopes) is replaced, via the model's `acquireWriteAccess` test seam.
@MainActor
final class RenameModelTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var model: RenameModel!
    private var suiteName: String!

    private var busyReason: String?
    private var openPath: String?
    private var accessRequests = 0
    private var grantAccess = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "RenameModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        model = RenameModel()
        busyReason = nil
        openPath = nil
        accessRequests = 0
        grantAccess = true
        model.acquireWriteAccess = { [unowned self] _ in
            accessRequests += 1
            return grantAccess ? RenameModel.WriteAccess(release: {}) : nil
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private var providers: RenameProviders {
        RenameProviders(openPhotoPath: { [unowned self] in openPath }, busyReason: { [unowned self] in busyReason })
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func read(_ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Real files (content = upper-cased stem) + sidecars, catalogued; returns photos in the given order.
    private func makePhotos(_ names: [String]) async throws -> [Photo] {
        for name in names {
            let stem = (name as NSString).deletingPathExtension.uppercased()
            try Data(stem.utf8).write(to: dir.appendingPathComponent(name))
            try Data("sidecar-of-\(stem)".utf8).write(to: dir.appendingPathComponent(name + ".photoapp.json"))
        }
        _ = try await db.importPhotos(at: names.map { dir.appendingPathComponent($0) })
        let byName = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.filename, $0) })
        return try names.map { try XCTUnwrap(byName[$0]) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func beginAndSettle(_ photos: [Photo], template: String? = nil) async throws {
        model.begin(photos: photos, catalog: catalog, providers: providers)
        if let template { model.template = template }
        // begin() fetches the catalog's path owners asynchronously; wait until that has landed.
        try await waitUntil("catalog path owners") { !self.model.isLoadingOwners }
    }

    private func applyAndWait() async throws {
        model.apply()
        try await waitUntil("apply to finish") { !self.model.isWorking }
    }

    // MARK: Opening

    func testBeginRefusesWhileBusyAndDoesNotPresentTheSheet() async throws {
        let photos = try await makePhotos(["a.jpg"])
        busyReason = "An export is running — wait for it to finish."
        model.begin(photos: photos, catalog: catalog, providers: providers)
        XCTAssertFalse(model.isPresentingSheet)
        XCTAssertEqual(model.statusMessage, "An export is running — wait for it to finish.")
    }

    func testBeginWithNothingSelectedSaysSo() {
        model.begin(photos: [], catalog: catalog, providers: providers)
        XCTAssertFalse(model.isPresentingSheet)
        XCTAssertNotNil(model.statusMessage)
    }

    // MARK: Preview

    func testThePreviewFollowsTheTemplateAndStartNumber() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(photos, template: "Trip_{seq:2}")
        XCTAssertEqual(model.plan?.entries.compactMap(\.newName), ["Trip_01.jpg", "Trip_02.jpg"])
        model.sequenceStartText = "10"
        XCTAssertEqual(model.plan?.entries.compactMap(\.newName), ["Trip_10.jpg", "Trip_11.jpg"])
        XCTAssertTrue(model.plan?.isApplicable ?? false)
    }

    func testAnInvalidTemplateOrStartNumberClearsThePlanAndExplainsWhy() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "{bogus}")
        XCTAssertNil(model.plan)
        XCTAssertEqual(model.templateError, .unknownToken("bogus"))
        model.template = "ok_{seq}"
        XCTAssertNil(model.templateError)
        XCTAssertNotNil(model.plan)
        model.sequenceStartText = "-3"
        XCTAssertNil(model.plan)
        XCTAssertNotNil(model.sequenceStartMessage)
    }

    func testAPhotoOpenInTheEditorIsBlockedInThePreview() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        openPath = path("b.jpg")
        try await beginAndSettle(photos, template: "n_{seq}")
        XCTAssertEqual(model.plan?.entries.last?.decision, .blocked(.openInEditor))
        XCTAssertFalse(model.plan?.isApplicable ?? true)
    }

    func testADateTokenReadsCaptureDatesOnceThenPlansWithThem() async throws {
        let photos = try await makePhotos(["a.jpg"])
        // Give the fixture a real EXIF capture date.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: photos[0].path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:12:25 08:30:00"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        try await beginAndSettle(photos, template: "{date}_{seq}")
        try await waitUntil("capture dates") { !self.model.isLoadingDates }
        XCTAssertEqual(model.plan?.entries.first?.newName, "2024-12-25_001.jpg")
    }

    // MARK: Apply

    func testApplyRenamesFilesSidecarsAndCatalogThenUndoRestoresEverything() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(photos, template: "Trip_{seq}")

        try await applyAndWait()

        XCTAssertFalse(model.isPresentingSheet)
        XCTAssertEqual(read("Trip_001.jpg"), "A")
        XCTAssertEqual(read("Trip_002.jpg.photoapp.json"), "sidecar-of-B")
        XCTAssertNil(read("a.jpg"))
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(model.statusMessage?.contains("Renamed 2 photos") ?? false, "\(String(describing: model.statusMessage))")
        let rows = try await db.allPhotos().map(\.filename).sorted()
        XCTAssertEqual(rows, ["Trip_001.jpg", "Trip_002.jpg"])

        model.statusMessage = nil
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }

        XCTAssertEqual(read("a.jpg"), "A")
        XCTAssertEqual(read("b.jpg.photoapp.json"), "sidecar-of-B")
        XCTAssertNil(read("Trip_001.jpg"))
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.statusMessage?.contains("Restored 2 photos") ?? false, "\(String(describing: model.statusMessage))")
    }

    func testApplyIsSingleFlight() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(photos, template: "x_{seq}")
        model.apply()
        XCTAssertTrue(model.isWorking) // flipped synchronously, before any await
        model.apply() // a double-click
        model.apply()
        try await waitUntil("apply to finish") { !self.model.isWorking }
        XCTAssertEqual(accessRequests, 1) // exactly ONE batch ran
        XCTAssertEqual(read("x_001.jpg"), "A")
    }

    func testApplyRefusesWhenSomethingBecameBusyAfterThePreview() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        busyReason = "Enhance is running — wait for it to finish."
        try await applyAndWait()
        XCTAssertEqual(model.sheetError, "Enhance is running — wait for it to finish.")
        XCTAssertNotNil(read("a.jpg"))
        XCTAssertEqual(accessRequests, 0)
    }

    func testApplyRefusesWhenThePhotoWasOpenedInTheEditorAfterThePreview() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        openPath = path("a.jpg") // the user opened it while the sheet was up
        try await applyAndWait()
        XCTAssertTrue(model.sheetError?.contains("changed") ?? false, "\(String(describing: model.sheetError))")
        XCTAssertNotNil(read("a.jpg"))
        XCTAssertTrue(model.isPresentingSheet) // stays open so the user can react
    }

    func testApplyRefusesWhenTheDiskChangedSinceThePreview() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "taken")
        try Data("someone else".utf8).write(to: dir.appendingPathComponent("taken.jpg")) // appeared after the preview
        try await applyAndWait()
        XCTAssertTrue(model.sheetError?.contains("changed") ?? false, "\(String(describing: model.sheetError))")
        XCTAssertEqual(read("taken.jpg"), "someone else") // never overwritten
        XCTAssertNotNil(read("a.jpg"))
    }

    func testADeclinedFolderGrantRenamesNothingAndReleasesTheLock() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        grantAccess = false
        try await applyAndWait()
        XCTAssertNotNil(read("a.jpg"))
        XCTAssertNil(read("new.jpg"))
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.canUndo)
    }

    func testCancelClosesTheSheet() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos)
        model.cancel()
        XCTAssertFalse(model.isPresentingSheet)
    }

    // MARK: Undo guards

    func testUndoWithNothingLoggedSaysSo() async throws {
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertEqual(model.statusMessage, "There is no rename to undo.")
    }

    func testUndoRefusesWhileAPhotoFromTheBatchIsOpenInTheEditor() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        try await applyAndWait()
        model.statusMessage = nil
        openPath = path("new.jpg")
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertTrue(model.statusMessage?.contains("Editor") ?? false, "\(String(describing: model.statusMessage))")
        XCTAssertNotNil(read("new.jpg")) // nothing moved
        XCTAssertTrue(model.canUndo)
    }

    func testUndoRefusesWhileBusyAndNeedsFolderAccessLikeApply() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        try await applyAndWait()

        busyReason = "A photo is still loading — try again in a moment."
        model.statusMessage = nil
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertEqual(model.statusMessage, "A photo is still loading — try again in a moment.")

        busyReason = nil
        grantAccess = false
        model.statusMessage = nil
        let before = accessRequests
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertEqual(accessRequests, before + 1) // undo asked for write access too
        XCTAssertNotNil(read("new.jpg")) // declined: still renamed
    }

    func testRefreshCanUndoFollowsTheLog() async throws {
        await model.refreshCanUndo(catalog: catalog)
        XCTAssertFalse(model.canUndo)
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        try await applyAndWait()
        model.statusMessage = nil
        let fresh = RenameModel()
        await fresh.refreshCanUndo(catalog: catalog)
        XCTAssertTrue(fresh.canUndo)
    }

    // MARK: Re-checks AFTER the folder prompt (commit-4 review)

    /// While a modal folder prompt is up, scheduled main-actor work keeps running. The seam flips state
    /// from INSIDE `acquireWriteAccess`, so these fail if the check is ever moved back before the prompt.
    func testApplyRefusesWhenSomethingBecameBusyDuringTheFolderPrompt() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        model.acquireWriteAccess = { [unowned self] _ in
            busyReason = "A photo is still loading — try again in a moment." // a load started during the prompt
            return RenameModel.WriteAccess(release: {})
        }
        try await applyAndWait()
        XCTAssertEqual(model.sheetError, "A photo is still loading — try again in a moment.")
        XCTAssertNotNil(read("a.jpg"))
        XCTAssertNil(read("new.jpg"))
        XCTAssertFalse(model.canUndo)
    }

    func testApplyRefusesWhenThePhotoWasOpenedDuringTheFolderPrompt() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        model.acquireWriteAccess = { [unowned self] _ in
            openPath = path("a.jpg")
            return RenameModel.WriteAccess(release: {})
        }
        try await applyAndWait()
        XCTAssertTrue(model.sheetError?.contains("changed while waiting") ?? false, "\(String(describing: model.sheetError))")
        XCTAssertNotNil(read("a.jpg"))
    }

    func testUndoRefusesWhenSomethingBecameBusyOrTheEditorOpenedAPhotoDuringTheFolderPrompt() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        try await applyAndWait()

        model.acquireWriteAccess = { [unowned self] _ in
            busyReason = "An export is running — wait for it to finish."
            return RenameModel.WriteAccess(release: {})
        }
        model.statusMessage = nil
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertEqual(model.statusMessage, "An export is running — wait for it to finish.")
        XCTAssertNotNil(read("new.jpg"))

        busyReason = nil
        model.acquireWriteAccess = { [unowned self] _ in
            openPath = path("new.jpg")
            return RenameModel.WriteAccess(release: {})
        }
        model.statusMessage = nil
        model.undo(catalog: catalog, providers: providers)
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertEqual(model.statusMessage, RenameBlock.openInEditor.message)
        XCTAssertNotNil(read("new.jpg")) // still renamed
        XCTAssertNil(read("a.jpg"))
    }

    /// D43: with the sheet on screen the success alert is held until the sheet has disappeared (never timed, never lost).
    func testTheSuccessAlertWaitsForTheSheetToDisappear() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(photos, template: "Trip_{seq}")
        model.sheetDidAppear()
        try await applyAndWait()
        XCTAssertNil(model.statusMessage, "raised while the sheet was still up")
        XCTAssertNotNil(model.pendingStatusMessage)
        model.sheetDidDisappear()
        XCTAssertNil(model.statusMessage, "delivered one run-loop turn after the sheet is gone, not inside onDisappear")
        try await waitUntil("the held alert") { self.model.statusMessage != nil }
        XCTAssertTrue(model.statusMessage?.contains("Renamed 2 photos") ?? false, "\(String(describing: model.statusMessage))")
        XCTAssertNil(model.pendingStatusMessage)
    }

    func testAHeldAlertIsDroppedWhenTheNextRenameBegins() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(photos, template: "Trip_{seq}")
        model.sheetDidAppear()
        try await applyAndWait()
        XCTAssertNotNil(model.pendingStatusMessage)
        model.sheetDidDisappear()
        model.statusMessage = nil
        model.begin(photos: photos, catalog: catalog, providers: providers)
        XCTAssertNil(model.pendingStatusMessage)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.statusMessage, "a stale message must not pop up after the next sheet opens")
    }

    // MARK: Opening, loading state, races

    func testBeginWhileTheSheetIsAlreadyOpenIsIgnored() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(Array(photos.prefix(1)))
        model.sheetDidAppear() // the sheet is genuinely on screen
        model.begin(photos: photos, catalog: catalog, providers: providers) // e.g. the Photo menu again
        XCTAssertEqual(model.photoCount, 1) // the open sheet keeps its original selection
    }

    func testTheRenameButtonWaitsForTheLibraryCheck() async throws {
        let photos = try await makePhotos(["a.jpg"])
        model.begin(photos: photos, catalog: catalog, providers: providers)
        model.template = "new"
        XCTAssertTrue(model.isLoadingOwners)
        XCTAssertFalse(model.canApply) // path owners not loaded yet
        try await waitUntil("catalog path owners") { !self.model.isLoadingOwners }
        XCTAssertTrue(model.canApply)
    }

    func testACataloguedPhotoWhoseFileIsMissingStillOwnsItsPath() async throws {
        let photos = try await makePhotos(["a.jpg", "ghost.jpg"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("ghost.jpg")) // row stays, file is gone
        try FileManager.default.removeItem(at: dir.appendingPathComponent("ghost.jpg.photoapp.json")) // and its edit file
        try await beginAndSettle([photos[0]], template: "ghost")
        XCTAssertEqual(model.plan?.entries.first?.decision, .blocked(.targetCatalogued))
        XCTAssertFalse(model.canApply)
    }

    /// `/tmp` vs `/private/tmp`-style spellings of the SAME file must still count as "open in the Editor".
    func testAPhotoOpenedViaASymlinkedPathIsStillRecognisedAsOpen() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("RenameModelTests-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        openPath = link.appendingPathComponent("a.jpg").path // a different spelling of the same file
        try await beginAndSettle(photos, template: "new")
        XCTAssertEqual(model.plan?.entries.first?.decision, .blocked(.openInEditor))
    }

    // MARK: Sheet lifecycle, catalog lock, error routing (commit-4 review, round 2)

    /// SwiftUI drops a presentation made while another is up: `isPresentingSheet` would stay true forever.
    func testASheetThatNeverAppearedDoesNotBlockTheNextBegin() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await beginAndSettle(Array(photos.prefix(1))) // presented, but `sheetDidAppear` is never called
        model.begin(photos: photos, catalog: catalog, providers: providers)
        XCTAssertEqual(model.photoCount, 2)
        // Re-presented on the NEXT main-queue turn (false -> true in one pass would be coalesced by SwiftUI).
        XCTAssertFalse(model.isPresentingSheet)
        try await waitUntil("the sheet to be re-presented") { self.model.isPresentingSheet }
    }

    func testTheSheetDisappearingResetsThePresentedState() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos)
        model.sheetDidAppear()
        model.sheetDidDisappear()
        XCTAssertFalse(model.isPresentingSheet)
        XCTAssertFalse(model.sheetIsVisible)
    }

    func testTheCatalogIsLockedForTheWholeApplyAndUndoThenUnlocked() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        var lockedDuringApply = false
        model.acquireWriteAccess = { [unowned self] _ in
            lockedDuringApply = catalog.isRenameInProgress
            return RenameModel.WriteAccess(release: {})
        }
        try await applyAndWait()
        XCTAssertTrue(lockedDuringApply)
        XCTAssertFalse(catalog.isRenameInProgress)

        var lockedDuringUndo = false
        model.acquireWriteAccess = { [unowned self] _ in
            lockedDuringUndo = catalog.isRenameInProgress
            return RenameModel.WriteAccess(release: {})
        }
        model.undo(catalog: catalog, providers: providers)
        XCTAssertTrue(catalog.isRenameInProgress) // flipped synchronously, like isWorking
        try await waitUntil("undo to finish") { !self.model.isWorking }
        XCTAssertTrue(lockedDuringUndo)
        XCTAssertFalse(catalog.isRenameInProgress)
    }

    func testTheCatalogIsUnlockedEvenWhenApplyIsRefused() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        grantAccess = false
        try await applyAndWait()
        XCTAssertFalse(catalog.isRenameInProgress)
    }

    /// Import/locate/remove could insert or repoint rows at paths the batch is about to claim.
    func testCatalogMutatorsRefuseWhileARenameIsInProgress() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let a = photos[0]
        catalog.isRenameInProgress = true

        catalog.importFolder() // must return BEFORE showing any file panel
        XCTAssertEqual(catalog.importStatusMessage, CatalogModel.renameInProgressMessage)
        catalog.importStatusMessage = nil
        catalog.importFolderTree()
        XCTAssertEqual(catalog.importStatusMessage, CatalogModel.renameInProgressMessage)
        catalog.importStatusMessage = nil
        await catalog.relocatePhoto(a)
        XCTAssertEqual(catalog.importStatusMessage, CatalogModel.renameInProgressMessage)
        catalog.importStatusMessage = nil
        await catalog.relocateSelectedPhotos()
        XCTAssertEqual(catalog.importStatusMessage, CatalogModel.renameInProgressMessage)

        catalog.removePhoto(a)
        try await Task.sleep(nanoseconds: 200_000_000) // removePhoto's DB delete is fire-and-forget
        let remaining = try await db.allPhotos()
        XCTAssertEqual(remaining.count, 1) // NOT removed

        catalog.isRenameInProgress = false
        XCTAssertEqual(catalog.importsInFlight, 0)
        XCTAssertFalse(catalog.isImporting)
    }

    /// If the sheet vanished mid-apply, a failure (possibly "files couldn't be put back — use Locate…")
    /// must still reach the user — as an alert, not as an unseen sheet error.
    func testAFailureAfterTheSheetVanishedIsReportedAsAnAlert() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        model.acquireWriteAccess = { [unowned self] _ in
            model.sheetDidDisappear() // the sheet goes away during the folder prompt...
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("a.jpg")) // ...and the file vanishes
            return RenameModel.WriteAccess(release: {})
        }
        try await applyAndWait()
        XCTAssertNotNil(model.statusMessage) // shown as an alert
        XCTAssertNil(model.sheetError)
    }

    /// The CATCH path (not just the early refusals): the failure happens inside `applyRename`, after every
    /// check passed — here the folder turns read-only at the post-prompt re-check — while the sheet is gone.
    func testAnApplyFailureInsideTheEngineAfterTheSheetVanishedIsAnAlert() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await beginAndSettle(photos, template: "new")
        var openPathCalls = 0
        let folder = dir!
        let sabotaging = RenameProviders(
            openPhotoPath: { [unowned self] in
                openPathCalls += 1
                // Calls: apply's early check (1), the post-prompt re-check (2). Break the folder RIGHT AFTER the
                // last check the model can still see, and make the sheet disappear.
                if openPathCalls == 2 {
                    model.sheetDidDisappear()
                    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
                }
                return nil
            },
            busyReason: { nil }
        )
        model.cancel() // re-open the sheet with the sabotaging providers installed
        model.begin(photos: photos, catalog: catalog, providers: sabotaging)
        model.template = "new"
        try await waitUntil("catalog path owners") { !self.model.isLoadingOwners }
        openPathCalls = 0
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        try await applyAndWait()

        XCTAssertNil(model.sheetError)
        XCTAssertTrue(model.statusMessage?.contains("Renaming failed") ?? false, "\(String(describing: model.statusMessage))")
        XCTAssertFalse(model.isPresentingSheet)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertNotNil(read("a.jpg")) // nothing lost
    }
}


/// The rule for "is it unsafe to rename or undo right now" (pure, so the wording and the catch-all are pinned).
final class RenameBusyStateTests: XCTestCase {
    func testNothingBusyMeansNoReason() {
        XCTAssertNil(RenameBusyState().reason)
    }

    func testEachFlagProducesItsOwnReason() {
        XCTAssertNotNil(RenameBusyState(isLoadInFlight: true).reason)
        XCTAssertNotNil(RenameBusyState(isExporting: true).reason)
        XCTAssertNotNil(RenameBusyState(isExportSheetOpen: true).reason)
        XCTAssertNotNil(RenameBusyState(isEnhancing: true).reason)
        XCTAssertNotNil(RenameBusyState(isImporting: true).reason)
        XCTAssertNotNil(RenameBusyState(hasPendingPaste: true).reason)
        XCTAssertTrue(RenameBusyState(isImporting: true).reason?.contains("import") ?? false)
        XCTAssertTrue(RenameBusyState(isEnhancing: true).reason?.contains("Enhance") ?? false)
    }

    /// While ANY modal file panel is up (Paste's folder grant, an import/locate picker, Export's destination)
    /// menu-driven work keeps running — so an open panel alone must refuse a rename/undo.
    func testAnOpenModalPanelAloneBlocksAndTakesPrecedence() {
        XCTAssertEqual(RenameBusyState(hasModalPanel: true).reason, "Finish or cancel the open dialog first.")
        XCTAssertEqual(
            RenameBusyState(isLoadInFlight: true, isImporting: true, hasModalPanel: true).reason,
            "Finish or cancel the open dialog first."
        )
    }
}
