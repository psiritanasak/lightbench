import XCTest
import CoreImage
@testable import PhotoApp

/// IMPROVEMENTS.md D28: `saveSidecarNow` used to read `editState` AFTER the folder-access step (which can show a modal
/// `NSOpenPanel` that pumps the run loop), so anything that changed `editState`/`currentURL` during that step was
/// written into the sidecar of the photo whose save had started.
///
/// REACHABILITY IS UNDETERMINED (probes 2026-10-02, a stub that spins the main run loop like the panel): a toy
/// multi-hop main-actor Task completes inside the nested loop when the spin starts from a run-loop TIMER callback
/// (event-like) but NOT from a main-queue block or a Swift job; and a REAL `load(from:)` queued before the save did
/// not complete in 10s even from a timer callback (so the full D28 interleave was never reproduced). Treat the fix as
/// defensive hardening. These tests pin it at the level that IS deterministic: the (photo, edits) pair is snapshotted
/// before the panel step, so a change made while the panel is up cannot leak into the write.
@MainActor
final class SaveSidecarRaceTests: XCTestCase {
    private var dir: URL!
    private var photoA: URL!
    private var photoB: URL!
    private var scopedFolder: URL!

    /// Stands in for `SidecarFolderAccess`; `duringPanel` runs inside `resolveOrRequest`.
    private final class PanelStub: SidecarFolderAccessing {
        var outcome: SidecarFolderAccess.Outcome
        var duringPanel: (() -> Void)?
        private(set) var requests = 0
        init(outcome: SidecarFolderAccess.Outcome) { self.outcome = outcome }
        func resolvedURL(for folder: URL) -> URL? { nil } // never silently resolved: every save "prompts"
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
            requests += 1
            duringPanel?()
            return outcome
        }
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SaveSidecarRaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photoA = dir.appendingPathComponent("a.png")
        photoB = dir.appendingPathComponent("b.png")
        for url in [photoA!, photoB!] {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // A genuinely security-scoped URL: `startAccessingSecurityScopedResource()` is false for a plain one.
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scopedFolder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func openPhotoA(with stub: SidecarFolderAccessing) async -> ImageDocumentModel {
        let model = ImageDocumentModel(folderAccess: stub)
        await model.load(from: photoA)
        return model
    }

    func testAChangeMadeWhileThePanelIsUpDoesNotLeakIntoTheSavedSidecar() async throws {
        let stub = PanelStub(outcome: .granted(scopedFolder))
        let model = await openPhotoA(with: stub)
        var saved: [URL] = []
        model.onSidecarSaved = { saved.append($0) }
        model.editState.exposureEV = 1.5 // the edit the user wants saved for A
        // While the (modal) panel is up the model's live state changes — a cheaper, load-free variant of the same bug.
        stub.duringPanel = { model.editState.exposureEV = 9 }

        model.flushPendingSidecarSave()

        XCTAssertEqual(stub.requests, 1)
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail("A's sidecar must exist") }
        XCTAssertEqual(stored.exposureEV, 1.5, "the snapshot taken BEFORE the panel is what gets written, not the live state after it")
        XCTAssertEqual(saved.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(model.editState.exposureEV, 9, "the live state itself is untouched; its own debounced save handles it")
    }

    func testAnOrdinarySaveStillWritesTheCurrentPhotosState() async throws {
        let stub = PanelStub(outcome: .granted(scopedFolder))
        let model = await openPhotoA(with: stub)
        model.editState.exposureEV = -0.75
        model.flushPendingSidecarSave()
        guard case .decoded(let stored) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail("sidecar expected") }
        XCTAssertEqual(stored.exposureEV, -0.75)
    }

    func testADeclinedFolderWritesNothingAndIsRemembered() async throws {
        let stub = PanelStub(outcome: .declined)
        let model = await openPhotoA(with: stub)
        model.editState.exposureEV = 1
        model.flushPendingSidecarSave()
        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoA), .missing)
        XCTAssertEqual(stub.requests, 1)
        model.editState.exposureEV = 2
        model.flushPendingSidecarSave()
        XCTAssertEqual(stub.requests, 1, "a declined folder is not asked again this session")
    }

    func testAFailedAccessSurfacesTheErrorAndWritesNothing() async throws {
        struct Boom: Error {}
        let stub = PanelStub(outcome: .failed(Boom()))
        let model = await openPhotoA(with: stub)
        model.editState.exposureEV = 1
        model.flushPendingSidecarSave()
        XCTAssertEqual(SidecarStore.read(forPhotoAt: photoA), .missing)
        XCTAssertNotNil(model.sidecarSaveErrorMessage)
    }
}
