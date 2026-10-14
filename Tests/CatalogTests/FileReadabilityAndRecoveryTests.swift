import Darwin
import XCTest
@testable import PhotoApp

/// IMPROVEMENTS.md D32 (a plain chmod is not a lost sandbox grant) and D31 (a failed thumbnail silently restores a stale folder grant, never
/// with a panel).
final class FileReadabilityTests: XCTestCase {
    private let me: uid_t = 501
    private let myGroup: gid_t = 20

    private func classify(_ openErrno: Int32?, mode: mode_t? = 0o644, owner: uid_t? = 501, group: gid_t? = 20, euid: uid_t = 501, groups: [gid_t] = [20]) -> FileReadability {
        FileReadability.classify(openErrno: openErrno, mode: mode, owner: owner, group: group, euid: euid, groups: groups)
    }

    func testTableOfOutcomes() {
        XCTAssertEqual(classify(nil), .readable)
        XCTAssertEqual(classify(ENOENT), .missing)
        XCTAssertEqual(classify(ENOTDIR), .missing)
        XCTAssertEqual(classify(EIO), .otherFailure)
        XCTAssertEqual(classify(EMFILE), .otherFailure)
        // Permission failure on a file the bits ALLOW this user to read: only the sandbox is left.
        XCTAssertEqual(classify(EPERM), .sandboxDenied)
        XCTAssertEqual(classify(EACCES), .sandboxDenied, "the verdict does not depend on which of the two errnos the sandbox uses")
        // ... and on a file the bits forbid: a plain chmod.
        XCTAssertEqual(classify(EACCES, mode: 0o000), .posixDenied)
        XCTAssertEqual(classify(EPERM, mode: 0o000), .posixDenied)
        XCTAssertEqual(classify(EACCES, mode: 0o044), .posixDenied, "owner bit decides for the owner even when group/other could read")
        XCTAssertEqual(classify(EACCES, mode: 0o040, owner: 0, group: 20), .sandboxDenied, "not the owner, in the group: the group bit decides")
        XCTAssertEqual(classify(EACCES, mode: 0o004, owner: 0, group: 99, groups: [20]), .sandboxDenied, "neither owner nor group: the other bit")
        XCTAssertEqual(classify(EACCES, mode: 0o640, owner: 0, group: 99, groups: [20]), .posixDenied)
        XCTAssertEqual(classify(EACCES, mode: 0o000, euid: 0), .sandboxDenied, "root is never stopped by the bits")
        XCTAssertEqual(classify(EPERM, mode: nil, owner: nil, group: nil), .sandboxDenied, "even stat is refused: that is the sandbox")
    }

    func testTheRealProbeSeesMissingReadableAndChmodedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileReadabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        XCTAssertEqual(FileReadability.probe(file.path), .readable)
        XCTAssertEqual(FileReadability.probe(dir.appendingPathComponent("gone.jpg").path), .missing)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if geteuid() != 0 {
            XCTAssertEqual(FileReadability.probe(file.path), .posixDenied, "a chmod 000 file is NOT a lost folder grant")
        }
    }
}

@MainActor
final class CatalogAccessRecoveryTests: XCTestCase {
    private var dir: URL!
    private var scopedFolder: URL!
    private var db: CatalogDatabase!
    private var model: CatalogModel!
    private var promptCalls = 0
    private var suiteName = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogAccessRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scopedFolder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "CatalogAccessRecoveryTests-\(UUID().uuidString)"
        model = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        promptCalls = 0
        model.folderReGrantPrompt = { _ in self.promptCalls += 1; return nil }
        // Two files that are NOT images, so their thumbnails fail.
        for name in ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([1, 2, 3])) }
        _ = try await db.importPhotos(at: ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"].map { dir.appendingPathComponent($0) })
        await model.refresh()
        model.activeFolders = [dir.path]
        model.folderBookmarks = [dir.path: try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func photo(_ name: String) throws -> Photo {
        try XCTUnwrap(model.photos.first { $0.filename == name })
    }

    // MARK: D32

    func testAPlainPermissionFailureDoesNotEvictTheFolderOrPromptAnymore() async throws {
        let file = dir.appendingPathComponent("a.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        guard geteuid() != 0 else { return }
        // A bookmark that cannot be resolved: if recovery ran it would fall through to the re-grant prompt (and evict the folder).
        model.folderBookmarks = [dir.path: Data([0, 1, 2])]
        await model.ensureAccessActive(forPhotoAt: file.path)
        XCTAssertEqual(promptCalls, 0, "a chmod'd file must not open a re-grant panel")
        XCTAssertTrue(model.activeFolders.contains(dir.path), "and must not evict a good folder")
    }

    // MARK: D31

    func testAFailedThumbnailOnAStaleScopeRestoresAccessSilentlyOnceAndBumpsTheGrid() async throws {
        model.readabilityProbe = { _ in .sandboxDenied }
        let before = model.thumbnailRevisions[try photo("b.jpg").path] ?? 0
        let first = await model.thumbnail(for: try photo("a.jpg"))
        XCTAssertNil(first)
        XCTAssertEqual(promptCalls, 0, "a scrolling grid never shows a panel")
        XCTAssertGreaterThan(model.thumbnailRevisions[try photo("b.jpg").path] ?? 0, before, "every photo under the root is asked to retry")
        XCTAssertGreaterThan(model.thumbnailRevisions[try photo("a.jpg").path] ?? 0, 0)
        // Once per root per session: a second failure does not re-resolve or bump again.
        let afterFirst = model.thumbnailRevisions[try photo("b.jpg").path] ?? 0
        _ = await model.thumbnail(for: try photo("b.jpg"))
        XCTAssertEqual(model.thumbnailRevisions[try photo("b.jpg").path] ?? 0, afterFirst)
    }

    func testACellWhoseSharedProbeLookedAtAnotherFileStillGetsItsOwnVerdict() async throws {
        // The first probe (photo a) says "plain chmod", the others really are sandbox-denied: they must not be starved by a's verdict.
        model.readabilityProbe = { path in path.hasSuffix("/a.jpg") ? .posixDenied : .sandboxDenied }
        let a = try photo("a.jpg"), b = try photo("b.jpg")
        let target: CatalogModel = model
        let first = Task { @MainActor in _ = await target.thumbnail(for: a) }
        let second = Task { @MainActor in _ = await target.thumbnail(for: b) }
        await first.value; await second.value
        XCTAssertGreaterThan(model.thumbnailRevisions[b.path] ?? 0, 0, "b's own probe ran and its grant was restored")
    }

    /// Regression for a livelock: a waiter that kept re-awaiting an already-finished recovery task never yielded, so the task's creator (on the same
    /// actor) could not clear its entry. Many concurrent failing cells over a root whose first probe is NOT a sandbox problem exercise exactly that loop.
    func testManyConcurrentFailuresNeverSpinAndAllFinish() async throws {
        model.readabilityProbe = { path in path.hasSuffix("/a.jpg") ? .posixDenied : .sandboxDenied }
        let photos = [try photo("a.jpg"), try photo("b.jpg"), try photo("c.jpg"), try photo("d.jpg")]
        let target: CatalogModel = model
        var tasks: [Task<Void, Never>] = []
        for index in 0..<200 {
            let p = photos[index % photos.count]
            tasks.append(Task { @MainActor in _ = await target.thumbnail(for: p) })
        }
        let finished = expectation(description: "all 200 finished")
        Task { for t in tasks { await t.value }; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertEqual(promptCalls, 0)
    }

    func testAWholeScreenOfFailingThumbnailsSharesOneProbeAndOneBump() async throws {
        final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }; var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
        let probes = Counter()
        model.readabilityProbe = { _ in probes.bump(); return .sandboxDenied }
        let a = try photo("a.jpg"), b = try photo("b.jpg")
        let target: CatalogModel = model
        var tasks: [Task<Void, Never>] = []
        for index in 0..<20 {
            let photo = index.isMultiple(of: 2) ? a : b
            tasks.append(Task { @MainActor in _ = await target.thumbnail(for: photo) })
        }
        for task in tasks { await task.value }
        XCTAssertEqual(probes.value, 1, "twenty concurrent failures share one probe")
        XCTAssertEqual(model.thumbnailRevisions[b.path], 1, "and one bump per photo, not one per cell")
        XCTAssertEqual(model.thumbnailRevisions[a.path], 1)
        XCTAssertEqual(promptCalls, 0)
    }

    func testANonSandboxFailureIsProbedOncePerPhotoNotOncePerRequest() async throws {
        final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }; var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
        let probes = Counter()
        model.readabilityProbe = { _ in probes.bump(); return .posixDenied }
        let a = try photo("a.jpg")
        for _ in 0..<5 { _ = await model.thumbnail(for: a) }
        XCTAssertEqual(probes.value, 1, "the verdict is remembered, so a stuck volume is not hit again on every scroll")
    }

    func testAFailedThumbnailThatIsNotASandboxProblemChangesNothing() async throws {
        // A different photo per verdict: a verdict is remembered per photo, so reusing one would skip the probe after the first pass.
        for (name, verdict) in zip(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], [FileReadability.posixDenied, .missing, .otherFailure, .readable]) {
            model.readabilityProbe = { _ in verdict }
            _ = await model.thumbnail(for: try photo(name))
            XCTAssertTrue(model.thumbnailRevisions.isEmpty, "\(verdict)")
        }
        XCTAssertEqual(promptCalls, 0)
    }

    func testAFailedThumbnailWithAnUnresolvableBookmarkStaysSilentAndBumpsNothing() async throws {
        model.folderBookmarks = [dir.path: Data([0, 1, 2])]
        model.readabilityProbe = { _ in .sandboxDenied }
        _ = await model.thumbnail(for: try photo("a.jpg"))
        XCTAssertEqual(promptCalls, 0, "silent means silent, even when the recovery cannot work")
        XCTAssertTrue(model.thumbnailRevisions.isEmpty)
        XCTAssertNil(model.importStatusMessage, "no alert from a grid cell either")
        XCTAssertFalse(model.activeFolders.contains(dir.path), "intended: a root whose bookmark cannot be resolved is no longer claimed as active")
    }
}
