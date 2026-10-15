import XCTest
@testable import PhotoApp

final class DroppedItemsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func folder(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: classify

    func testAFolderOfPhotosIsAFlatImport() throws {
        try touch("flat/a.jpg"); try touch("flat/b.png")
        let url = try folder("flat")
        XCTAssertEqual(DroppedItems.classify([url]).folders, [.init(url: url, asTree: false)])
    }

    func testAFolderWithPhotosInASubfolderIsATreeImport() throws {
        try touch("tree/a.jpg"); try touch("tree/2024/b.jpg")
        let url = try folder("tree")
        XCTAssertEqual(DroppedItems.classify([url]).folders, [.init(url: url, asTree: true)])
    }

    func testPhotosOnlyInSubfoldersStillMakeATree() throws {
        try touch("deep/2024/b.jpg")
        let url = try folder("deep")
        XCTAssertEqual(DroppedItems.classify([url]).folders, [.init(url: url, asTree: true)])
    }

    func testAFolderWithNoPhotosIsReportedNotImported() throws {
        try touch("docs/readme.txt")
        let url = try folder("docs")
        let plan = DroppedItems.classify([url])
        XCTAssertTrue(plan.folders.isEmpty)
        XCTAssertEqual(plan.emptyFolders, [url])
        XCTAssertEqual(DroppedItems.leftOutMessage(for: plan), "No photos found in \"docs\".")
    }

    func testAPhotoOpensInTheEditorAndOnlyTheFirstOfSeveralDoes() throws {
        let a = try touch("loose/a.jpg"), b = try touch("loose/b.heic"), c = try touch("loose/c.tif")
        let plan = DroppedItems.classify([a, b, c])
        XCTAssertEqual(plan.photoToOpen, a)
        XCTAssertEqual(plan.skippedPhotoCount, 2)
        XCTAssertTrue(plan.folders.isEmpty)
        let message = try XCTUnwrap(DroppedItems.leftOutMessage(for: plan))
        XCTAssertTrue(message.contains("2 other photos were not opened"))
        XCTAssertTrue(message.contains("drop their folder"))
    }

    func testOneSkippedPhotoReadsInTheSingular() throws {
        let plan = DroppedItems.classify([try touch("p/a.jpg"), try touch("p/b.jpg")])
        XCTAssertTrue(try XCTUnwrap(DroppedItems.leftOutMessage(for: plan)).contains("1 other photo was not opened"))
    }

    func testEverythingElseIsIgnoredAndAnAllIgnoredDropSaysSo() throws {
        let plan = DroppedItems.classify([try touch("misc/notes.txt"), try touch("misc/a.photoapp.json"), URL(string: "https://example.com/a.jpg")!])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.ignoredCount, 2, "a non-file URL is skipped silently, a file of another type is counted")
        XCTAssertNotNil(DroppedItems.leftOutMessage(for: plan))
    }

    func testIgnoredItemsAreNotMentionedWhenSomethingWasUsed() throws {
        let plan = DroppedItems.classify([try touch("m/a.jpg"), try touch("m/notes.txt")])
        XCTAssertEqual(plan.photoToOpen?.lastPathComponent, "a.jpg")
        XCTAssertNil(DroppedItems.leftOutMessage(for: plan))
    }

    func testTheSameItemDroppedTwiceCountsOnce() throws {
        let a = try touch("dup/a.jpg")
        let plan = DroppedItems.classify([a, a])
        XCTAssertEqual(plan.skippedPhotoCount, 0)
    }

    func testFoldersAndAPhotoCanArriveTogether() throws {
        try touch("one/a.jpg")
        let one = try folder("one"), photo = try touch("solo/s.jpg")
        let plan = DroppedItems.classify([one, photo])
        XCTAssertEqual(plan.folders.map(\.url), [one])
        XCTAssertEqual(plan.photoToOpen, photo)
    }

    func testAPackageIsNotImportedFromTheInside() throws {
        try touch("Lib.photoslibrary/originals/a.jpg")
        let lib = dir.appendingPathComponent("Lib.photoslibrary", isDirectory: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8).write(to: lib.appendingPathComponent("Info.plist"))
        // Mark it as a package the way Finder does for a bundle directory: a known package extension.
        let values = try lib.resourceValues(forKeys: [.isPackageKey])
        try XCTSkipUnless(values.isPackage == true, "this machine does not treat .photoslibrary as a package")
        let plan = DroppedItems.classify([lib])
        XCTAssertTrue(plan.folders.isEmpty)
        XCTAssertEqual(plan.packages, [lib])
        XCTAssertTrue(try XCTUnwrap(DroppedItems.leftOutMessage(for: plan)).contains("package"))
    }

    func testAFolderContainingAPackageDoesNotImportThePackagesPhotos() throws {
        try touch("Pictures/top.jpg")
        try touch("Pictures/Lib.photoslibrary/originals/a.jpg")
        let lib = dir.appendingPathComponent("Pictures/Lib.photoslibrary")
        try XCTSkipUnless((try lib.resourceValues(forKeys: [.isPackageKey])).isPackage == true, "not treated as a package here")
        let root = try folder("Pictures")
        let node = try XCTUnwrap(PhotoImporter.scanFolderTree(at: root))
        XCTAssertEqual(node.imageFiles.map(\.lastPathComponent), ["top.jpg"])
        XCTAssertTrue(node.children.isEmpty, "the package is opaque")
        XCTAssertEqual(DroppedItems.classify([root]).folders, [.init(url: root, asTree: false)])
    }

    func testASubfolderDroppedWithItsParentIsImportedOnce() throws {
        try touch("p/a.jpg"); try touch("p/sub/b.jpg")
        let parent = try folder("p"), child = try folder("p/sub")
        XCTAssertEqual(DroppedItems.classify([child, parent]).folders, [.init(url: parent, asTree: true)])
        XCTAssertEqual(DroppedItems.classify([parent, child]).folders.map(\.url), [parent])
    }

    func testASiblingWithTheSamePrefixIsNotMistakenForASubfolder() throws {
        try touch("album/a.jpg"); try touch("album-2/b.jpg")
        let one = try folder("album"), two = try folder("album-2")
        XCTAssertEqual(DroppedItems.classify([one, two]).folders.map(\.url), [one, two])
    }

    // MARK: refusal gate

    func testTheGateAllowsAnIdleApp() {
        XCTAssertNil(DroppedItems.refusal(renameWorking: false, renameInProgress: false, culling: false, loadInFlight: false, toolSheetBusy: false))
    }

    func testEachBusyStateRefusesWithItsOwnMessage() {
        func message(r: Bool = false, p: Bool = false, c: Bool = false, l: Bool = false, t: Bool = false) -> String? {
            DroppedItems.refusal(renameWorking: r, renameInProgress: p, culling: c, loadInFlight: l, toolSheetBusy: t)
        }
        XCTAssertTrue(try XCTUnwrap(message(c: true)).contains("culling"))
        XCTAssertFalse(try XCTUnwrap(message(c: true)).contains("drop"), "also read by Finder / Dock opens")
        XCTAssertTrue(try XCTUnwrap(message(r: true)).contains("rename"))
        XCTAssertTrue(try XCTUnwrap(message(p: true)).contains("rename"))
        XCTAssertTrue(try XCTUnwrap(message(l: true)).contains("loading"))
        XCTAssertTrue(try XCTUnwrap(message(t: true)).contains("sheet"))
        XCTAssertTrue(try XCTUnwrap(message(r: true, p: true, c: true, l: true, t: true)).contains("culling"), "culling is reported first")
    }

    // MARK: wiring pins

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheWindowAcceptsDropsAndTheDelegateQueuesFinderOpens() throws {
        let modifier = try source("Sources/UI/DropAndOpenModifier.swift")
        XCTAssertTrue(modifier.contains(".dropDestination(for: URL.self)"))
        XCTAssertTrue(modifier.contains("DroppedItems.refusal("), "the drop is gated like the menus")
        XCTAssertTrue(modifier.contains("DroppedItems.classify("))
        XCTAssertEqual(modifier.components(separatedBy: "if let message = refusal()").count - 1, 2, "checked before AND after the off-main scan")
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)"))
        XCTAssertTrue(app.contains(".modifier(DropAndOpenModifier("))
        XCTAssertTrue(try source("Sources/App/AppDelegate.swift").contains("OpenRequests.shared.enqueue(urls)"))
    }

    func testTheAppIsOfferedAsAnAlternateHandlerNeverTheDefault() throws {
        let project = try source("project.yml")
        XCTAssertTrue(project.contains("CFBundleDocumentTypes"))
        XCTAssertTrue(project.contains("public.camera-raw-image"))
        XCTAssertFalse(project.contains("LSHandlerRank: Default") || project.contains("LSHandlerRank: Owner"))
        let plist = try source("Sources/App/Info.plist")
        XCTAssertTrue(plist.contains("CFBundleDocumentTypes") && plist.contains("public.folder"), "the checked-in Info.plist matches project.yml")
        XCTAssertEqual(plist.components(separatedBy: "<string>Alternate</string>").count - 1, 2)
        XCTAssertFalse(plist.contains("<string>Default</string>") || plist.contains("<string>Owner</string>"))
        XCTAssertEqual(project.components(separatedBy: "LSHandlerRank: Alternate").count - 1, 2)
    }
}

@MainActor
final class OpenRequestsTests: XCTestCase {
    func testRequestsQueuedBeforeTheUIExistsAreDeliveredOnceInOrder() {
        let requests = OpenRequests()
        let a = URL(fileURLWithPath: "/tmp/a.jpg"), b = URL(fileURLWithPath: "/tmp/b.jpg")
        requests.enqueue([a]); requests.enqueue([b])
        XCTAssertEqual(requests.drain(), [a, b])
        XCTAssertTrue(requests.drain().isEmpty)
        XCTAssertTrue(requests.pending.isEmpty)
    }
}
