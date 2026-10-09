import AppKit
import XCTest
@testable import PhotoApp

final class EditorTabTests: XCTestCase {
    func testTabOrderAndLabels() {
        XCTAssertEqual(EditorTab.allCases, [.adjust, .looks, .retouch, .redEye, .masks, .crop, .cleanUp])
        XCTAssertEqual(EditorTab.allCases.map(\.label), ["Adjust", "Looks", "Retouch", "Red-Eye", "Masks", "Crop", "Clean Up"])
    }

    func testCompareAndZoomSurviveEverywhereButCropAndCleanUp() {
        for tab in [EditorTab.adjust, .looks, .retouch, .redEye, .masks] { XCTAssertTrue(tab.keepsCompareAndZoom, tab.label) }
        XCTAssertFalse(EditorTab.crop.keepsCompareAndZoom)
        XCTAssertFalse(EditorTab.cleanUp.keepsCompareAndZoom)
    }

    // MARK: - Point-tool ownership (what a tab switch does to armed modes and selections)

    private let allModes: [EditorInteractionMode] = [
        .none, .pickingWhiteBalance, .placingRedEye, .paintingBrush(maskID: UUID()), .pickingColorRange(maskID: UUID()),
        .pickingPointColor(pointColorID: UUID()), .pickingSubject(maskID: UUID()), .placingRetouchSpot,
    ]

    func testEachModeIsOwnedByExactlyTheTabWhoseControlsArmIt() {
        XCTAssertNil(EditorInteractionMode.none.ownerTab)
        XCTAssertEqual(EditorInteractionMode.pickingWhiteBalance.ownerTab, .adjust)
        XCTAssertEqual(EditorInteractionMode.pickingPointColor(pointColorID: UUID()).ownerTab, .adjust)
        XCTAssertEqual(EditorInteractionMode.placingRedEye.ownerTab, .redEye)
        XCTAssertEqual(EditorInteractionMode.placingRetouchSpot.ownerTab, .retouch)
        XCTAssertEqual(EditorInteractionMode.paintingBrush(maskID: UUID()).ownerTab, .masks)
        XCTAssertEqual(EditorInteractionMode.pickingColorRange(maskID: UUID()).ownerTab, .masks)
        XCTAssertEqual(EditorInteractionMode.pickingSubject(maskID: UUID()).ownerTab, .masks)
    }

    /// Every mode x every tab: an armed mode survives a switch ONLY to its owner tab (and `.none` never "disarms").
    func testLiteralSwitchCases() {
        XCTAssertTrue(EditorTab.masks.switchEffects(armed: .placingRetouchSpot).disarmsMode)
        XCTAssertFalse(EditorTab.retouch.switchEffects(armed: .placingRetouchSpot).disarmsMode)
        XCTAssertTrue(EditorTab.adjust.switchEffects(armed: .placingRedEye).disarmsMode)
        XCTAssertFalse(EditorTab.redEye.switchEffects(armed: .placingRedEye).disarmsMode)
        XCTAssertFalse(EditorTab.adjust.switchEffects(armed: .pickingWhiteBalance).disarmsMode)
        XCTAssertTrue(EditorTab.masks.switchEffects(armed: .pickingWhiteBalance).disarmsMode)
    }

    func testAModeSurvivesOnlyASwitchToItsOwnerTab() {
        for mode in allModes {
            for tab in EditorTab.allCases {
                let expectedDisarm = mode.ownerTab != nil && mode.ownerTab != tab
                XCTAssertEqual(tab.switchEffects(armed: mode).disarmsMode, expectedDisarm, "\(mode) -> \(tab.label)")
            }
        }
    }

    func testEachSelectionIsKeptOnlyByItsOwnerTab() {
        for tab in EditorTab.allCases {
            let e = tab.switchEffects(armed: .none)
            XCTAssertEqual(e.clearsMaskSelection, tab != .masks, tab.label)
            XCTAssertEqual(e.clearsPointColorSelection, tab != .adjust, tab.label)
            XCTAssertEqual(e.clearsRetouchSelection, tab != .retouch, tab.label)
        }
    }

    /// Behaviour of the tabs that exist on the rail today is unchanged: leaving for Looks or Crop clears every selection and
    /// disarms every armed mode, exactly as `disarmsPointModes` did.
    func testLooksAndCropStillClearEverything() {
        for tab in [EditorTab.looks, .crop, .cleanUp] {
            for mode in allModes where mode != .none {
                XCTAssertTrue(tab.switchEffects(armed: mode).disarmsMode, "\(mode) -> \(tab.label)")
            }
            XCTAssertEqual(tab.switchEffects(armed: .none), EditorTab.SwitchEffects(
                disarmsMode: false, clearsMaskSelection: true, clearsPointColorSelection: true, clearsRetouchSelection: true))
        }
    }

    /// The Looks tab opens with its two grids visible; Presets (a plain list) and the Adjust sections stay collapsed.
    func testLooksAndStyleOpenByDefaultWhileEverythingElseStaysCollapsed() {
        let panel = AdjustPanelState()
        XCTAssertTrue(panel.isLooksSectionExpanded)
        XCTAssertTrue(panel.isStyleSectionExpanded)
        XCTAssertFalse(panel.isPresetsSectionExpanded)
        XCTAssertFalse(panel.isLightSectionExpanded)
    }

    // MARK: - Tool rail

    func testRailShowsTheToolsInOrderAndNotTheInertCleanUp() {
        XCTAssertEqual(EditorTab.railTabs, [.adjust, .looks, .retouch, .redEye, .masks, .crop])
        XCTAssertEqual(EditorTab.railTabs.map(\.railTitle), ["Edit", "Looks", "Retouch", "Red-eye", "Masks", "Crop"])
        XCTAssertFalse(EditorTab.railTabs.contains(.cleanUp))
    }

    func testRailSymbolsAreDistinctAndRealSystemSymbols() {
        let symbols = EditorTab.allCases.map(\.railSymbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "each tab needs its own icon")
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    /// The rail is a pure relocation: the tab's own label and every tab-change rule are untouched.
    func testRailTitlesDoNotReplaceTheTabLabels() {
        XCTAssertEqual(EditorTab.adjust.label, "Adjust")
        XCTAssertEqual(EditorTab.adjust.railTitle, "Edit")
    }
}
