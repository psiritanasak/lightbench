import XCTest
@testable import PhotoApp

/// Verifies `EditHistory`'s pure past/future stack logic — extracted from
/// `ImageDocumentModel`'s debounced coalescing glue so the actual undo/redo
/// bookkeeping gets direct, timing-free unit test coverage, matching the
/// established `CropAspectMath`/`RedEyeHitTest` precedent for pulling real
/// logic out of the UI layer into a testable pure type.
final class EditHistoryTests: XCTestCase {
    private func state(exposure: Double) -> EditState {
        var state = EditState()
        state.exposureEV = exposure
        return state
    }

    func testFreshHistoryCannotUndoOrRedo() {
        let history = EditHistory()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.current, .identity)
    }

    func testCommitThenUndoRestoresThePriorState() {
        var history = EditHistory(.identity)
        history.commit(state(exposure: 1.0))

        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.current, state(exposure: 1.0))

        history.undo()

        XCTAssertEqual(history.current, .identity)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
    }

    func testRedoReappliesTheUndoneState() {
        var history = EditHistory(.identity)
        history.commit(state(exposure: 1.0))
        history.undo()
        history.redo()

        XCTAssertEqual(history.current, state(exposure: 1.0))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testCommittingTheCurrentValueIsANoOp() {
        // A burst that nets no actual change (e.g. a slider dragged back to
        // its starting value) must not create a phantom undo step.
        var history = EditHistory(.identity)
        history.commit(.identity)

        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.current, .identity)
    }

    func testNewCommitAfterUndoClearsTheRedoStack() {
        var history = EditHistory(.identity)
        history.commit(state(exposure: 1.0))
        history.undo()
        XCTAssertTrue(history.canRedo)

        history.commit(state(exposure: 2.0))

        XCTAssertFalse(history.canRedo, "committing a new edit after an undo should abandon the redone-from branch")
        XCTAssertEqual(history.current, state(exposure: 2.0))
    }

    func testUndoOnEmptyPastIsASafeNoOp() {
        var history = EditHistory(.identity)
        history.undo()

        XCTAssertEqual(history.current, .identity)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testRedoOnEmptyFutureIsASafeNoOp() {
        var history = EditHistory(.identity)
        history.commit(state(exposure: 1.0))
        history.redo()

        XCTAssertEqual(history.current, state(exposure: 1.0))
        XCTAssertFalse(history.canRedo)
    }

    func testDeepUndoRedoSequenceLandsOnExpectedStatesInOrder() {
        var history = EditHistory(.identity)
        history.commit(state(exposure: 1.0))
        history.commit(state(exposure: 2.0))
        history.commit(state(exposure: 3.0))

        history.undo()
        XCTAssertEqual(history.current, state(exposure: 2.0))
        history.undo()
        XCTAssertEqual(history.current, state(exposure: 1.0))
        history.undo()
        XCTAssertEqual(history.current, .identity)
        XCTAssertFalse(history.canUndo)

        history.redo()
        XCTAssertEqual(history.current, state(exposure: 1.0))
        history.redo()
        XCTAssertEqual(history.current, state(exposure: 2.0))
        history.redo()
        XCTAssertEqual(history.current, state(exposure: 3.0))
        XCTAssertFalse(history.canRedo)
    }

    /// `Mask` is the first nested type inside `EditState.masks` whose own
    /// `Equatable` conformance this stack's no-op guard depends on — pins
    /// that a drag that nets no actual change to a mask (same shape as
    /// `testCommittingTheCurrentValueIsANoOp`, but exercising the new
    /// array field specifically) still doesn't create a phantom undo step.
    func testCommittingAnUnchangedMaskIsANoOp() {
        var withMask = EditState.identity
        withMask.masks = [Mask(centerX: 0.4, centerY: 0.4, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]
        var history = EditHistory(withMask)

        history.commit(withMask)

        XCTAssertFalse(history.canUndo)
    }

    func testDistinctMasksProduceDistinctHistoryEntries() {
        var history = EditHistory(.identity)
        var withFirstMask = EditState.identity
        withFirstMask.masks = [Mask(centerX: 0.3, centerY: 0.3, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]
        var withSecondMask = EditState.identity
        withSecondMask.masks = [Mask(centerX: 0.7, centerY: 0.7, radiusX: 0.2, radiusY: 0.2, exposureEV: 0.5)]

        history.commit(withFirstMask)
        history.commit(withSecondMask)

        XCTAssertEqual(history.current, withSecondMask)
        history.undo()
        XCTAssertEqual(history.current, withFirstMask)
        history.undo()
        XCTAssertEqual(history.current, .identity)
    }

    func testCommitBeyondTheLimitDropsTheOldestStep() {
        var history = EditHistory(.identity, limit: 2)
        history.commit(state(exposure: 1.0))
        history.commit(state(exposure: 2.0))
        history.commit(state(exposure: 3.0)) // should push out the identity->1.0 step

        // Only 2 steps of past retained: exposure 1.0 and 2.0 (as "past"
        // entries), current is 3.0.
        history.undo()
        XCTAssertEqual(history.current, state(exposure: 2.0))
        history.undo()
        XCTAssertEqual(history.current, state(exposure: 1.0))
        XCTAssertFalse(history.canUndo, "the oldest step (back to identity) should have been dropped at the limit")
    }
}
