import XCTest
import CoreImage
@testable import PhotoApp

/// A Targeted drag must never straddle, overwrite or outlive another edit: every other edit path ends it first, only the touched
/// fields are ever written, cancel never clobbers later edits, and the persisted `_history` includes the step.
@MainActor
final class TargetedDragLifecycleTests: XCTestCase {
    private final class GrantedAccess: SidecarFolderAccessing {
        let folder: URL
        init(_ folder: URL) { self.folder = folder }
        func resolvedURL(for folder: URL) -> URL? { self.folder }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(self.folder) }
    }

    private var dir: URL!
    private var photo: URL!
    private var photo2: URL!
    private var access: GrantedAccess!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TargetedDragLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photo = dir.appendingPathComponent("a.png")
        photo2 = dir.appendingPathComponent("b.png")
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        for url in [photo!, photo2!] {
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        access = GrantedAccess(try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let grey: (r: Double, g: Double, b: Double) = (0.5, 0.5, 0.5)
    private let red: (r: Double, g: Double, b: Double) = (0.8, 0.2, 0.2)

    private func openModel(sample: (r: Double, g: Double, b: Double)? = nil) async -> ImageDocumentModel {
        let model = ImageDocumentModel(folderAccess: access)
        await model.load(from: photo)
        let value = sample ?? grey
        model.targetSampler = { _, _, _ in value }
        return model
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 500_000_000) }

    /// The state at the history cursor (what the history says the photo looks like).
    private func historyState(_ model: ImageDocumentModel) -> EditState { model.historyEntries[model.currentHistoryIndex].state }

    private func startedCurveDrag(_ model: ImageDocumentModel, delta: Double = 0.1) {
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: delta)
    }

    // MARK: - Other edit sources end the drag first

    func testUndoMidDragCommitsTheDragThenUndoesIt() async throws {
        let model = await openModel()
        model.editState.contrast = 0.3
        try await settle()
        startedCurveDrag(model)
        model.undo()
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertEqual(model.editState.toneCurvePoints, [], "undo undid the dragged step, not a stale state")
        XCTAssertEqual(model.editState.contrast, 0.3, accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(model.editState.toneCurvePoints.count, 3, "the drag's step is in history and redoable")
    }

    func testRevertMidDragEndsItAndRevertWins() async throws {
        let model = await openModel()
        model.editState.contrast = 0.3
        try await settle()
        startedCurveDrag(model)
        model.revertToOriginal()
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertEqual(model.editState.toneCurvePoints, [])
        XCTAssertEqual(model.editState.contrast, 0)
        try await settle()
        XCTAssertEqual(model.editState.toneCurvePoints, [], "no late write resurrects the drag")
    }

    func testPasteMidDragEndsItAndKeepsThePastedState() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        var pasted = EditState()
        pasted.vibrance = 0.5
        _ = model.pasteSettings(pasted)
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertEqual(model.editState.vibrance, 0.5, accuracy: 1e-9)
    }

    func testHistoryJumpMidDragEndsItFirst() async throws {
        let model = await openModel()
        model.editState.contrast = 0.3
        try await settle()
        startedCurveDrag(model)
        let first = try XCTUnwrap(model.historyEntries.first)
        model.jumpToHistory(id: first.id)
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertEqual(model.editState, EditState(), "jumped to the opened state, nothing of the drag left on top")
    }

    func testAnEditAfterTheDragLayerGoesAwayIsStillRecorded() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        model.endTargetedDrag() // what the view does when the layer's gate turns false or the gesture is cancelled
        let steps = model.historyEntries.count
        model.editState.contrast = 0.4
        try await settle()
        XCTAssertEqual(model.historyEntries.count, steps + 1, "coalescing is not stuck suppressed")
        XCTAssertEqual(model.editState.contrast, 0.4, accuracy: 1e-9)
    }

    func testCancelledDragLeavesCoalescingWorking() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        model.cancelTargetedDrag()
        let steps = model.historyEntries.count
        model.editState.contrast = 0.4
        try await settle()
        XCTAssertEqual(model.historyEntries.count, steps + 1)
    }

    // MARK: - Only touched fields; cancel never clobbers

    func testAnotherEditDuringTheDragSurvivesUpdatesAndEnd() async throws {
        let model = await openModel()
        startedCurveDrag(model, delta: 0.1)
        // A direct write to another field while the drag runs (the shape of an async writer such as Fix Color Cast; the paths
        // that go through `finalizePendingCommit` end the drag instead, see the undo/revert/paste tests above).
        model.editState.contrast = 0.4
        model.updateTargetedDrag(delta: 0.15)
        model.endTargetedDrag()
        XCTAssertEqual(model.editState.contrast, 0.4, accuracy: 1e-9)
        XCTAssertEqual(model.editState.toneCurvePoints.count, 3)
        // It is its OWN history step, not folded into the "Targeted Curve" row.
        XCTAssertEqual(model.historyEntries.last?.summary, "Targeted Curve")
        XCTAssertEqual(try XCTUnwrap(model.historyEntries.last).state.contrast, 0, "the Targeted row holds the drag's fields only")
        try await settle()
        XCTAssertEqual(model.historyEntries.count, 3, "opened, Targeted Curve, then the separate contrast step")
        XCTAssertEqual(historyState(model), model.editState)
    }

    func testCancelRestoresOnlyTheTouchedFields() async throws {
        let model = await openModel(sample: red)
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.saturation), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.4)
        model.editState.contrast = 0.4
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState.redSaturation, 0, accuracy: 1e-9)
        XCTAssertEqual(model.editState.orangeSaturation, 0, accuracy: 1e-9)
        XCTAssertEqual(model.editState.contrast, 0.4, accuracy: 1e-9, "the later edit is not rolled back")
        try await settle()
        XCTAssertEqual(historyState(model), model.editState, "the later edit was committed, not left unrecorded")
        XCTAssertEqual(model.historyEntries.count, 2)
    }

    func testCancelDoesNothingWhenTheTouchedFieldsWereChangedByAnotherEdit() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        let other = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.2, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        model.editState.toneCurvePoints = other
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState.toneCurvePoints, other)
        XCTAssertFalse(model.isTargetedDragActive)
    }

    func testCancelBeforeAnyUpdateChangesNothing() async throws {
        let model = await openModel()
        model.editState.contrast = 0.2
        try await settle()
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState.contrast, 0.2, accuracy: 1e-9)
        XCTAssertEqual(model.editState.toneCurvePoints, [])
    }

    /// A drag ended from outside (another edit path) while the pointer is still down: the view makes no second begin, so further
    /// moves reach a model with no drag and change nothing.
    func testMovesAfterAnExternallyEndedDragApplyNothing() async throws {
        let model = await openModel(sample: red)
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.saturation), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.3)
        model.undo() // ends (commits) the drag, then undoes it
        XCTAssertFalse(model.isTargetedDragActive)
        let state = model.editState
        let steps = model.historyEntries.count
        XCTAssertTrue(model.canRedo)
        model.updateTargetedDrag(delta: 0.6)
        model.updateTargetedDrag(delta: 0.9)
        XCTAssertEqual(model.editState, state)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertTrue(model.canRedo, "redo was not dropped")
    }

    func testDragBegunTwiceKeepsTheFirstDrag() async throws {
        let model = await openModel()
        startedCurveDrag(model, delta: 0.1)
        XCTAssertFalse(model.beginTargetedDrag(tool: .curve, normalizedX: 0.1, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.2)
        model.endTargetedDrag()
        XCTAssertEqual(model.editState.toneCurvePoints.count, 3)
    }

    func testBlackAndWhiteMixRefusesToStartWhileBlackAndWhiteIsOff() async throws {
        let model = await openModel(sample: red)
        XCTAssertFalse(model.beginTargetedDrag(tool: .grayMix, normalizedX: 0.5, normalizedY: 0.5))
        model.editState.blackAndWhite = true
        try await settle()
        XCTAssertTrue(model.beginTargetedDrag(tool: .grayMix, normalizedX: 0.5, normalizedY: 0.5))
        model.endTargetedDrag()
    }

    // MARK: - Persisted history

    private func persistedSummaries(_ url: URL) throws -> [String] {
        let archive = try XCTUnwrap(SidecarStore.readHistory(forPhotoAt: url))
        return archive.entries.map(\.summary)
    }

    func testSidecarHistoryHoldsTheStepAfterADragWithALongPause() async throws {
        let model = await openModel()
        XCTAssertTrue(model.beginTargetedDrag(tool: .curve, normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.1)
        // Longer than the ~1 s sidecar debounce: the sidecar is written mid-drag (without a history that matches the state).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // No further update: only the save the END schedules can put the history into the sidecar now.
        model.endTargetedDrag()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(try persistedSummaries(photo).contains("Targeted Curve"))
        let reloaded = await openModel()
        XCTAssertEqual(reloaded.editState.toneCurvePoints.count, 3)
        XCTAssertEqual(reloaded.historyEntries.last?.summary, "Targeted Curve")
    }

    func testFlushMidDragCommitsTheDragIntoThePersistedHistory() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        model.flushPendingSidecarSave() // the quit / leave-the-editor path
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertTrue(try persistedSummaries(photo).contains("Targeted Curve"))
    }

    /// The sidecar debounce already fired mid-drag (so `flushPendingSidecarSave` would find no pending save): the flush must still
    /// end the drag and persist its step.
    func testFlushAfterTheMidDragSaveAlreadyFiredStillPersistsTheStep() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        model.flushPendingSidecarSave()
        XCTAssertFalse(model.isTargetedDragActive)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(try persistedSummaries(photo).contains("Targeted Curve"))
    }

    func testCurveCancelKeepsAnEditToAnotherField() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        model.editState.contrast = 0.4
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState.toneCurvePoints, [])
        XCTAssertEqual(model.editState.contrast, 0.4, accuracy: 1e-9)
    }

    func testBandCancelDoesNothingWhenAnotherEditChangedTheTouchedBand() async throws {
        let model = await openModel(sample: red)
        XCTAssertTrue(model.beginTargetedDrag(tool: .selectiveColor(.saturation), normalizedX: 0.5, normalizedY: 0.5))
        model.updateTargetedDrag(delta: 0.4)
        model.editState.redSaturation = -0.7 // a slider moved by hand mid-drag
        model.cancelTargetedDrag()
        XCTAssertEqual(model.editState.redSaturation, -0.7, accuracy: 1e-9)
        try await settle()
        XCTAssertEqual(historyState(model), model.editState, "the hand edit was committed after the cancel")
        XCTAssertEqual(model.historyEntries.count, 2)
    }

    func testSwitchingPhotosMidDragCommitsToTheOutgoingPhotoHistory() async throws {
        let model = await openModel()
        startedCurveDrag(model)
        await model.load(from: photo2)
        XCTAssertFalse(model.isTargetedDragActive)
        XCTAssertEqual(model.editState.toneCurvePoints, [], "the new photo is untouched")
        XCTAssertTrue(try persistedSummaries(photo).contains("Targeted Curve"))
    }
}
