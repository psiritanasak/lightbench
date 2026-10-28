import XCTest
import CoreImage
@testable import PhotoApp

/// The persistent "Edits not saved" signal: `ImageDocumentModel.sidecarSaveStatus` follows every way a save can fail to reach
/// disk (D81 refusals, a declined folder, a write error) and clears when the open photo's edits are safe again.
@MainActor
final class SidecarSaveStatusTests: XCTestCase {
    /// Declines for chosen folders; grants everything else (the scoped test folder).
    private final class Access: SidecarFolderAccessing {
        let scoped: URL
        var declinedPaths: Set<String> = []
        var declineCount = 0
        var duringPanel: (() -> Void)?
        var requestCount = 0
        init(_ scoped: URL) { self.scoped = scoped }
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
            duringPanel?()
            requestCount += 1
            if declinedPaths.contains(folder.path) { declineCount += 1; return .declined }
            return .granted(scoped)
        }
    }

    private var dir: URL!
    private var sub: URL!
    private var photoA: URL!
    private var photoB: URL!
    private var photoC: URL!
    private var scoped: URL!
    private var access: Access!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarSaveStatusTests-\(UUID().uuidString)")
        sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        photoA = dir.appendingPathComponent("a.png")
        photoB = dir.appendingPathComponent("b.png")
        photoC = sub.appendingPathComponent("c.png")
        for url in [photoA!, photoB!, photoC!] {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scoped = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        access = Access(scoped)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func model() -> ImageDocumentModel { ImageDocumentModel(folderAccess: access) }
    private func garbage(_ photo: URL) throws {
        try Data("{ not json".utf8).write(to: XCTUnwrap(SidecarStore.versionedSidecarURL(for: photo, versionKey: nil)))
    }

    // MARK: Refusals

    func testAFreshModelAndAFreshLoadAreOk() async {
        let m = model()
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        await m.load(from: photoA)
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
    }

    func testAnUndecodableSidecarRefusalIsPublishedAndPersistsAfterTheAlertIsDismissed() async throws {
        try garbage(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .refusedUnreadable)
        m.sidecarSaveErrorMessage = nil
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave() // the once-per-load alert stays silent; the status must not clear
        XCTAssertNil(m.sidecarSaveErrorMessage)
        XCTAssertEqual(m.sidecarSaveStatus, .refusedUnreadable)
    }

    func testADecodableForeignSidecarIsRefusedNotLoaded() async throws {
        let m = model()
        await m.load(from: photoA)
        var foreign = EditState(); foreign.exposureEV = 3
        try SidecarStore.write(foreign, forPhotoAt: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .refusedNotLoaded)
    }

    func testASilentRefusalPublishesTheStatusWithoutAnAlert() async throws {
        try garbage(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.saveSidecarNowForTesting(suppressErrorMessage: true)
        XCTAssertNil(m.sidecarSaveErrorMessage)
        XCTAssertEqual(m.sidecarSaveStatus, .refusedUnreadable)
    }

    func testLoadingAnotherPhotoClearsARefusal() async throws {
        try garbage(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .refusedUnreadable)
        await m.load(from: photoB)
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
    }

    func testReloadingAFixedSidecarClearsTheStatusAndLoadsTheFile() async throws {
        try garbage(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        var good = EditState(); good.exposureEV = 4
        try SidecarStore.write(good, forPhotoAt: photoA)
        await m.reloadCurrentPhotoFromSidecar()
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        XCTAssertEqual(m.editState.exposureEV, 4, accuracy: 1e-9)
        m.editState.exposureEV = 5
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 5, accuracy: 1e-9)
    }

    func testReloadWithNoPhotoOpenIsANoOp() async {
        let m = model()
        await m.reloadCurrentPhotoFromSidecar()
        XCTAssertNil(m.currentURL)
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
    }

    func testTheSidecarURLNamesTheOpenPhotosEditFile() async throws {
        let m = model()
        XCTAssertNil(m.currentSidecarURL)
        await m.load(from: photoA)
        XCTAssertEqual(m.currentSidecarURL, SidecarStore.versionedSidecarURL(for: photoA, versionKey: nil))
    }

    // MARK: Declined folder

    func testADeclinedFolderIsPublishedAndPersistsAcrossSaves() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave() // skipped without a second panel
        XCTAssertEqual(access.declineCount, 1)
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
    }

    func testADeclinedFolderStatusFollowsPhotoSwitches() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        await m.load(from: photoC) // another folder: fine
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        await m.load(from: photoB) // back in the declined folder: starts declined
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
    }

    func testADeclineForAnOutgoingPhotoDoesNotMarkTheNewlyOpenedOne() async {
        let m = model()
        await m.load(from: photoC)
        m.editState.exposureEV = 1
        let target = photoA!
        access.declinedPaths = [sub.path]
        access.duringPanel = { m.simulateLoadFinishedForTesting(url: target, ownedKey: nil) }
        m.saveSidecarNowForTesting()
        XCTAssertEqual(m.sidecarSaveStatus, .ok, "the decline belongs to C's folder, A is the open photo now")
    }

    func testASaveIntoADeclinedFolderRepublishesTheStatusEvenIfItWasCleared() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave() // the folder is now remembered as declined
        await m.load(from: photoC) // status ok again (another folder)
        m.simulateLoadFinishedForTesting(url: photoB, ownedKey: nil) // B opened without a recompute
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        m.saveSidecarNowForTesting()
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
    }

    func testGrantingAccessAfterADeclineWritesAndClears() async throws {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
        access.declinedPaths = []
        m.grantAccessAndRetrySidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail("retry must write") }
        XCTAssertEqual(stored.exposureEV, 1, accuracy: 1e-9)
    }

    func testGrantingAccessAndDecliningAgainKeepsTheStatus() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        m.grantAccessAndRetrySidecarSave() // the panel is cancelled again
        XCTAssertEqual(access.declineCount, 2, "the retry asked again")
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
    }

    func testClearDeclinedFolderAloneNeverClearsTheStatus() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        m.clearDeclinedFolder(sub.path)
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
        m.clearDeclinedFolder(dir.path) // forgetting the decline writes nothing, so the edits are still only in memory
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
    }

    func testAnUnchangedPasteAfterClearingTheDeclineKeepsTheChip() async {
        access.declinedPaths = [dir.path]
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined)
        m.clearDeclinedFolder(dir.path) // what PasteSettingsModel does after re-granting the folder
        XCTAssertEqual(m.pasteSettings(m.editState), .unchanged, "nothing to paste: no save is attempted")
        XCTAssertEqual(m.sidecarSaveStatus, .folderDeclined, "nothing was written, so the edits are still unsaved")
        if case .decoded = SidecarStore.read(forPhotoAt: photoA) { XCTFail("nothing should have been written") }
    }

    func testARetryDoesNotLeaveAnExtraDelayedSaveBehind() async throws {
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1 // schedules the debounced save
        let before = access.requestCount
        m.retrySidecarSave()
        XCTAssertEqual(access.requestCount, before + 1)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(access.requestCount, before + 1, "the superseded delayed save must not fire")
    }

    // MARK: Write failure

    func testAWriteFailureIsPublishedAndARetryAfterItIsFixedClearsIt() async throws {
        let m = model()
        await m.load(from: photoA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        guard case .writeFailed(let reason) = m.sidecarSaveStatus else { return XCTFail("got \(m.sidecarSaveStatus)") }
        XCTAssertFalse(reason.isEmpty)
        m.sidecarSaveErrorMessage = nil
        m.flushPendingSidecarSave()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        m.retrySidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail("retry must write") }
        XCTAssertEqual(stored.exposureEV, 1, accuracy: 1e-9)
    }

    func testASuccessfulSaveClearsAnEarlierWriteFailure() async throws {
        let m = model()
        await m.load(from: photoA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        XCTAssertEqual(m.sidecarSaveStatus, .ok)
    }

    func testASilentWriteFailureStillPublishesTheStatus() async throws {
        let m = model()
        await m.load(from: photoA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        m.editState.exposureEV = 1
        m.saveSidecarNowForTesting(suppressErrorMessage: true)
        XCTAssertNil(m.sidecarSaveErrorMessage)
        guard case .writeFailed = m.sidecarSaveStatus else { return XCTFail("got \(m.sidecarSaveStatus)") }
    }
}
