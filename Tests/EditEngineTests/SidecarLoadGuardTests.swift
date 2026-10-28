import XCTest
import CoreImage
@testable import PhotoApp

/// D81: the Editor must never overwrite a sidecar it did not load. Two layers: a load that still reads the sidecar when no
/// sidecar-save bookmark resolves (folders imported by drop / Finder-open / Import only have the catalog's), and a save-time
/// guard that refuses to replace an existing sidecar the model neither loaded nor wrote itself.
@MainActor
final class SidecarLoadGuardTests: XCTestCase {
    /// `resolvedURL` is nil (no sidecar bookmark) unless `resolves`; `resolveOrRequest` always grants the scoped folder.
    private final class Access: SidecarFolderAccessing {
        let folder: URL
        let resolves: Bool
        init(_ folder: URL, resolves: Bool) { self.folder = folder; self.resolves = resolves }
        func resolvedURL(for folder: URL) -> URL? { resolves ? self.folder : nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(self.folder) }
    }

    private static let versionKey = "abcdef01"
    private var dir: URL!
    private var photoA: URL!
    private var photoB: URL!
    private var scoped: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarLoadGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photoA = dir.appendingPathComponent("a.png")
        photoB = dir.appendingPathComponent("b.png")
        for url in [photoA!, photoB!] {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scoped = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func model(resolves: Bool = false) -> ImageDocumentModel {
        ImageDocumentModel(folderAccess: Access(scoped, resolves: resolves))
    }

    private func sidecarFile(_ photo: URL, versionKey: String? = nil) throws -> URL {
        try XCTUnwrap(SidecarStore.versionedSidecarURL(for: photo, versionKey: versionKey))
    }

    private func sidecarBytes(_ photo: URL, versionKey: String? = nil) throws -> Data {
        try Data(contentsOf: sidecarFile(photo, versionKey: versionKey))
    }

    private func writeGarbage(for photo: URL, versionKey: String? = nil) throws {
        try Data("{ not json".utf8).write(to: sidecarFile(photo, versionKey: versionKey))
    }

    // MARK: Load fallback

    func testLoadReadsTheSidecarEvenWithoutASidecarBookmark() async throws {
        var state = EditState(); state.exposureEV = 1.25
        try SidecarStore.write(state, forPhotoAt: photoA)
        let m = model(resolves: false)
        await m.load(from: photoA)
        XCTAssertEqual(m.editState.exposureEV, 1.25, accuracy: 1e-9, "was identity before D81")
    }

    func testLoadFallbackAlsoRestoresPersistedHistory() async throws {
        let writer = model(resolves: true)
        await writer.load(from: photoA)
        for ev in [0.5, 1.0] {
            writer.editState.exposureEV = ev
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        writer.flushPendingSidecarSave()
        let expected = writer.historyEntries.map(\.summary)
        XCTAssertEqual(expected.count, 3)
        let m = model(resolves: false)
        await m.load(from: photoA)
        XCTAssertEqual(m.historyEntries.map(\.summary), expected)
    }

    func testLoadWithAResolvingBookmarkIsUnchanged() async throws {
        var state = EditState(); state.exposureEV = -0.5
        try SidecarStore.write(state, forPhotoAt: photoA)
        let m = model(resolves: true)
        await m.load(from: photoA)
        XCTAssertEqual(m.editState.exposureEV, -0.5, accuracy: 1e-9)
    }

    // MARK: Save guard

    func testASidecarWrittenBehindTheModelsBackIsNotOverwritten() async throws {
        let m = model()
        await m.load(from: photoA) // no sidecar yet
        var foreign = EditState(); foreign.exposureEV = 3
        try SidecarStore.write(foreign, forPhotoAt: photoA)
        let before = try sidecarBytes(photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoA), before)
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
    }

    func testAnUndecodableSidecarPresentAtOpenIsNotOverwritten() async throws {
        try writeGarbage(for: photoA)
        let before = try sidecarBytes(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoA), before)
        XCTAssertTrue(m.sidecarSaveErrorMessage?.contains("can't be read") == true)
    }

    func testARefusalDoesNotDeclineTheFolder() async throws {
        try writeGarbage(for: photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
        // Photo B in the SAME folder has no sidecar: its save must still go through (the folder was not declined).
        await m.load(from: photoB)
        m.sidecarSaveErrorMessage = nil
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoB) else { return XCTFail("B must be saved") }
        XCTAssertEqual(stored.exposureEV, 2, accuracy: 1e-9)
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testARefusedPhotoCanBeEditedAgainAfterReopeningOnceItsSidecarIsLoadable() async throws {
        try writeGarbage(for: photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
        var good = EditState(); good.exposureEV = 4
        try SidecarStore.write(good, forPhotoAt: photoA)
        await m.load(from: photoA) // "close and reopen"
        m.sidecarSaveErrorMessage = nil
        m.editState.exposureEV = 5
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 5, accuracy: 1e-9)
    }

    func testALoadedSidecarIsEditedAndWritten() async throws {
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 2, accuracy: 1e-9)
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testConsecutiveSavesAfterTheModelsOwnFirstWriteAllLand() async throws {
        let m = model()
        await m.load(from: photoA) // no sidecar: first save creates it
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 2, accuracy: 1e-9, "the second save must not see its own first write as foreign")
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testOwnershipIsResetByEachLoad() async throws {
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave() // A owned
        try writeGarbage(for: photoB) // B has a foreign, undecodable sidecar
        let before = try sidecarBytes(photoB)
        await m.load(from: photoB)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoB), before, "A's ownership must not carry over to B")
        // Back to A: ownership is re-established by decoding its sidecar on load.
        await m.load(from: photoA)
        m.sidecarSaveErrorMessage = nil
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 2, accuracy: 1e-9)
    }

    func testReloadingTheSamePhotoDropsOwnershipOfAFileThatBecameForeign() async throws {
        // Owned after the first write; the file is then replaced by garbage; a RELOAD (which cannot decode it) must not
        // keep the old ownership.
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        try writeGarbage(for: photoA)
        let before = try sidecarBytes(photoA)
        await m.load(from: photoA)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoA), before)
    }

    func testRevertAndPasteOnAnOwnedPhotoStillWrite() async throws {
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        var pasted = EditState(); pasted.contrast = 0.4
        _ = m.pasteSettings(pasted)
        m.flushPendingSidecarSave()
        guard case .decoded(let afterPaste) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(afterPaste.contrast, 0.4, accuracy: 1e-9)
        m.revertToOriginal()
        m.flushPendingSidecarSave()
        guard case .decoded(let afterRevert) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(afterRevert.contrast, 0, accuracy: 1e-9)
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testAVersionSidecarIsGuardedByItsOwnKey() async throws {
        // The master's sidecar is decodable; the copy's own edit file is a foreign, undecodable file.
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: photoA)
        try writeGarbage(for: photoA, versionKey: Self.versionKey)
        let before = try sidecarBytes(photoA, versionKey: Self.versionKey)
        let m = model()
        await m.load(from: photoA, versionKey: Self.versionKey)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoA, versionKey: Self.versionKey), before)
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
        guard case .decoded(let master) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(master.exposureEV, 1, accuracy: 1e-9, "the master's sidecar is untouched")
    }

    func testSwitchingFromAMasterToItsCopyDoesNotCarryOwnershipOver() async throws {
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave() // the master is owned
        try writeGarbage(for: photoA, versionKey: Self.versionKey)
        let before = try sidecarBytes(photoA, versionKey: Self.versionKey)
        await m.load(from: photoA, versionKey: Self.versionKey)
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        XCTAssertEqual(try sidecarBytes(photoA, versionKey: Self.versionKey), before)
    }

    // MARK: Alert once, messages, silent saves, panel race

    func testARefusalAlertIsShownOncePerLoad() async throws {
        try writeGarbage(for: photoA)
        let before = try sidecarBytes(photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
        m.sidecarSaveErrorMessage = nil // the user dismissed the alert
        m.editState.exposureEV = 2
        m.flushPendingSidecarSave()
        m.editState.exposureEV = 3
        m.flushPendingSidecarSave()
        XCTAssertNil(m.sidecarSaveErrorMessage, "later saves for the same refused photo stay silent")
        XCTAssertEqual(try sidecarBytes(photoA), before)
        await m.load(from: photoA) // reopening clears the once-flag
        m.editState.exposureEV = 4
        m.flushPendingSidecarSave()
        XCTAssertNotNil(m.sidecarSaveErrorMessage, "a fresh load may tell the user again")
    }

    func testDecodedAndUndecodableRefusalsHaveDifferentMessages() async throws {
        var foreign = EditState(); foreign.exposureEV = 3
        try SidecarStore.write(foreign, forPhotoAt: photoB)
        let m = model()
        await m.load(from: photoA)
        try SidecarStore.write(foreign, forPhotoAt: photoA) // decodable, written behind the model's back
        m.editState.exposureEV = 1
        m.flushPendingSidecarSave()
        let decodedMessage = try XCTUnwrap(m.sidecarSaveErrorMessage)
        let n = model()
        try writeGarbage(for: photoA)
        await n.load(from: photoA)
        n.editState.exposureEV = 1
        n.flushPendingSidecarSave()
        let undecodableMessage = try XCTUnwrap(n.sidecarSaveErrorMessage)
        XCTAssertNotEqual(decodedMessage, undecodableMessage)
        XCTAssertTrue(undecodableMessage.contains("can't be read"))
        XCTAssertTrue(decodedMessage.contains("wasn't loaded"))
    }

    func testASilentRefusedSaveShowsNothingAndDoesNotArmTheOnceFlag() async throws {
        try writeGarbage(for: photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1
        m.saveSidecarNowForTesting(suppressErrorMessage: true)
        XCTAssertNil(m.sidecarSaveErrorMessage)
        m.saveSidecarNowForTesting()
        XCTAssertNotNil(m.sidecarSaveErrorMessage, "the user's own save still tells them")
    }

    func testTheSilentSaveOfAnOwnedPhotoStillWrites() async throws {
        // The shape of the decoder-pin backfill: an automatic, error-suppressed save of a photo whose sidecar was loaded.
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: photoA)
        let m = model()
        await m.load(from: photoA)
        m.editState.exposureEV = 1.5
        m.saveSidecarNowForTesting(suppressErrorMessage: true)
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 1.5, accuracy: 1e-9)
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testALoadFinishingInsideTheAccessPanelDoesNotMakeThePhotosOwnSaveForeign() async throws {
        final class PanelHook: SidecarFolderAccessing {
            let folder: URL
            var duringPanel: (() -> Void)?
            init(_ folder: URL) { self.folder = folder }
            func resolvedURL(for folder: URL) -> URL? { nil }
            func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
                duringPanel?()
                return .granted(self.folder)
            }
        }
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: photoA)
        let hook = PanelHook(scoped)
        let m = ImageDocumentModel(folderAccess: hook)
        await m.load(from: photoA) // A is owned
        m.editState.exposureEV = 2
        // While the panel is up "a load of B finishes": ownership now names another photo.
        hook.duringPanel = {
            m.simulateLoadFinishedForTesting(url: self.photoB, ownedKey: nil) // B opened inside the panel, no sidecar
        }
        m.saveSidecarNowForTesting()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail() }
        XCTAssertEqual(stored.exposureEV, 2, accuracy: 1e-9, "A's snapshot was owned when the save began")
        XCTAssertNil(m.sidecarSaveErrorMessage)
    }

    func testPastingOntoAnOpenPhotoWhoseSaveWasRefusedReportsSkipped() async throws {
        var pasted = EditState(); pasted.contrast = 0.4
        for foreignDecodable in [false, true] {
            if !foreignDecodable { try writeGarbage(for: photoA) }
            let m = model()
            await m.load(from: photoA)
            if foreignDecodable { // written behind the model's back after open
                var foreign = EditState(); foreign.exposureEV = 3
                try SidecarStore.write(foreign, forPhotoAt: photoA)
            }
            let before = try sidecarBytes(photoA)
            XCTAssertEqual(m.pasteSettings(pasted), .skipped, "first paste (foreignDecodable: \(foreignDecodable))")
            pasted.contrast += 0.1
            XCTAssertEqual(m.pasteSettings(pasted), .skipped, "second paste, refusal already armed")
            XCTAssertEqual(try sidecarBytes(photoA), before)
            try FileManager.default.removeItem(at: sidecarFile(photoA))
        }
    }

    func testTheSamePhotoReloadedInsideThePanelIsStillGuarded() async throws {
        final class PanelHook: SidecarFolderAccessing {
            let folder: URL
            var duringPanel: (() -> Void)?
            init(_ folder: URL) { self.folder = folder }
            func resolvedURL(for folder: URL) -> URL? { nil }
            func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
                duringPanel?()
                return .granted(self.folder)
            }
        }
        var state = EditState(); state.exposureEV = 1
        try SidecarStore.write(state, forPhotoAt: photoA)
        let hook = PanelHook(scoped)
        let m = ImageDocumentModel(folderAccess: hook)
        await m.load(from: photoA) // owned at the start of the save
        m.editState.exposureEV = 2
        let garbage = Data("{ not json".utf8)
        let file = try sidecarFile(photoA)
        hook.duringPanel = {
            // A reload of the SAME photo finishing inside the panel could not decode the (now broken) file.
            try? garbage.write(to: file)
            m.sidecarOwnedEditKey_forTesting = nil
        }
        m.saveSidecarNowForTesting()
        XCTAssertEqual(try Data(contentsOf: file), garbage, "the broken file is left untouched")
        XCTAssertNotNil(m.sidecarSaveErrorMessage)
    }
}
