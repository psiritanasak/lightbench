import XCTest
@testable import PhotoApp

final class EditorRailActionRulesTests: XCTestCase {
    func testRevertNeedsAnImageAndARealEdit() {
        XCTAssertTrue(EditorRailActionRules.canRevert(hasImage: true, isEffectivelyIdentity: false))
        XCTAssertFalse(EditorRailActionRules.canRevert(hasImage: true, isEffectivelyIdentity: true))
        XCTAssertFalse(EditorRailActionRules.canRevert(hasImage: false, isEffectivelyIdentity: false))
    }

    func testEnhanceIsBlockedByEachInFlightOperation() {
        XCTAssertTrue(EditorRailActionRules.canEnhance(hasImage: true, isLoadInFlight: false, isEnhancing: false, isRenameWorking: false))
        XCTAssertFalse(EditorRailActionRules.canEnhance(hasImage: false, isLoadInFlight: false, isEnhancing: false, isRenameWorking: false))
        XCTAssertFalse(EditorRailActionRules.canEnhance(hasImage: true, isLoadInFlight: true, isEnhancing: false, isRenameWorking: false))
        XCTAssertFalse(EditorRailActionRules.canEnhance(hasImage: true, isLoadInFlight: false, isEnhancing: true, isRenameWorking: false))
        XCTAssertFalse(EditorRailActionRules.canEnhance(hasImage: true, isLoadInFlight: false, isEnhancing: false, isRenameWorking: true))
    }

    func testCompareNeedsAnImageAndNotCropping() {
        let none = EditorRailActionRules.ArmedModes()
        XCTAssertTrue(EditorRailActionRules.canCompare(hasImage: true, isCropping: false, armed: none))
        XCTAssertFalse(EditorRailActionRules.canCompare(hasImage: false, isCropping: false, armed: none))
        XCTAssertFalse(EditorRailActionRules.canCompare(hasImage: true, isCropping: true, armed: none))
    }

    /// Every armed point mode blocks Compare on its own.
    func testEachArmedModeBlocksCompare() {
        var cases: [(String, EditorRailActionRules.ArmedModes)] = []
        var m = EditorRailActionRules.ArmedModes(); m.whiteBalance = true; cases.append(("whiteBalance", m))
        m = EditorRailActionRules.ArmedModes(); m.redEye = true; cases.append(("redEye", m))
        m = EditorRailActionRules.ArmedModes(); m.colorRange = true; cases.append(("colorRange", m))
        m = EditorRailActionRules.ArmedModes(); m.pointColor = true; cases.append(("pointColor", m))
        m = EditorRailActionRules.ArmedModes(); m.subject = true; cases.append(("subject", m))
        m = EditorRailActionRules.ArmedModes(); m.retouchSpot = true; cases.append(("retouchSpot", m))
        for (name, armed) in cases {
            XCTAssertTrue(armed.any, name)
            XCTAssertFalse(EditorRailActionRules.canCompare(hasImage: true, isCropping: false, armed: armed), name)
        }
        XCTAssertFalse(EditorRailActionRules.ArmedModes().any)
    }

    func testHistoryNeedsAnImage() {
        XCTAssertTrue(EditorRailActionRules.canShowHistory(hasImage: true))
        XCTAssertFalse(EditorRailActionRules.canShowHistory(hasImage: false))
    }
}
