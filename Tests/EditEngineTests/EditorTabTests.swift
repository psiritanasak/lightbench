import XCTest
@testable import PhotoApp

final class EditorTabTests: XCTestCase {
    func testTabOrderAndLabels() {
        XCTAssertEqual(EditorTab.allCases, [.adjust, .looks, .crop, .cleanUp])
        XCTAssertEqual(EditorTab.allCases.map(\.label), ["Adjust", "Looks", "Crop", "Clean Up"])
    }

    func testCompareAndZoomSurviveOnlyOnAdjustAndLooks() {
        XCTAssertTrue(EditorTab.adjust.keepsCompareAndZoom)
        XCTAssertTrue(EditorTab.looks.keepsCompareAndZoom)
        XCTAssertFalse(EditorTab.crop.keepsCompareAndZoom)
        XCTAssertFalse(EditorTab.cleanUp.keepsCompareAndZoom)
    }

    func testEveryTabButAdjustDisarmsThePointModes() {
        XCTAssertFalse(EditorTab.adjust.disarmsPointModes)
        for tab in [EditorTab.looks, .crop, .cleanUp] { XCTAssertTrue(tab.disarmsPointModes, tab.label) }
    }

    /// Looks keeps the live image but must still drop an armed picker: the one combination that differs from both neighbours.
    func testLooksIsTheOnlyTabThatKeepsCompareYetDisarmsPointModes() {
        let both = EditorTab.allCases.filter { $0.keepsCompareAndZoom && $0.disarmsPointModes }
        XCTAssertEqual(both, [.looks])
    }

    /// The Looks tab opens with its two grids visible; Presets (a plain list) and the Adjust sections stay collapsed.
    func testLooksAndStyleOpenByDefaultWhileEverythingElseStaysCollapsed() {
        let panel = AdjustPanelState()
        XCTAssertTrue(panel.isLooksSectionExpanded)
        XCTAssertTrue(panel.isStyleSectionExpanded)
        XCTAssertFalse(panel.isPresetsSectionExpanded)
        XCTAssertFalse(panel.isLightSectionExpanded)
        XCTAssertFalse(panel.isHistorySectionExpanded)
    }
}
