import AppKit
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
    }

    // MARK: - Tool rail

    func testRailShowsEditLooksCropInOrderAndNotTheInertCleanUp() {
        XCTAssertEqual(EditorTab.railTabs, [.adjust, .looks, .crop])
        XCTAssertEqual(EditorTab.railTabs.map(\.railTitle), ["Edit", "Looks", "Crop"])
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
