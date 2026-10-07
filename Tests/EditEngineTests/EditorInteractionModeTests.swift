import XCTest
import Foundation
@testable import PhotoApp

/// Verifies `EditorInteractionMode`'s projections and mutation helpers,
/// with particular focus on the targeted-disarm hazard its own doc comment
/// names: a blanket `.none` inside `disarmMaskModes()`/`disarmPointColorPick()`
/// would silently disarm WB/Red-Eye/each other, not just the mode it's
/// meant to touch.
final class EditorInteractionModeTests: XCTestCase {
    private let maskID = UUID()
    private let otherMaskID = UUID()
    private let pointColorID = UUID()
    private let otherPointColorID = UUID()

    // MARK: - Projections

    func testNoneProjectsAllFalseAndNil() {
        let mode = EditorInteractionMode.none

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.pointColorPickingID)
    }

    func testPickingWhiteBalanceProjectsOnlyItsOwnFlag() {
        let mode = EditorInteractionMode.pickingWhiteBalance

        XCTAssertTrue(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.pointColorPickingID)
    }

    func testPlacingRedEyeProjectsOnlyItsOwnFlag() {
        let mode = EditorInteractionMode.placingRedEye

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertTrue(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.pointColorPickingID)
    }

    func testPaintingBrushProjectsItsMaskIDOnly() {
        let mode = EditorInteractionMode.paintingBrush(maskID: maskID)

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertEqual(mode.brushPaintingMaskID, maskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.pointColorPickingID)
    }

    func testPickingColorRangeProjectsItsMaskIDOnly() {
        let mode = EditorInteractionMode.pickingColorRange(maskID: maskID)

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertEqual(mode.colorPickingMaskID, maskID)
        XCTAssertNil(mode.pointColorPickingID)
    }

    func testPickingSubjectProjectsItsMaskIDOnly() {
        let mode = EditorInteractionMode.pickingSubject(maskID: maskID)

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.pointColorPickingID)
        XCTAssertEqual(mode.subjectPickingMaskID, maskID)
        XCTAssertNil(EditorInteractionMode.pickingColorRange(maskID: maskID).subjectPickingMaskID, "same id under another case is not subject picking")
    }

    func testPickingPointColorProjectsItsInstanceIDOnly() {
        let mode = EditorInteractionMode.pickingPointColor(pointColorID: pointColorID)

        XCTAssertFalse(mode.isPickingWhiteBalance)
        XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID)
        XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertEqual(mode.pointColorPickingID, pointColorID)
    }

    // MARK: - toggle(_:)
    //
    // `toggle` is written against the whole enum (not just the 2 payload-free
    // cases it's actually called with, from the WB/Red-Eye buttons) — these
    // cases exercise the wider API its signature actually offers, not just
    // its two real call sites.

    func testToggleFromNoneArmsWhiteBalance() {
        var mode = EditorInteractionMode.none
        mode.toggle(.pickingWhiteBalance)
        XCTAssertEqual(mode, .pickingWhiteBalance)
    }

    func testToggleFromNoneArmsRedEye() {
        var mode = EditorInteractionMode.none
        mode.toggle(.placingRedEye)
        XCTAssertEqual(mode, .placingRedEye)
    }

    func testToggleTheSameArmedModeDisarms() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.toggle(.pickingWhiteBalance)
        XCTAssertEqual(mode, .none)
    }

    func testToggleRedEyeOffMirrorsWhiteBalance() {
        var mode = EditorInteractionMode.placingRedEye
        mode.toggle(.placingRedEye)
        XCTAssertEqual(mode, .none)
    }

    func testToggleADifferentModeSwitchesDirectly() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.toggle(.placingRedEye)
        XCTAssertEqual(mode, .placingRedEye)
    }

    func testToggleFromAPayloadCaseSwitchesDirectly() {
        var mode = EditorInteractionMode.paintingBrush(maskID: maskID)
        mode.toggle(.pickingWhiteBalance)
        XCTAssertEqual(mode, .pickingWhiteBalance)
    }

    // MARK: - disarm(_:)

    func testDisarmMatchingCaseAndPayloadClears() {
        var mode = EditorInteractionMode.paintingBrush(maskID: maskID)
        mode.disarm(.paintingBrush(maskID: maskID))
        XCTAssertEqual(mode, .none)
    }

    func testDisarmSameCaseDifferentPayloadIsANoOp() {
        var mode = EditorInteractionMode.paintingBrush(maskID: maskID)
        mode.disarm(.paintingBrush(maskID: otherMaskID))
        XCTAssertEqual(mode, .paintingBrush(maskID: maskID))
    }

    func testDisarmDifferentCaseIsANoOp() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.disarm(.placingRedEye)
        XCTAssertEqual(mode, .pickingWhiteBalance)
    }

    /// The case this diff's own reviewer flagged as unguarded by any
    /// existing test: the SAME `UUID` armed under a DIFFERENT case (exactly
    /// what `AdjustTabView.delete(_ mask:)` produces when it calls
    /// `disarm(.paintingBrush(id))` then `disarm(.pickingColorRange(id))`
    /// against whichever one is actually armed) must not cross-match.
    func testDisarmDoesNotCrossMatchTheSameIDUnderADifferentCase() {
        var mode = EditorInteractionMode.pickingColorRange(maskID: maskID)
        mode.disarm(.paintingBrush(maskID: maskID))
        XCTAssertEqual(mode, .pickingColorRange(maskID: maskID))
    }

    // MARK: - disarmMaskModes() — the hazard the doc comment names

    func testDisarmMaskModesClearsBrushPainting() {
        var mode = EditorInteractionMode.paintingBrush(maskID: maskID)
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .none)
    }

    func testDisarmMaskModesClearsColorRangePickingForAnyID() {
        var mode = EditorInteractionMode.pickingColorRange(maskID: otherMaskID)
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .none)
    }

    func testDisarmMaskModesClearsSubjectPickingForAnyID() {
        var mode = EditorInteractionMode.pickingSubject(maskID: otherMaskID)
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .none)
    }

    func testSubjectPickingTogglesAndSwitchesLikeTheOtherPayloadModes() {
        var mode = EditorInteractionMode.none
        mode.toggle(.pickingSubject(maskID: maskID))
        XCTAssertEqual(mode.subjectPickingMaskID, maskID)
        mode.toggle(.pickingSubject(maskID: maskID))
        XCTAssertEqual(mode, .none)
        mode.toggle(.pickingSubject(maskID: maskID))
        mode.toggle(.pickingWhiteBalance)
        XCTAssertEqual(mode, .pickingWhiteBalance, "arming another mode replaces subject picking")
        mode = .pickingSubject(maskID: maskID)
        mode.disarm(.pickingSubject(maskID: otherMaskID))
        XCTAssertEqual(mode.subjectPickingMaskID, maskID, "a disarm for a different mask is a no-op")
    }

    func testDisarmMaskModesLeavesWhiteBalanceArmed() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .pickingWhiteBalance)
    }

    func testDisarmMaskModesLeavesRedEyeArmed() {
        var mode = EditorInteractionMode.placingRedEye
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .placingRedEye)
    }

    func testDisarmMaskModesLeavesPointColorPickingArmed() {
        var mode = EditorInteractionMode.pickingPointColor(pointColorID: pointColorID)
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .pickingPointColor(pointColorID: pointColorID))
    }

    // MARK: - disarmPointColorPick() — the mirrored hazard

    func testDisarmPointColorPickClearsForAnyID() {
        var mode = EditorInteractionMode.pickingPointColor(pointColorID: otherPointColorID)
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .none)
    }

    func testDisarmPointColorPickLeavesBrushPaintingArmed() {
        var mode = EditorInteractionMode.paintingBrush(maskID: maskID)
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .paintingBrush(maskID: maskID))
    }

    func testDisarmPointColorPickLeavesColorRangePickingArmed() {
        var mode = EditorInteractionMode.pickingColorRange(maskID: maskID)
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .pickingColorRange(maskID: maskID))
    }

    func testDisarmPointColorPickLeavesWhiteBalanceArmed() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .pickingWhiteBalance)
    }

    func testDisarmPointColorPickLeavesRedEyeArmed() {
        var mode = EditorInteractionMode.placingRedEye
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .placingRedEye)
    }

    // MARK: - Place Spots (retouch)

    func testPlacingRetouchSpotProjectsOnlyItsOwnFlag() {
        let mode = EditorInteractionMode.placingRetouchSpot
        XCTAssertTrue(mode.isPlacingRetouchSpot)
        XCTAssertFalse(mode.isPickingWhiteBalance); XCTAssertFalse(mode.isPlacingRedEyeCorrections)
        XCTAssertNil(mode.brushPaintingMaskID); XCTAssertNil(mode.colorPickingMaskID)
        XCTAssertNil(mode.subjectPickingMaskID); XCTAssertNil(mode.pointColorPickingID)
        XCTAssertFalse(EditorInteractionMode.none.isPlacingRetouchSpot)
        XCTAssertFalse(EditorInteractionMode.placingRedEye.isPlacingRetouchSpot)
    }

    func testArmingPlaceSpotsReplacesAnotherToolAndTogglesOff() {
        var mode = EditorInteractionMode.pickingWhiteBalance
        mode.toggle(.placingRetouchSpot)
        XCTAssertEqual(mode, .placingRetouchSpot, "one tool at a time: arming Place Spots replaces the armed tool")
        mode.toggle(.placingRedEye)
        XCTAssertEqual(mode, .placingRedEye, "and another tool replaces it")
        mode.toggle(.placingRetouchSpot); mode.toggle(.placingRetouchSpot)
        XCTAssertEqual(mode, .none, "toggling it twice disarms")
    }

    func testMaskAndPointColorCleanupLeavePlaceSpotsArmed() {
        var mode = EditorInteractionMode.placingRetouchSpot
        mode.disarmMaskModes()
        XCTAssertEqual(mode, .placingRetouchSpot, "collapsing Masks or an undone mask must not disarm the spot tool")
        mode.disarmPointColorPick()
        XCTAssertEqual(mode, .placingRetouchSpot)
        mode.disarm(.placingRetouchSpot)
        XCTAssertEqual(mode, .none)
    }
}

