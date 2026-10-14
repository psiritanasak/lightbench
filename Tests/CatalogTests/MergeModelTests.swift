import XCTest
@testable import PhotoApp

/// Folder access that always declines, so no test can open a real file panel (a hung modal panel stalled the suite once).
@MainActor
private final class DecliningAccess: SidecarFolderAccessing {
    private(set) var requests = 0
    func resolvedURL(for folder: URL) -> URL? { nil }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { requests += 1; return .declined }
}

@MainActor
final class MergeModelTests: XCTestCase {
    private var catalog: CatalogModel!
    private var access: DecliningAccess!
    private var model: MergeModel!

    override func setUp() async throws {
        catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: UserDefaults(suiteName: "MergeModelTests-\(UUID().uuidString)")!)
        access = DecliningAccess()
        model = MergeModel(folderAccess: access)
    }

    private func photo(_ name: String, id: Int64) -> Photo {
        Photo(id: id, path: "/tmp/does-not-exist/\(name)", filename: name, fileSize: nil, importedAt: Date())
    }

    // MARK: Request guards

    func testRequestNeedsTwoToNinePhotosAndExplainsWhy() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, MergeModel.selectionProblem(.hdr, count: 1))
        XCTAssertFalse(catalog.mergeBusy)

        model.statusMessage = nil
        model.request(.hdr, photos: (1...10).map { photo("p\($0).jpg", id: Int64($0)) }, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.statusMessage?.contains("at most 9") ?? false)
    }

    func testAValidRequestOpensTheConfirmationAndMarksTheCatalogBusyUntilCancelled() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        XCTAssertEqual(model.pending?.photos.count, 2)
        XCTAssertTrue(catalog.mergeBusy, "other sheets and menu items must see the pending merge")
        XCTAssertTrue(catalog.toolSheetIsBusy, "batch rename must not start under a pending merge")
        model.cancel()
        XCTAssertNil(model.pending)
        XCTAssertFalse(catalog.mergeBusy)
        XCTAssertFalse(catalog.toolSheetIsBusy)
    }

    func testPanoramaRequestsFollowTheirOwnLimitsAndText() {
        model.request(.panorama, photos: [photo("a.jpg", id: 1)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, "Select at least two overlapping photos to make a panorama.")
        model.statusMessage = nil
        model.request(.panorama, photos: (1...13).map { photo("p\($0).jpg", id: Int64($0)) }, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.statusMessage?.contains("at most 12") ?? false)
        model.statusMessage = nil
        // Ten photos are fine for a panorama but too many for an HDR bracket.
        let ten = (1...10).map { photo("p\($0).jpg", id: Int64($0)) }
        XCTAssertNil(MergeModel.selectionProblem(.panorama, count: 10))
        XCTAssertNotNil(MergeModel.selectionProblem(.hdr, count: 10))
        model.request(.panorama, photos: ten, catalog: catalog)
        XCTAssertEqual(model.pending?.kind, .panorama)
        let request = try! XCTUnwrap(model.pending)
        XCTAssertEqual(MergeModel.confirmationTitle(request), "Stitch 10 photos into a panorama?")
        let message = MergeModel.confirmationMessage(.init(kind: .panorama, photos: ten, estimatedBytes: 1_000_000))
        XCTAssertTrue(message.contains("overlap by about half"))
        XCTAssertTrue(message.contains("order they were taken"))
        XCTAssertTrue(message.contains("roughly") && !message.contains("up to"), "an estimate, not a bound: a diagonal sweep can exceed it")
        XCTAssertTrue(message.contains("5.5 MB") || message.contains("6 MB") || message.contains("5,5 MB"), "about (10 + 1) / 2 frames of 1 MB: \(message)")
        XCTAssertFalse(message.contains("Tripod"), "tripod is an HDR concept")
    }

    func testPanoramaSummaryReportsSizeCroppingAndAWeakJoin() {
        let url = URL(fileURLWithPath: "/tmp/a-Pano.tiff")
        var outcome = MergeOutcome(url: url, frameCount: 3, referenceName: "b.jpg",
                                   alignment: [.init(name: "b.jpg", inlierCount: 90, matchCount: 100), .init(name: "c.jpg", inlierCount: 14, matchCount: 50)])
        outcome.mode = .panorama
        outcome.size = CGSize(width: 5200, height: 3100)
        outcome.cropped = true
        let text = MergeModel.summary(outcome)
        XCTAssertTrue(text.hasPrefix("Created “a-Pano.tiff” (5200 × 3100) from 3 photos, edges cropped."))
        XCTAssertTrue(text.contains("The join at “c.jpg” was uncertain"))
        outcome.cropped = false
        XCTAssertTrue(MergeModel.summary(outcome).contains("edges kept."))
    }

    func testASecondRequestWhileOneIsPendingIsIgnored() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        let first = model.pending
        model.request(.hdr, photos: [photo("c.jpg", id: 3), photo("d.jpg", id: 4), photo("e.jpg", id: 5)], catalog: catalog)
        XCTAssertEqual(model.pending, first)
    }

    func testRequestIsRefusedWhileARenameRuns() {
        catalog.isRenameInProgress = true
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, CatalogModel.renameInProgressMessage)
    }

    /// The dialog's button hands `confirm` the request it was presented with; `pending` may already be nil by then. The merge must still start
    /// (it fails fast here on the unreadable fake paths, which is fine — what matters is that it was NOT silently dropped).
    func testConfirmRunsTheRequestItIsGivenEvenWhenPendingWasAlreadyCleared() async throws {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], estimatedBytes: nil)
        XCTAssertNil(model.pending)
        model.confirm(request, option: .hdr(align: true), catalog: catalog)
        XCTAssertTrue(model.isMerging, "confirm must start the merge from the request it was handed")
        XCTAssertTrue(catalog.mergeBusy)
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isMerging, "isMerging is released on every exit path")
        XCTAssertEqual(access.requests, 1, "the merge reached the folder-access step with the request it was handed")
        XCTAssertFalse(catalog.mergeBusy)
    }

    func testConfirmIsIgnoredWhileAMergeIsAlreadyRunning() async throws {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], estimatedBytes: nil)
        model.confirm(request, option: .hdr(align: true), catalog: catalog)
        XCTAssertTrue(model.isMerging)
        model.confirm(request, option: .hdr(align: false), catalog: catalog) // a double click must not start a second merge
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isMerging)
        XCTAssertEqual(access.requests, 1, "only ONE merge started")
    }

    /// Batch rename must refuse while a merge is pending or running — checked at the point rename/undo re-check (`RenameBusyState`).
    func testRenameBusyStateRefusesDuringAMerge() {
        XCTAssertNotNil(RenameBusyState(isMerging: true).reason)
        XCTAssertTrue(RenameBusyState(isMerging: true).reason?.contains("Merge") ?? false)
        XCTAssertNil(RenameBusyState(isMerging: false).reason)
    }

    // MARK: Text

    func testConfirmationTextNamesTheCountTheFirstPhotoTheSizeAndTheTripodChoice() {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("first.jpg", id: 1), photo("second.jpg", id: 2), photo("third.jpg", id: 3)], estimatedBytes: 192_000_000)
        XCTAssertEqual(MergeModel.confirmationTitle(request), "Merge 3 photos to HDR?")
        let message = MergeModel.confirmationMessage(request)
        XCTAssertTrue(message.contains("first.jpg"))
        XCTAssertTrue(message.contains("MB"), "a size estimate is shown")
        XCTAssertTrue(message.contains("not changed"))
        XCTAssertTrue(message.contains("Tripod"))
        let unknown = MergeModel.confirmationMessage(.init(kind: .hdr, photos: request.photos, estimatedBytes: nil))
        XCTAssertFalse(unknown.contains("roughly"))
    }

    func testSummaryReportsAlignmentAndWarnsAboutAWeakFrame() {
        let url = URL(fileURLWithPath: "/tmp/mid-HDR.tiff")
        let good = MergeOutcome(url: url, frameCount: 3, referenceName: "mid.jpg",
                                alignment: [.init(name: "a.jpg", inlierCount: 80, matchCount: 100), .init(name: "b.jpg", inlierCount: 60, matchCount: 100)])
        XCTAssertEqual(MergeModel.summary(good), "Created “mid-HDR.tiff” from 3 photos (exposure reference: mid.jpg), aligned.")
        let weak = MergeOutcome(url: url, frameCount: 3, referenceName: "mid.jpg",
                                alignment: [.init(name: "a.jpg", inlierCount: 80, matchCount: 100), .init(name: "b.jpg", inlierCount: 13, matchCount: 40)])
        XCTAssertTrue(MergeModel.summary(weak).contains("“b.jpg” was uncertain"))
        let corrected = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [],
                                    gains: [.init(name: "b.jpg", exifGain: 2.0, usedGain: 2.24)])
        XCTAssertTrue(MergeModel.summary(corrected).contains("“b.jpg” was measured 12% brighter than its camera data implied and was corrected"))
        let negligible = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [],
                                      gains: [.init(name: "b.jpg", exifGain: 2.0, usedGain: 2.05)])
        XCTAssertFalse(MergeModel.summary(negligible).contains("corrected"), "a 2.5% difference is not worth mentioning")
        let tripod = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [])
        XCTAssertTrue(MergeModel.summary(tripod).hasSuffix("without alignment."))
    }

    func testEstimatedBytesIsEightBytesPerPixelAndNilForAnUnreadableFile() throws {
        XCTAssertNil(MergeModel.estimatedOutputBytes(forFileAt: URL(fileURLWithPath: "/tmp/definitely-not-here.jpg")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-est-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.png")
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        try PhotoExporter.write(image, format: .png, quality: 1, to: url)
        XCTAssertEqual(MergeModel.estimatedOutputBytes(forFileAt: url), 40 * 30 * 8)
    }

    // MARK: Selection used by the merge

    func testMergeActsOnlyOnSelectedPhotosTheGridActuallyShows() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-vis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.png", "b.png", "c.png"] {
            try PhotoExporter.write(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), format: .png, quality: 1, to: dir.appendingPathComponent(name))
        }
        _ = try await db.importPhotos(at: ["a.png", "b.png", "c.png"].map { dir.appendingPathComponent($0) })
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "MergeModelTests-\(UUID().uuidString)")!)
        await model.refresh()
        let mine = model.photos.filter { $0.path.hasPrefix(dir.path) }
        XCTAssertEqual(mine.count, 3)
        for p in mine { model.toggleSelection(of: p) }
        XCTAssertEqual(model.selectedPhotosInDisplayedGrid.count, 3)
        model.searchText = "a.png" // hides b and c from the grid; they stay selected
        XCTAssertEqual(model.selectedPhotos.count, 3, "selection itself is untouched by a filter")
        XCTAssertEqual(model.selectedPhotosInDisplayedGrid.map(\.filename), ["a.png"], "a merge must not silently include photos the grid hides")
    }
}

/// Pins the wiring that cannot be driven by clicks here: the menu items exist, are Library-only, and every other tool is blocked meanwhile.
final class MergeWiringTests: XCTestCase {
    private func text(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
    }

    func testThePhotoMenuItemIsLibraryOnlyNeedsTwoVisiblePhotosAndRespectsBusyState() throws {
        let app = try text("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Merge Photos to HDR…\") { catalog.mergeRequested = .hdr }"))
        XCTAssertTrue(app.contains("Button(\"Merge Photos to Panorama…\") { catalog.mergeRequested = .panorama }"))
        XCTAssertEqual(app.components(separatedBy: "catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy").count - 1, 2, "both merge items need 2+ visible photos")
        XCTAssertTrue(app.contains("cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy"))
    }

    func testOtherToolsAreBlockedWhileAMergeIsPendingOrRunning() throws {
        let app = try text("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("catalog.selectedPhotos.isEmpty || document.isLoadInFlight || catalog.mergeBusy"), "Paste Settings")
        XCTAssertTrue(app.contains("renameModel.isWorking || document.isLoadInFlight || catalog.mergeBusy"), "Rename Files")
        XCTAssertTrue(app.contains("renameModel.isPresentingSheet || catalog.mergeBusy"), "Undo Rename")
        let sheets = try text("Sources/UI/DuplicatesSheetView.swift")
        XCTAssertEqual(sheets.components(separatedBy: "catalog.mergeBusy").count - 1, 4, "keyword, duplicates and people sheets block on a merge, and so does the XMP dialog")
        XCTAssertTrue(sheets.contains("MergeDialogModifier(") && sheets.contains("model: catalog.merge,"))
        let model = try text("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(model.contains("faces.isWorking || mergeBusy"), "batch rename must not start under a merge")
    }

    func testTheSelectionMenuHasAMergeItemThatNeedsTwoVisiblePhotos() throws {
        let content = try text("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("catalog.mergeRequested = .hdr"))
        XCTAssertTrue(content.contains("catalog.mergeRequested = .panorama"))
        XCTAssertTrue(content.contains("Merge to Panorama (\\(catalog.selectedPhotosInDisplayedGrid.count))…"))
        XCTAssertTrue(content.contains("catalog.selectedPhotosInDisplayedGrid.count < 2 || otherSheetIsPresented || catalog.mergeBusy"),
                      "the enabled state uses the SAME set the merge acts on")
        XCTAssertTrue(content.contains("Merge to HDR (\\(catalog.selectedPhotosInDisplayedGrid.count))…"), "so does the label")
        XCTAssertTrue(content.contains("isMerging: catalog.mergeBusy"), "rename/undo re-check the merge flag")
        XCTAssertTrue(content.contains("|| document.isLoadInFlight || catalog.mergeBusy || catalog.xmpBusy\n                        )"), "selection-menu Rename Files")
        XCTAssertTrue(content.contains("renameModel.isWorking || document.isLoadInFlight || catalog.mergeBusy || catalog.xmpBusy)"), "selection-menu Undo Rename")
        XCTAssertTrue(content.contains("pasteModel.pendingTargets != nil || catalog.mergeBusy"), "otherSheetIsPresented includes a merge")
    }
}
