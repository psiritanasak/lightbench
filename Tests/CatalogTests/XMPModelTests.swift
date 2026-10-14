import XCTest
@testable import PhotoApp

/// Grants (or declines) access without ever opening a real file panel.
@MainActor
private final class StubAccess: SidecarFolderAccessing {
    var grant: URL?
    var duringPrompt: (() -> Void)?
    private(set) var requests = 0
    func resolvedURL(for folder: URL) -> URL? { nil }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
        requests += 1
        duringPrompt?()
        if let grant { return .granted(grant) }
        return .declined
    }
}

@MainActor
final class XMPModelTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var access: StubAccess!
    private var model: XMPModel!
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("XMPModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "XMPModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        access = StubAccess()
        model = XMPModel(folderAccess: access)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makePhotos(_ names: [String]) async throws -> [Photo] {
        let urls = names.map { dir.appendingPathComponent($0) }
        for url in urls { try Data("x".utf8).write(to: url) }
        _ = try await db.importPhotos(at: urls)
        await catalog.refresh()
        return try await db.allPhotos().filter { names.contains($0.filename) }.sorted { $0.filename < $1.filename }
    }

    private func run(_ kind: XMPModel.Kind, _ photos: [Photo]) async throws {
        model.request(kind, photos: photos, catalog: catalog)
        let request = try XCTUnwrap(model.pending)
        model.confirm(request, catalog: catalog)
        for _ in 0..<2000 where model.isWorking || catalog.xmpBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isWorking)
    }

    // MARK: busy state

    func testAPendingRequestMarksTheCatalogBusyUntilCancelled() async throws {
        let photos = try await makePhotos(["a.jpg"])
        model.request(.write, photos: photos, catalog: catalog)
        XCTAssertTrue(catalog.xmpBusy)
        XCTAssertTrue(catalog.toolSheetIsBusy, "other sheets and batch rename must see it")
        model.cancel()
        XCTAssertFalse(catalog.xmpBusy)
        XCTAssertFalse(catalog.toolSheetIsBusy)
    }

    func testAnEmptySelectionExplainsInsteadOfOpeningADialog() {
        model.request(.read, photos: [], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertNotNil(model.statusMessage)
    }

    // MARK: write

    func testWriteProducesSidecarsFromTheCatalogAndNeverTouchesThePhotoBytes() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await db.setRating(4, for: photos[0].id!)
        try await db.setColorLabel(.blue, for: photos[0].id!)
        try await db.setFlagStatus(.rejected, for: photos[1].id!)
        try await db.addKeywords(["Sky", "Beach"], to: [photos[0].id!])
        await catalog.refresh()
        let before = try Data(contentsOf: URL(fileURLWithPath: photos[0].path))
        access.grant = dir

        // The app passes the grid's CURRENT rows (`selectedPhotosInDisplayedGrid`), not rows captured before the edits.
        let fresh = try await db.allPhotos().sorted { $0.filename < $1.filename }
        try await run(.write, fresh)

        guard case .decoded(let a) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[0].path)),
              case .decoded(let b) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[1].path)) else { return XCTFail("missing sidecars") }
        XCTAssertEqual(a.rating, 4)
        XCTAssertEqual(a.label, .blue)
        XCTAssertEqual(Set(a.keywords ?? []), ["Sky", "Beach"])
        XCTAssertEqual(b.isRejected, true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: photos[0].path)), before)
        XCTAssertTrue(model.statusMessage?.contains("Wrote XMP for 2 photos") ?? false, model.statusMessage ?? "nil")
        XCTAssertEqual(access.requests, 1, "one prompt per distinct folder")
    }

    func testAJpegSharingARawsNameIsSkippedEvenWhenTheRawIsNotSelected() async throws {
        _ = try await makePhotos(["IMG_1.cr2", "IMG_1.jpg", "IMG_2.jpg"])
        for photo in try await db.allPhotos() { try await db.setRating(2, for: photo.id!) } // something to write for every photo
        let all = try await db.allPhotos()
        access.grant = dir
        let jpgs = all.filter { $0.filename.hasSuffix(".jpg") }
        try await run(.write, jpgs)
        XCTAssertEqual(XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: all.first { $0.filename == "IMG_1.jpg" }!.path)), .missing)
        guard case .decoded = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: all.first { $0.filename == "IMG_2.jpg" }!.path)) else { return XCTFail("IMG_2 should have one") }
        XCTAssertTrue(model.statusMessage?.contains("1 photo skipped because a RAW file") ?? false, model.statusMessage ?? "nil")
    }

    func testAnUnreadableExistingSidecarIsLeftAloneAndReported() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let xmp = XMPSidecarStore.sidecarURL(for: URL(fileURLWithPath: photos[0].path))
        let junk = Data("not xmp at all".utf8)
        try junk.write(to: xmp)
        access.grant = dir
        try await run(.write, photos)
        XCTAssertEqual(try Data(contentsOf: xmp), junk)
        XCTAssertTrue(model.statusMessage?.contains("couldn't be read") ?? false, model.statusMessage ?? "nil")
    }

    func testDecliningFolderAccessWritesNothing() async throws {
        let photos = try await makePhotos(["a.jpg"])
        access.grant = nil
        try await run(.write, photos)
        XCTAssertEqual(XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[0].path)), .missing)
        XCTAssertTrue(model.statusMessage?.contains("folder access not granted") ?? false, model.statusMessage ?? "nil")
    }

    // MARK: read

    func testReadReplacesRatingLabelAndAddsKeywordsThenRefreshesTheCatalog() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await db.setRating(1, for: photos[0].id!)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 5, isRejected: false, label: .green, keywords: ["Alpine"]),
                                  forPhotoAt: URL(fileURLWithPath: photos[0].path))
        access.grant = dir
        try await run(.read, photos)
        let a = try await db.allPhotos().first { $0.id == photos[0].id }
        XCTAssertEqual(a?.rating, 5)
        XCTAssertEqual(a?.colorLabel, .green)
        XCTAssertEqual(catalog.keywordNames(for: [a!])[a!.id!], ["Alpine"])
        XCTAssertTrue(model.statusMessage?.contains("Updated 1 photo from XMP") ?? false, model.statusMessage ?? "nil")
        XCTAssertTrue(model.statusMessage?.contains("1 photo had no XMP") ?? false, model.statusMessage ?? "nil")
    }

    // MARK: reviewer-requested behaviours

    func testWriteNeverErasesWhatAnotherAppPutInTheFile() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let url = URL(fileURLWithPath: photos[0].path)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 4, isRejected: false, label: .purple, keywords: ["FromBridge"]), forPhotoAt: url)
        access.grant = dir
        try await run(.write, photos) // the Library has no rating, label or keywords for it
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 4)
        XCTAssertEqual(f.label, .purple)
        XCTAssertEqual(f.keywords, ["FromBridge"])
    }

    func testUnRejectingInTheLibraryClearsAnOldMinusOneMarker() async throws {
        let photos = try await makePhotos(["a.jpg"])
        let url = URL(fileURLWithPath: photos[0].path)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 0, isRejected: true), forPhotoAt: url)
        access.grant = dir
        try await run(.write, photos)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.isRejected, false)
    }

    func testWriteUsesFreshRowsNotTheOnesCapturedAtRequestTime() async throws {
        let photos = try await makePhotos(["a.jpg"])
        access.grant = dir
        model.request(.write, photos: photos, catalog: catalog)
        // The user rates the photo while the folder prompt is up (the stub blocks until that write has landed).
        access.duringPrompt = { [db] in
            let id = photos[0].id!
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { try? await db!.setRating(5, for: id); semaphore.signal() }
            semaphore.wait()
        }
        model.confirm(try XCTUnwrap(model.pending), catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[0].path)) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 5)
    }

    func testARenameStartingDuringTheFolderPromptStopsTheRun() async throws {
        let photos = try await makePhotos(["a.jpg"])
        access.grant = dir
        access.duringPrompt = { [catalog] in catalog!.isRenameInProgress = true }
        try await run(.write, photos)
        catalog.isRenameInProgress = false
        XCTAssertEqual(XMPSidecarStore.read(forPhotoAt: URL(fileURLWithPath: photos[0].path)), .missing)
    }

    func testOnePromptPerDistinctFolderAcrossFolders() async throws {
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.jpg"), b = sub.appendingPathComponent("b.jpg"), c = sub.appendingPathComponent("c.jpg")
        for url in [a, b, c] { try Data("x".utf8).write(to: url) }
        _ = try await db.importPhotos(at: [a, b, c])
        await catalog.refresh()
        access.grant = dir
        try await run(.write, try await db.allPhotos())
        XCTAssertEqual(access.requests, 2)
    }

    func testReadKeepsAPickAndAJpegBesideARawDoesNotTakeTheRawsXMP() async throws {
        let photos = try await makePhotos(["IMG_1.cr2", "IMG_1.jpg", "other.jpg"])
        let byName = Dictionary(uniqueKeysWithValues: photos.map { ($0.filename, $0) })
        try XMPSidecarStore.write(XMPLibraryFields(rating: 5, isRejected: false, label: .red), forPhotoAt: URL(fileURLWithPath: byName["IMG_1.cr2"]!.path))
        try XMPSidecarStore.write(XMPLibraryFields(rating: 3, isRejected: false), forPhotoAt: URL(fileURLWithPath: byName["other.jpg"]!.path))
        try await db.setFlagStatus(.picked, for: byName["other.jpg"]!.id!)
        access.grant = dir
        try await run(.read, try await db.allPhotos())
        let after = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.filename, $0) })
        XCTAssertEqual(after["IMG_1.cr2"]?.rating, 5)
        XCTAssertEqual(after["IMG_1.jpg"]?.rating, 0, "the RAW owns IMG_1.xmp")
        XCTAssertEqual(after["IMG_1.jpg"]?.colorLabel, ColorLabel.none)
        XCTAssertEqual(after["other.jpg"]?.rating, 3)
        XCTAssertEqual(after["other.jpg"]?.flagStatus, .picked, "a normal rating never undoes a Pick")
    }

    func testEmbeddedZeroRatingNeverClearsStars() {
        XCTAssertNil(XMPModel.embeddedFields(XMPLibraryFields(rating: 0, isRejected: false, label: .blue)).rating)
        XCTAssertEqual(XMPModel.embeddedFields(XMPLibraryFields(rating: 0, isRejected: false, label: .blue)).label, .blue)
        XCTAssertEqual(XMPModel.embeddedFields(XMPLibraryFields(rating: 4, isRejected: false)).rating, 4)
        XCTAssertEqual(XMPModel.embeddedFields(XMPLibraryFields(rating: 0, isRejected: true)).isRejected, true)
    }

    func testAutoReadAfterImportFillsOnlyDefaultsOfNewPhotos() async throws {
        let old = try await makePhotos(["old.jpg"])
        try await db.setRating(2, for: old[0].id!)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 5, isRejected: false), forPhotoAt: URL(fileURLWithPath: old[0].path))
        let before = Set(old.compactMap(\.id))
        let new = try await makePhotos(["new.jpg"])
        try XMPSidecarStore.write(XMPLibraryFields(rating: 4, isRejected: false, label: .red, keywords: ["Imported"]),
                                  forPhotoAt: URL(fileURLWithPath: new[0].path))

        await catalog.autoReadXMP(newerThan: before)

        let all = Dictionary(uniqueKeysWithValues: try await db.allPhotos().map { ($0.filename, $0) })
        XCTAssertEqual(all["new.jpg"]?.rating, 4)
        XCTAssertEqual(all["new.jpg"]?.colorLabel, .red)
        XCTAssertEqual(catalog.keywordNames(for: [all["new.jpg"]!])[all["new.jpg"]!.id!], ["Imported"])
        XCTAssertEqual(all["old.jpg"]?.rating, 2, "photos that were already in the catalog are never touched by the import pass")
    }

    func testAutoReadNeverOverwritesAValueTheUserAlreadySet() async throws {
        let photos = try await makePhotos(["a.jpg"])
        try await db.setRating(1, for: photos[0].id!)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 5, isRejected: false, label: .green), forPhotoAt: URL(fileURLWithPath: photos[0].path))
        await catalog.autoReadXMP(newerThan: [])
        let a = try await db.allPhotos().first
        XCTAssertEqual(a?.rating, 1)
        XCTAssertEqual(a?.colorLabel, .green, "an unset label is still filled")
    }

    // MARK: pure text

    func testSummaryAndTitles() {
        var r = XMPModel.Result(kind: .write)
        XCTAssertEqual(XMPModel.summary(r), "No XMP files were written.")
        r.changed = 1; r.sharedWithRaw = 2; r.noAccess = 3; r.unreadable = 1; r.failed = 1
        XCTAssertEqual(XMPModel.summary(r), "Wrote XMP for 1 photo; 2 photos skipped because a RAW file with the same name owns the .xmp; "
                       + "1 photo have an .xmp that couldn't be read (left untouched); 1 photo failed; 3 photos skipped (folder access not granted).")
        XCTAssertEqual(XMPModel.summary(.init(kind: .read)), "The Library already matched the XMP data.")
        let one = XMPModel.Request(kind: .read, photos: [Photo(id: 1, path: "/a/b.jpg", filename: "b.jpg", fileSize: nil, importedAt: Date())])
        XCTAssertEqual(XMPModel.confirmationTitle(one), "Read XMP metadata for 1 photo?")
        XCTAssertTrue(XMPModel.confirmationMessage(.init(kind: .write, photos: one.photos)).contains("Pick flags and edits are not stored"))
    }

    func testRenameIsBlockedWhileXMPIsBusy() {
        XCTAssertNotNil(RenameBusyState(isXMPBusy: true).reason)
        XCTAssertNil(RenameBusyState().reason)
    }

    func testMenusAndSheetsAreWiredToTheXMPBusyFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/App/PhotoAppApp.swift"), encoding: .utf8)
        for needle in ["Button(\"Write Metadata to XMP…\")", "Button(\"Read Metadata from XMP…\")"] { XCTAssertTrue(app.contains(needle), needle) }
        let content = try String(contentsOf: root.appendingPathComponent("Sources/UI/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("isXMPBusy: catalog.xmpBusy"), "batch rename must see XMP work")
        let sheets = try String(contentsOf: root.appendingPathComponent("Sources/UI/DuplicatesSheetView.swift"), encoding: .utf8)
        XCTAssertTrue(sheets.contains("XMPDialogModifier("))
    }

    func testDistinctFoldersKeepsFirstSeenOrder() {
        func p(_ path: String) -> Photo { Photo(id: nil, path: path, filename: "f", fileSize: nil, importedAt: Date()) }
        XCTAssertEqual(XMPModel.distinctFolders(of: [p("/b/1.jpg"), p("/a/2.jpg"), p("/b/3.jpg")]).map(\.path), ["/b", "/a"])
    }
}
