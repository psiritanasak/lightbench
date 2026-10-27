import XCTest
import CoreImage
@testable import PhotoApp

/// Virtual copies in the Editor: each version has its own edit file and history, a save lands on the OPEN version only, and the identity
/// sites (open photo, rating bar row, thumbnails, paste target) tell two versions of one file apart.
@MainActor
final class VirtualCopyDocumentTests: XCTestCase {
    private var dir: URL!
    private var imageURL: URL!
    private var scopedFolder: URL!

    private final class GrantStub: SidecarFolderAccessing {
        let granted: URL
        init(_ granted: URL) { self.granted = granted }
        func resolvedURL(for folder: URL) -> URL? { granted }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(granted) }
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VirtualCopyDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        imageURL = dir.appendingPathComponent("a.png")
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: image, to: imageURL, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scopedFolder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var master: Photo {
        Photo(id: 1, path: imageURL.path, filename: "a.png", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
    }

    private var copy: Photo {
        Photo(id: 2, path: imageURL.path, filename: "a.png", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: 1, versionKey: "aaaaaaaa", versionName: "Copy 1")
    }

    func testEachVersionSavesToItsOwnFileWithItsOwnHistory() async throws {
        let model = ImageDocumentModel(folderAccess: GrantStub(scopedFolder))
        var masterSaves = 0
        var versionSaves: [String] = []
        model.onSidecarSaved = { _ in masterSaves += 1 }
        model.onVersionSidecarSaved = { _, key in versionSaves.append(key) }

        await model.load(photo: master)
        XCTAssertNil(model.currentVersionKey)
        XCTAssertEqual(model.currentEditKey, imageURL.path)
        model.editState.exposureEV = 1
        model.flushPendingSidecarSave()

        await model.load(photo: copy)
        XCTAssertEqual(model.currentVersionKey, "aaaaaaaa")
        XCTAssertEqual(model.currentEditKey, copy.editKey)
        XCTAssertNotEqual(model.currentEditKey, imageURL.path)
        XCTAssertEqual(model.editState.exposureEV, 0, "a copy with no edit file yet opens unedited, not with the master's edits")
        model.editState.exposureEV = -2
        model.flushPendingSidecarSave()

        XCTAssertEqual(masterSaves, 1)
        XCTAssertEqual(versionSaves, ["aaaaaaaa"])
        guard case .decoded(let storedMaster) = SidecarStore.read(forPhotoAt: imageURL),
              case .decoded(let storedCopy) = SidecarStore.read(forPhotoAt: imageURL, versionKey: "aaaaaaaa") else {
            return XCTFail("both versions must have their own edit file")
        }
        XCTAssertEqual(storedMaster.exposureEV, 1)
        XCTAssertEqual(storedCopy.exposureEV, -2)
        // Per-version history: each file's archive ends at that version's own edit.
        let masterHistory = try XCTUnwrap(SidecarStore.readHistory(forPhotoAt: imageURL))
        let copyHistory = try XCTUnwrap(SidecarStore.readHistory(forPhotoAt: imageURL, versionKey: "aaaaaaaa"))
        XCTAssertEqual(masterHistory.entries[masterHistory.currentIndex].state.exposureEV, 1)
        XCTAssertEqual(copyHistory.entries[copyHistory.currentIndex].state.exposureEV, -2)

        // Reopening restores each version separately.
        await model.load(photo: master)
        XCTAssertEqual(model.editState.exposureEV, 1)
        await model.load(photo: copy)
        XCTAssertEqual(model.editState.exposureEV, -2)
    }

    func testSwitchingFromTheMasterToItsCopyFlushesTheMastersPendingEditToTheMastersFile() async throws {
        let model = ImageDocumentModel(folderAccess: GrantStub(scopedFolder))
        await model.load(photo: master)
        model.editState.exposureEV = 0.75 // still inside the save debounce
        await model.load(photo: copy)
        guard case .decoded(let storedMaster) = SidecarStore.read(forPhotoAt: imageURL) else { return XCTFail("master file expected") }
        XCTAssertEqual(storedMaster.exposureEV, 0.75)
        XCTAssertEqual(SidecarStore.read(forPhotoAt: imageURL, versionKey: "aaaaaaaa"), .missing, "the copy's file is not written by the master's pending edit")
    }

    func testRevertOnACopyResetsOnlyThatVersion() async throws {
        let model = ImageDocumentModel(folderAccess: GrantStub(scopedFolder))
        await model.load(photo: master)
        model.editState.exposureEV = 1
        model.flushPendingSidecarSave()
        await model.load(photo: copy)
        model.editState.exposureEV = 2
        model.flushPendingSidecarSave()
        model.revertToOriginal()
        model.flushPendingSidecarSave()
        guard case .decoded(let storedCopy) = SidecarStore.read(forPhotoAt: imageURL, versionKey: "aaaaaaaa"),
              case .decoded(let storedMaster) = SidecarStore.read(forPhotoAt: imageURL) else { return XCTFail("files expected") }
        XCTAssertEqual(storedCopy.exposureEV, 0)
        XCTAssertEqual(storedMaster.exposureEV, 1, "the master keeps its edits")
    }

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // MARK: Identity sites

    func testThePasteTargetMatchIsByEditKeySoTheMasterIsNotTheOpenCopy() {
        let plan = PasteSettingsPlan.make(targets: [master, copy], openPhotoPath: copy.editKey)
        XCTAssertEqual(plan.openPhoto?.id, 2)
        XCTAssertEqual(plan.byFolder.flatMap(\.photos).map(\.id), [1], "the master is an ordinary batch target, written to its own file")
    }

    func testTheRatingBarResolvesTheOpenVersionNotItsMaster() async throws {
        let rows = [master, copy]
        let meta = EditorPhotoMeta(resolve: { key in rows.first { $0.editKey == key } })
        let task = try XCTUnwrap(meta.sync(path: copy.editKey, isLoading: false))
        await task.value
        XCTAssertEqual(meta.photo?.id, 2)
        var rated: [Photo] = []
        meta.configure(
            resolve: { key in rows.first { $0.editKey == key } },
            setRating: { _, photo in rated.append(photo) }, setFlagStatus: { _, _ in }, setColorLabel: { _, _ in })
        meta.setRating(4)
        XCTAssertEqual(rated.map(\.id), [2], "a rating key acts on the open VERSION's row")
    }

    func testNavigationAndFilmstripFindTheRightVersionByEditKey() {
        let photos = [master, copy]
        XCTAssertEqual(LibraryNavigation.neighbor(of: copy.editKey, in: photos, offset: -1)?.id, 1)
        XCTAssertEqual(LibraryNavigation.neighbor(of: master.editKey, in: photos, offset: 1)?.id, 2)
    }

    func testThumbnailsAreKeyedByEditKeySoTwoVersionsRenderDifferently() async throws {
        var edited = EditState(); edited.exposureEV = 2
        try SidecarStore.write(edited, forPhotoAt: imageURL, versionKey: "aaaaaaaa")
        let cache = ThumbnailCache()
        let masterThumb = await cache.thumbnail(for: master)
        let copyThumb = await cache.thumbnail(for: copy)
        let a = try XCTUnwrap(masterThumb), b = try XCTUnwrap(copyThumb)
        func firstPixelRed(_ image: CGImage) -> UInt8 {
            guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
            return bytes[0]
        }
        XCTAssertNotEqual(firstPixelRed(a), firstPixelRed(b), "the +2 EV copy must not be served the master's cached thumbnail")
        // Invalidating one version leaves the other cached; invalidating the file drops both.
        await cache.invalidate(editKey: copy.editKey)
        let copyAgain = await cache.thumbnail(for: copy)
        XCTAssertNotNil(copyAgain)
        // Invalidating the FILE drops every version: swap the two edit files on disk, and both thumbnails must be re-rendered from them.
        var plain = EditState(); plain.exposureEV = 0
        try SidecarStore.write(edited, forPhotoAt: imageURL) // master now +2 EV
        try SidecarStore.write(plain, forPhotoAt: imageURL, versionKey: "aaaaaaaa") // copy now unedited
        await cache.invalidate(path: imageURL.path)
        let masterAfter = try unwrapped(await cache.thumbnail(for: master))
        let copyAfter = try unwrapped(await cache.thumbnail(for: copy))
        XCTAssertEqual(firstPixelRed(masterAfter), firstPixelRed(b), "the master was re-rendered with its new edits")
        XCTAssertEqual(firstPixelRed(copyAfter), firstPixelRed(a), "the copy was re-rendered too")
    }

    // MARK: Source pins for the identity sites

    func testIdentitySitesUseTheEditKeyNotThePath() throws {
        func text(_ relative: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        let grid = try text("Sources/UI/LibraryGridView.swift")
        XCTAssertTrue(grid.contains(".id(item.cellID)"), "the cell identity is the stack-aware cell id, which is built from the edit key (StackCellPresentation)")
        XCTAssertTrue(try text("Sources/Catalog/StackCellPresentation.swift").contains("editKey"), "...so two versions of one file still get distinct cells")
        XCTAssertTrue(grid.contains("catalog.thumbnailRevisions[photo.editKey"))
        XCTAssertTrue(grid.contains("ThumbnailTaskKey(path: photo.editKey"))
        XCTAssertFalse(grid.contains(".id(photo.path)"))
        let cache = try text("Sources/UI/ThumbnailCache.swift")
        XCTAssertTrue(cache.contains("let editKey = photo.editKey"))
        let cull = try text("Sources/UI/CullPreviewCache.swift")
        XCTAssertTrue(cull.contains("let editKey = photo.editKey"))
        let film = try text("Sources/UI/EditorFilmstripView.swift")
        XCTAssertTrue(film.contains("photo.editKey == currentEditKey"))
        let content = try text("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains(".onChange(of: document.currentEditKey)"), "a master and its copy are one URL: the tab/zoom reset must key on the edit key")
        XCTAssertTrue(content.contains("editorMeta.sync(path: document.currentEditKey"))
        let paste = try text("Sources/UI/PasteSettingsModel.swift")
        XCTAssertTrue(paste.contains("photo.editKey == openPhotoPath"))
        let doc = try text("Sources/UI/ImageDocumentModel.swift")
        XCTAssertTrue(doc.contains("historyEditKey == editKey"), "a save may only embed the history that belongs to the open VERSION")
        XCTAssertTrue(doc.contains("SidecarStore.write(snapshot, historyObject: historyObject, forPhotoAt: url, versionKey: versionKey)"))
        XCTAssertTrue(doc.contains("SidecarStore.write(snapshot, forPhotoAt: url, versionKey: versionKey)"))
        XCTAssertTrue(doc.contains("SidecarStore.read(forPhotoAt: url, versionKey: versionKey)"))
        XCTAssertTrue(doc.contains("SidecarStore.readHistory(forPhotoAt: url, versionKey: versionKey)"))
        let exporter = try text("Sources/Rendering/PhotoExporter.swift")
        XCTAssertTrue(exporter.contains("versionKey: photo.versionKey"))
    }
}
