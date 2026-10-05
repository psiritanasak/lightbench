import XCTest
import CoreImage
@testable import PhotoApp

/// Persisted edit history: the `_history` key in a photo's sidecar, written by `saveSidecarNow` and restored by `load(from:)`
/// only while it is consistent with the sidecar's own edits.
@MainActor
final class PersistedHistoryTests: XCTestCase {
    private final class GrantedAccess: SidecarFolderAccessing {
        let folder: URL
        init(_ folder: URL) { self.folder = folder }
        func resolvedURL(for folder: URL) -> URL? { self.folder }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(self.folder) }
    }

    private var dir: URL!
    private var photo: URL!
    private var access: GrantedAccess!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PersistedHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photo = dir.appendingPathComponent("a.png")
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: image, to: photo, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        access = GrantedAccess(try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func openModel() async -> ImageDocumentModel {
        let model = ImageDocumentModel(folderAccess: access)
        await model.load(from: photo)
        return model
    }

    /// Three settled edits, then a flush (what a photo switch does). Returns the model's history summaries.
    private func makeEditedSidecar() async throws -> [String] {
        let model = await openModel()
        for ev in [0.5, 1.0, 1.5] {
            model.editState.exposureEV = ev
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        model.flushPendingSidecarSave()
        return model.historyEntries.map(\.summary)
    }

    func testHistorySurvivesReloadAndUndoWalksBackAcrossIt() async throws {
        let summaries = try await makeEditedSidecar()
        XCTAssertEqual(summaries.count, 4)
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.map(\.summary), summaries)
        XCTAssertEqual(reloaded.editState.exposureEV, 1.5, accuracy: 1e-9)
        reloaded.undo()
        XCTAssertEqual(reloaded.editState.exposureEV, 1.0, accuracy: 1e-9)
        reloaded.undo(); reloaded.undo()
        XCTAssertEqual(reloaded.editState.exposureEV, 0, accuracy: 1e-9)
    }

    func testAFlushInsideTheCoalescingWindowStillPersistsTheLatestStep() async throws {
        let model = await openModel()
        model.editState.exposureEV = 2 // no sleep: the history commit is still pending
        model.flushPendingSidecarSave()
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.count, 2)
        XCTAssertEqual(reloaded.editState.exposureEV, 2, accuracy: 1e-9)
    }

    func testASidecarRewrittenWithoutHistoryLoadsWithAFreshOpenedRow() async throws {
        _ = try await makeEditedSidecar()
        var state = EditState(); state.exposureEV = 1.5
        try SidecarStore.write(state, forPhotoAt: photo) // batch-paste shape: no `_history`
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.count, 1)
        XCTAssertEqual(reloaded.editState.exposureEV, 1.5, accuracy: 1e-9)
    }

    func testAHistoryWhoseCurrentStateDiffersFromTheSidecarIsDiscarded() async throws {
        _ = try await makeEditedSidecar()
        let archive = try XCTUnwrap(SidecarStore.readHistory(forPhotoAt: photo))
        let object = try XCTUnwrap(HistoryArchive(entries: archive.entries, currentIndex: archive.currentIndex).jsonObject())
        var other = EditState(); other.exposureEV = -1 // edited elsewhere (e.g. an older build) after the history was written
        try SidecarStore.write(other, historyObject: object, forPhotoAt: photo)
        XCTAssertNil(SidecarStore.readHistory(forPhotoAt: photo))
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.count, 1)
        XCTAssertEqual(reloaded.editState.exposureEV, -1, accuracy: 1e-9)
    }

    func testAnUneditedPhotoWritesNoHistoryKeyAndAnOlderSidecarLoadsAsBefore() async throws {
        var state = EditState(); state.exposureEV = 0.7
        try SidecarStore.write(state, forPhotoAt: photo)
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.count, 1)
        let data = try Data(contentsOf: SidecarStore.sidecarURL(for: photo))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object[HistoryArchive.sidecarKey])
    }

    func testAnOlderReaderStillDecodesTheEditStateFromAHistoryBearingSidecar() async throws {
        _ = try await makeEditedSidecar()
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: photo) else { return XCTFail("sidecar must still decode") }
        XCTAssertEqual(state.exposureEV, 1.5, accuracy: 1e-9)
    }

    /// Drag-like doubles need 17 significant digits; the consistency check must survive that re-serialisation round trip.
    func testLongDecimalValuesStillRestore() async throws {
        let model = await openModel()
        model.editState.exposureEV = 0.1 + 0.2
        try await Task.sleep(nanoseconds: 500_000_000)
        model.editState.contrast = 0.0729922544083155
        try await Task.sleep(nanoseconds: 500_000_000)
        model.flushPendingSidecarSave()
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.historyEntries.count, 3)
        XCTAssertEqual(reloaded.editState.exposureEV, 0.1 + 0.2)
        XCTAssertEqual(reloaded.editState.contrast, 0.0729922544083155)
    }

    func testHistoryDoesNotLeakIntoAnotherPhotosSidecar() async throws {
        _ = try await makeEditedSidecar()
        let second = dir.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: photo, to: second)
        let model = await openModel()
        await model.load(from: second)
        XCTAssertEqual(model.historyEntries.count, 1)
        XCTAssertNil(SidecarStore.readHistory(forPhotoAt: second))
    }
}
